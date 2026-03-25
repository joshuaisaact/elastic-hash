// Elastic layout + linear probing (our approach)
#include "common.h"
#include "bench_harness.h"

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

    // Linear probing: (base + probe) & mask
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

    void insert(const char* key, size_t key_len, uint64_t value) {
        uint64_t h = hash_key(key, key_len);
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

    __attribute__((noinline))
    uint64_t* get_overflow(uint64_t h, const char* key, size_t key_len, uint8_t fp) const {
        if (num_tiers <= 1) return nullptr;
        size_t nb = tier_bucket_counts[1];
        size_t ts = tier_starts[1];
        size_t max_p = std::min(MAX_PROBES, nb);
        for (size_t probe = 0; probe < max_p; probe++) {
            size_t abs_idx = ts + bucket_index(h, probe, nb);
            uint16_t mask = match_fingerprint(fingerprints[abs_idx], fp);
            while (mask) {
                size_t slot = __builtin_ctz(mask);
                auto& e = entries[abs_idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                    return (uint64_t*)&e.value;
                }
                mask &= mask - 1;
            }
            if (__builtin_expect(match_empty(fingerprints[abs_idx]) != 0, 0)) return nullptr;
        }
        return nullptr;
    }

    uint64_t* get(const char* key, size_t key_len) const {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t mask = tier0_bucket_mask;
        uint64_t bucket_base = h >> tier0_bucket_shift;

        __builtin_prefetch(&entries[bucket_base & mask], 0, 3);

        for (size_t probe = 0; probe < MAX_PROBES; probe++) {
            size_t bucket_idx = (bucket_base + probe) & mask;
            uint16_t fpmask = match_fingerprint(fingerprints[bucket_idx], fp);
            while (fpmask) {
                size_t slot = __builtin_ctz(fpmask);
                auto& e = entries[bucket_idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                    return (uint64_t*)&e.value;
                }
                fpmask &= fpmask - 1;
            }
            if (__builtin_expect(match_empty(fingerprints[bucket_idx]) != 0, 0)) {
                return nullptr;
            }
        }

        return const_cast<HashTable*>(this)->get_overflow(h, key, key_len, fp);
    }

    bool remove(const char* key, size_t key_len) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);

        // Search all tiers
        for (size_t t = 0; t < num_tiers; t++) {
            size_t nb = tier_bucket_counts[t];
            size_t ts = tier_starts[t];
            size_t max_p = std::min(MAX_PROBES, nb);
            for (size_t probe = 0; probe < max_p; probe++) {
                size_t abs_idx = ts + bucket_index(h, probe, nb);
                uint16_t fpmask = match_fingerprint(fingerprints[abs_idx], fp);
                while (fpmask) {
                    size_t slot = __builtin_ctz(fpmask);
                    auto& e = entries[abs_idx][slot];
                    if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                        fingerprints[abs_idx][slot] = TOMBSTONE;
                        tier_slot_counts[t]--;
                        count--;
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

int main() {
    run_bench<HashTable>("elastic_linear");
    return 0;
}
