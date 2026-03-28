// Unified adversarial benchmark: elastic hash C++ vs abseil flat_hash_map
// Same compiler, same methodology, string_view keys, shuffled access.
// Tests: size sweep, load factor sweep, hot-set, latency distribution.
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

// ---- wyhash (same as elastic C++ port) ----
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
    const uint64_t s2 = 0x8ebc6af09c88c6e3, s3 = 0x589965cc75374cc3;
    seed ^= s0;
    if (len <= 16) {
        if (len >= 4) {
            a = (wyr8(p) << 32) | (wyr8(p + ((len >> 3) << 2)) >> 32);
            b = (wyr8(p + len - 8) << 32) | (wyr8(p + len - 4 - ((len >> 3) << 2)) >> 32);
        } else if (len > 0) {
            a = ((uint64_t)p[0] << 16) | ((uint64_t)p[len >> 1] << 8) | p[len - 1];
            b = 0;
        } else { a = b = 0; }
    } else {
        size_t i = len;
        if (i > 48) {
            uint64_t see1 = seed, see2 = seed;
            while (i > 48) {
                seed = wymix(wyr8(p) ^ s1, wyr8(p + 8) ^ seed);
                see1 = wymix(wyr8(p + 16) ^ s2, wyr8(p + 24) ^ see1);
                see2 = wymix(wyr8(p + 32) ^ s3, wyr8(p + 40) ^ see2);
                p += 48; i -= 48;
            }
            seed ^= see1 ^ see2;
        }
        while (i > 16) { seed = wymix(wyr8(p) ^ s1, wyr8(p + 8) ^ seed); i -= 16; p += 16; }
        a = wyr8(p + i - 16); b = wyr8(p + i - 8);
    }
    return wymix(s1 ^ len, wymix(a ^ s1, b ^ seed));
}

// ---- Elastic Hash C++ (same as bench-elastic-cpp.cpp) ----
static constexpr size_t BUCKET_SIZE = 16;
static constexpr size_t MAX_PROBES = 7;
static constexpr uint8_t TOMBSTONE = 0xFF;
static constexpr size_t KEY_LEN = 16;

#ifdef __ARM_NEON
static inline uint16_t match_fingerprint(const uint8_t* fps, uint8_t fp) {
    uint8x16_t v = vld1q_u8(fps);
    uint8x16_t needle = vdupq_n_u8(fp);
    uint8x16_t cmp = vceqq_u8(v, needle);
    static const uint8_t shift_table[16] = {1,2,4,8,16,32,64,128,1,2,4,8,16,32,64,128};
    uint8x16_t shift = vld1q_u8(shift_table);
    uint8x16_t bits = vandq_u8(cmp, shift);
    uint8x8_t lo = vget_low_u8(bits), hi = vget_high_u8(bits);
    lo = vpadd_u8(lo, lo); lo = vpadd_u8(lo, lo); lo = vpadd_u8(lo, lo);
    hi = vpadd_u8(hi, hi); hi = vpadd_u8(hi, hi); hi = vpadd_u8(hi, hi);
    return (uint16_t)((vget_lane_u8(hi, 0) << 8) | vget_lane_u8(lo, 0));
}
#else
static inline uint16_t match_fingerprint(const uint8_t* fps, uint8_t fp) {
    __m128i v = _mm_loadu_si128((const __m128i*)fps);
    __m128i needle = _mm_set1_epi8((char)fp);
    return (uint16_t)_mm_movemask_epi8(_mm_cmpeq_epi8(v, needle));
}
#endif

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
        entries = (StringEntry(*)[BUCKET_SIZE])calloc(total_buckets, BUCKET_SIZE * sizeof(StringEntry));
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
    bool remove(const char* key, size_t key_len) {
        uint64_t h = hash(key, key_len); uint8_t fp = fingerprint(h);
        size_t mask = tier0_bucket_mask;
        uint64_t bb = h >> tier0_bucket_shift;
        for (size_t p = 0; p < MAX_PROBES; p++) {
            size_t bi = (bb + p) & mask;
            uint16_t m = match_fingerprint(fingerprints[bi], fp);
            while (m) { size_t s = __builtin_ctz(m); auto& e = entries[bi][s]; if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) { fingerprints[bi][s] = TOMBSTONE; count--; return true; } m &= m - 1; }
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

static const char hex_chars_g[] = "0123456789abcdef";
static void u64_to_hex(uint64_t val, char* buf) {
    for (int i = KEY_LEN - 1; i >= 0; i--) { buf[i] = hex_chars_g[val & 0xF]; val >>= 4; }
}

static uint64_t median_val(uint64_t* arr, int n) {
    std::sort(arr, arr + n); return arr[n / 2];
}

constexpr uint64_t KEY_SEED = 0xDEADBEEF12345678;
constexpr uint64_t MISS_SEED = 0xCAFEBABE87654321;
constexpr int TOTAL_RUNS = 12;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;

struct KeyData {
    std::vector<char> key_buf, miss_buf;
    std::vector<std::string_view> keys, miss_keys;
    std::vector<size_t> order;
    size_t fill;

    void generate(size_t f) {
        fill = f;
        key_buf.resize(fill * KEY_LEN);
        miss_buf.resize(fill * KEY_LEN);
        keys.resize(fill);
        miss_keys.resize(fill);
        order.resize(fill);

        uint64_t ks = KEY_SEED, ms = MISS_SEED;
        for (size_t i = 0; i < fill; i++) {
            u64_to_hex(splitmix64(ks), &key_buf[i * KEY_LEN]);
            u64_to_hex(splitmix64(ms), &miss_buf[i * KEY_LEN]);
            keys[i] = std::string_view(&key_buf[i * KEY_LEN], KEY_LEN);
            miss_keys[i] = std::string_view(&miss_buf[i * KEY_LEN], KEY_LEN);
            order[i] = i;
        }
        uint64_t rng = 42;
        for (size_t i = fill - 1; i > 0; i--) {
            size_t j = splitmix64(rng) % (i + 1);
            std::swap(order[i], order[j]);
        }
    }
};

// ---- Test 1: Size sweep (both sides, shuffled, 50% load) ----
static void size_sweep() {
    printf("=== SIZE SWEEP (50%% load, shuffled, string keys) ===\n");
    constexpr size_t sizes[] = {8192, 16384, 32768, 65536, 131072, 262144, 524288,
                                 1048576, 2097152, 4194304, 8388608};

    for (size_t n : sizes) {
        size_t fill = n / 2;
        KeyData kd;
        kd.generate(fill);

        // Elastic hash
        uint64_t e_lkp[MEASURED], e_mis[MEASURED], e_ins[MEASURED], e_del[MEASURED];
        for (int r = 0; r < TOTAL_RUNS; r++) {
            ElasticHashCpp map; map.init(n);
            auto s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) map.insert(&kd.key_buf[i * KEY_LEN], KEY_LEN, i);
            auto e = std::chrono::steady_clock::now();
            uint64_t ins = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();

            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) do_not_optimize(map.get(&kd.key_buf[kd.order[i] * KEY_LEN], KEY_LEN));
            e = std::chrono::steady_clock::now();
            uint64_t lkp = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();

            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) do_not_optimize(map.get(&kd.miss_buf[kd.order[i] * KEY_LEN], KEY_LEN));
            e = std::chrono::steady_clock::now();
            uint64_t mis = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();

            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill / 2; i++) do_not_optimize(map.remove(&kd.key_buf[i * KEY_LEN], KEY_LEN));
            e = std::chrono::steady_clock::now();
            uint64_t del = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();

            if (r >= WARMUP) { int idx = r - WARMUP; e_ins[idx] = ins; e_lkp[idx] = lkp; e_mis[idx] = mis; e_del[idx] = del; }
            map.destroy();
        }

        // Abseil
        uint64_t a_lkp[MEASURED], a_mis[MEASURED], a_ins[MEASURED], a_del[MEASURED];
        for (int r = 0; r < TOTAL_RUNS; r++) {
            absl::flat_hash_map<std::string_view, uint64_t> map;
            map.reserve(n);
            auto s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) map.emplace(kd.keys[i], i);
            auto e = std::chrono::steady_clock::now();
            uint64_t ins = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();

            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) { auto it = map.find(kd.keys[kd.order[i]]); do_not_optimize(it->second); }
            e = std::chrono::steady_clock::now();
            uint64_t lkp = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();

            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) { auto it = map.find(kd.miss_keys[kd.order[i]]); do_not_optimize(it == map.end()); }
            e = std::chrono::steady_clock::now();
            uint64_t mis = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();

            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill / 2; i++) { auto it = map.find(kd.keys[i]); if (it != map.end()) map.erase(it); }
            e = std::chrono::steady_clock::now();
            uint64_t del = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();

            if (r >= WARMUP) { int idx = r - WARMUP; a_ins[idx] = ins; a_lkp[idx] = lkp; a_mis[idx] = mis; a_del[idx] = del; }
        }

        uint64_t el = median_val(e_lkp, MEASURED), al = median_val(a_lkp, MEASURED);
        uint64_t em = median_val(e_mis, MEASURED), am = median_val(a_mis, MEASURED);
        uint64_t ei = median_val(e_ins, MEASURED), ai = median_val(a_ins, MEASURED);
        uint64_t ed = median_val(e_del, MEASURED), ad = median_val(a_del, MEASURED);
        printf("SIZE\tn=%zu\telastic_hit=%llu\tabseil_hit=%llu\thit_ratio=%.2f\telastic_miss=%llu\tabseil_miss=%llu\tmiss_ratio=%.2f\telastic_ins=%llu\tabseil_ins=%llu\tins_ratio=%.2f\telastic_del=%llu\tabseil_del=%llu\tdel_ratio=%.2f\n",
               n, (unsigned long long)el, (unsigned long long)al, (double)al/(double)el,
               (unsigned long long)em, (unsigned long long)am, (double)am/(double)em,
               (unsigned long long)ei, (unsigned long long)ai, (double)ai/(double)ei,
               (unsigned long long)ed, (unsigned long long)ad, (double)ad/(double)ed);
        fflush(stdout);
    }
}

// ---- Test 2: Hot-set benchmark ----
static void hot_set_bench() {
    printf("\n=== HOT-SET BENCHMARK (1M table, 50%% load, varying hot set size) ===\n");
    constexpr size_t N = 1048576;
    constexpr size_t FILL = N / 2;
    constexpr size_t HOT_SIZES[] = {1024, 4096, 16384, 65536, FILL};
    constexpr size_t OPS = 1000000; // 1M lookups

    KeyData kd;
    kd.generate(FILL);

    for (size_t hot_size : HOT_SIZES) {
        if (hot_size > FILL) continue;

        // Generate hot access pattern: randomly pick from first hot_size keys
        std::vector<size_t> hot_order(OPS);
        uint64_t rng = 12345;
        for (size_t i = 0; i < OPS; i++) {
            hot_order[i] = splitmix64(rng) % hot_size;
        }

        // Elastic
        uint64_t e_lkp[MEASURED];
        for (int r = 0; r < TOTAL_RUNS; r++) {
            ElasticHashCpp map; map.init(N);
            for (size_t i = 0; i < FILL; i++) map.insert(&kd.key_buf[i * KEY_LEN], KEY_LEN, i);
            auto s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < OPS; i++) do_not_optimize(map.get(&kd.key_buf[hot_order[i] * KEY_LEN], KEY_LEN));
            auto e = std::chrono::steady_clock::now();
            if (r >= WARMUP) e_lkp[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            map.destroy();
        }

        // Abseil
        uint64_t a_lkp[MEASURED];
        for (int r = 0; r < TOTAL_RUNS; r++) {
            absl::flat_hash_map<std::string_view, uint64_t> map;
            map.reserve(N);
            for (size_t i = 0; i < FILL; i++) map.emplace(kd.keys[i], i);
            auto s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < OPS; i++) { auto it = map.find(kd.keys[hot_order[i]]); do_not_optimize(it->second); }
            auto e = std::chrono::steady_clock::now();
            if (r >= WARMUP) a_lkp[r - WARMUP] = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
        }

        uint64_t el = median_val(e_lkp, MEASURED), al = median_val(a_lkp, MEASURED);
        printf("HOTSET\thot=%zu\telastic=%llu\tabseil=%llu\tratio=%.2f\n",
               hot_size, (unsigned long long)el, (unsigned long long)al, (double)al / (double)el);
        fflush(stdout);
    }
}

// ---- Test 3: Latency distribution (rdtsc per lookup) ----
static inline uint64_t rdtsc() {
    unsigned int lo, hi;
    __asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

static void latency_distribution() {
    printf("\n=== LATENCY DISTRIBUTION (1M table, 50%% load, per-lookup cycles) ===\n");
    constexpr size_t N = 1048576;
    constexpr size_t FILL = N / 2;
    constexpr size_t SAMPLE = 100000; // measure 100K lookups

    KeyData kd;
    kd.generate(FILL);

    // Sample a random subset of shuffled lookups
    std::vector<size_t> sample_idx(SAMPLE);
    uint64_t rng = 99999;
    for (size_t i = 0; i < SAMPLE; i++) sample_idx[i] = splitmix64(rng) % FILL;

    // Elastic
    std::vector<uint64_t> e_cycles(SAMPLE);
    {
        ElasticHashCpp map; map.init(N);
        for (size_t i = 0; i < FILL; i++) map.insert(&kd.key_buf[i * KEY_LEN], KEY_LEN, i);
        // Warmup
        for (size_t i = 0; i < SAMPLE; i++) do_not_optimize(map.get(&kd.key_buf[sample_idx[i] * KEY_LEN], KEY_LEN));
        // Measure
        for (size_t i = 0; i < SAMPLE; i++) {
            uint64_t t0 = rdtsc();
            do_not_optimize(map.get(&kd.key_buf[sample_idx[i] * KEY_LEN], KEY_LEN));
            uint64_t t1 = rdtsc();
            e_cycles[i] = t1 - t0;
        }
        map.destroy();
    }

    // Abseil
    std::vector<uint64_t> a_cycles(SAMPLE);
    {
        absl::flat_hash_map<std::string_view, uint64_t> map;
        map.reserve(N);
        for (size_t i = 0; i < FILL; i++) map.emplace(kd.keys[i], i);
        // Warmup
        for (size_t i = 0; i < SAMPLE; i++) { auto it = map.find(kd.keys[sample_idx[i]]); do_not_optimize(it->second); }
        // Measure
        for (size_t i = 0; i < SAMPLE; i++) {
            uint64_t t0 = rdtsc();
            auto it = map.find(kd.keys[sample_idx[i]]);
            do_not_optimize(it->second);
            uint64_t t1 = rdtsc();
            a_cycles[i] = t1 - t0;
        }
    }

    std::sort(e_cycles.begin(), e_cycles.end());
    std::sort(a_cycles.begin(), a_cycles.end());

    auto pct = [&](const std::vector<uint64_t>& v, double p) -> uint64_t {
        return v[(size_t)(p / 100.0 * (v.size() - 1))];
    };

    printf("LATENCY\timpl=elastic\tp50=%llu\tp90=%llu\tp99=%llu\tp99.9=%llu\tmax=%llu\n",
           (unsigned long long)pct(e_cycles, 50), (unsigned long long)pct(e_cycles, 90),
           (unsigned long long)pct(e_cycles, 99), (unsigned long long)pct(e_cycles, 99.9),
           (unsigned long long)e_cycles.back());
    printf("LATENCY\timpl=abseil\tp50=%llu\tp90=%llu\tp99=%llu\tp99.9=%llu\tmax=%llu\n",
           (unsigned long long)pct(a_cycles, 50), (unsigned long long)pct(a_cycles, 90),
           (unsigned long long)pct(a_cycles, 99), (unsigned long long)pct(a_cycles, 99.9),
           (unsigned long long)a_cycles.back());
    fflush(stdout);
}

// ---- Test 4: Load factor sweep at 1M ----
static void load_sweep() {
    printf("\n=== LOAD FACTOR SWEEP (1M table, shuffled, string keys) ===\n");
    constexpr size_t N = 1048576;
    constexpr int loads[] = {10, 25, 50, 75, 90, 99};

    for (int pct : loads) {
        size_t fill = N * pct / 100;
        KeyData kd;
        kd.generate(fill);

        uint64_t e_lkp[MEASURED], a_lkp[MEASURED], e_mis[MEASURED], a_mis[MEASURED];
        uint64_t e_ins[MEASURED], a_ins[MEASURED], e_del[MEASURED], a_del[MEASURED];

        for (int r = 0; r < TOTAL_RUNS; r++) {
            ElasticHashCpp map; map.init(N);
            auto s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) map.insert(&kd.key_buf[i * KEY_LEN], KEY_LEN, i);
            auto e = std::chrono::steady_clock::now();
            uint64_t ins = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) do_not_optimize(map.get(&kd.key_buf[kd.order[i] * KEY_LEN], KEY_LEN));
            e = std::chrono::steady_clock::now();
            uint64_t lkp = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) do_not_optimize(map.get(&kd.miss_buf[kd.order[i] * KEY_LEN], KEY_LEN));
            e = std::chrono::steady_clock::now();
            uint64_t mis = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill / 2; i++) do_not_optimize(map.remove(&kd.key_buf[i * KEY_LEN], KEY_LEN));
            e = std::chrono::steady_clock::now();
            uint64_t del = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            if (r >= WARMUP) { int idx = r - WARMUP; e_ins[idx] = ins; e_lkp[idx] = lkp; e_mis[idx] = mis; e_del[idx] = del; }
            map.destroy();
        }
        for (int r = 0; r < TOTAL_RUNS; r++) {
            absl::flat_hash_map<std::string_view, uint64_t> map; map.reserve(N);
            auto s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) map.emplace(kd.keys[i], i);
            auto e = std::chrono::steady_clock::now();
            uint64_t ins = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) { auto it = map.find(kd.keys[kd.order[i]]); do_not_optimize(it->second); }
            e = std::chrono::steady_clock::now();
            uint64_t lkp = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill; i++) { auto it = map.find(kd.miss_keys[kd.order[i]]); do_not_optimize(it == map.end()); }
            e = std::chrono::steady_clock::now();
            uint64_t mis = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            s = std::chrono::steady_clock::now();
            for (size_t i = 0; i < fill / 2; i++) { auto it = map.find(kd.keys[i]); if (it != map.end()) map.erase(it); }
            e = std::chrono::steady_clock::now();
            uint64_t del = std::chrono::duration_cast<std::chrono::microseconds>(e - s).count();
            if (r >= WARMUP) { int idx = r - WARMUP; a_ins[idx] = ins; a_lkp[idx] = lkp; a_mis[idx] = mis; a_del[idx] = del; }
        }

        uint64_t el = median_val(e_lkp, MEASURED), al = median_val(a_lkp, MEASURED);
        uint64_t em = median_val(e_mis, MEASURED), am = median_val(a_mis, MEASURED);
        uint64_t ei = median_val(e_ins, MEASURED), ai = median_val(a_ins, MEASURED);
        uint64_t ed = median_val(e_del, MEASURED), ad = median_val(a_del, MEASURED);
        printf("LOAD\tload=%d\telastic_hit=%llu\tabseil_hit=%llu\thit_ratio=%.2f\telastic_miss=%llu\tabseil_miss=%llu\tmiss_ratio=%.2f\telastic_ins=%llu\tabseil_ins=%llu\tins_ratio=%.2f\telastic_del=%llu\tabseil_del=%llu\tdel_ratio=%.2f\n",
               pct, (unsigned long long)el, (unsigned long long)al, (double)al/(double)el,
               (unsigned long long)em, (unsigned long long)am, (double)am/(double)em,
               (unsigned long long)ei, (unsigned long long)ai, (double)ai/(double)ei,
               (unsigned long long)ed, (unsigned long long)ad, (double)ad/(double)ed);
        fflush(stdout);
    }
}

int main(int argc, char** argv) {
    if (argc > 1 && std::string_view(argv[1]) == "size") { size_sweep(); return 0; }
    if (argc > 1 && std::string_view(argv[1]) == "hot") { hot_set_bench(); return 0; }
    if (argc > 1 && std::string_view(argv[1]) == "latency") { latency_distribution(); return 0; }
    if (argc > 1 && std::string_view(argv[1]) == "load") { load_sweep(); return 0; }

    // Default: run all
    size_sweep();
    hot_set_bench();
    latency_distribution();
    load_sweep();
    return 0;
}
