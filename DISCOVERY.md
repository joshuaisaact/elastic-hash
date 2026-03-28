# What we actually found

Eight rounds of benchmarking, ~100 experiments, 3 languages. Here's what the evidence says.

## The complete evidence chain

### What we ruled out (not the cause)

| Hypothesis | Experiment | Result |
|---|---|---|
| The tiered algorithm helps | Controlled experiment: 4 implementations (tiered/flat x linear/triangular) | All within 3-12%. Flat = tiered. |
| Separate allocations avoid cache conflicts | bench_alloc_isolation: same code, one vs two allocs | Within noise at every size/load |
| 8-bit fingerprints (vs hashbrown's 7-bit) | bench_optimization_isolation: 8-bit vs 7-bit with independent bits | Within noise |
| Cold-hinted matchEmpty | bench_optimization_isolation: with vs without cold hint | Within noise |
| Our hash function is faster | bench-abseil-wyhash: gave abseil wyhash | absl::Hash is actually faster. We win despite slower hash. |
| Cache level fitting (FP in L2, ctrl in L3) | M4 test: 16MB L2 fits everything | Advantage grew from 1.7x to 2.6x. Not about cache levels. |

### What we confirmed matters (the actual causes)

**1. Entry prefetch at probe 0: ~7% (measured in Zig)**

We prefetch the entry array before the fingerprint scan. Hashbrown doesn't prefetch at all. The Zig optimization isolation test measured 7% at 1M/50%. However, this may undercount the effect -- hashbrown PR #677 shows a DataFusion contributor measured 2.4x from batch prefetching in hashbrown.

**2. Linear probing vs triangular probing: ~9% (measured in C++)**

The controlled experiment showed flat_linear at 10,553us vs flat_triangular at 11,512us = 9% difference. Linear probing accesses adjacent fingerprint buckets, so multiple probes share a cache line (4 buckets per 64-byte line). Triangular probing jumps around, defeating the hardware prefetcher.

**3. Simpler code: unmeasured but real**

Hashbrown's lookup goes through `HashMap::get` -> `RawTable::find` -> closures -> `ProbeSeq::move_next` with generic trait bounds. Ours is a flat loop with direct array indexing. We never isolated this, but the gap between "Zig none" (no optimizations, 10,983us) and Rust flat hash (all optimizations, 12,816us) is 17% -- and both implement the same algorithm. Part of that is language overhead, part is that our code is structurally simpler.

### The numbers, reconciled

All numbers at 1M elements, 50% load, string keys, shuffled:

| Implementation | Hit (us) | Notes |
|---|---|---|
| Zig flat hash (all optimizations) | ~10,000 | Our best |
| Zig flat hash (no opts: 7-bit, no prefetch, no cold hint) | ~11,000 | Still uses linear probing + separated layout |
| Rust flat hash (all optimizations + growth check) | ~12,800 | Same design, different language |
| Rust hashbrown + ahash | ~15,300 | The baseline to beat |
| Abseil (C++) | ~21,800 | SwissTable reference |

**Decomposition of the gap from Zig best (10,000) to hashbrown (15,300):**

- ~10% from our 3 micro-optimizations (prefetch + 8-bit FP + cold hint)
- ~17% from Zig vs Rust compiler/language (same algorithm, different codegen)
- ~20% from architecture (Rust flat vs hashbrown: linear probing + prefetch + simpler code)

**Decomposition of the Rust-vs-Rust gap (12,800 vs 15,300 = 20%):**

The ~20% comes from some combination of:
- Linear probing (~9%, measured in C++)
- Entry prefetch (~7%, measured in Zig)
- Simpler code path (remainder, ~4%)

These compound: 1.09 * 1.07 * 1.04 = 1.21x, which matches the measured 1.20x.

### The string key amplifier

With u64 keys (cheap 8-byte comparison), the Rust-vs-Rust gap is smaller:
- 1M/50%: Flat 6,257 vs hashbrown ~8,500 = ~1.36x (from the Zig u64 test)
- 1M/90%: roughly tied

With 16-byte string keys: 1.20x. With 256-byte keys: up to 1.62x. Fingerprint filtering saves more expensive memcmp calls, amplifying the base architectural advantage.

## What we actually discovered

**Nothing fundamentally new.** Separated fingerprint arrays, linear probing, and software prefetching are all known techniques. Abseil already separates ctrl bytes from slots. hashbrown already uses SIMD fingerprint matching. The prefetch idea has been proposed in hashbrown PR #677.

**What IS new:** Nobody had combined all three (separated layout + linear probing + entry prefetch) in a single implementation, benchmarked it against hashbrown/abseil head-to-head with controlled methodology, and shown the 10-50% compound effect. The individual techniques are known; the empirical validation that they compound to a meaningful win is the contribution.

**The elastic hash paper's algorithm (tiered insertion) was a red herring.** The controlled experiment proves it adds nothing. The actual speed comes from implementation choices that could be applied to any SIMD hash table.

## The honest pitch

If you use string keys (16+ bytes) at moderate load (10-75%) with tables above 64K elements, a flat hash table with separated fingerprint arrays, linear probing, and entry prefetch at probe 0 is 10-50% faster than hashbrown on hit lookups. The advantage compounds from three small, independently-known optimizations.

Trade-offs:
- Miss lookups at 90%+ load: hashbrown is 2x faster (fewer empty slots means early termination can't fire)
- Hit lookups at 99% load: roughly tied
- Integer keys: advantage shrinks to 10-36%
- Small tables (<16K with integer keys): no advantage

The most portable, immediately-actionable finding: **entry prefetch at probe 0**. This single optimization can be added to hashbrown (PR #677 is already open) and would benefit any workload with random access to large tables.
