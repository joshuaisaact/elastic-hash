// Realistic workload benchmarks for abseil flat_hash_map
// Tests patterns that mirror actual production hash table usage
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <vector>
#include <random>
#include "absl/container/flat_hash_map.h"

template <typename T>
inline void do_not_optimize(T const& val) {
    asm volatile("" : : "r,m"(val) : "memory");
}

static uint64_t splitmix64(uint64_t& state) {
    state += 0x9e3779b97f4a7c15;
    uint64_t z = state;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

constexpr int RUNS = 8;
constexpr int WARMUP = 2;
constexpr int MEASURED = RUNS - WARMUP;

static uint64_t median(uint64_t* arr, int n) {
    std::sort(arr, arr + n);
    return arr[n / 2];
}

// Workload 1: Mixed read/write (90% lookup, 5% insert, 5% delete)
// Simulates a cache or index under steady-state load
static void bench_mixed(size_t initial_size) {
    constexpr size_t OPS = 1000000;
    uint64_t times[MEASURED];

    // Pre-generate keys
    uint64_t ks = 0xDEADBEEF12345678;
    std::vector<uint64_t> initial_keys(initial_size);
    for (size_t i = 0; i < initial_size; i++) initial_keys[i] = splitmix64(ks);

    // Pre-generate operation keys (some exist, some don't)
    std::vector<uint64_t> op_keys(OPS);
    std::vector<int> op_types(OPS); // 0=lookup_hit, 1=lookup_miss, 2=insert, 3=delete
    std::mt19937_64 rng(12345);
    for (size_t i = 0; i < OPS; i++) {
        int r = rng() % 100;
        if (r < 80) { // 80% hit lookup
            op_types[i] = 0;
            op_keys[i] = initial_keys[rng() % initial_size];
        } else if (r < 90) { // 10% miss lookup
            op_types[i] = 1;
            op_keys[i] = splitmix64(ks); // very unlikely to be in table
        } else if (r < 95) { // 5% insert
            op_types[i] = 2;
            op_keys[i] = splitmix64(ks);
        } else { // 5% delete
            op_types[i] = 3;
            op_keys[i] = initial_keys[rng() % initial_size];
        }
    }

    for (int r = 0; r < RUNS; r++) {
        absl::flat_hash_map<uint64_t, uint64_t> map;
        map.reserve(initial_size * 2); // typical: reserve 2x expected
        for (size_t i = 0; i < initial_size; i++) map.emplace(initial_keys[i], i);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < OPS; i++) {
            switch (op_types[i]) {
                case 0: { // hit lookup
                    auto it = map.find(op_keys[i]);
                    do_not_optimize(it != map.end() ? it->second : 0);
                    break;
                }
                case 1: { // miss lookup
                    auto it = map.find(op_keys[i]);
                    do_not_optimize(it == map.end());
                    break;
                }
                case 2: // insert
                    map.emplace(op_keys[i], i);
                    break;
                case 3: { // delete
                    auto it = map.find(op_keys[i]);
                    if (it != map.end()) map.erase(it);
                    break;
                }
            }
        }
        auto end = std::chrono::steady_clock::now();

        if (r >= WARMUP)
            times[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    }

    printf("ABSEIL\tmixed_rw\tn=%zu\tops=%zu\tus=%lu\n",
           initial_size, OPS, median(times, MEASURED));
}

// Workload 2: Hot-key lookup (zipf-like: 20% of keys get 80% of lookups)
static void bench_hotkey(size_t n) {
    constexpr size_t OPS = 1000000;
    uint64_t times[MEASURED];

    uint64_t ks = 0xDEADBEEF12345678;
    std::vector<uint64_t> keys(n);
    for (size_t i = 0; i < n; i++) keys[i] = splitmix64(ks);

    // Generate zipf-like access pattern: 80% of lookups hit first 20% of keys
    std::vector<uint64_t> lookup_keys(OPS);
    std::mt19937_64 rng(42);
    size_t hot_count = n / 5; // top 20%
    for (size_t i = 0; i < OPS; i++) {
        if (rng() % 100 < 80) {
            lookup_keys[i] = keys[rng() % hot_count]; // hot key
        } else {
            lookup_keys[i] = keys[rng() % n]; // any key
        }
    }

    for (int r = 0; r < RUNS; r++) {
        absl::flat_hash_map<uint64_t, uint64_t> map;
        map.reserve(n);
        for (size_t i = 0; i < n; i++) map.emplace(keys[i], i);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < OPS; i++) {
            auto it = map.find(lookup_keys[i]);
            do_not_optimize(it->second);
        }
        auto end = std::chrono::steady_clock::now();

        if (r >= WARMUP)
            times[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    }

    printf("ABSEIL\thotkey\tn=%zu\tops=%zu\tus=%lu\n",
           n, OPS, median(times, MEASURED));
}

// Workload 3: Build-then-read (insert N elements, then do 10N lookups)
// Simulates building an index then serving queries
static void bench_build_read(size_t n) {
    constexpr size_t READ_MULT = 10;
    uint64_t build_times[MEASURED], read_times[MEASURED];

    uint64_t ks = 0xDEADBEEF12345678;
    std::vector<uint64_t> keys(n);
    for (size_t i = 0; i < n; i++) keys[i] = splitmix64(ks);

    // Random read order
    std::vector<size_t> read_order(n * READ_MULT);
    std::mt19937_64 rng(99);
    for (size_t i = 0; i < n * READ_MULT; i++) read_order[i] = rng() % n;

    for (int r = 0; r < RUNS; r++) {
        absl::flat_hash_map<uint64_t, uint64_t> map;
        map.reserve(n);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < n; i++) map.emplace(keys[i], i);
        auto end = std::chrono::steady_clock::now();

        if (r >= WARMUP)
            build_times[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < n * READ_MULT; i++) {
            auto it = map.find(keys[read_order[i]]);
            do_not_optimize(it->second);
        }
        end = std::chrono::steady_clock::now();

        if (r >= WARMUP)
            read_times[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    }

    printf("ABSEIL\tbuild_read\tn=%zu\tbuild_us=%lu\tread_us=%lu\n",
           n, median(build_times, MEASURED), median(read_times, MEASURED));
}

int main() {
    printf("=== Realistic workload benchmarks (abseil) ===\n\n");

    // Mixed read/write at different table sizes
    for (size_t n : {100000, 500000, 1000000}) {
        bench_mixed(n);
    }

    // Hot-key lookup
    for (size_t n : {100000, 500000, 1000000}) {
        bench_hotkey(n);
    }

    // Build-then-read
    for (size_t n : {100000, 500000, 1000000}) {
        bench_build_read(n);
    }

    return 0;
}
