#pragma once
#include "common.h"

constexpr uint64_t KEY_SEED = 0xDEADBEEF12345678;
constexpr uint64_t MISS_SEED = 0xCAFEBABE87654321;
constexpr int TOTAL_RUNS = 12;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;

template <typename HT>
static void bench(const char* impl_name, size_t n, size_t fill, int load_pct) {
    // Generate keys
    std::vector<char> key_buf(fill * KEY_LEN);
    std::vector<char> miss_buf(fill * KEY_LEN);
    uint64_t ks = KEY_SEED, ms = MISS_SEED;
    for (size_t i = 0; i < fill; i++) {
        u64_to_hex(splitmix64(ks), &key_buf[i * KEY_LEN]);
        u64_to_hex(splitmix64(ms), &miss_buf[i * KEY_LEN]);
    }

    // Shuffle order
    std::vector<size_t> order(fill);
    for (size_t i = 0; i < fill; i++) order[i] = i;
    uint64_t rng = 42;
    for (size_t i = fill - 1; i > 0; i--) {
        size_t j = splitmix64(rng) % (i + 1);
        std::swap(order[i], order[j]);
    }

    uint64_t ins[MEASURED], lkp[MEASURED], del[MEASURED], mis[MEASURED];

    for (int r = 0; r < TOTAL_RUNS; r++) {
        HT map;
        map.init(n);

        // Insert
        auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            map.insert(&key_buf[i * KEY_LEN], KEY_LEN, i);
        }
        auto end = std::chrono::steady_clock::now();
        uint64_t insert_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        // Shuffled hit lookup
        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            do_not_optimize(map.get(&key_buf[order[i] * KEY_LEN], KEY_LEN));
        }
        end = std::chrono::steady_clock::now();
        uint64_t lookup_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        // Shuffled miss lookup
        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            do_not_optimize(map.get(&miss_buf[order[i] * KEY_LEN], KEY_LEN));
        }
        end = std::chrono::steady_clock::now();
        uint64_t miss_us = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

        // Delete all (not half — measure full delete)
        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill; i++) {
            do_not_optimize(map.remove(&key_buf[i * KEY_LEN], KEY_LEN));
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

        map.destroy();
    }

    printf("%s\tsize=%zu\tload=%d\tinsert=%llu\thit=%llu\tmiss=%llu\tdelete=%llu\n",
           impl_name, n, load_pct,
           median_val(ins, MEASURED), median_val(lkp, MEASURED),
           median_val(mis, MEASURED), median_val(del, MEASURED));
    fflush(stdout);
}

template <typename HT>
static void run_bench(const char* impl_name) {
    size_t sizes[] = {16384, 65536, 262144, 1048576, 4194304};
    int loads[] = {10, 25, 50, 75, 90, 99};

    for (size_t n : sizes) {
        for (int pct : loads) {
            size_t fill = n * pct / 100;
            if (fill == 0) fill = 1;
            bench<HT>(impl_name, n, fill, pct);
        }
    }
}
