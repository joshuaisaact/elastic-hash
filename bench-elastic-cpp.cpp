// C++ port of elastic hash — same algorithm, same layout, same compiler as abseil.
// Purpose: isolate data structure advantage from Zig/LLVM codegen advantage.
//
// Uses wyhash (matching the Zig version) and the same tiered bucket structure
// with SIMD fingerprint matching.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <vector>
#include <string_view>

#ifdef __ARM_NEON
#include <arm_neon.h>
#else
#include <immintrin.h>
#endif

// ---- wyhash (minimal, matching Zig's std.hash.Wyhash for 16-byte keys) ----
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
    // Zig's Wyhash with seed=0, secret=default
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

// ---- Constants ----
static constexpr size_t BUCKET_SIZE = 16;
static constexpr size_t MAX_PROBES = 7;
static constexpr uint8_t TOMBSTONE = 0xFF;
static constexpr size_t KEY_LEN = 16;

// ---- SIMD fingerprint matching ----
#ifdef __ARM_NEON
static inline uint16_t match_fingerprint(const uint8_t* fps, uint8_t fp) {
    uint8x16_t v = vld1q_u8(fps);
    uint8x16_t needle = vdupq_n_u8(fp);
    uint8x16_t cmp = vceqq_u8(v, needle);
    // Extract bitmask: one bit per lane
    static const uint8_t shift_table[16] = {1,2,4,8,16,32,64,128,1,2,4,8,16,32,64,128};
    uint8x16_t shift = vld1q_u8(shift_table);
    uint8x16_t bits = vandq_u8(cmp, shift);
    uint8x8_t lo = vget_low_u8(bits);
    uint8x8_t hi = vget_high_u8(bits);
    uint64_t lo_sum, hi_sum;
    // Use pairwise addition to collapse each half to a single byte
    lo = vpadd_u8(lo, lo); lo = vpadd_u8(lo, lo); lo = vpadd_u8(lo, lo);
    hi = vpadd_u8(hi, hi); hi = vpadd_u8(hi, hi); hi = vpadd_u8(hi, hi);
    lo_sum = vget_lane_u8(lo, 0);
    hi_sum = vget_lane_u8(hi, 0);
    return (uint16_t)((hi_sum << 8) | lo_sum);
}

static inline uint16_t match_empty(const uint8_t* fps) {
    return match_fingerprint(fps, 0);
}
#else
static inline uint16_t match_fingerprint(const uint8_t* fps, uint8_t fp) {
    __m128i v = _mm_loadu_si128((const __m128i*)fps);
    __m128i needle = _mm_set1_epi8((char)fp);
    __m128i cmp = _mm_cmpeq_epi8(v, needle);
    return (uint16_t)_mm_movemask_epi8(cmp);
}

static inline uint16_t match_empty(const uint8_t* fps) {
    return match_fingerprint(fps, 0);
}
#endif

static inline uint16_t match_empty_or_tombstone(const uint8_t* fps) {
    return match_empty(fps) | match_fingerprint(fps, TOMBSTONE);
}

// ---- Data structures ----
struct StringEntry {
    const char* key_ptr;
    size_t key_len;
    uint64_t value;
};

struct ElasticHashCpp {
    // Hot path fields
    uint8_t (*fingerprints)[BUCKET_SIZE];
    StringEntry (*entries)[BUCKET_SIZE];
    size_t tier0_bucket_mask;
    unsigned tier0_bucket_shift;

    // Tier metadata
    size_t* tier_starts;
    size_t* tier_bucket_counts;
    size_t* tier_slot_counts;
    size_t num_tiers;
    size_t total_buckets;
    size_t tier0_bucket_count;
    size_t count;
    size_t current_batch;

    static uint64_t hash(const char* key, size_t len) {
        return wyhash(key, len);
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
        uint64_t base = h >> shift;
        return (base + probe) & (num_buckets - 1);
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
        count = 0;
        current_batch = 0;
    }

    void destroy() {
        free(fingerprints);
        free(entries);
        free(tier_starts);
        free(tier_bucket_counts);
        free(tier_slot_counts);
    }

    static constexpr double DELTA = 0.01;
    static constexpr double DELTA_HALF = DELTA / 2.0;
    static constexpr double PROBE_CONSTANT = 16.0;

    double get_empty_fraction(size_t tier) const {
        double used = (double)tier_slot_counts[tier];
        double total = (double)(tier_bucket_counts[tier] * BUCKET_SIZE);
        return 1.0 - used / total;
    }

    static size_t probe_limit(double epsilon) {
        if (epsilon <= 0.0) return MAX_PROBES;
        double log_inv_eps = log(1.0 / epsilon);
        double log_inv_delta = log(1.0 / DELTA);
        double limit = PROBE_CONSTANT * std::min(log_inv_eps * log_inv_eps, log_inv_delta);
        return std::min((size_t)std::max(1.0, limit), MAX_PROBES);
    }

    bool try_insert_with_limit(size_t tier, uint64_t h, uint8_t fp,
                               const char* key, size_t key_len, uint64_t value, size_t limit) {
        size_t num_buckets = tier_bucket_counts[tier];
        size_t max_probe = std::min(limit, num_buckets);
        for (size_t probe = 0; probe < max_probe; probe++) {
            size_t rel = bucket_index(h, probe, num_buckets);
            size_t abs_idx = tier_starts[tier] + rel;
            uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
            if (mask) {
                size_t slot = __builtin_ctz(mask);
                fingerprints[abs_idx][slot] = fp;
                entries[abs_idx][slot] = {key, key_len, value};
                tier_slot_counts[tier]++;
                count++;
                return true;
            }
        }
        return false;
    }

    void insert(const char* key, size_t key_len, uint64_t value) {
        uint64_t h = hash(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t i = current_batch;

        if (i == 0) {
            insert_into_tier(0, h, fp, key, key_len, value);
            if (get_empty_fraction(0) <= 0.12) current_batch = 1;
            return;
        }

        if (i >= num_tiers) {
            insert_any_tier(h, fp, key, key_len, value);
            return;
        }

        size_t primary = i - 1;
        size_t secondary = i;
        double e1 = get_empty_fraction(primary);
        double e2 = get_empty_fraction(secondary);

        if (e1 > DELTA_HALF && e2 > 0.25) {
            if (!try_insert_with_limit(primary, h, fp, key, key_len, value, probe_limit(e1))) {
                insert_into_tier(secondary, h, fp, key, key_len, value);
            }
        } else if (e1 <= DELTA_HALF) {
            insert_into_tier(secondary, h, fp, key, key_len, value);
        } else {
            insert_into_tier(primary, h, fp, key, key_len, value);
        }

        if (e1 <= DELTA_HALF && e2 <= 0.25 && i + 1 < num_tiers) {
            current_batch = i + 1;
        }
    }

    void insert_into_tier(size_t tier, uint64_t h, uint8_t fp,
                          const char* key, size_t key_len, uint64_t value) {
        size_t num_buckets = tier_bucket_counts[tier];
        size_t max_probe = std::min(num_buckets, MAX_PROBES);
        for (size_t probe = 0; probe < max_probe; probe++) {
            size_t rel = bucket_index(h, probe, num_buckets);
            size_t abs_idx = tier_starts[tier] + rel;
            uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
            if (mask) {
                size_t slot = __builtin_ctz(mask);
                fingerprints[abs_idx][slot] = fp;
                entries[abs_idx][slot] = {key, key_len, value};
                tier_slot_counts[tier]++;
                count++;
                return;
            }
        }
        insert_any_tier(h, fp, key, key_len, value);
    }

    void insert_any_tier(uint64_t h, uint8_t fp,
                         const char* key, size_t key_len, uint64_t value) {
        for (size_t j = 1; j <= MAX_PROBES; j++) {
            for (size_t t = 0; t < num_tiers; t++) {
                size_t nb = tier_bucket_counts[t];
                if (j - 1 >= nb) continue;
                size_t rel = bucket_index(h, j - 1, nb);
                size_t abs_idx = tier_starts[t] + rel;
                uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
                if (mask) {
                    size_t slot = __builtin_ctz(mask);
                    fingerprints[abs_idx][slot] = fp;
                    entries[abs_idx][slot] = {key, key_len, value};
                    tier_slot_counts[t]++;
                    count++;
                    return;
                }
            }
        }
    }

    // The critical function — same algorithm as Zig version
    __attribute__((noinline))
    uint64_t* get_overflow(uint64_t h, const char* key, size_t key_len, uint8_t fp) const {
        if (num_tiers <= 1) return nullptr;
        size_t nb = tier_bucket_counts[1];
        size_t ts = tier_starts[1];
        size_t max_p = std::min(MAX_PROBES, nb);
        for (size_t probe = 0; probe < max_p; probe++) {
            size_t abs_idx = ts + bucket_index(h, probe, nb);
            // Check fingerprint matches
            uint16_t mask = match_fingerprint(fingerprints[abs_idx], fp);
            while (mask) {
                size_t slot = __builtin_ctz(mask);
                auto& e = entries[abs_idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                    return (uint64_t*)&e.value;
                }
                mask &= mask - 1;
            }
            if (match_empty(fingerprints[abs_idx])) return nullptr;
        }
        return nullptr;
    }

    uint64_t* get(const char* key, size_t key_len) const {
        uint64_t h = hash(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t mask = tier0_bucket_mask;
        uint64_t bucket_base = h >> tier0_bucket_shift;

        // Prefetch entry data for probe 0
        __builtin_prefetch(&entries[bucket_base & mask], 0, 3);

        for (size_t probe = 0; probe < MAX_PROBES; probe++) {
            size_t bucket_idx = (bucket_base + probe) & mask;
            // Check fingerprint matches
            uint16_t fpmask = match_fingerprint(fingerprints[bucket_idx], fp);
            while (fpmask) {
                size_t slot = __builtin_ctz(fpmask);
                auto& e = entries[bucket_idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                    return (uint64_t*)&e.value;
                }
                fpmask &= fpmask - 1;
            }
            // Early termination on empty (cold path)
            if (__builtin_expect(match_empty(fingerprints[bucket_idx]) != 0, 0)) {
                return nullptr;
            }
        }

        return const_cast<ElasticHashCpp*>(this)->get_overflow(h, key, key_len, fp);
    }

    bool remove(const char* key, size_t key_len) {
        uint64_t h = hash(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t mask = tier0_bucket_mask;
        uint64_t bucket_base = h >> tier0_bucket_shift;

        for (size_t probe = 0; probe < MAX_PROBES; probe++) {
            size_t bucket_idx = (bucket_base + probe) & mask;
            uint16_t fpmask = match_fingerprint(fingerprints[bucket_idx], fp);
            while (fpmask) {
                size_t slot = __builtin_ctz(fpmask);
                auto& e = entries[bucket_idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                    fingerprints[bucket_idx][slot] = TOMBSTONE;
                    count--;
                    return true;
                }
                fpmask &= fpmask - 1;
            }
        }
        return false;
    }
};

// ---- Benchmark harness (identical to abseil benchmark) ----
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

constexpr uint64_t KEY_SEED = 0xDEADBEEF12345678;
constexpr uint64_t MISS_SEED = 0xCAFEBABE87654321;
constexpr int TOTAL_RUNS = 12;
constexpr int WARMUP = 2;
constexpr int MEASURED = TOTAL_RUNS - WARMUP;

static void bench(size_t n, size_t fill, int load_pct) {
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
        ElasticHashCpp map;
        map.init(n);

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

        // Delete half
        start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < fill / 2; i++) {
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

    printf("ELASTIC-CPP\tn=%zu\tload=%d\tinsert_us=%llu\tlookup_us=%llu\tdelete_us=%llu\tmiss_us=%llu\n",
           n, load_pct,
           median_val(ins, MEASURED), median_val(lkp, MEASURED),
           median_val(del, MEASURED), median_val(mis, MEASURED));
    fflush(stdout);
}

int main() {
    printf("=== Elastic Hash C++ port (same compiler as abseil) ===\n\n");

    // Load factor sweep at 1M
    int pcts[] = {10, 25, 50, 75, 90, 99};
    for (int pct : pcts) {
        bench(1048576, 1048576 * pct / 100, pct);
    }

    printf("\nDONE\n");
    return 0;
}
