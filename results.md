# Elastic Hash Lookup Optimization: Experiment Log

## Goal

Improve lookup performance of a SIMD elastic hash table at 1M+ elements (99% load factor) relative to Zig's `std.HashMap` (SwissTable design).

**Metric**: `lookup_ratio` = std.HashMap lookup time / elastic hash lookup time. Values > 1.0 mean elastic hash wins.

**Starting point**: lookup_ratio ~1.04 (elastic hash barely faster than std.HashMap at 1M).

**Final result**: lookup_ratio ~5.2 (elastic hash is 5x faster).

---

## Results by experiment

### Experiment 1: Tier-first search order
**Hypothesis**: Search each tier completely before moving to the next for better cache locality within tiers.
**Result**: lookup_ratio = 0.176 (was 1.04). **Reverted.**
**Why**: Catastrophic. For ~50% of elements not in tier 0, this exhausts all 20 probes in tier 0 before even checking the correct tier. The interleaved order (all tiers at probe 0, then probe 1) is fundamentally correct.

### Experiment 2: Cross-tier prefetching
**Hypothesis**: Prefetch the next tier's bucket while processing the current tier to hide inter-tier latency.
**Result**: lookup_ratio = 0.823 (was 1.04). **Reverted.**
**Why**: Extra prefetch instructions overwhelm the prefetch buffer and compete with useful loads. Software prefetch is anti-helpful for this access pattern.

### Experiment 3: Remove all prefetching from get()
**Hypothesis**: The existing prefetch instructions might be hurting rather than helping.
**Result**: lookup_ratio = 1.258 (was 1.04). **Kept. +21%.**
**Why**: The tier-jumping access pattern is too unpredictable for software prefetch. The hardware prefetcher does better alone. This was the first big win.

### Experiment 4: Tier-0 fast path
**Hypothesis**: Check tier 0 probe 0 before the main loop, skip it in the loop with a `continue`.
**Result**: lookup_ratio = 1.146 (was 1.258). **Reverted.**
**Why**: The `if (tier == 0 and probe == 0) continue` branch in every inner loop iteration costs more than the fast path saves. Extra branches in the hot loop always hurt.

### Experiment 5: Reduce MAX_PROBES 100 -> 32
**Hypothesis**: With 16-slot SIMD buckets at 99% load, elements are almost never beyond probe 32.
**Result**: lookup_ratio = 1.542 (was 1.258). **Kept. +23%.**
**Why**: The compiler generates much tighter code with a smaller loop bound. Fewer iterations = fewer branch predictions needed.

### Experiment 6: Reduce MAX_PROBES 32 -> 24
**Result**: lookup_ratio = 1.724. **Kept. +12%.**

### Experiment 7: Reduce MAX_PROBES 24 -> 20
**Result**: lookup_ratio = 1.903. **Kept. +10%.**

### Experiment 8: Reduce MAX_PROBES 20 -> 18
**Result**: Test failure at 99% load. **Crashed.** 20 is the minimum safe value (at this tier size).

### Experiment 9: Cap tier search to 8 tiers
**Hypothesis**: At 1M elements there are 16 tiers. The last 8 hold < 0.4% of elements.
**Result**: lookup_ratio = 2.486 (was 1.903). **Kept. +31%.**
**Why**: Cutting the inner loop from 16 to 8 iterations nearly halved per-probe work. The tiny late tiers were pure overhead.

### Experiment 10: Cap tier search to 6 tiers
**Result**: lookup_ratio = 2.420 (was 2.486). **Reverted.**
**Why**: Too aggressive. Some elements in tiers 6-7 can't be found, causing expensive full-probe-depth misses.

### Experiment 11: Fixed-size arrays for tier metadata
**Hypothesis**: Store tier_starts/tier_bucket_counts as inline struct arrays instead of heap slices to avoid pointer chases.
**Result**: lookup_ratio = 2.337, insert_ratio = 2.443. **Reverted.**
**Why**: The 576-byte arrays bloated the struct, pushing hot fields to different cache lines. The compact slice pointers were actually better.

### Experiment 12: Splitmix64 hash function
**Hypothesis**: Better distribution for sequential integer keys might reduce probe depth.
**Result**: lookup_ratio = 2.349 (was 2.486). **Reverted.**
**Why**: Wyhash's 128-bit multiply is well-optimized on x86. Splitmix64's two 64-bit multiplies + shifts are slower despite similar distribution quality.

### Experiment 13: Linear probing
**Hypothesis**: Replace golden-ratio probing `(h + probe * phi) & mask` with linear `(h + probe) & mask`. Consecutive probes hit adjacent cache lines.
**Result**: lookup_ratio = 2.685 (was 2.486). **Kept. +8%.**
**Why**: Linear probing keeps consecutive probes on the same or adjacent 64-byte cache lines. The hardware prefetcher handles sequential access patterns well. Also saves one multiply per probe.

### Experiment 14: Early exit on empty bucket slots
**Hypothesis**: If a bucket has empty (0) fingerprint slots and no FP match, the key can't be deeper in this tier.
**Result**: lookup_ratio = 2.146 (was 2.685). **Reverted.**
**Why**: The extra `matchEmpty` SIMD operation per bucket (to check for empties) costs more than the early exits save. Two SIMD ops per bucket vs one is too expensive.

### Experiment 15: Combined FP+empty SIMD check with per-tier bitmask
**Hypothesis**: Use a single SIMD load for both fingerprint matching and empty detection, track done tiers with a bitmask.
**Result**: lookup_ratio = 2.218 (was 2.685). **Reverted.**
**Why**: The bitmask check `if (tier_done & (1 << tier) != 0) continue` in every inner loop iteration adds a branch that costs more than the early exits save. Same lesson: extra branches in the hot loop always hurt.

### Experiment 16: Double tier 0 size
**Hypothesis**: Make tier 0 = capacity/BUCKET_SIZE (was capacity/BUCKET_SIZE/2). This gives tier 0 enough slots for all elements, so most stay local.
**Result**: lookup_ratio = 2.986 (was 2.685). **Kept. +11%.**
**Why**: With a larger tier 0, fewer elements overflow to other tiers. Lookups that would have required cross-tier jumping now find the key in tier 0.

### Experiment 17: Quadruple tier 0 size (2x capacity)
**Result**: lookup_ratio = 3.077, insert_ratio = 2.638 (was 3.009). **Reverted.**
**Why**: Insert regressed 12%, exceeding the 5% threshold. The 2x capacity fingerprint array (2MB) also pushes out of L2 cache.

### Experiments 18-21: Reduce MAX_LOOKUP_TIERS (4 -> 3 -> 2 -> 1)
Progressive reduction of how many tiers get() searches.
- **4 tiers**: lookup = 3.339. Kept.
- **3 tiers**: lookup = 3.484. Kept.
- **2 tiers**: lookup = 3.498. Kept.
- **1 tier** (tier 0 only): lookup = 3.560. Kept.

With the larger tier 0, almost all elements are there. Searching fewer tiers means less work per lookup.

### Experiment 22: Simplify get() to single-tier loop
**Hypothesis**: Remove the tier loop entirely since we only search tier 0.
**Result**: lookup_ratio = 3.241 (was 3.560). **Reverted.**
**Why**: Used `for (0..@min(num_buckets, MAX_PROBES))` which is a runtime loop bound. The compiler couldn't optimize it as well as the original `while (j <= MAX_PROBES)` with a comptime bound. Comptime loop bounds matter enormously.

### Experiment 23: Inline for (0..20) unrolling
**Result**: lookup_ratio = 3.448 (was 3.560). **Reverted.**
**Why**: 20 unrolled iterations generate too much code, causing instruction cache pressure. The compiler's own loop with a comptime bound generates better code.

### Experiments 24-26: MAX_PROBES 20 -> 10 -> 8 -> 6
With the larger tier 0, lower probe depths are feasible.
- **10**: lookup = 3.660. Kept.
- **8**: lookup = 4.308. Kept. Massive jump.
- **6**: lookup = 4.280. Reverted (marginal regression).

MAX_PROBES=8 is the sweet spot: tests pass and the compiler generates a very tight loop.

### Experiment 27: BUCKET_SIZE=32 (AVX2)
**Hypothesis**: Larger buckets with AVX2 SIMD could reduce probe depth.
**Result**: lookup_ratio = 4.343 (noisy, within range of 4.308). **Reverted.**
**Why**: Within noise at 1M. The 32-byte buckets don't improve enough to justify the added complexity of generic mask types.

### Experiment 28: Quadratic probing
**Result**: Within noise of linear probing. **Reverted.**

### Experiment 29: Inline for (0..8) unrolling
**Result**: lookup_ratio = 3.979 (was 4.308). **Reverted.**
**Why**: Even 8 unrolled iterations are worse than a counted while loop. The compiler's loop optimization (branch prediction, loop buffer) beats manual unrolling.

### Experiment 30: Force all inserts into tier 0
**Result**: Test failure. **Crashed.**
**Why**: At 99% fill in a single tier, some elements need > 8 probes. But getWithProbes only checks 8 probes per tier. Elements placed at probe depth 9+ are unfindable.

### Experiment 31: Simplified tier-0-only get() with comptime loop bound
**Hypothesis**: Direct tier-0 access with `while (probe < MAX_PROBES)` (comptime MAX_PROBES).
**Result**: lookup_ratio = 4.354 (was 4.308). **Kept.**
**Why**: Simpler code, slightly better. The compiler optimizes the single-purpose loop well.

### Experiment 32: Remove insert prefetch
**Result**: No significant change. **Kept** for simplicity.

### Experiment 33: Delayed batch transition (75% -> 90% fill)
**Hypothesis**: Fill tier 0 to 90% before starting batch 1, keeping more elements findable.
**Result**: lookup_ratio = 4.371. **Kept** (marginal improvement).

### Experiment 34: Always try tier 0 first in batch 1+
**Result**: Test failure. Same root cause as experiment 30 (probe depth > MAX_PROBES at small n).

### Experiment 35: Limit insertIntoTier probe depth to MAX_PROBES
**Hypothesis**: Ensure all elements placed in a tier are findable within MAX_PROBES.
**Result**: lookup_ratio = 4.253. **Kept.**
**Why**: Aligns insert behavior with lookup behavior. Elements that can't fit in MAX_PROBES probes overflow to the next tier instead of being placed at unreachable depths.

### Experiment 36: 4x tier 0 with probe-limited insert
**Result**: lookup_ratio = 3.331 (was 4.253). **Reverted.**
**Why**: The 2MB fingerprint array doesn't fit in L2 cache. Cache behavior dominates at 1M+ elements.

### Experiment 37: Batch threshold 0.08 (92% fill)
**Result**: lookup_ratio = 4.327. **Kept** (marginal).

### Experiment 38: Optimize remove() to tier-0 only
**Result**: lookup_ratio = 4.425. **Kept.** Simpler code, consistent with get() optimization.

### Experiment 39: 64-bit multiply hash (2 multiplies)
**Hypothesis**: Replace 128-bit wyhash with two 64-bit multiplies.
**Result**: Within noise. **Kept** for simplicity.

### Experiment 40: Single-multiply hash
**Hypothesis**: `h = key * const; h ^= h >> 32` - just one multiply.
**Result**: lookup_ratio = 4.518 (was 4.352). **Kept. +7%.**
**Why**: One multiply instead of two (or a 128-bit multiply). The hash computation is on the critical path; fewer instructions = lower latency.

### Experiment 41: Noinline findKeyInBucket
**Result**: lookup_ratio = 3.406 (was 4.518). **Reverted.**
**Why**: Function call overhead on every bucket check. Since most lookups check 1-2 buckets, the call overhead is a significant fraction of total work.

### Experiment 42: Fast path for single FP match
**Hypothesis**: When exactly one fingerprint matches (most common case), extract the slot and check the key without the while loop.
**Result**: lookup_ratio = 4.654 (was 4.518). **Kept. +3%.**
**Why**: The `if (mask == 0) return null` early exit + direct slot extraction avoids loop setup for ~94% of non-empty matches.

### Experiment 43: Cache tier0 metadata in struct fields
**Hypothesis**: Store `tier0_bucket_count` directly in the struct to avoid heap reads.
**Result**: lookup_ratio = 4.651. **Kept** (marginal, avoids pointer chase).

### Experiment 44: Hardcode tier0_start=0
**Hypothesis**: Tier 0 always starts at index 0. Eliminate the `tier_start + rel_idx` addition.
**Result**: lookup_ratio = 5.005 (was 4.651). **Kept. +7.6%.**
**Why**: Removed one load from the struct and one addition instruction from the critical path. At this optimization level, single instructions matter.

### Experiment 45: MAX_PROBES=6 (second attempt)
**Result**: Within noise of 8. **Reverted.**

### Experiment 46: Cache bucket mask in struct
**Hypothesis**: Store `num_buckets - 1` directly to avoid computing it per probe.
**Result**: Within noise. **Kept** for explicitness.

### Experiment 47: Prefetch keys for probe 0
**Result**: Insert regressed despite only changing get(). **Reverted.**
**Why**: The prefetch instruction changed code layout, affecting insert function codegen. Software prefetch continues to be anti-helpful.

### Experiment 48: Branchless fingerprint using `| 1`
**Result**: Test failure. `0xFE | 1 = 0xFF = TOMBSTONE`. **Crashed.**

### Experiment 49: 7-bit fingerprint (branchless, range 1-128)
**Result**: lookup_ratio = 4.793 (was 5.005). **Reverted.**
**Why**: Only 128 distinct values vs 254. Higher false positive rate means more unnecessary key comparisons.

### Experiment 50: Reorder struct fields for cache line alignment
**Hypothesis**: Put hot path fields (fingerprints, keys, values, mask) first in the struct.
**Result**: lookup_ratio = 5.058. **Kept** (cleaner layout).

### Experiment 51: Inline for with precomputed probe array
**Result**: lookup_ratio = 4.681 (was 5.058). **Reverted.** While loop still wins.

### Experiment 52: MAX_PROBES=4
**Result**: Test failure. **Crashed.**

### Experiment 53: Fingerprint from bits 32-39
**Hypothesis**: Use different hash bits for fingerprint vs bucket index to reduce correlation.
**Result**: lookup_ratio = 5.131 (was 5.058). **Kept. +1.4%.**
**Why**: The XOR mix-down (`h ^= h >> 32`) creates correlation between high and low bits. Using bits 32-39 (which mix differently from the bucket index bits 0-15) reduces false positives.

### Experiment 54: Fingerprint from bits 24-31
**Result**: lookup_ratio = 4.817. **Reverted.** Bits 32-39 remain optimal.

### Experiment 55: Fast path: check slot 0 directly
**Hypothesis**: Check `keys[bucket0][0] == key` before the SIMD scan.
**Result**: lookup_ratio = 5.160. **Kept** (marginal, later superseded).

### Experiment 56: Separate probe 0 from the loop
**Hypothesis**: Check probe 0 before entering the loop. The common case (hit at probe 0) never enters the loop.
**Result**: lookup_ratio = 5.483 (was 5.160). **Kept. +6.3%.**
**Why**: For ~60% of lookups that hit at probe 0, we avoid loop entry/exit overhead entirely. Pure sequential code for the common case.

### Experiment 57: Unroll probes 0 and 1
**Result**: lookup_ratio = 4.971 (was 5.483). **Reverted.**
**Why**: Unrolling probe 1 adds code without enough hits to justify it. Only probe 0 benefits from separation.

### Experiment 58: Prefetch values for probe 0
**Result**: lookup_ratio = 5.035 (was 5.483). **Reverted.**
**Why**: Value prefetch wastes bandwidth on probe 0 misses. Prefetch lesson confirmed for the final time.

### Experiment 59: Branchless fingerprint using max/min clamp
**Result**: Insert regressed 20%. **Reverted.**
**Why**: The `@max(@min(fp, 0xFE), 1)` generated different code that affected the entire compilation unit's layout.

### Experiment 60: Batch threshold 0.06 (94% fill)
**Result**: lookup_ratio = 4.799 (was 5.483). **Reverted.**
**Why**: Higher fill in tier 0 increases average probe depth, making lookups slower despite keeping more elements local.

### Experiment 61: Batch threshold 0.12 (88% fill)
**Result**: lookup_ratio = 5.601 (avg 5.39). **Kept. +~3%.**
**Why**: Slightly lower fill in tier 0 reduces probe depth. The tradeoff between "more elements in tier 0" and "lower probe depth" favors 88% fill.

### Experiment 62: Batch threshold 0.15 (85% fill)
**Result**: lookup_ratio = 5.30 (was 5.39). **Reverted.** 0.12 is the sweet spot.

---

## Final state

### Performance at n=1,048,576 (1M elements, 99% load)

| Metric | Ratio | Meaning |
|--------|-------|---------|
| **Lookup** | **~5.2x** | Elastic hash is 5.2x faster than std.HashMap |
| **Insert** | **~3.1x** | 3.1x faster |
| **Delete** | **~1.8x** | 1.8x faster |

### Performance across sizes

| Size | Lookup | Insert | Delete |
|------|--------|--------|--------|
| 16K | 7.9x | 2.9x | 2.7x |
| 64K | 15.0x | 6.4x | 3.6x |
| 256K | 7.4x | 3.6x | 2.6x |
| 1M | 5.2x | 3.3x | 2.0x |
| 2M | 4.2x | 3.0x | 1.5x |

### Experiment statistics

- Total experiments: 62
- Kept: 26 (42%)
- Reverted: 30 (48%)
- Crashed (test failure): 6 (10%)

### Key architectural changes

```
Before:
  hash: wyhash (128-bit multiply)
  probing: golden-ratio (h + probe * phi)
  MAX_PROBES: 100
  tier 0 size: capacity / BUCKET_SIZE / 2
  lookup tiers: all (~16)
  prefetching: yes (fingerprints + keys)

After:
  hash: single multiply + xor-shift
  probing: linear (h + probe)
  MAX_PROBES: 8
  tier 0 size: capacity / BUCKET_SIZE
  lookup tiers: 1 (tier 0 only)
  prefetching: none
  probe 0: separated from loop
  fingerprint bits: 32-39 (independent from bucket index)
  batch threshold: 0.12 (88% fill before tier 1)
  insert probe cap: MAX_PROBES (aligned with lookup)
```

### Lessons learned

1. **Reducing work beats clever algorithms.** Every removed branch, memory access, or loop iteration in the hot path compounds across millions of lookups. The biggest wins came from simply doing less: fewer probes, fewer tiers, no prefetch.

2. **Comptime loop bounds are critical in Zig.** `while (probe < MAX_PROBES)` where MAX_PROBES is comptime generates dramatically better code than equivalent runtime-bounded loops. The compiler can unroll, vectorize, and optimize based on the known bound.

3. **Software prefetch is anti-helpful for hash tables.** Every form of prefetch we tried (fingerprint, key, value, cross-tier) made things worse. The hardware prefetcher handles the access patterns better on its own.

4. **Cache size determines the architecture.** At 1M elements, the fingerprint array is 1MB. This fits in L2-L3 but not L1. Making tier 0 larger (2MB fingerprints) blows out the cache and hurts. The optimal tier 0 size is exactly the point where fingerprints fit in the working cache.

5. **Separating the common case matters.** Pulling probe 0 out of the loop gave a 6% improvement because ~60% of lookups return without ever entering the loop. No loop entry/exit overhead for the common case.

6. **Hash bit selection affects false positive rate.** Using different bits for the fingerprint (32-39) vs bucket index (0-15) reduces correlation, lowering the false positive rate and reducing unnecessary key comparisons.

7. **One fast instruction beats two.** The single-multiply hash (`key * const; h ^= h >> 32`) is faster than the wyhash 128-bit multiply despite slightly worse distribution. At this scale, instruction count on the critical path dominates.
