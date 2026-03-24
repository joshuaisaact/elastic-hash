#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <vector>
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
constexpr int TOTAL_RUNS = 12;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;

struct BenchResult {
    uint64_t insert_us;
    uint64_t lookup_us;
    uint64_t delete_us;
    uint64_t miss_us;
};

static uint64_t median(uint64_t* arr, int n) {
    std::sort(arr, arr + n);
    return arr[n / 2];
}

static BenchResult bench(size_t n, size_t fill) {
    // Pre-generate keys (same for every run)
    std::vector<uint64_t> keys(fill), miss_keys(fill);
    uint64_t ks = KEY_SEED, ms = MISS_SEED;
    for (size_t i = 0; i < fill; i++) {
        keys[i] = splitmix64(ks);
        miss_keys[i] = splitmix64(ms);
    }

    uint64_t ins[MEASURED], lkp[MEASURED], del[MEASURED], mis[MEASURED];

    for (int r = 0; r < TOTAL_RUNS; r++) {
        absl::flat_hash_map<uint64_t, uint64_t> map;
        map.reserve(n);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            map.emplace(keys[i], i);
        }
        auto end = std::chrono::steady_clock::now();
        uint64_t insert_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            auto it = map.find(keys[i]);
            do_not_optimize(it->second);
        }
        end = std::chrono::steady_clock::now();
        uint64_t lookup_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            auto it = map.find(miss_keys[i]);
            do_not_optimize(it == map.end());
        }
        end = std::chrono::steady_clock::now();
        uint64_t miss_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill / 2; i++) {
            auto it = map.find(keys[i]);
            if (it != map.end()) map.erase(it);
        }
        end = std::chrono::steady_clock::now();
        uint64_t delete_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        if (r >= WARMUP) {
            int idx = r - WARMUP;
            ins[idx] = insert_us;
            lkp[idx] = lookup_us;
            del[idx] = delete_us;
            mis[idx] = miss_us;
        }
    }

    return {median(ins, MEASURED), median(lkp, MEASURED),
            median(del, MEASURED), median(mis, MEASURED)};
}

int main() {
    constexpr size_t sizes[] = {16384, 65536, 262144, 1048576, 2097152};
    constexpr int load_pcts[] = {10, 25, 50, 75, 90};

    fprintf(stderr, "\n=== Abseil flat_hash_map Benchmark (median of %d, %d warmup) ===\n\n",
            MEASURED, WARMUP);

    // All sizes at 99% load
    for (size_t n : sizes) {
        size_t fill = n * 99 / 100;
        auto r = bench(n, fill);
        printf("RESULT\tn=%zu\tload=99\tinsert_us=%lu\tlookup_us=%lu\tdelete_us=%lu\tmiss_us=%lu\n",
               n, r.insert_us, r.lookup_us, r.delete_us, r.miss_us);
        fflush(stdout);
    }

    // Multiple load factors at 1M
    constexpr size_t n = 1048576;
    for (int pct : load_pcts) {
        size_t fill = n * pct / 100;
        auto r = bench(n, fill);
        printf("RESULT\tn=%zu\tload=%d\tinsert_us=%lu\tlookup_us=%lu\tdelete_us=%lu\tmiss_us=%lu\n",
               n, pct, r.insert_us, r.lookup_us, r.delete_us, r.miss_us);
        fflush(stdout);
    }

    fprintf(stderr, "\nDONE\n");
    return 0;
}
