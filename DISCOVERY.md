# What we actually found

~150 experiments across Zig, C++, and Rust. Started trying to prove elastic hash is faster than abseil/hashbrown. Ended up finding something different and more useful.

## The journey in four acts

### Act 1: Elastic hash is faster (but not because of elastic hash)

A SIMD hash table based on the 2025 "Optimal Bounds for Open Addressing" paper beat abseil by 1.4-2.4x on hit lookups (string keys) and Rust's hashbrown by 1.1-1.5x.

But when we tested tiered vs flat layouts with the same fingerprint design, they performed identically. The paper's tiered algorithm contributes nothing to average-case speed. The advantage came from implementation details: separated fingerprint arrays, linear probing, entry prefetch, simpler code paths.

### Act 2: None of our optimizations transfer to hashbrown

We patched each optimization into hashbrown's actual source code:
- Prefetch in `find()`: no effect
- Linear probing: no effect
- Branch hint flip: no effect
- Monomorphized `find_inner`: no effect
- All combined: no effect

LLVM was silently eliminating our prefetch instructions. Even when we forced them to survive with compiler fences, hashbrown's code structure left no gap between prefetch and data access for the memory system to respond.

### Act 3: perf stat revealed the root cause

| Counter | Hashbrown | Our flat hash |
|---------|-----------|---------------|
| Cycles | 854M | 773M |
| Instructions | 529M | 748M |
| IPC | 0.62 | 0.97 |
| L1 cache miss rate | 26.8% | 13.0% |

Hashbrown executes 41% fewer instructions but is 10% slower. IPC of 0.62 means it spends 38% of cycles stalled on cache misses. Our code has more instructions but keeps the pipeline full because the prefetch has time to complete within the longer instruction sequence.

### Act 4: Batched lookups are the real solution

Single-lookup prefetch has a ceiling (~8%) because there's only 15-20 cycles between prefetch and data access in hashbrown's loop. Not enough for the memory system to respond.

But batching 4 lookups -- hash all 4 keys, prefetch all 4 slots, then look up all 4 -- creates ~80 cycles of gap. The hash computations ARE the filler work.

| Approach | Cycles | vs Baseline | L1 misses |
|---|---|---|---|
| Stock hashbrown | 910M | -- | 29.8M |
| Prefetch ctrl+data in `find()` | 841M | **-7.6%** | 20.8M (-30%) |
| `get_batch_4()` | 649M | **-28.7%** | 19.3M (-35%) |
| Our flat hash (reference) | 791M | -13% | 23.1M |

The batched approach doesn't just beat stock hashbrown -- it beats our purpose-built flat hash table by 18%. Hashbrown's "overhead" becomes an advantage in batched mode because the hash computation between prefetch and access is substantial enough to hide memory latency.

## The hidden bottleneck nobody talks about

The ctrl byte array is the real problem. At 1M elements, it's 1MB -- doesn't fit in L1 (48KB). Every `Group::load` in hashbrown's probe loop pays an L1 miss penalty. This is invisible in hashbrown's benchmarks because they test small tables (1000 elements, 16KB -- fits in L1).

Prefetching ctrl bytes before `find_inner` cuts L1 misses by 30%. Combined with data prefetch, that's the 7.6% internal improvement. The batched approach goes further by amortizing the ctrl byte misses across 4 lookups.

## What's submittable to hashbrown

Three additions, ~50 lines total, no breaking changes:

**1. `RawTable::prefetch(hash)`** (15 lines)
Prefetches ctrl bytes and data slot for a given hash. Building block for the other two.

**2. `HashMap::prefetch_get(key)`** (10 lines)
Hashes a key and prefetches its ctrl+data. Lets callers pipeline: prefetch key N+1 while processing key N. This is exactly what hashbrown PR #677 requested, what @Amanieu said he's "in favor of," and what abseil already provides.

**3. `HashMap::get_batch_4(keys)`** (25 lines)
Hashes 4 keys, issues 8 prefetches (4 ctrl + 4 data), then does all 4 lookups. 28% faster than single lookups. This is a concrete implementation of what DataFusion's @Dandandan measured 2.4x from with manual batching.

Currently x86_64 only (`_mm_prefetch`). ARM needs `prfm pldl1keep` equivalent -- the inline asm is already shown in PR #677 discussion.

## What we ruled out along the way

| Hypothesis | Experiment | Result |
|---|---|---|
| Tiered algorithm helps | Controlled: 4 impls (tiered/flat x linear/triangular) | Within 3-12%. Flat = tiered. |
| Separate allocations avoid cache conflicts | Same code, one vs two allocs | Within noise |
| 8-bit vs 7-bit fingerprints matter | Isolation test with independent bits | Within noise |
| Cold-hinted matchEmpty matters | Isolation test | Within noise |
| Our hash function is faster | Gave abseil wyhash | absl::Hash is actually faster |
| Cache level fitting | M4 (16MB L2) test | Advantage grew, not shrank |
| Linear probing helps hashbrown | Patched ProbeSeq | No effect |
| Branch hints help hashbrown | Flipped likely/unlikely | No effect |
| dyn dispatch is the overhead | Monomorphized find_inner | LLVM already devirtualizes |
| Prefetch helps hashbrown (single lookup) | Patched find() with fence | 7.6% internal, up to 28% batched |

## The elastic hash paper

The paper's contribution -- tiered insertion for O(log^2) worst-case probes -- was a red herring for performance. Tiers add complexity (batch insertion, overflow, bloom filters) for zero average-case benefit. They do absorb overflow at ~75% load (preventing resize cascades), but they cause 10-21x worse p99 tail latency from tier spillover.

The paper's theoretical contribution (worst-case bounds) stands. Its practical performance story doesn't.

## The honest conclusion

We didn't discover a faster hash table algorithm. We discovered that hashbrown leaves 28% on the table for batch workloads because it doesn't prefetch, and that the ctrl byte array is a hidden L1 bottleneck at scale. The fix is a small API addition -- `prefetch_get` and `get_batch_4` -- that lets callers opt into faster bulk lookups without changing hashbrown's internals or safety guarantees.

The single-lookup story is more modest: 7.6% from internal prefetch of ctrl+data, achievable with a ~10 line change to `find()`. Whether that's worth the platform-specific code is a judgment call for the maintainers.

Everything we built along the way -- the elastic hash, the flat hash, the Zig implementation, the controlled experiments -- was scaffolding to arrive at this finding. The scaffolding was useful for ruling things out, but the deliverable is the prefetch patch.
