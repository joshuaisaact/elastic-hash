// Shuffled vs ordered string key lookup comparison
#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <chrono>
#include <vector>
#include <random>
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
constexpr int TOTAL_RUNS = 12;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;
constexpr size_t KEY_LEN = 16;
static const char hex_chars[] = "0123456789abcdef";

static void u64_to_hex(uint64_t val, char* buf) {
    for (int i = KEY_LEN - 1; i >= 0; i--) { buf[i] = hex_chars[val & 0xF]; val >>= 4; }
}

static uint64_t median_val(uint64_t* arr, int n) {
    std::sort(arr, arr + n);
    return arr[n / 2];
}

static void bench(size_t n, size_t fill, int load_pct) {
    std::vector<char> key_buf(fill * KEY_LEN);
    uint64_t ks = KEY_SEED;
    for (size_t i = 0; i < fill; i++) u64_to_hex(splitmix64(ks), &key_buf[i * KEY_LEN]);

    std::vector<std::string_view> keys(fill);
    for (size_t i = 0; i < fill; i++) keys[i] = std::string_view(&key_buf[i * KEY_LEN], KEY_LEN);

    std::vector<size_t> shuffle_order(fill);
    for (size_t i = 0; i < fill; i++) shuffle_order[i] = i;
    std::mt19937_64 rng(42);
    for (size_t i = fill - 1; i > 0; i--) { size_t j = rng() % (i + 1); std::swap(shuffle_order[i], shuffle_order[j]); }

    uint64_t lkp_ordered[MEASURED], lkp_shuffled[MEASURED];

    for (int r = 0; r < TOTAL_RUNS; r++) {
        absl::flat_hash_map<std::string_view, uint64_t> map;
        map.reserve(n);
        for (size_t i = 0; i < fill; i++) map.emplace(keys[i], i);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) { auto it = map.find(keys[i]); do_not_optimize(it->second); }
        auto end = std::chrono::steady_clock::now();
        uint64_t ordered_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) { auto it = map.find(keys[shuffle_order[i]]); do_not_optimize(it->second); }
        end = std::chrono::steady_clock::now();
        uint64_t shuffled_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        if (r >= WARMUP) { int idx = r - WARMUP; lkp_ordered[idx] = ordered_us; lkp_shuffled[idx] = shuffled_us; }
    }

    printf("ABSEIL\tn=%zu\tload=%d\tordered=%lu\tshuffled=%lu\n",
           n, load_pct, median_val(lkp_ordered, MEASURED), median_val(lkp_shuffled, MEASURED));
    fflush(stdout);
}

int main() {
    // Load factor sweep at 1M
    constexpr int pcts[] = {10, 25, 50, 75, 90, 99};
    for (int pct : pcts) bench(1048576, 1048576 * pct / 100, pct);
    // Size sweep at 50% load
    constexpr size_t sizes[] = {16384, 65536, 262144, 1048576, 4194304};
    for (size_t s : sizes) bench(s, s / 2, 50);
    return 0;
}
