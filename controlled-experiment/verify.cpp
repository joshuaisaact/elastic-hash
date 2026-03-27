// Correctness test for all 4 implementations.
// We include each impl's HashTable in a separate namespace.

#include "common.h"
#include "verify_harness.h"

// We can't re-include the impl files since they have main().
// Instead, we duplicate the 4 HashTable structs here under namespaces.
// This is the price of the "each impl is a standalone program" design.

// ============================================================
// 1. Elastic + Linear
// ============================================================
namespace elastic_linear {

struct HashTable {
    uint8_t (*fingerprints)[BUCKET_SIZE];
    StringEntry (*entries)[BUCKET_SIZE];
    size_t tier0_bucket_mask;
    unsigned tier0_bucket_shift;
    size_t* tier_starts;
    size_t* tier_bucket_counts;
    size_t* tier_slot_counts;
    size_t num_tiers;
    size_t total_buckets;
    size_t tier0_bucket_count;
    size_t count;
    size_t current_batch;

    static constexpr double DELTA = 0.01;
    static constexpr double DELTA_HALF = DELTA / 2.0;
    static constexpr double PROBE_CONSTANT = 16.0;

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
        free(fingerprints); free(entries);
        free(tier_starts); free(tier_bucket_counts); free(tier_slot_counts);
    }

    double get_empty_fraction(size_t tier) const {
        return 1.0 - (double)tier_slot_counts[tier] / (double)(tier_bucket_counts[tier] * BUCKET_SIZE);
    }

    static size_t probe_limit(double epsilon) {
        if (epsilon <= 0.0) return MAX_PROBES;
        double l1 = log(1.0 / epsilon), l2 = log(1.0 / DELTA);
        return std::min((size_t)std::max(1.0, PROBE_CONSTANT * std::min(l1 * l1, l2)), MAX_PROBES);
    }

    bool try_insert_with_limit(size_t tier, uint64_t h, uint8_t fp,
                               const char* key, size_t key_len, uint64_t value, size_t limit) {
        size_t nb = tier_bucket_counts[tier], mp = std::min(limit, nb);
        for (size_t probe = 0; probe < mp; probe++) {
            size_t abs_idx = tier_starts[tier] + bucket_index(h, probe, nb);
            uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
            if (mask) {
                size_t slot = __builtin_ctz(mask);
                fingerprints[abs_idx][slot] = fp;
                entries[abs_idx][slot] = {key, key_len, value};
                tier_slot_counts[tier]++; count++;
                return true;
            }
        }
        return false;
    }

    void insert_into_tier(size_t tier, uint64_t h, uint8_t fp,
                          const char* key, size_t key_len, uint64_t value) {
        size_t nb = tier_bucket_counts[tier], mp = std::min(nb, MAX_PROBES);
        for (size_t probe = 0; probe < mp; probe++) {
            size_t abs_idx = tier_starts[tier] + bucket_index(h, probe, nb);
            uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
            if (mask) {
                size_t slot = __builtin_ctz(mask);
                fingerprints[abs_idx][slot] = fp;
                entries[abs_idx][slot] = {key, key_len, value};
                tier_slot_counts[tier]++; count++;
                return;
            }
        }
        insert_any_tier(h, fp, key, key_len, value);
    }

    void insert_any_tier(uint64_t h, uint8_t fp, const char* key, size_t key_len, uint64_t value) {
        for (size_t j = 1; j <= MAX_PROBES; j++) {
            for (size_t t = 0; t < num_tiers; t++) {
                size_t nb = tier_bucket_counts[t];
                if (j - 1 >= nb) continue;
                size_t abs_idx = tier_starts[t] + bucket_index(h, j - 1, nb);
                uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
                if (mask) {
                    size_t slot = __builtin_ctz(mask);
                    fingerprints[abs_idx][slot] = fp;
                    entries[abs_idx][slot] = {key, key_len, value};
                    tier_slot_counts[t]++; count++;
                    return;
                }
            }
        }
    }

    void insert(const char* key, size_t key_len, uint64_t value) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t i = current_batch;
        if (i == 0) {
            insert_into_tier(0, h, fp, key, key_len, value);
            if (get_empty_fraction(0) <= 0.12) current_batch = 1;
            return;
        }
        if (i >= num_tiers) { insert_any_tier(h, fp, key, key_len, value); return; }
        size_t primary = i - 1, secondary = i;
        double e1 = get_empty_fraction(primary), e2 = get_empty_fraction(secondary);
        if (e1 > DELTA_HALF && e2 > 0.25) {
            if (!try_insert_with_limit(primary, h, fp, key, key_len, value, probe_limit(e1)))
                insert_into_tier(secondary, h, fp, key, key_len, value);
        } else if (e1 <= DELTA_HALF) {
            insert_into_tier(secondary, h, fp, key, key_len, value);
        } else {
            insert_into_tier(primary, h, fp, key, key_len, value);
        }
        if (e1 <= DELTA_HALF && e2 <= 0.25 && i + 1 < num_tiers) current_batch = i + 1;
    }

    uint64_t* get(const char* key, size_t key_len) const {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        // Search all tiers
        for (size_t t = 0; t < num_tiers; t++) {
            size_t nb = tier_bucket_counts[t], ts = tier_starts[t];
            size_t mp = std::min(MAX_PROBES, nb);
            for (size_t probe = 0; probe < mp; probe++) {
                size_t abs_idx = ts + bucket_index(h, probe, nb);
                uint16_t fpmask = match_fingerprint(fingerprints[abs_idx], fp);
                while (fpmask) {
                    size_t slot = __builtin_ctz(fpmask);
                    auto& e = entries[abs_idx][slot];
                    if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0)
                        return (uint64_t*)&e.value;
                    fpmask &= fpmask - 1;
                }
                if (__builtin_expect(match_empty(fingerprints[abs_idx]) != 0, 0)) break;
            }
        }
        return nullptr;
    }

    bool remove(const char* key, size_t key_len) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        for (size_t t = 0; t < num_tiers; t++) {
            size_t nb = tier_bucket_counts[t], ts = tier_starts[t];
            size_t mp = std::min(MAX_PROBES, nb);
            for (size_t probe = 0; probe < mp; probe++) {
                size_t abs_idx = ts + bucket_index(h, probe, nb);
                uint16_t fpmask = match_fingerprint(fingerprints[abs_idx], fp);
                while (fpmask) {
                    size_t slot = __builtin_ctz(fpmask);
                    auto& e = entries[abs_idx][slot];
                    if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                        fingerprints[abs_idx][slot] = TOMBSTONE;
                        tier_slot_counts[t]--; count--;
                        return true;
                    }
                    fpmask &= fpmask - 1;
                }
                if (__builtin_expect(match_empty(fingerprints[abs_idx]) != 0, 0)) break;
            }
        }
        return false;
    }
};

} // namespace elastic_linear

// ============================================================
// 2. Flat + Triangular
// ============================================================
namespace flat_triangular {

struct HashTable {
    uint8_t (*fingerprints)[BUCKET_SIZE];
    StringEntry (*entries)[BUCKET_SIZE];
    size_t bucket_count, bucket_mask;
    unsigned bucket_shift;
    size_t count;

    static size_t bucket_index(uint64_t h, size_t probe, size_t num_buckets) {
        unsigned bits = __builtin_ctzll(num_buckets);
        unsigned shift = std::min(64u - bits, 63u);
        uint64_t base = h >> shift;
        return (base + probe * (probe + 1) / 2) & (num_buckets - 1);
    }

    void init(size_t n) {
        size_t capacity = 1;
        while (capacity < n) capacity <<= 1;
        capacity *= 2;
        bucket_count = std::max(capacity / BUCKET_SIZE, (size_t)1);
        fingerprints = (uint8_t(*)[BUCKET_SIZE])calloc(bucket_count, BUCKET_SIZE);
        entries = (StringEntry(*)[BUCKET_SIZE])calloc(bucket_count, BUCKET_SIZE * sizeof(StringEntry));
        bucket_mask = bucket_count - 1;
        bucket_shift = 64 - __builtin_ctzll(bucket_count);
        count = 0;
    }

    void destroy() { free(fingerprints); free(entries); }

    void insert(const char* key, size_t key_len, uint64_t value) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        for (size_t probe = 0; probe < bucket_count; probe++) {
            size_t idx = bucket_index(h, probe, bucket_count);
            uint16_t mask = match_empty_or_tombstone(fingerprints[idx]);
            if (mask) {
                size_t slot = __builtin_ctz(mask);
                fingerprints[idx][slot] = fp;
                entries[idx][slot] = {key, key_len, value};
                count++;
                return;
            }
        }
    }

    uint64_t* get(const char* key, size_t key_len) const {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t mp = std::min(bucket_count, MAX_PROBES);
        for (size_t probe = 0; probe < mp; probe++) {
            size_t idx = bucket_index(h, probe, bucket_count);
            uint16_t fpmask = match_fingerprint(fingerprints[idx], fp);
            while (fpmask) {
                size_t slot = __builtin_ctz(fpmask);
                auto& e = entries[idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0)
                    return (uint64_t*)&e.value;
                fpmask &= fpmask - 1;
            }
            if (__builtin_expect(match_empty(fingerprints[idx]) != 0, 0)) return nullptr;
        }
        return nullptr;
    }

    bool remove(const char* key, size_t key_len) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t mp = std::min(bucket_count, MAX_PROBES);
        for (size_t probe = 0; probe < mp; probe++) {
            size_t idx = bucket_index(h, probe, bucket_count);
            uint16_t fpmask = match_fingerprint(fingerprints[idx], fp);
            while (fpmask) {
                size_t slot = __builtin_ctz(fpmask);
                auto& e = entries[idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                    fingerprints[idx][slot] = TOMBSTONE;
                    count--;
                    return true;
                }
                fpmask &= fpmask - 1;
            }
            if (__builtin_expect(match_empty(fingerprints[idx]) != 0, 0)) return false;
        }
        return false;
    }
};

} // namespace flat_triangular

// ============================================================
// 3. Elastic + Triangular
// ============================================================
namespace elastic_triangular {

struct HashTable {
    uint8_t (*fingerprints)[BUCKET_SIZE];
    StringEntry (*entries)[BUCKET_SIZE];
    size_t tier0_bucket_mask;
    unsigned tier0_bucket_shift;
    size_t* tier_starts;
    size_t* tier_bucket_counts;
    size_t* tier_slot_counts;
    size_t num_tiers;
    size_t total_buckets;
    size_t tier0_bucket_count;
    size_t count;
    size_t current_batch;

    static constexpr double DELTA = 0.01;
    static constexpr double DELTA_HALF = DELTA / 2.0;
    static constexpr double PROBE_CONSTANT = 16.0;

    static size_t bucket_index(uint64_t h, size_t probe, size_t num_buckets) {
        unsigned bits = __builtin_ctzll(num_buckets);
        unsigned shift = std::min(64u - bits, 63u);
        uint64_t base = h >> shift;
        return (base + probe * (probe + 1) / 2) & (num_buckets - 1);
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
        free(fingerprints); free(entries);
        free(tier_starts); free(tier_bucket_counts); free(tier_slot_counts);
    }

    double get_empty_fraction(size_t tier) const {
        return 1.0 - (double)tier_slot_counts[tier] / (double)(tier_bucket_counts[tier] * BUCKET_SIZE);
    }

    static size_t probe_limit(double epsilon) {
        if (epsilon <= 0.0) return MAX_PROBES;
        double l1 = log(1.0 / epsilon), l2 = log(1.0 / DELTA);
        return std::min((size_t)std::max(1.0, PROBE_CONSTANT * std::min(l1 * l1, l2)), MAX_PROBES);
    }

    bool try_insert_with_limit(size_t tier, uint64_t h, uint8_t fp,
                               const char* key, size_t key_len, uint64_t value, size_t limit) {
        size_t nb = tier_bucket_counts[tier], mp = std::min(limit, nb);
        for (size_t probe = 0; probe < mp; probe++) {
            size_t abs_idx = tier_starts[tier] + bucket_index(h, probe, nb);
            uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
            if (mask) {
                size_t slot = __builtin_ctz(mask);
                fingerprints[abs_idx][slot] = fp;
                entries[abs_idx][slot] = {key, key_len, value};
                tier_slot_counts[tier]++; count++;
                return true;
            }
        }
        return false;
    }

    void insert_into_tier(size_t tier, uint64_t h, uint8_t fp,
                          const char* key, size_t key_len, uint64_t value) {
        size_t nb = tier_bucket_counts[tier], mp = std::min(nb, MAX_PROBES);
        for (size_t probe = 0; probe < mp; probe++) {
            size_t abs_idx = tier_starts[tier] + bucket_index(h, probe, nb);
            uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
            if (mask) {
                size_t slot = __builtin_ctz(mask);
                fingerprints[abs_idx][slot] = fp;
                entries[abs_idx][slot] = {key, key_len, value};
                tier_slot_counts[tier]++; count++;
                return;
            }
        }
        insert_any_tier(h, fp, key, key_len, value);
    }

    void insert_any_tier(uint64_t h, uint8_t fp, const char* key, size_t key_len, uint64_t value) {
        for (size_t j = 1; j <= MAX_PROBES; j++) {
            for (size_t t = 0; t < num_tiers; t++) {
                size_t nb = tier_bucket_counts[t];
                if (j - 1 >= nb) continue;
                size_t abs_idx = tier_starts[t] + bucket_index(h, j - 1, nb);
                uint16_t mask = match_empty_or_tombstone(fingerprints[abs_idx]);
                if (mask) {
                    size_t slot = __builtin_ctz(mask);
                    fingerprints[abs_idx][slot] = fp;
                    entries[abs_idx][slot] = {key, key_len, value};
                    tier_slot_counts[t]++; count++;
                    return;
                }
            }
        }
    }

    void insert(const char* key, size_t key_len, uint64_t value) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t i = current_batch;
        if (i == 0) {
            insert_into_tier(0, h, fp, key, key_len, value);
            if (get_empty_fraction(0) <= 0.12) current_batch = 1;
            return;
        }
        if (i >= num_tiers) { insert_any_tier(h, fp, key, key_len, value); return; }
        size_t primary = i - 1, secondary = i;
        double e1 = get_empty_fraction(primary), e2 = get_empty_fraction(secondary);
        if (e1 > DELTA_HALF && e2 > 0.25) {
            if (!try_insert_with_limit(primary, h, fp, key, key_len, value, probe_limit(e1)))
                insert_into_tier(secondary, h, fp, key, key_len, value);
        } else if (e1 <= DELTA_HALF) {
            insert_into_tier(secondary, h, fp, key, key_len, value);
        } else {
            insert_into_tier(primary, h, fp, key, key_len, value);
        }
        if (e1 <= DELTA_HALF && e2 <= 0.25 && i + 1 < num_tiers) current_batch = i + 1;
    }

    uint64_t* get(const char* key, size_t key_len) const {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        for (size_t t = 0; t < num_tiers; t++) {
            size_t nb = tier_bucket_counts[t], ts = tier_starts[t];
            size_t mp = std::min(MAX_PROBES, nb);
            for (size_t probe = 0; probe < mp; probe++) {
                size_t abs_idx = ts + bucket_index(h, probe, nb);
                uint16_t fpmask = match_fingerprint(fingerprints[abs_idx], fp);
                while (fpmask) {
                    size_t slot = __builtin_ctz(fpmask);
                    auto& e = entries[abs_idx][slot];
                    if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0)
                        return (uint64_t*)&e.value;
                    fpmask &= fpmask - 1;
                }
                if (__builtin_expect(match_empty(fingerprints[abs_idx]) != 0, 0)) break;
            }
        }
        return nullptr;
    }

    bool remove(const char* key, size_t key_len) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        for (size_t t = 0; t < num_tiers; t++) {
            size_t nb = tier_bucket_counts[t], ts = tier_starts[t];
            size_t mp = std::min(MAX_PROBES, nb);
            for (size_t probe = 0; probe < mp; probe++) {
                size_t abs_idx = ts + bucket_index(h, probe, nb);
                uint16_t fpmask = match_fingerprint(fingerprints[abs_idx], fp);
                while (fpmask) {
                    size_t slot = __builtin_ctz(fpmask);
                    auto& e = entries[abs_idx][slot];
                    if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                        fingerprints[abs_idx][slot] = TOMBSTONE;
                        tier_slot_counts[t]--; count--;
                        return true;
                    }
                    fpmask &= fpmask - 1;
                }
                if (__builtin_expect(match_empty(fingerprints[abs_idx]) != 0, 0)) break;
            }
        }
        return false;
    }
};

} // namespace elastic_triangular

// ============================================================
// 4. Flat + Linear
// ============================================================
namespace flat_linear {

struct HashTable {
    uint8_t (*fingerprints)[BUCKET_SIZE];
    StringEntry (*entries)[BUCKET_SIZE];
    size_t bucket_count, bucket_mask;
    unsigned bucket_shift;
    size_t count;

    static size_t bucket_index(uint64_t h, size_t probe, size_t num_buckets) {
        unsigned bits = __builtin_ctzll(num_buckets);
        unsigned shift = std::min(64u - bits, 63u);
        uint64_t base = h >> shift;
        return (base + probe) & (num_buckets - 1);
    }

    void init(size_t n) {
        size_t capacity = 1;
        while (capacity < n) capacity <<= 1;
        capacity *= 2;
        bucket_count = std::max(capacity / BUCKET_SIZE, (size_t)1);
        fingerprints = (uint8_t(*)[BUCKET_SIZE])calloc(bucket_count, BUCKET_SIZE);
        entries = (StringEntry(*)[BUCKET_SIZE])calloc(bucket_count, BUCKET_SIZE * sizeof(StringEntry));
        bucket_mask = bucket_count - 1;
        bucket_shift = 64 - __builtin_ctzll(bucket_count);
        count = 0;
    }

    void destroy() { free(fingerprints); free(entries); }

    void insert(const char* key, size_t key_len, uint64_t value) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        for (size_t probe = 0; probe < bucket_count; probe++) {
            size_t idx = bucket_index(h, probe, bucket_count);
            uint16_t mask = match_empty_or_tombstone(fingerprints[idx]);
            if (mask) {
                size_t slot = __builtin_ctz(mask);
                fingerprints[idx][slot] = fp;
                entries[idx][slot] = {key, key_len, value};
                count++;
                return;
            }
        }
    }

    uint64_t* get(const char* key, size_t key_len) const {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t mp = std::min(bucket_count, MAX_PROBES);
        for (size_t probe = 0; probe < mp; probe++) {
            size_t idx = bucket_index(h, probe, bucket_count);
            uint16_t fpmask = match_fingerprint(fingerprints[idx], fp);
            while (fpmask) {
                size_t slot = __builtin_ctz(fpmask);
                auto& e = entries[idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0)
                    return (uint64_t*)&e.value;
                fpmask &= fpmask - 1;
            }
            if (__builtin_expect(match_empty(fingerprints[idx]) != 0, 0)) return nullptr;
        }
        return nullptr;
    }

    bool remove(const char* key, size_t key_len) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t mp = std::min(bucket_count, MAX_PROBES);
        for (size_t probe = 0; probe < mp; probe++) {
            size_t idx = bucket_index(h, probe, bucket_count);
            uint16_t fpmask = match_fingerprint(fingerprints[idx], fp);
            while (fpmask) {
                size_t slot = __builtin_ctz(fpmask);
                auto& e = entries[idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                    fingerprints[idx][slot] = TOMBSTONE;
                    count--;
                    return true;
                }
                fpmask &= fpmask - 1;
            }
            if (__builtin_expect(match_empty(fingerprints[idx]) != 0, 0)) return false;
        }
        return false;
    }
};

} // namespace flat_linear

// ============================================================
// Main
// ============================================================
int main() {
    bool all_ok = true;
    all_ok &= verify<elastic_linear::HashTable>("elastic_linear");
    all_ok &= verify<flat_triangular::HashTable>("flat_triangular");
    all_ok &= verify<elastic_triangular::HashTable>("elastic_triangular");
    all_ok &= verify<flat_linear::HashTable>("flat_linear");

    if (all_ok) {
        printf("\nAll 4 implementations passed.\n");
        return 0;
    } else {
        printf("\nSome implementations FAILED.\n");
        return 1;
    }
}
