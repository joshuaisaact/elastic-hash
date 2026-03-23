# Autoresearch Insights (58 experiments)

## Result: lookup_ratio ~5.2x at n=1048576

Started at ~1.04, now ~5.2x faster than std.HashMap on lookup at 1M elements, 99% load.
Insert: ~3.3x faster. Delete: ~1.7x faster. All operations beat std.HashMap.

## Final architecture

```
get(key):
    h = key * 0x517cc1b727220a95; h ^= h >> 32
    fp = (h >> 32) clamped to 1-254               # bits 32-39, independent from bucket bits
    mask = self.tier0_bucket_mask                   # cached in struct

    bucket0 = h & mask                              # probe 0 separated from loop
    if findKeyInBucket(bucket0, key, fp): return

    for probe 1..7:                                 # comptime MAX_PROBES=8
        bucket = (h + probe) & mask                 # linear probing
        if findKeyInBucket(bucket, key, fp): return

findKeyInBucket:
    SIMD compare 16 fingerprints
    if single match: check key directly (fast path)
    else: iterate remaining matches (rare)
```

## Optimization categories ranked by cumulative impact

### Loop reduction (~10x)
- MAX_PROBES: 100 -> 8
- Tier search: 16 tiers -> 1 tier (tier 0 only)
- Separated probe 0 from loop (avoids loop entry for ~60% of lookups)

### Cache optimization (~2x)
- Removed ALL software prefetch (hurts every time)
- Linear probing (adjacent cache lines for sequential probes)
- Larger tier 0 (capacity/BUCKET_SIZE, holds all elements)
- Hardcoded tier0_start=0 (eliminated addition)
- Cached tier0_bucket_mask in struct

### Algorithm tuning (~1.3x)
- Single-multiply hash (h = key * const; h ^= h >> 32)
- Fingerprint from bits 32-39 (less correlation with bucket index from low bits)
- Fast path for single FP match in findKeyInBucket
- Delayed batch threshold (92% fill before switching)
- Insert probe depth limited to MAX_PROBES

## What never works for this workload
- Software prefetching (ANY form)
- Extra branches in the hot loop
- Inline-for loop unrolling (instruction cache pressure)
- Noinline on hot functions (call overhead)
- Reduced fingerprint bits (higher false positive rate)
- Larger struct (pushes hot fields apart)
