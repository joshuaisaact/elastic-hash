// Verification benchmark: shuffled lookup order + multiple sizes + capacity checks
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

constexpr uint64_t KEY_SEED = 0xDEADBEEF12345678;
constexpr int TOTAL_RUNS = 12;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;

static uint64_t median(uint64_t* arr, int n) {
    std::sort(arr, arr + n);
    return arr[n / 2];
}

static void bench(size_t n, size_t fill, const char* label) {
    std::vector<uint64_t> keys(fill);
    uint64_t ks = KEY_SEED;
    for (size_t i = 0; i < fill; i++) keys[i] = splitmix64(ks);

    // Shuffled lookup order (Fisher-Yates with fixed seed for reproducibility)
    std::vector<size_t> lookup_order(fill);
    for (size_t i = 0; i < fill; i++) lookup_order[i] = i;
    std::mt19937_64 rng(42);
    for (size_t i = fill - 1; i > 0; i--) {
        size_t j = rng() % (i + 1);
        std::swap(lookup_order[i], lookup_order[j]);
    }

    uint64_t lkp_ordered[MEASURED], lkp_shuffled[MEASURED];

    for (int r = 0; r < TOTAL_RUNS; r++) {
        absl::flat_hash_map<uint64_t, uint64_t> map;
        map.reserve(n);
        for (size_t i = 0; i < fill; i++) map.emplace(keys[i], i);

        // Ordered lookup (same as main benchmark)
        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            auto it = map.find(keys[i]);
            do_not_optimize(it->second);
        }
        auto end = std::chrono::steady_clock::now();
        uint64_t ordered_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        // Shuffled lookup
        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            auto it = map.find(keys[lookup_order[i]]);
            do_not_optimize(it->second);
        }
        end = std::chrono::steady_clock::now();
        uint64_t shuffled_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        if (r >= WARMUP) {
            int idx = r - WARMUP;
            lkp_ordered[idx] = ordered_us;
            lkp_shuffled[idx] = shuffled_us;
        }
    }

    printf("ABSEIL\t%s\tn=%zu\tload=%zu\tordered_us=%lu\tshuffled_us=%lu\n",
           label, n, fill * 100 / n,
           median(lkp_ordered, MEASURED), median(lkp_shuffled, MEASURED));
    fflush(stdout);
}

int main() {
    printf("=== Abseil verification: ordered vs shuffled lookup ===\n\n");

    // Multiple sizes at 50% load
    constexpr size_t sizes[] = {65536, 262144, 1048576, 4194304};
    for (size_t n : sizes) {
        bench(n, n / 2, "50pct");
    }

    // 1M at multiple loads
    constexpr int pcts[] = {10, 25, 50, 75, 90, 99};
    for (int pct : pcts) {
        bench(1048576, 1048576 * pct / 100, "1M");
    }

    return 0;
}
