// Flat layout + linear probing
#include "common.h"
#include "bench_harness.h"

struct HashTable {
    uint8_t (*fingerprints)[BUCKET_SIZE];
    StringEntry (*entries)[BUCKET_SIZE];
    size_t bucket_count;
    size_t bucket_mask;
    unsigned bucket_shift;
    size_t count;

    // Linear probing: (base + probe) & mask
    static size_t bucket_index(uint64_t h, size_t probe, size_t num_buckets) {
        unsigned bits = __builtin_ctzll(num_buckets);
        unsigned shift = std::min(64u - bits, 63u);
        uint64_t base = h >> shift;
        return (base + probe) & (num_buckets - 1);
    }

    void init(size_t n) {
        // Flat layout: same capacity as elastic tier 0 (same effective load)
        size_t capacity = 1;
        while (capacity < n) capacity <<= 1;
        bucket_count = std::max(capacity / BUCKET_SIZE, (size_t)1);

        fingerprints = (uint8_t(*)[BUCKET_SIZE])calloc(bucket_count, BUCKET_SIZE);
        entries = (StringEntry(*)[BUCKET_SIZE])calloc(bucket_count, BUCKET_SIZE * sizeof(StringEntry));

        bucket_mask = bucket_count - 1;
        bucket_shift = 64 - __builtin_ctzll(bucket_count);
        count = 0;
    }

    void destroy() {
        free(fingerprints);
        free(entries);
    }

    void insert(const char* key, size_t key_len, uint64_t value) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t max_probe = std::min(bucket_count, MAX_PROBES);

        for (size_t probe = 0; probe < max_probe; probe++) {
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
        // Fallback: scan further
        for (size_t probe = MAX_PROBES; probe < bucket_count; probe++) {
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
        uint64_t bucket_base_raw = h >> bucket_shift;

        __builtin_prefetch(&entries[bucket_base_raw & bucket_mask], 0, 3);

        size_t max_probe = std::min(bucket_count, MAX_PROBES);
        for (size_t probe = 0; probe < max_probe; probe++) {
            size_t idx = (bucket_base_raw + probe) & bucket_mask;
            uint16_t fpmask = match_fingerprint(fingerprints[idx], fp);
            while (fpmask) {
                size_t slot = __builtin_ctz(fpmask);
                auto& e = entries[idx][slot];
                if (e.key_len == key_len && memcmp(e.key_ptr, key, key_len) == 0) {
                    return (uint64_t*)&e.value;
                }
                fpmask &= fpmask - 1;
            }
            if (__builtin_expect(match_empty(fingerprints[idx]) != 0, 0)) {
                return nullptr;
            }
        }
        return nullptr;
    }

    bool remove(const char* key, size_t key_len) {
        uint64_t h = hash_key(key, key_len);
        uint8_t fp = fingerprint(h);
        size_t max_probe = std::min(bucket_count, MAX_PROBES);

        for (size_t probe = 0; probe < max_probe; probe++) {
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

int main() {
    run_bench<HashTable>("flat_linear");
    return 0;
}
