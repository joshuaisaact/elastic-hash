// String-key benchmark for abseil flat_hash_map
// Uses string_view keys pointing to pre-generated hex strings (same as Zig side)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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

static void bench(size_t n, size_t fill, int load_pct) {
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

    uint64_t ins[MEASURED], lkp[MEASURED], del[MEASURED], mis[MEASURED];

    for (int r = 0; r < TOTAL_RUNS; r++) {
        absl::flat_hash_map<std::string_view, uint64_t> map;
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

    printf("RESULT\tn=%zu\tload=%d\tinsert_us=%lu\tlookup_us=%lu\tdelete_us=%lu\tmiss_us=%lu\n",
           n, load_pct, median_val(ins, MEASURED), median_val(lkp, MEASURED),
           median_val(del, MEASURED), median_val(mis, MEASURED));
    fflush(stdout);
}

int main() {
    fprintf(stderr, "\n=== Abseil string_view Benchmark (median of %d, %d warmup, %zu-byte keys) ===\n\n",
            MEASURED, WARMUP, KEY_LEN);

    constexpr size_t sizes[] = {16384, 65536, 262144, 1048576};
    for (size_t n : sizes) {
        bench(n, n * 99 / 100, 99);
    }

    constexpr int pcts[] = {10, 25, 50, 75, 90};
    constexpr size_t n = 1048576;
    for (int pct : pcts) {
        bench(n, n * pct / 100, pct);
    }

    fprintf(stderr, "\nDONE\n");
    return 0;
}
