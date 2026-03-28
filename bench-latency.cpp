// Robust latency distribution measurement.
// Uses rdtsc, multiple independent runs, and tests at multiple loads.
// Also measures miss latency distribution separately.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <vector>
#include <string_view>
#include <cmath>
#include "absl/container/flat_hash_map.h"

#ifdef __ARM_NEON
#include <arm_neon.h>
#else
#include <immintrin.h>
#endif

// ---- wyhash ----
static inline uint64_t wymix(uint64_t a, uint64_t b) {
    __uint128_t r = (__uint128_t)a * b;
    return (uint64_t)(r >> 64) ^ (uint64_t)r;
}
static inline uint64_t wyr8(const uint8_t* p) {
    uint64_t v; memcpy(&v, p, 8); return v;
}
static uint64_t wyhash(const void* key, size_t len) {
    const uint8_t* p = (const uint8_t*)key;
    uint64_t seed = 0, a, b;
    const uint64_t s0 = 0xa0761d6478bd642f, s1 = 0xe7037ed1a0b428db;
    seed ^= s0;
    if (len <= 16) {
        if (len >= 4) {
            a = (wyr8(p) << 32) | (wyr8(p + ((len >> 3) << 2)) >> 32);
            b = (wyr8(p + len - 8) << 32) | (wyr8(p + len - 4 - ((len >> 3) << 2)) >> 32);
        } else if (len > 0) {
            a = ((uint64_t)p[0] << 16) | ((uint64_t)p[len >> 1] << 8) | p[len - 1];
            b = 0;
        } else { a = b = 0; }
    } else { a = b = 0; }
    return wymix(s1 ^ len, wymix(a ^ s1, b ^ seed));
}

// ---- Elastic hash (string keys, same as bench-disprove.cpp) ----
static constexpr size_t BUCKET_SIZE = 16;
static constexpr size_t MAX_PROBES = 7;
static constexpr uint8_t TOMBSTONE = 0xFF;
static constexpr size_t KEY_LEN = 16;

static inline uint16_t match_fingerprint(const uint8_t* fps, uint8_t fp) {
    __m128i v = _mm_loadu_si128((const __m128i*)fps);
    __m128i needle = _mm_set1_epi8((char)fp);
    return (uint16_t)_mm_movemask_epi8(_mm_cmpeq_epi8(v, needle));
}
static inline uint16_t match_empty(const uint8_t* fps) { return match_fingerprint(fps, 0); }
static inline uint16_t match_empty_or_tombstone(const uint8_t* fps) {
    return match_empty(fps) | match_fingerprint(fps, TOMBSTONE);
}

struct StringEntry { const char* key_ptr; size_t key_len; uint64_t value; };

struct ElasticHashCpp {
    uint8_t (*fingerprints)[BUCKET_SIZE];
    StringEntry (*entries)[BUCKET_SIZE];
    size_t tier0_bucket_mask;
    unsigned tier0_bucket_shift;
    size_t* tier_starts;
    size_t* tier_bucket_counts;
    size_t* tier_slot_counts;
    size_t num_tiers, total_buckets, tier0_bucket_count, count, current_batch;

    static uint64_t hash(const char* key, size_t len) { return wyhash(key, len); }
    static uint8_t fingerprint(uint64_t h) {
        uint8_t fp = (uint8_t)(h >> 32);
        if (fp == 0) return 1; if (fp == TOMBSTONE) return 0xFE; return fp;
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
            bkt = std::max(bkt, (size_t)1); tier_starts[i] = total_buckets;
            tier_bucket_counts[i] = bkt; tier_slot_counts[i] = 0;
            total_buckets += bkt; bkt /= 2;
        }
        fingerprints = (uint8_t(*)[BUCKET_SIZE])calloc(total_buckets, BUCKET_SIZE);
        entries = (StringEntry(*)[BUCKET_SIZE])calloc(total_buckets, BUCKET_SIZE * sizeof(StringEntry));
        tier0_bucket_count = tier_bucket_counts[0]; tier0_bucket_mask = tier0_bucket_count - 1;
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
    bool try_insert_with_limit(size_t tier, uint64_t h, uint8_t fp, const char* key, size_t key_len, uint64_t value, size_t limit) {
        size_t nb = tier_bucket_counts[tier], mp = std::min(limit, nb);
        for (size_t p = 0; p < mp; p++) {
            size_t ai = tier_starts[tier] + bucket_index(h, p, nb);
            uint16_t m = match_empty_or_tombstone(fingerprints[ai]);
            if (m) { size_t s = __builtin_ctz(m); fingerprints[ai][s] = fp; entries[ai][s] = {key, key_len, value}; tier_slot_counts[tier]++; count++; return true; }
        }
        return false;
    }
    void insert(const char* key, size_t key_len, uint64_t value) {
        uint64_t h = hash(key, key_len); uint8_t fp = fingerprint(h);
        size_t i = current_batch;
        if (i == 0) { insert_into_tier(0, h, fp, key, key_len, value); if (get_empty_fraction(0) <= 0.12) current_batch = 1; return; }
        if (i >= num_tiers) { insert_any_tier(h, fp, key, key_len, value); return; }
        size_t pri = i - 1, sec = i;
        double e1 = get_empty_fraction(pri), e2 = get_empty_fraction(sec);
        if (e1 > DELTA_HALF && e2 > 0.25) { if (!try_insert_with_limit(pri, h, fp, key, key_len, value, probe_limit(e1))) insert_into_tier(sec, h, fp, key, key_len, value); }
        else if (e1 <= DELTA_HALF) insert_into_tier(sec, h, fp, key, key_len, value);
        else insert_into_tier(pri, h, fp, key, key_len, value);
        if (e1 <= DELTA_HALF && e2 <= 0.25 && i + 1 < num_tiers) current_batch = i + 1;
    }
    void insert_into_tier(size_t tier, uint64_t h, uint8_t fp, const char* key, size_t key_len, uint64_t value) {
        size_t nb = tier_bucket_counts[tier], mp = std::min(nb, MAX_PROBES);
        for (size_t p = 0; p < mp; p++) {
            size_t ai = tier_starts[tier] + bucket_index(h, p, nb);
            uint16_t m = match_empty_or_tombstone(fingerprints[ai]);
            if (m) { size_t s = __builtin_ctz(m); fingerprints[ai][s] = fp; entries[ai][s] = {key, key_len, value}; tier_slot_counts[tier]++; count++; return; }
        }
        insert_any_tier(h, fp, key, key_len, value);
    }
    void insert_any_tier(uint64_t h, uint8_t fp, const char* key, size_t key_len, uint64_t value) {
        for (size_t j = 1; j <= MAX_PROBES; j++)
            for (size_t t = 0; t < num_tiers; t++) {
                size_t nb = tier_bucket_counts[t]; if (j - 1 >= nb) continue;
                size_t ai = tier_starts[t] + bucket_index(h, j - 1, nb);
                uint16_t m = match_empty_or_tombstone(fingerprints[ai]);
                if (m) { size_t s = __builtin_ctz(m); fingerprints[ai][s] = fp; entries[ai][s] = {key, key_len, value}; tier_slot_counts[t]++; count++; return; }
            }
    }
    __attribute__((noinline))
    uint64_t* get_overflow(uint64_t h, const char* key, size_t key_len, uint8_t fp) const {
        if (num_tiers <= 1) return nullptr;
        size_t nb = tier_bucket_counts[1], ts = tier_starts[1], mp = std::min(MAX_PROBES, nb);
        for (size_t p = 0; p < mp; p++) {
            size_t ai = ts + bucket_index(h, p, nb);
            uint16_t m = match_fingerprint(fingerprints[ai], fp);
            while (m) { size_t s = __builtin_ctz(m); auto& e = entries[ai][s]; if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) return (uint64_t*)&e.value; m &= m - 1; }
            if (match_empty(fingerprints[ai])) return nullptr;
        }
        return nullptr;
    }
    uint64_t* get(const char* key, size_t key_len) const {
        uint64_t h = hash(key, key_len); uint8_t fp = fingerprint(h);
        size_t mask = tier0_bucket_mask;
        uint64_t bb = h >> tier0_bucket_shift;
        __builtin_prefetch(&entries[bb & mask], 0, 3);
        for (size_t p = 0; p < MAX_PROBES; p++) {
            size_t bi = (bb + p) & mask;
            uint16_t m = match_fingerprint(fingerprints[bi], fp);
            while (m) { size_t s = __builtin_ctz(m); auto& e = entries[bi][s]; if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) return (uint64_t*)&e.value; m &= m - 1; }
            if (__builtin_expect(match_empty(fingerprints[bi]) != 0, 0)) return nullptr;
        }
        return const_cast<ElasticHashCpp*>(this)->get_overflow(h, key, key_len, fp);
    }
};

template <typename T>
inline void do_not_optimize(T const& val) { asm volatile("" : : "r,m"(val) : "memory"); }

static uint64_t splitmix64(uint64_t& state) {
    state += 0x9e3779b97f4a7c15; uint64_t z = state;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

static const char hex_chars_g[] = "0123456789abcdef";
static void u64_to_hex(uint64_t val, char* buf) {
    for (int i = KEY_LEN - 1; i >= 0; i--) { buf[i] = hex_chars_g[val & 0xF]; val >>= 4; }
}

constexpr uint64_t KEY_SEED = 0xDEADBEEF12345678;
constexpr uint64_t MISS_SEED = 0xCAFEBABE87654321;

static inline uint64_t rdtsc() {
    unsigned int lo, hi;
    __asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

static void print_distribution(const char* impl, const char* op, std::vector<uint64_t>& cycles) {
    std::sort(cycles.begin(), cycles.end());
    size_t n = cycles.size();
    auto pct = [&](double p) -> uint64_t { return cycles[(size_t)(p / 100.0 * (n - 1))]; };
    printf("LATENCY\timpl=%s\top=%s\tp50=%llu\tp90=%llu\tp95=%llu\tp99=%llu\tp99.9=%llu\tmax=%llu\n",
           impl, op,
           (unsigned long long)pct(50), (unsigned long long)pct(90),
           (unsigned long long)pct(95), (unsigned long long)pct(99),
           (unsigned long long)pct(99.9), (unsigned long long)cycles.back());
}

int main() {
    constexpr size_t N = 1048576;
    constexpr size_t SAMPLE = 500000; // 500K samples for robust percentiles
    constexpr int RUNS = 5;

    int loads[] = {25, 50, 75, 99};

    for (int pct : loads) {
        size_t fill = N * pct / 100;
        printf("\n=== LATENCY DISTRIBUTION: n=%zu, load=%d%%, %zu samples, %d runs ===\n", N, pct, SAMPLE, RUNS);

        // Generate keys
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

        // Random sample indices
        std::vector<size_t> sample_idx(SAMPLE), miss_sample_idx(SAMPLE);
        uint64_t rng = 99999;
        for (size_t i = 0; i < SAMPLE; i++) {
            sample_idx[i] = splitmix64(rng) % fill;
            miss_sample_idx[i] = splitmix64(rng) % fill;
        }

        // Best-of-RUNS for each implementation
        std::vector<uint64_t> best_e_hit, best_a_hit, best_e_miss, best_a_miss;

        for (int r = 0; r < RUNS; r++) {
            // Elastic hit
            std::vector<uint64_t> e_hit(SAMPLE), e_miss(SAMPLE);
            {
                ElasticHashCpp map; map.init(N);
                for (size_t i = 0; i < fill; i++) map.insert(&key_buf[i * KEY_LEN], KEY_LEN, i);
                // Warmup
                for (size_t i = 0; i < std::min(SAMPLE, (size_t)50000); i++) do_not_optimize(map.get(&key_buf[sample_idx[i] * KEY_LEN], KEY_LEN));
                // Measure hits
                for (size_t i = 0; i < SAMPLE; i++) {
                    uint64_t t0 = rdtsc();
                    do_not_optimize(map.get(&key_buf[sample_idx[i] * KEY_LEN], KEY_LEN));
                    e_hit[i] = rdtsc() - t0;
                }
                // Measure misses
                for (size_t i = 0; i < SAMPLE; i++) {
                    uint64_t t0 = rdtsc();
                    do_not_optimize(map.get(&miss_buf[miss_sample_idx[i] * KEY_LEN], KEY_LEN));
                    e_miss[i] = rdtsc() - t0;
                }
                map.destroy();
            }

            // Abseil hit
            std::vector<uint64_t> a_hit(SAMPLE), a_miss(SAMPLE);
            {
                absl::flat_hash_map<std::string_view, uint64_t> map; map.reserve(N);
                for (size_t i = 0; i < fill; i++) map.emplace(keys[i], i);
                for (size_t i = 0; i < std::min(SAMPLE, (size_t)50000); i++) { auto it = map.find(keys[sample_idx[i]]); do_not_optimize(it->second); }
                for (size_t i = 0; i < SAMPLE; i++) {
                    uint64_t t0 = rdtsc();
                    auto it = map.find(keys[sample_idx[i]]);
                    do_not_optimize(it->second);
                    a_hit[i] = rdtsc() - t0;
                }
                for (size_t i = 0; i < SAMPLE; i++) {
                    uint64_t t0 = rdtsc();
                    auto it = map.find(miss_keys[miss_sample_idx[i]]);
                    do_not_optimize(it == map.end());
                    a_miss[i] = rdtsc() - t0;
                }
            }

            // Keep best (lowest median) run
            std::sort(e_hit.begin(), e_hit.end());
            std::sort(a_hit.begin(), a_hit.end());
            if (r == 0 || e_hit[SAMPLE/2] < best_e_hit[SAMPLE/2]) best_e_hit = e_hit;
            if (r == 0 || a_hit[SAMPLE/2] < best_a_hit[SAMPLE/2]) best_a_hit = a_hit;
            if (r == 0 || e_miss[SAMPLE/2] < ([&]{ std::sort(e_miss.begin(), e_miss.end()); return best_e_miss; }())[SAMPLE/2]) best_e_miss = e_miss;
            if (r == 0 || a_miss[SAMPLE/2] < ([&]{ std::sort(a_miss.begin(), a_miss.end()); return best_a_miss; }())[SAMPLE/2]) best_a_miss = a_miss;
        }

        print_distribution("elastic", "hit", best_e_hit);
        print_distribution("abseil", "hit", best_a_hit);
        print_distribution("elastic", "miss", best_e_miss);
        print_distribution("abseil", "miss", best_a_miss);
    }

    return 0;
}
