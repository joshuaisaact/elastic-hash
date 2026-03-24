// Mixed workload benchmark for abseil flat_hash_map.
// Same operation distribution as autobench-mixed.zig:
// 40% hit, 40% miss, 10% insert, 10% delete.
#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <chrono>
#include <vector>
#include <string_view>
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

constexpr uint64_t KEY_SEED = 0xDEADBEEF12345678;
constexpr uint64_t MISS_SEED = 0xCAFEBABE87654321;
constexpr uint64_t OP_SEED = 0x1234ABCD5678EF01;
constexpr int TOTAL_RUNS = 8;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;
constexpr size_t KEY_LEN = 16;
constexpr size_t N = 1048576;
constexpr size_t OPS_PER_RUN = 1000000;

static const char hex_chars[] = "0123456789abcdef";

static void u64_to_hex(uint64_t val, char* buf) {
    for (int i = KEY_LEN - 1; i >= 0; i--) {
        buf[i] = hex_chars[val & 0xF];
        val >>= 4;
    }
}

static uint64_t median_val(uint64_t* arr, int n) {
    std::sort(arr, arr + n);
    return arr[n / 2];
}

int main() {
    printf("=== Abseil Mixed Workload Benchmark ===\n");
    printf("=== %zu ops per run, 40%% hit / 40%% miss / 10%% insert / 10%% delete ===\n", OPS_PER_RUN);

    // Pre-generate key pool
    size_t key_pool_size = N * 2;
    std::vector<char> key_pool_buf(key_pool_size * KEY_LEN);
    uint64_t ks = KEY_SEED;
    for (size_t i = 0; i < key_pool_size; i++)
        u64_to_hex(splitmix64(ks), &key_pool_buf[i * KEY_LEN]);

    std::vector<std::string_view> key_pool(key_pool_size);
    for (size_t i = 0; i < key_pool_size; i++)
        key_pool[i] = std::string_view(&key_pool_buf[i * KEY_LEN], KEY_LEN);

    // Miss keys
    std::vector<char> miss_buf(OPS_PER_RUN * KEY_LEN);
    uint64_t ms = MISS_SEED;
    for (size_t i = 0; i < OPS_PER_RUN; i++)
        u64_to_hex(splitmix64(ms), &miss_buf[i * KEY_LEN]);

    std::vector<std::string_view> miss_keys(OPS_PER_RUN);
    for (size_t i = 0; i < OPS_PER_RUN; i++)
        miss_keys[i] = std::string_view(&miss_buf[i * KEY_LEN], KEY_LEN);

    // Operation sequence
    std::vector<uint8_t> ops(OPS_PER_RUN);
    uint64_t op_rng = OP_SEED;
    for (size_t i = 0; i < OPS_PER_RUN; i++)
        ops[i] = splitmix64(op_rng) % 10;

    // Random indices
    std::vector<uint64_t> rand_indices(OPS_PER_RUN);
    uint64_t idx_rng = 0xFEDCBA9876543210;
    for (size_t i = 0; i < OPS_PER_RUN; i++)
        rand_indices[i] = splitmix64(idx_rng);

    int load_pcts[] = {25, 50, 75};

    for (int pct : load_pcts) {
        size_t fill = N * pct / 100;
        uint64_t times[MEASURED];

        for (int r = 0; r < TOTAL_RUNS; r++) {
            absl::flat_hash_map<std::string_view, uint64_t> map;
            map.reserve(N);

            for (size_t i = 0; i < fill; i++)
                map.emplace(key_pool[i], i);

            size_t live_count = fill;
            size_t next_insert = fill;
            size_t miss_idx = 0;

            auto start = std::chrono::steady_clock::now();

            for (size_t i = 0; i < OPS_PER_RUN; i++) {
                uint8_t op = ops[i];
                if (op < 4) {
                    if (live_count > 0) {
                        size_t ki = rand_indices[i] % live_count;
                        auto it = map.find(key_pool[ki]);
                        if (it != map.end()) do_not_optimize(it->second);
                    }
                } else if (op < 8) {
                    auto it = map.find(miss_keys[miss_idx % OPS_PER_RUN]);
                    do_not_optimize(it);
                    miss_idx++;
                } else if (op == 8) {
                    if (next_insert < key_pool_size) {
                        map.emplace(key_pool[next_insert], next_insert);
                        next_insert++;
                        live_count++;
                    }
                } else {
                    if (live_count > 0) {
                        size_t ki = rand_indices[i] % live_count;
                        map.erase(key_pool[ki]);
                    }
                }
            }

            auto end = std::chrono::steady_clock::now();
            uint64_t total_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

            if (r >= WARMUP) {
                times[r - WARMUP] = total_us;
            }
        }

        uint64_t med = median_val(times, MEASURED);
        uint64_t ops_sec = OPS_PER_RUN * 1000000ULL / med;
        printf("MIXED\tload=%d\ttotal_us=%llu\tops_per_sec=%llu\n", pct, med, ops_sec);
    }

    printf("\nDONE\n");
    return 0;
}
