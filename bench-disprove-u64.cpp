// Attack 6: u64 key comparison — same C++ harness, integer keys instead of strings.
// verify-results.md showed only 15-20% shuffled advantage with u64 keys.
// If the advantage is much larger here, it means the string-key benchmarks
// inflate the advantage due to expensive key comparisons.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <vector>
#include "absl/container/flat_hash_map.h"

#ifdef __ARM_NEON
#include <arm_neon.h>
#else
#include <immintrin.h>
#endif

// ---- SIMD fingerprint matching ----
static constexpr size_t BUCKET_SIZE = 16;
static constexpr size_t MAX_PROBES = 7;
static constexpr uint8_t TOMBSTONE = 0xFF;

static inline uint16_t match_fingerprint(const uint8_t* fps, uint8_t fp) {
    __m128i v = _mm_loadu_si128((const __m128i*)fps);
    __m128i needle = _mm_set1_epi8((char)fp);
    return (uint16_t)_mm_movemask_epi8(_mm_cmpeq_epi8(v, needle));
}
static inline uint16_t match_empty(const uint8_t* fps) { return match_fingerprint(fps, 0); }
static inline uint16_t match_empty_or_tombstone(const uint8_t* fps) {
    return match_empty(fps) | match_fingerprint(fps, TOMBSTONE);
}

struct U64Entry { uint64_t key; uint64_t value; };

struct ElasticHashU64 {
    uint8_t (*fingerprints)[BUCKET_SIZE];
    U64Entry (*entries)[BUCKET_SIZE];
    size_t tier0_bucket_mask;
    unsigned tier0_bucket_shift;
    size_t* tier_starts;
    size_t* tier_bucket_counts;
    size_t* tier_slot_counts;
    size_t num_tiers, total_buckets, tier0_bucket_count, count, current_batch;

    // Simple multiply hash (fast for u64)
    static uint64_t hash(uint64_t key) {
        key ^= key >> 33;
        key *= 0xff51afd7ed558ccd;
        key ^= key >> 33;
        key *= 0xc4ceb9fe1a85ec53;
        key ^= key >> 33;
        return key;
    }
    static uint8_t fingerprint(uint64_t h) {
        uint8_t fp = (uint8_t)(h >> 32);
        if (fp == 0) return 1;
        if (fp == TOMBSTONE) return 0xFE;
        return fp;
    }
    static size_t bucket_index(uint64_t h, size_t probe, size_t num_buckets) {
        unsigned bits = __builtin_ctzll(num_buckets);
        unsigned shift = std::min(64u - bits, 63u);
        return ((h >> shift) + probe) & (num_buckets - 1);
    }

    void init(size_t n) {
        size_t capacity = 1;
        while (capacity < n) capacity <<= 1;
        size_t t0_buckets = std::max(capacity / BUCKET_SIZE, (size_t)1);
        num_tiers = 1;
        { size_t tmp = t0_buckets; while (tmp > 1) { tmp >>= 1; num_tiers++; } }
        tier_starts = (size_t*)calloc(num_tiers, sizeof(size_t));
        tier_bucket_counts = (size_t*)calloc(num_tiers, sizeof(size_t));
        tier_slot_counts = (size_t*)calloc(num_tiers, sizeof(size_t));
        total_buckets = 0;
        size_t bkt = t0_buckets;
        for (size_t i = 0; i < num_tiers; i++) {
            bkt = std::max(bkt, (size_t)1);
            tier_starts[i] = total_buckets;
            tier_bucket_counts[i] = bkt;
            tier_slot_counts[i] = 0;
            total_buckets += bkt;
            bkt /= 2;
        }
        fingerprints = (uint8_t(*)[BUCKET_SIZE])calloc(total_buckets, BUCKET_SIZE);
        entries = (U64Entry(*)[BUCKET_SIZE])calloc(total_buckets, BUCKET_SIZE * sizeof(U64Entry));
        tier0_bucket_count = tier_bucket_counts[0];
        tier0_bucket_mask = tier0_bucket_count - 1;
        tier0_bucket_shift = 64 - __builtin_ctzll(tier0_bucket_count);
        count = 0; current_batch = 0;
    }
    void destroy() { free(fingerprints); free(entries); free(tier_starts); free(tier_bucket_counts); free(tier_slot_counts); }

    static constexpr double DELTA = 0.01, DELTA_HALF = DELTA / 2.0, PROBE_CONSTANT = 16.0;
    double get_empty_fraction(size_t tier) const {
        return 1.0 - (double)tier_slot_counts[tier] / (double)(tier_bucket_counts[tier] * BUCKET_SIZE);
    }
    static size_t probe_limit(double epsilon) {
        if (epsilon <= 0.0) return MAX_PROBES;
        double l1 = log(1.0 / epsilon), l2 = log(1.0 / DELTA);
        return std::min((size_t)std::max(1.0, PROBE_CONSTANT * std::min(l1 * l1, l2)), MAX_PROBES);
    }
    bool try_insert_with_limit(size_t tier, uint64_t h, uint8_t fp, uint64_t key, uint64_t value, size_t limit) {
        size_t nb = tier_bucket_counts[tier], mp = std::min(limit, nb);
        for (size_t p = 0; p < mp; p++) {
            size_t ai = tier_starts[tier] + bucket_index(h, p, nb);
            uint16_t m = match_empty_or_tombstone(fingerprints[ai]);
            if (m) { size_t s = __builtin_ctz(m); fingerprints[ai][s] = fp; entries[ai][s] = {key, value}; tier_slot_counts[tier]++; count++; return true; }
        }
        return false;
    }
    void insert(uint64_t key, uint64_t value) {
        uint64_t h = hash(key); uint8_t fp = fingerprint(h);
        size_t i = current_batch;
        if (i == 0) { insert_into_tier(0, h, fp, key, value); if (get_empty_fraction(0) <= 0.12) current_batch = 1; return; }
        if (i >= num_tiers) { insert_any_tier(h, fp, key, value); return; }
        size_t pri = i - 1, sec = i;
        double e1 = get_empty_fraction(pri), e2 = get_empty_fraction(sec);
        if (e1 > DELTA_HALF && e2 > 0.25) { if (!try_insert_with_limit(pri, h, fp, key, value, probe_limit(e1))) insert_into_tier(sec, h, fp, key, value); }
        else if (e1 <= DELTA_HALF) insert_into_tier(sec, h, fp, key, value);
        else insert_into_tier(pri, h, fp, key, value);
        if (e1 <= DELTA_HALF && e2 <= 0.25 && i + 1 < num_tiers) current_batch = i + 1;
    }
    void insert_into_tier(size_t tier, uint64_t h, uint8_t fp, uint64_t key, uint64_t value) {
        size_t nb = tier_bucket_counts[tier], mp = std::min(nb, MAX_PROBES);
        for (size_t p = 0; p < mp; p++) {
            size_t ai = tier_starts[tier] + bucket_index(h, p, nb);
            uint16_t m = match_empty_or_tombstone(fingerprints[ai]);
            if (m) { size_t s = __builtin_ctz(m); fingerprints[ai][s] = fp; entries[ai][s] = {key, value}; tier_slot_counts[tier]++; count++; return; }
        }
        insert_any_tier(h, fp, key, value);
    }
    void insert_any_tier(uint64_t h, uint8_t fp, uint64_t key, uint64_t value) {
        for (size_t j = 1; j <= MAX_PROBES; j++)
            for (size_t t = 0; t < num_tiers; t++) {
                size_t nb = tier_bucket_counts[t]; if (j - 1 >= nb) continue;
                size_t ai = tier_starts[t] + bucket_index(h, j - 1, nb);
                uint16_t m = match_empty_or_tombstone(fingerprints[ai]);
                if (m) { size_t s = __builtin_ctz(m); fingerprints[ai][s] = fp; entries[ai][s] = {key, value}; tier_slot_counts[t]++; count++; return; }
            }
    }
    __attribute__((noinline))
    uint64_t* get_overflow(uint64_t h, uint64_t key, uint8_t fp) const {
        if (num_tiers <= 1) return nullptr;
        size_t nb = tier_bucket_counts[1], ts = tier_starts[1], mp = std::min(MAX_PROBES, nb);
        for (size_t p = 0; p < mp; p++) {
            size_t ai = ts + bucket_index(h, p, nb);
            uint16_t m = match_fingerprint(fingerprints[ai], fp);
            while (m) { size_t s = __builtin_ctz(m); if (entries[ai][s].key == key) return &entries[ai][s].value; m &= m - 1; }
            if (match_empty(fingerprints[ai])) return nullptr;
        }
        return nullptr;
    }
    uint64_t* get(uint64_t key) const {
        uint64_t h = hash(key); uint8_t fp = fingerprint(h);
        size_t mask = tier0_bucket_mask;
        uint64_t bb = h >> tier0_bucket_shift;
        __builtin_prefetch(&entries[bb & mask], 0, 3);
        for (size_t p = 0; p < MAX_PROBES; p++) {
            size_t bi = (bb + p) & mask;
            uint16_t m = match_fingerprint(fingerprints[bi], fp);
            while (m) { size_t s = __builtin_ctz(m); if (entries[bi][s].key == key) return &entries[bi][s].value; m &= m - 1; }
            if (__builtin_expect(match_empty(fingerprints[bi]) != 0, 0)) return nullptr;
        }
        return const_cast<ElasticHashU64*>(this)->get_overflow(h, key, fp);
    }
    bool remove(uint64_t key) {
        uint64_t h = hash(key); uint8_t fp = fingerprint(h);
        size_t mask = tier0_bucket_mask;
        uint64_t bb = h >> tier0_bucket_shift;
        for (size_t p = 0; p < MAX_PROBES; p++) {
            size_t bi = (bb + p) & mask;
            uint16_t m = match_fingerprint(fingerprints[bi], fp);
            while (m) { size_t s = __builtin_ctz(m); if (entries[bi][s].key == key) { fingerprints[bi][s] = TOMBSTONE; count--; return true; } m &= m - 1; }
        }
        return false;
    }
};

// ---- Harness ----
template <typename T>
inline void do_not_optimize(T const& val) { asm volatile("" : : "r,m"(val) : "memory"); }

static uint64_t splitmix64(uint64_t& state) {
    state += 0x9e3779b97f4a7c15;
    uint64_t z = state;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

static uint64_t median_val(uint64_t* arr, int n) {
    std::sort(arr, arr + n); return arr[n / 2];
}

constexpr uint64_t KEY_SEED = 0xDEADBEEF12345678;
constexpr uint64_t MISS_SEED = 0xCAFEBABE87654321;
constexpr int TOTAL_RUNS = 12;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;

int main() {
    printf("=== U64 KEY COMPARISON (shuffled, elastic C++ vs abseil) ===\n\n");

    constexpr size_t sizes[] = {65536, 262144, 1048576, 4194304};
    constexpr int loads[] = {10, 25, 50, 75, 90, 99};

    for (size_t n : sizes) {
        for (int pct : loads) {
            size_t fill = n * pct / 100;
            if (fill == 0) fill = 1;

            std::vector<uint64_t> keys(fill), miss_keys(fill);
            uint64_t ks = KEY_SEED, ms = MISS_SEED;
            for (size_t i = 0; i < fill; i++) { keys[i] = splitmix64(ks); miss_keys[i] = splitmix64(ms); }

            // Shuffle
            std::vector<size_t> order(fill);
            for (size_t i = 0; i < fill; i++) order[i] = i;
            uint64_t rng = 42;
            for (size_t i = fill - 1; i > 0; i--) { size_t j = splitmix64(rng) % (i + 1); std::swap(order[i], order[j]); }

            // Elastic
            uint64_t e_lkp[MEASURED], e_mis[MEASURED], e_ins[MEASURED], e_del[MEASURED];
            for (int r = 0; r < TOTAL_RUNS; r++) {
                ElasticHashU64 map; map.init(n);
                auto s = std::chrono::steady_clock::now();
                for (size_t i = 0; i < fill; i++) map.insert(keys[i], i);
                auto e = std::chrono::steady_clock::now();
                uint64_t ins = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
                s = std::chrono::steady_clock::now();
                for (size_t i = 0; i < fill; i++) do_not_optimize(map.get(keys[order[i]]));
                e = std::chrono::steady_clock::now();
                uint64_t lkp = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
                s = std::chrono::steady_clock::now();
                for (size_t i = 0; i < fill; i++) do_not_optimize(map.get(miss_keys[order[i]]));
                e = std::chrono::steady_clock::now();
                uint64_t mis = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
                s = std::chrono::steady_clock::now();
                for (size_t i = 0; i < fill / 2; i++) do_not_optimize(map.remove(keys[i]));
                e = std::chrono::steady_clock::now();
                uint64_t del = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
                if (r >= WARMUP) { int idx = r - WARMUP; e_ins[idx] = ins; e_lkp[idx] = lkp; e_mis[idx] = mis; e_del[idx] = del; }
                map.destroy();
            }

            // Abseil
            uint64_t a_lkp[MEASURED], a_mis[MEASURED], a_ins[MEASURED], a_del[MEASURED];
            for (int r = 0; r < TOTAL_RUNS; r++) {
                absl::flat_hash_map<uint64_t, uint64_t> map; map.reserve(n);
                auto s = std::chrono::steady_clock::now();
                for (size_t i = 0; i < fill; i++) map.emplace(keys[i], i);
                auto e = std::chrono::steady_clock::now();
                uint64_t ins = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
                s = std::chrono::steady_clock::now();
                for (size_t i = 0; i < fill; i++) { auto it = map.find(keys[order[i]]); do_not_optimize(it->second); }
                e = std::chrono::steady_clock::now();
                uint64_t lkp = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
                s = std::chrono::steady_clock::now();
                for (size_t i = 0; i < fill; i++) { auto it = map.find(miss_keys[order[i]]); do_not_optimize(it == map.end()); }
                e = std::chrono::steady_clock::now();
                uint64_t mis = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
                s = std::chrono::steady_clock::now();
                for (size_t i = 0; i < fill / 2; i++) { auto it = map.find(keys[i]); if (it != map.end()) map.erase(it); }
                e = std::chrono::steady_clock::now();
                uint64_t del = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
                if (r >= WARMUP) { int idx = r - WARMUP; a_ins[idx] = ins; a_lkp[idx] = lkp; a_mis[idx] = mis; a_del[idx] = del; }
            }

            uint64_t el = median_val(e_lkp, MEASURED), al = median_val(a_lkp, MEASURED);
            uint64_t em = median_val(e_mis, MEASURED), am = median_val(a_mis, MEASURED);
            uint64_t ei = median_val(e_ins, MEASURED), ai = median_val(a_ins, MEASURED);
            uint64_t ed = median_val(e_del, MEASURED), ad = median_val(a_del, MEASURED);
            printf("U64\tn=%zu\tload=%d\telastic_hit=%llu\tabseil_hit=%llu\thit_ratio=%.2f\telastic_miss=%llu\tabseil_miss=%llu\tmiss_ratio=%.2f\telastic_ins=%llu\tabseil_ins=%llu\tins_ratio=%.2f\n",
                   n, pct, (unsigned long long)el, (unsigned long long)al, (double)al/(double)el,
                   (unsigned long long)em, (unsigned long long)am, (double)am/(double)em,
                   (unsigned long long)ei, (unsigned long long)ai, (double)ai/(double)ei);
            fflush(stdout);
        }
        printf("\n");
    }

    return 0;
}
