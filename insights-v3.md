# Autoresearch v3: Insights

## Headline result

With paper-faithful multi-tier lookup (100% find rate), the elastic hash beats abseil's flat_hash_map by 40-65% on hit lookups at normal load factors (10-75%) when both tables are allocated with equal capacity.

This is unexpected. The paper's theoretical contribution targets extreme load (99%+). But the practical win is at normal load, where most hash tables actually operate.

## Results at n=1,048,576 (median of 3 runs, random keys, both reserve(n))

| Load | Hit Lookup | Miss Lookup | Insert | Delete |
|------|-----------|-------------|--------|--------|
| 10% | **1.55x faster** | 0.55 | **2.17x faster** | **2.5x faster** |
| 25% | **1.65x faster** | 0.49 | **1.96x faster** | **2.7x faster** |
| 50% | **1.59x faster** | 0.44 | **1.90x faster** | **2.8x faster** |
| 75% | **1.42x faster** | 0.40 | **1.71x faster** | **2.4x faster** |
| 90% | **1.14x faster** | 0.40 | **1.32x faster** | **2.6x faster** |
| 99% | 0.95 (5% slower) | 0.39 | 0.92 (8% slower) | **2.7x faster** |

## Why this needs rigorous verification

1. **The benchmark methodology matters enormously.** The results changed dramatically when we switched from `reserve(fill)` to `reserve(n)` for abseil. With `reserve(fill)`, abseil had a much smaller table at low loads and won easily. With `reserve(n)`, both tables have the same capacity, and elastic hash wins. Which is the fair comparison?

2. **Sequential vs random keys.** With sequential keys (0, 1, 2, ...), elastic hash appeared 55% faster at 99% load. With random keys, it's only 5% slower. The hash function interacts with the key distribution.

3. **abseil may have a smarter reserve() strategy.** `reserve(n)` tells abseil "I plan to insert n elements." Abseil may allocate more internal slots than necessary (its growth factor is ~7/8 load before rehash). We should check what abseil actually allocates vs what we allocate.

4. **We only test u64 -> u64.** Real workloads use string keys, composite keys, etc. Abseil's hash (absl::Hash) is designed for these. Our multiply hash is specialized for integers.

5. **Single-threaded only.** Abseil has no contention in these benchmarks, but in real use it's thread-safe with some overhead.

## Things that need independent verification

- Run on different hardware (different cache sizes, different CPUs)
- Test with string keys
- Verify abseil's internal table size matches ours at each load factor
- Test with a realistic hit/miss ratio (90% hit, 10% miss)
- Compare memory usage
- Profile to confirm the performance difference is from the data structure, not measurement artifact

## What made multi-tier work

The function pointer trick: `get()` searches tier 0, then calls through an opaque function pointer for tier 1+. LLVM can't see through the function pointer, so it optimizes `get()`'s hot loop independently. The function pointer adds ~5 cycles of call overhead but only for the ~3% of lookups that reach tier 1.

Early termination in the overflow function (not the main loop) improves miss performance in tier 1 without any cost to tier-0 hits.

## Architecture summary

```
get(key):
    h = hash(key)                       // single multiply + xor-shift
    fp = fingerprint(h)                  // bits 32-39, 8-bit
    bucket_base = h >> shift             // upper bits for bucket index

    prefetch(entries[bucket_base])       // hide DRAM latency

    for probe 0..6:                     // 7 probes in tier 0
        bucket = (bucket_base + probe) & mask
        SIMD match fingerprints[bucket] against fp
        if match: check key, return value

    return get_overflow_fn(self, h, key, fp)  // opaque function pointer

get_overflow(self, h, key, fp):         // noinline, cold path
    for probe 0..6 in tier 1:
        SIMD match + early termination on empty
    return null
```
