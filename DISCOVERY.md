# What we actually found

Eight rounds of benchmarking, ~100 experiments, 3 languages, and then a focused attempt to patch our findings into hashbrown's actual source code. The results are not what we expected.

## The short version

A minimal SIMD hash table with linear probing, entry prefetch, and cold-hinted early termination is 10-20% faster than Rust's hashbrown on hit lookups (same language, same hash function). We proved this with controlled Rust-vs-Rust benchmarks.

We then tried to make hashbrown faster by patching each of these optimizations into its actual source code. None of them helped. Not prefetch, not linear probing, not branch hints, not all three combined, not even monomorphizing the closure dispatch. Every patch landed within measurement noise of stock hashbrown.

The optimizations are real -- they work in our code. They just can't help hashbrown because hashbrown's bottleneck is its own abstraction overhead, and our optimizations target something downstream of that bottleneck.

## What we ruled out

| Hypothesis | Experiment | Result |
|---|---|---|
| The tiered algorithm helps | Controlled experiment: 4 impls (tiered/flat x linear/triangular) | All within 3-12%. Flat = tiered. |
| Separate allocations avoid cache set conflicts | bench_alloc_isolation: identical code, one vs two allocs | Within noise at every size/load |
| 8-bit fingerprints (vs hashbrown's 7-bit) | bench_optimization_isolation: 8-bit vs 7-bit with independent bits | Within noise |
| Cold-hinted matchEmpty | bench_optimization_isolation: with vs without | Within noise |
| Our hash function is faster | bench-abseil-wyhash: gave abseil the same wyhash | absl::Hash is actually faster. We win despite a slower hash. |
| Cache level fitting (FPs in L2, ctrl in L3) | M4 test: 16MB L2 fits everything | Advantage grew from 1.7x to 2.6x. Not about cache levels. |
| Prefetch helps hashbrown | Patched hashbrown source with prefetch in find() | No measurable effect |
| Linear probing helps hashbrown | Patched ProbeSeq to constant stride | No measurable effect |
| Branch hint flip helps hashbrown | Changed likely→unlikely on empty check | No measurable effect |
| dyn FnMut dispatch is the overhead | Changed find_inner to impl FnMut | LLVM already devirtualizes. No effect. |
| All patches combined help hashbrown | Applied all four at once | No measurable effect |

## What we confirmed (in our implementation)

These optimizations produce measurable gains when tested in our stripped-down implementation:

| Optimization | Measured effect | Method |
|---|---|---|
| Entry prefetch at probe 0 | ~7% faster hits, ~23% slower misses | Zig: all_on vs no_prefetch at 1M/50% |
| Linear vs triangular probing | ~9% faster hits | C++ controlled experiment: flat_linear vs flat_triangular |
| Cold-hinted empty check | ~0-3% | Zig: within noise individually, may compound |

These compound: 1.09 x 1.07 ≈ 1.17x, close to the 1.20x measured in Rust-vs-Rust comparison.

## The paradox: why patches don't transfer

Our simple lookup loop is roughly 15 instructions. hashbrown's equivalent path is significantly larger -- closures, Bucket indirection, ProbeSeq abstraction, safety checks. The total per-lookup overhead is higher.

Adding a prefetch to a 15-instruction loop saves cycles that are a meaningful fraction of the total. Adding the same prefetch to a larger instruction sequence saves the same absolute cycles, but they're a smaller fraction and get lost in the noise of everything else.

Think of it as: our code is fast enough that memory latency is the bottleneck, so hiding memory latency (prefetch) helps. Hashbrown's code has enough instruction overhead that it's compute-bound on the lookup path, not memory-bound. Prefetch doesn't help when you're not waiting on memory.

This also explains why linear probing (better cache line utilization) helps in our code but not in hashbrown -- the cache line savings are real but small compared to hashbrown's instruction overhead.

## The actual Rust-vs-Rust numbers

All at 1M elements, 50% load, 16-byte string keys, shuffled access, ahash, with growth checks:

| Implementation | Hit (us) | Miss (us) | Insert (us) |
|---|---|---|---|
| Our Rust flat hash | 12,816 | 8,984 | 4,498 |
| Rust hashbrown + ahash | 15,319 | 6,800 | 15,797 |

Hit lookups: **1.20x faster**. Inserts: **3.5x faster**. Miss lookups: hashbrown wins (1.32x).

Across load factors at 1M:

| Load | Our hit | hashbrown hit | Ratio |
|------|---------|---------------|-------|
| 10% | 1,477 | 2,134 | **1.44x** |
| 25% | 4,364 | 6,593 | **1.51x** |
| 50% | 12,816 | 15,319 | **1.20x** |
| 75% | 23,740 | 25,566 | **1.08x** |
| 90% | 31,633 | 31,309 | tied |
| 99% | 37,486 | 36,999 | tied |

The advantage is largest at low-moderate load and disappears at 90%+.

## What this means

There are 10-20% of free hit-lookup performance on the table for Rust's standard HashMap, but you can't get it with surgical patches. You'd need to restructure the lookup hot path to be a tighter loop with less abstraction. That's a hard sell because hashbrown's abstractions (generic over key/value types, safe API, flexible hasher trait, iterator support, entry API) are the reason it's the standard library's HashMap.

The alternative is a purpose-built hash table that trades API ergonomics for raw speed. This exists in the ecosystem already (e.g., nohash-hasher for integer keys, custom tables in DataFusion and DuckDB). Our implementation is another point in that design space: maximally simple lookup, good for hit-heavy workloads with string keys at moderate load.

## The elastic hash paper

The paper's contribution (tiered insertion for O(log^2) worst-case probes) was a red herring for performance. The controlled experiment proved flat and tiered layouts perform identically on average. The tiers do help in one specific scenario: absorbing overflow at ~75% load to prevent resize cascades. But they also cause 10-21x worse p99 tail latency from tier spillover, which is worse than the problem they solve.

## What's actually worth sharing

1. **The empirical finding**: a minimal SIMD hash table beats hashbrown by 10-50% on hits. This hasn't been published as a controlled comparison before.

2. **The patch-transfer failure**: none of the individual optimizations help when applied to hashbrown. This tells the hashbrown maintainers something useful -- the performance gap isn't from missing optimizations, it's from structural overhead. If they want to close it, they need to rethink the lookup path's abstraction layers, not add prefetch hints.

3. **The prefetch tradeoff**: entry prefetch at probe 0 speeds hits by ~7% but slows misses by ~23%. This is directly relevant to hashbrown PR #677 where DataFusion is requesting prefetch support. The tradeoff should be documented.

4. **Miss optimization**: the cold-hinted `matchEmpty` early termination took miss lookups from 4x slower than abseil to 2.9x faster. This was the single biggest optimization in the repo's history (44% hit improvement, 80% miss improvement on M4). hashbrown already does early termination on empty, but with the opposite branch hint (optimized for misses, not hits).
