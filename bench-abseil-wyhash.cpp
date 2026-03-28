// Attack 1: Abseil flat_hash_map with wyhash instead of absl::Hash
// Purpose: isolate data structure advantage from hash function advantage.
// If the gap narrows significantly, the elastic hash claim is partly about
// having a faster hash, not a faster data structure.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <chrono>
#include <vector>
#include <string_view>
#include "absl/container/flat_hash_map.h"

// ---- wyhash (same as bench-elastic-cpp.cpp) ----
static inline uint64_t wymix(uint64_t a, uint64_t b) {
    __uint128_t r = (__uint128_t)a * b;
    return (uint64_t)(r >> 64) ^ (uint64_t)r;
}

static inline uint64_t wyr8(const uint8_t* p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}

static uint64_t wyhash(const void* key, size_t len) {
    const uint8_t* p = (const uint8_t*)key;
    uint64_t seed = 0;
    uint64_t a, b;
    const uint64_t s0 = 0xa0761d6478bd642f;
    const uint64_t s1 = 0xe7037ed1a0b428db;
    const uint64_t s2 = 0x8ebc6af09c88c6e3;
    const uint64_t s3 = 0x589965cc75374cc3;

    seed ^= s0;
    if (len <= 16) {
        if (len >= 4) {
            a = (wyr8(p) << 32) | (wyr8(p + ((len >> 3) << 2)) >> 32);
            b = (wyr8(p + len - 8) << 32) | (wyr8(p + len - 4 - ((len >> 3) << 2)) >> 32);
        } else if (len > 0) {
            a = ((uint64_t)p[0] << 16) | ((uint64_t)p[len >> 1] << 8) | p[len - 1];
            b = 0;
        } else {
            a = b = 0;
        }
    } else {
        size_t i = len;
        if (i > 48) {
            uint64_t see1 = seed, see2 = seed;
            while (i > 48) {
                seed = wymix(wyr8(p) ^ s1, wyr8(p + 8) ^ seed);
                see1 = wymix(wyr8(p + 16) ^ s2, wyr8(p + 24) ^ see1);
                see2 = wymix(wyr8(p + 32) ^ s3, wyr8(p + 40) ^ see2);
                p += 48;
                i -= 48;
            }
            seed ^= see1 ^ see2;
        }
        while (i > 16) {
            seed = wymix(wyr8(p) ^ s1, wyr8(p + 8) ^ seed);
            i -= 16;
            p += 16;
        }
        a = wyr8(p + i - 16);
        b = wyr8(p + i - 8);
    }
    return wymix(s1 ^ len, wymix(a ^ s1, b ^ seed));
}

// Custom hash policy for abseil: use wyhash instead of absl::Hash
struct WyhashPolicy {
    using is_transparent = void;
    size_t operator()(std::string_view sv) const {
        return wyhash(sv.data(), sv.size());
    }
};

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
constexpr size_t KEY_LEN = 16;

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

static void bench(const char* label, size_t n, size_t fill, int load_pct) {
    // Pre-generate key strings
    std::vector<char> key_buf(fill * KEY_LEN), miss_buf(fill * KEY_LEN);
    uint64_t ks = KEY_SEED, ms = MISS_SEED;
    for (size_t i = 0; i < fill; i++) {
        u64_to_hex(splitmix64(ks), &key_buf[i * KEY_LEN]);
        u64_to_hex(splitmix64(ms), &miss_buf[i * KEY_LEN]);
    }

    // Create string_views
    std::vector<std::string_view> keys(fill), miss_keys(fill);
    for (size_t i = 0; i < fill; i++) {
        keys[i] = std::string_view(&key_buf[i * KEY_LEN], KEY_LEN);
        miss_keys[i] = std::string_view(&miss_buf[i * KEY_LEN], KEY_LEN);
    }

    // Shuffle order (same seed as elastic benchmark)
    std::vector<size_t> order(fill);
    for (size_t i = 0; i < fill; i++) order[i] = i;
    uint64_t rng = 42;
    for (size_t i = fill - 1; i > 0; i--) {
        size_t j = splitmix64(rng) % (i + 1);
        std::swap(order[i], order[j]);
    }

    uint64_t ins[MEASURED], lkp[MEASURED], del[MEASURED], mis[MEASURED];

    for (int r = 0; r < TOTAL_RUNS; r++) {
        absl::flat_hash_map<std::string_view, uint64_t, WyhashPolicy> map;
        map.reserve(n);

        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            map.emplace(keys[i], i);
        }
        auto end = std::chrono::steady_clock::now();
        uint64_t insert_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        // Shuffled hit lookup
        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            auto it = map.find(keys[order[i]]);
            do_not_optimize(it->second);
        }
        end = std::chrono::steady_clock::now();
        uint64_t lookup_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        // Shuffled miss lookup
        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            auto it = map.find(miss_keys[order[i]]);
            do_not_optimize(it == map.end());
        }
        end = std::chrono::steady_clock::now();
        uint64_t miss_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        // Delete half
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

    printf("%s\tn=%zu\tload=%d\tinsert_us=%llu\tlookup_us=%llu\tdelete_us=%llu\tmiss_us=%llu\n",
           label, n, load_pct,
           (unsigned long long)median_val(ins, MEASURED),
           (unsigned long long)median_val(lkp, MEASURED),
           (unsigned long long)median_val(del, MEASURED),
           (unsigned long long)median_val(mis, MEASURED));
    fflush(stdout);
}

int main() {
    printf("=== Abseil + wyhash vs Abseil + absl::Hash (string_view keys, shuffled) ===\n\n");

    // Also run with default absl::Hash for direct comparison
    auto bench_default = [](size_t n, size_t fill, int load_pct) {
        std::vector<char> key_buf(fill * KEY_LEN), miss_buf(fill * KEY_LEN);
        uint64_t ks = KEY_SEED, ms = MISS_SEED;
        for (size_t i = 0; i < fill; i++) {
            u64_to_hex(splitmix64(ks), &key_buf[i * KEY_LEN]);
            u64_to_hex(splitmix64(ms), &miss_buf[i * KEY_LEN]);
        }
        std::vector<std::string_view> keys(fill), miss_keys(fill);
        for (size_t i = 0; i < fill; i++) {
            keys[i] = std::string_view(&key_buf[i * KEY_LEN], KEY_LEN);
            miss_keys[i] = std::string_view(&miss_buf[i * KEY_LEN], KEY_LEN);
        }
        std::vector<size_t> order(fill);
        for (size_t i = 0; i < fill; i++) order[i] = i;
        uint64_t rng = 42;
        for (size_t i = fill - 1; i > 0; i--) {
            size_t j = splitmix64(rng) % (i + 1);
            std::swap(order[i], order[j]);
        }

        uint64_t ins[MEASURED], lkp[MEASURED], del[MEASURED], mis[MEASURED];
        for (int r = 0; r < TOTAL_RUNS; r++) {
            absl::flat_hash_map<std::string_view, uint64_t> map;
            map.reserve(n);
            auto start = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) map.emplace(keys[i], i);
            auto end = std::chrono::steady_clock::now();
            uint64_t insert_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

            start = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) {
                auto it = map.find(keys[order[i]]);
                do_not_optimize(it->second);
            }
            end = std::chrono::steady_clock::now();
            uint64_t lookup_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

            start = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) {
                auto it = map.find(miss_keys[order[i]]);
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
        printf("ABSEIL-DEFAULT\tn=%zu\tload=%d\tinsert_us=%llu\tlookup_us=%llu\tdelete_us=%llu\tmiss_us=%llu\n",
               n, load_pct,
               (unsigned long long)median_val(ins, MEASURED),
               (unsigned long long)median_val(lkp, MEASURED),
               (unsigned long long)median_val(del, MEASURED),
               (unsigned long long)median_val(mis, MEASURED));
        fflush(stdout);
    };

    // Test at multiple sizes and loads
    constexpr size_t sizes[] = {65536, 262144, 1048576, 4194304};
    constexpr int loads[] = {25, 50, 75};

    for (size_t n : sizes) {
        for (int pct : loads) {
            size_t fill = n * pct / 100;
            bench("ABSEIL-WYHASH", n, fill, pct);
            bench_default(n, fill, pct);
        }
    }

    printf("\nDONE\n");
    return 0;
}
