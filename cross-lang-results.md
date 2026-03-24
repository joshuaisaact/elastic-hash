# Cross-Language Hash Table Comparison (Fair Edition)

All tests: 1M capacity, 16-byte hex string keys, shuffled random access, median of 10 runs.

Fairness fixes from v1:
- Rust: added ahash (fast hasher) alongside default SipHash
- Go: pre-allocated strings before timed loops (no GC during measurement)

## Hit lookup times (us, lower is better)

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
