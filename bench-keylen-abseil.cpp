// Variable key length benchmark for abseil flat_hash_map.
#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <chrono>
#include <vector>
#include <string>
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
constexpr int TOTAL_RUNS = 10;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;
constexpr size_t N = 1048576;
constexpr size_t FILL = N / 2;

static const char hex_chars[] = "0123456789abcdef";

static void fill_hex(uint64_t val, char* buf, size_t len) {
    uint64_t v = val;
    for (size_t i = 0; i < len; i++) {
        if (i % 16 == 0 && i > 0) v = v * 0x9e3779b97f4a7c15;
        buf[i] = hex_chars[v & 0xF];
        v >>= 4;
        if (v == 0) v = val * (i + 1);
    }
}

static uint64_t median_val(uint64_t* arr, int n) {
    std::sort(arr, arr + n);
    return arr[n / 2];
}

static void bench_keylen(size_t key_len) {
    // Generate keys
    std::vector<std::string> keys(FILL);
    std::vector<std::string> miss_keys(FILL);
    uint64_t ks = KEY_SEED;
    uint64_t ms = MISS_SEED;
    for (size_t i = 0; i < FILL; i++) {
        keys[i].resize(key_len);
        miss_keys[i].resize(key_len);
        fill_hex(splitmix64(ks), keys[i].data(), key_len);
        fill_hex(splitmix64(ms), miss_keys[i].data(), key_len);
    }

    // Shuffle orders
    std::vector<size_t> hit_order(FILL), miss_order(FILL);
    for (size_t i = 0; i < FILL; i++) { hit_order[i] = i; miss_order[i] = i; }
    uint64_t rng1 = 42, rng2 = 99;
    for (size_t i = FILL - 1; i > 0; i--) {
        size_t j = splitmix64(rng1) % (i + 1);
        std::swap(hit_order[i], hit_order[j]);
        j = splitmix64(rng2) % (i + 1);
        std::swap(miss_order[i], miss_order[j]);
    }

    uint64_t hit_times[MEASURED], miss_times[MEASURED];

    for (int r = 0; r < TOTAL_RUNS; r++) {
        absl::flat_hash_map<std::string_view, uint64_t> map;
        map.reserve(N);
        for (size_t i = 0; i < FILL; i++)
            map.emplace(std::string_view(keys[i]), i);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < FILL; i++) {
            auto it = map.find(std::string_view(keys[hit_order[i]]));
            do_not_optimize(it->second);
        }
        auto end = std::chrono::steady_clock::now();
        uint64_t hit_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < FILL; i++) {
            auto it = map.find(std::string_view(miss_keys[miss_order[i]]));
            do_not_optimize(it);
        }
        end = std::chrono::steady_clock::now();
        uint64_t miss_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        if (r >= WARMUP) {
            hit_times[r - WARMUP] = hit_us;
            miss_times[r - WARMUP] = miss_us;
        }
    }

    printf("KEYLEN\tlen=%zu\thit_shuffled=%llu\tmiss_shuffled=%llu\n",
           key_len, median_val(hit_times, MEASURED), median_val(miss_times, MEASURED));
}

int main() {
    printf("=== Abseil Variable Key Length (n=%zu, 50%% load, shuffled) ===\n\n", N);
    size_t lens[] = {8, 16, 32, 64, 128, 256};
    for (size_t kl : lens) bench_keylen(kl);
    printf("\nDONE\n");
    return 0;
}
