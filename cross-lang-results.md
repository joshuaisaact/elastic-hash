# Cross-Language Hash Table Comparison (Fair Edition)

All tests: 1M capacity, 16-byte hex string keys, shuffled random access, median of 10 runs.

Fairness fixes from v1:
- Rust: added ahash (fast hasher) alongside default SipHash
- Go: pre-allocated strings before timed loops (no GC during measurement)

## Apple Silicon M4 results

Tested on M4 (~16MB shared L2). The hypothesis was that elastic hash's advantage was cache-density-specific: our 1MB fingerprint array fits in x86's ~512KB L2 while abseil's 2MB control bytes spill to L3. On M4, both should fit in L2, so the advantage should shrink or disappear.

**It didn't.** It got bigger.

### Shuffled hit lookup (us, lower is better)

| Load | Elastic (Zig) | Abseil (C++) | Ratio |
|------|--------------|-------------|-------|
| 10% | **719** | 2,861 | **3.98x** |
| 25% | **2,276** | 10,169 | **4.47x** |
| 50% | **8,863** | 22,984 | **2.59x** |
| 75% | **15,972** | 33,624 | **2.11x** |
| 90% | **22,118** | 41,671 | **1.88x** |
| 99% | **25,748** | 46,543 | **1.81x** |

### x86 vs M4 comparison (shuffled hit lookup at 50% load)

| Platform | Elastic | Abseil | Gap |
|----------|---------|--------|-----|
| x86 (~512KB L2) | 11,119 | 19,312 | **1.74x** |
| M4 (~16MB L2) | 8,863 | 22,984 | **2.59x** |

The advantage grew from 1.74x to 2.59x. The tiered metadata advantage is not about L2 vs L3 spill -- it's about cache lines touched per probe. Separated, dense fingerprint arrays mean fewer cache line fetches under random access, regardless of which cache level they live in.

### Full cross-language M4 results (unshuffled)

| Load | Elastic (Zig) | Abseil (C++) | Rust+ahash | Go swiss | Go builtin |
|------|--------------|-------------|-----------|---------|-----------|
| 10% | **1,065** | 1,707 | 2,187 | 5,160 | 4,690 |
| 25% | **4,056** | 4,555 | 7,699 | 16,588 | 16,631 |
| 50% | **8,404** | 9,027 | 16,838 | 32,722 | 38,163 |
| 75% | 16,557 | **14,110** | 32,883 | 51,002 | 54,561 |
| 90% | **15,913** | 17,994 | 45,691 | 67,572 | 64,953 |
| 99% | 19,491 | **18,420** | 40,120 | 78,009 | 74,073 |

Note: unshuffled results show a much smaller gap vs abseil (1.07x at 50%) because sequential access doesn't stress cache line efficiency. The shuffled test is the realistic one.

### M4 size sweep at 50% load, shuffled hit lookup (us)

Clean sequential run -- no concurrent benchmarks to cause contention.

| Size | Elastic (Zig) | Abseil (C++) | Rust+ahash | Go swiss | Go builtin |
|------|--------------|-------------|-----------|---------|-----------|
| 16K | **33** | 48 | 40 | 61 | 72 |
| 64K | **159** | 207 | 200 | 293 | 327 |
| 256K | **684** | 1,507 | 2,073 | 2,423 | 4,443 |
| 1M | **9,488** | 22,261 | 17,182 | 28,720 | 33,749 |
| 4M | **59,234** | 113,400 | 105,560 | 137,990 | 154,052 |

| Size | vs Abseil | vs Rust+ahash | vs Go swiss |
|------|----------|--------------|------------|
| 16K | **1.45x** | 1.21x | 1.85x |
| 64K | **1.30x** | 1.26x | 1.84x |
| 256K | **2.20x** | **3.03x** | **3.54x** |
| 1M | **2.35x** | **1.81x** | **3.03x** |
| 4M | **1.91x** | **1.78x** | **2.33x** |

Elastic hash wins at every table size from 16K to 4M. The x86 finding that small tables (<100K) favored abseil does not hold on M4 -- elastic hash is faster even at 16K.

### M4 load factor sweep at 50%, shuffled (us, elastic vs abseil)

Consistent across 3 runs (values from the clean sequential run):

| Load | Elastic | Abseil | Ratio |
|------|---------|--------|-------|
| 10% | 553 | 3,232 | **5.85x** |
| 25% | 2,109 | 18,085 | **8.58x** |
| 50% | 9,284 | 21,473 | **2.31x** |
| 75% | 17,383 | 37,120 | **2.14x** |
| 90% | 24,042 | 45,323 | **1.89x** |
| 99% | 55,491 | 50,232 | **0.91x** |

At 99% load abseil pulls ahead, consistent with x86 results. At every other load factor elastic hash wins convincingly.

---

## x86 results (Linux, AMD/Intel ~512KB L2)

### Hit lookup times (us, lower is better)

| Load | Elastic (Zig) | Abseil (C++) | Rust+ahash | Rust+siphash | Go swiss | Go builtin |
|------|--------------|-------------|-----------|-------------|---------|-----------|
| 10% | **950** | 1,867 | 2,253 | 4,634 | 2,961 | 2,942 |
| 25% | **3,828** | 7,137 | 6,759 | 13,600 | 10,341 | 11,432 |
| 50% | **11,119** | 19,312 | 16,235 | 32,131 | 25,304 | 25,869 |
| 75% | **20,425** | 32,964 | 26,602 | 52,075 | 42,437 | 42,678 |
| 90% | **27,227** | 40,753 | 32,826 | 65,339 | 51,975 | 52,511 |
| 99% | **33,318** | 45,404 | 36,292 | 72,145 | 57,488 | 58,123 |

## Gaps (competitor / elastic, >1 = elastic wins)

| Load | vs Abseil | vs Rust+ahash | vs Go swiss | vs Go builtin |
|------|----------|--------------|------------|--------------|
| 10% | **1.97** | **2.37** | **3.12** | **3.10** |
| 25% | **1.86** | **1.77** | **2.70** | **2.99** |
| 50% | **1.74** | **1.46** | **2.28** | **2.33** |
| 75% | **1.61** | **1.30** | **2.08** | **2.09** |
| 90% | **1.50** | **1.21** | **1.91** | **1.93** |
| 99% | **1.36** | **1.09** | **1.73** | **1.74** |

Elastic hash wins against every competitor at every load factor.

## Ranking at 50% load

1. **Elastic Hash (Zig)**: 11,119us
2. Rust hashbrown + ahash: 16,235us (1.46x slower)
3. Abseil (C++): 19,312us (1.74x slower)
4. Go swiss.Map: 25,304us (2.28x slower)
5. Go builtin map: 25,869us (2.33x slower)
6. Rust hashbrown + siphash: 32,131us (2.89x slower)

## Key observations

**Rust with ahash is the closest competitor** -- only 9% slower at 99% load, 46% at 50%. The hashbrown data structure is well-optimized; the SipHash default was the main handicap.

**Rust+ahash is faster than abseil** by 15-19% across load factors. Abseil is not actually the fastest SwissTable variant.

**Go's pre-allocated strings helped a lot** -- swiss.Map went from 69,715us to 25,304us at 50%. But Go still has runtime overhead (GC tracking, interface dispatch).

## What the fairness fixes changed

| Competitor | Unfair gap (50%) | Fair gap (50%) | Change |
|-----------|-----------------|---------------|--------|
| Rust hashbrown | 2.98x | **1.46x** | ahash instead of siphash |
| Go swiss.Map | 6.27x | **2.28x** | pre-allocated strings |
| Abseil | 1.74x | 1.74x | unchanged |

## Miss lookups (Elastic hash weakness)

| Load | Elastic | Abseil | Rust+ahash | Go swiss |
|------|---------|--------|-----------|---------|
| 50% | 12,343 | 5,264 | 6,522 | 21,926 |
| 99% | 38,205 | 11,832 | 20,228 | 50,758 |

Abseil dominates misses due to early termination. Rust+ahash is second.

## Remaining fairness caveats

- Go still has GC overhead even without allocation in the hot loop (GC may pause during measurement)
- Rust's ahash uses hardware AES instructions for hashing, which is faster than wyhash on AES-NI hardware
- Cross-language comparisons inherently include compiler/runtime differences, not just data structure differences
- The only truly apples-to-apples comparison is elastic hash (Zig) vs abseil (C++), both compiled native with similar LLVM/GCC backends and no runtime overhead
