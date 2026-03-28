#include <cstdint>
#include <cstdio>
#include <chrono>
#include "absl/container/flat_hash_map.h"
#include "absl/hash/hash.h"

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

// Our hash function (same as in hybrid.zig)
inline uint64_t elastic_hash(uint64_t key) {
    uint64_t h = key * 0x517cc1b727220a95ULL;
    return h ^ (h >> 32);
}

int main() {
    constexpr size_t N = 10000000; // 10M hashes
    constexpr int RUNS = 10;

    uint64_t keys[1024];
    uint64_t ks = 0xDEADBEEF12345678;
    for (int i = 0; i < 1024; i++) keys[i] = splitmix64(ks);

    // Time our hash
    uint64_t best_ours = UINT64_MAX;
    for (int r = 0; r < RUNS; r++) {
        auto start = std::chrono::steady_clock::now();
        uint64_t acc = 0;
        for (size_t i = 0; i < N; i++) {
            acc += elastic_hash(keys[i & 1023]);
        }
        auto end = std::chrono::steady_clock::now();
        do_not_optimize(acc);
        uint64_t us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
        if (us < best_ours) best_ours = us;
    }

    // Time abseil hash
    absl::Hash<uint64_t> abseil_hasher;
    uint64_t best_abseil = UINT64_MAX;
    for (int r = 0; r < RUNS; r++) {
        auto start = std::chrono::steady_clock::now();
        uint64_t acc = 0;
        for (size_t i = 0; i < N; i++) {
            acc += abseil_hasher(keys[i & 1023]);
        }
        auto end = std::chrono::steady_clock::now();
        do_not_optimize(acc);
        uint64_t us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
        if (us < best_abseil) best_abseil = us;
    }

    printf("Hash function cost (10M u64 hashes, best of %d runs):\n", RUNS);
    printf("  Elastic (multiply+xor-shift): %lu us (%.1f ns/hash)\n",
           best_ours, best_ours * 1000.0 / N);
    printf("  Abseil (absl::Hash<u64>):     %lu us (%.1f ns/hash)\n",
           best_abseil, best_abseil * 1000.0 / N);
    printf("  Ratio (abseil/elastic):       %.2fx\n",
           (double)best_abseil / best_ours);

    return 0;
}
