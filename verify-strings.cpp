// Comprehensive string key verification for abseil
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <chrono>
#include <vector>
#include <string>
#include <string_view>
#include <random>
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

constexpr uint64_t KEY_SEED = 0xDEADBEEF12345678;
constexpr int TOTAL_RUNS = 12;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;
static const char hex_chars[] = "0123456789abcdef";

static void gen_hex_key(uint64_t val, char* buf, size_t len) {
    // Fill with hex from splitmix64 values, repeating if needed
    for (size_t i = 0; i < len; i++) {
        buf[i] = hex_chars[(val >> ((i % 16) * 4)) & 0xF];
        if (i % 16 == 15) val = val * 0x517cc1b727220a95 + i; // mix for longer keys
    }
}

static uint64_t median_val(uint64_t* arr, int n) {
    std::sort(arr, arr + n);
    return arr[n / 2];
}

// Test 1: Hash function cost for strings
static void test_hash_cost() {
    printf("=== Test 1: Hash function cost (16-byte strings) ===\n");
    constexpr size_t N = 10000000;
    char keys[1024][16];
    uint64_t ks = KEY_SEED;
    for (int i = 0; i < 1024; i++) {
        uint64_t v = splitmix64(ks);
        for (int j = 15; j >= 0; j--) { keys[i][j] = hex_chars[v & 0xF]; v >>= 4; }
    }

    absl::Hash<std::string_view> hasher;
    uint64_t best = UINT64_MAX;
    for (int r = 0; r < 10; r++) {
        auto start = std::chrono::steady_clock::now();
        uint64_t acc = 0;
        for (size_t i = 0; i < N; i++) {
            acc += hasher(std::string_view(keys[i & 1023], 16));
        }
        auto end = std::chrono::steady_clock::now();
        do_not_optimize(acc);
        uint64_t us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
        if (us < best) best = us;
    }
    printf("  absl::Hash<string_view>(16B): %lu us (%.1f ns/hash)\n\n", best, best * 1000.0 / N);
}

// Test 2: Variable key lengths (shuffled lookup, 1M at 50% load)
static void test_variable_lengths() {
    printf("=== Test 2: Variable key lengths (1M, 50%% load, shuffled) ===\n");
    constexpr size_t n = 1048576;
    constexpr size_t fill = n / 2;
    constexpr size_t key_lens[] = {8, 16, 32, 64, 128, 256};

    for (size_t klen : key_lens) {
        std::vector<char> key_buf(fill * klen);
        uint64_t ks = KEY_SEED;
        for (size_t i = 0; i < fill; i++) {
            gen_hex_key(splitmix64(ks), &key_buf[i * klen], klen);
        }

        std::vector<std::string_view> keys(fill);
        for (size_t i = 0; i < fill; i++)
            keys[i] = std::string_view(&key_buf[i * klen], klen);

        // Shuffle
        std::vector<size_t> order(fill);
        for (size_t i = 0; i < fill; i++) order[i] = i;
        std::mt19937_64 rng(42);
        for (size_t i = fill - 1; i > 0; i--) { size_t j = rng() % (i + 1); std::swap(order[i], order[j]); }

        uint64_t times[MEASURED];
        for (int r = 0; r < TOTAL_RUNS; r++) {
            absl::flat_hash_map<std::string_view, uint64_t> map;
            map.reserve(n);
            for (size_t i = 0; i < fill; i++) map.emplace(keys[i], i);

            auto start = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) {
                auto it = map.find(keys[order[i]]);
                do_not_optimize(it->second);
            }
            auto end = std::chrono::steady_clock::now();
            if (r >= WARMUP)
                times[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
        }
        printf("  klen=%3zu: %lu us\n", klen, median_val(times, MEASURED));
    }
    printf("\n");
}

// Test 3: Multiple table sizes at 50% load, shuffled, 16-byte keys
static void test_sizes() {
    printf("=== Test 3: Table sizes (50%% load, shuffled, 16B keys) ===\n");
    constexpr size_t sizes[] = {100000, 500000, 1000000, 2000000, 4000000};

    for (size_t n : sizes) {
        size_t fill = n / 2;
        std::vector<char> key_buf(fill * 16);
        uint64_t ks = KEY_SEED;
        for (size_t i = 0; i < fill; i++) {
            uint64_t v = splitmix64(ks);
            for (int j = 15; j >= 0; j--) { key_buf[i * 16 + j] = hex_chars[v & 0xF]; v >>= 4; }
        }

        std::vector<std::string_view> keys(fill);
        for (size_t i = 0; i < fill; i++)
            keys[i] = std::string_view(&key_buf[i * 16], 16);

        std::vector<size_t> order(fill);
        for (size_t i = 0; i < fill; i++) order[i] = i;
        std::mt19937_64 rng(42);
        for (size_t i = fill - 1; i > 0; i--) { size_t j = rng() % (i + 1); std::swap(order[i], order[j]); }

        uint64_t times[MEASURED];
        for (int r = 0; r < TOTAL_RUNS; r++) {
            absl::flat_hash_map<std::string_view, uint64_t> map;
            map.reserve(n);
            for (size_t i = 0; i < fill; i++) map.emplace(keys[i], i);

            auto start = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) {
                auto it = map.find(keys[order[i]]);
                do_not_optimize(it->second);
            }
            auto end = std::chrono::steady_clock::now();
            if (r >= WARMUP)
                times[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
        }
        printf("  n=%7zu fill=%7zu: %lu us\n", n, fill, median_val(times, MEASURED));
    }
    printf("\n");
}

// Test 4: std::string (owning) vs string_view at 1M 50%
static void test_owning_strings() {
    printf("=== Test 4: std::string (owning) vs string_view (1M, 50%%, shuffled) ===\n");
    constexpr size_t n = 1048576;
    constexpr size_t fill = n / 2;

    std::vector<char> key_buf(fill * 16);
    uint64_t ks = KEY_SEED;
    for (size_t i = 0; i < fill; i++) {
        uint64_t v = splitmix64(ks);
        for (int j = 15; j >= 0; j--) { key_buf[i * 16 + j] = hex_chars[v & 0xF]; v >>= 4; }
    }

    std::vector<std::string> owned_keys(fill);
    std::vector<std::string_view> sv_keys(fill);
    for (size_t i = 0; i < fill; i++) {
        owned_keys[i] = std::string(&key_buf[i * 16], 16);
        sv_keys[i] = std::string_view(&key_buf[i * 16], 16);
    }

    std::vector<size_t> order(fill);
    for (size_t i = 0; i < fill; i++) order[i] = i;
    std::mt19937_64 rng(42);
    for (size_t i = fill - 1; i > 0; i--) { size_t j = rng() % (i + 1); std::swap(order[i], order[j]); }

    // string_view map
    uint64_t sv_times[MEASURED];
    for (int r = 0; r < TOTAL_RUNS; r++) {
        absl::flat_hash_map<std::string_view, uint64_t> map;
        map.reserve(n);
        for (size_t i = 0; i < fill; i++) map.emplace(sv_keys[i], i);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            auto it = map.find(sv_keys[order[i]]);
            do_not_optimize(it->second);
        }
        auto end = std::chrono::steady_clock::now();
        if (r >= WARMUP)
            sv_times[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    }

    // std::string map
    uint64_t str_times[MEASURED];
    for (int r = 0; r < TOTAL_RUNS; r++) {
        absl::flat_hash_map<std::string, uint64_t> map;
        map.reserve(n);
        for (size_t i = 0; i < fill; i++) map.emplace(owned_keys[i], i);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            auto it = map.find(owned_keys[order[i]]);
            do_not_optimize(it->second);
        }
        auto end = std::chrono::steady_clock::now();
        if (r >= WARMUP)
            str_times[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    }

    printf("  string_view: %lu us\n", median_val(sv_times, MEASURED));
    printf("  std::string: %lu us\n", median_val(str_times, MEASURED));
    printf("  ratio (string/sv): %.2f\n\n", (double)median_val(str_times, MEASURED) / median_val(sv_times, MEASURED));
}

int main() {
    test_hash_cost();
    test_variable_lengths();
    test_sizes();
    test_owning_strings();
    return 0;
}
