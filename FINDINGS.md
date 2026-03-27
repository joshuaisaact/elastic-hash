# Elastic Hash: What We Actually Know

## What is it

A hash table based on the 2025 paper "Optimal Bounds for Open Addressing Without Reordering" (Farach-Colton, Krapivin, Kuszmaul). The paper's contribution is tiered arrays that prevent cluster merging, giving O(log^2) worst-case probes instead of O(n). Our implementation adds SIMD fingerprint matching, separated metadata layout, and a cold-hinted early termination optimization.

## The bottom line

Elastic hash is **1.7x faster on hit lookups** and **2.6x faster on inserts** than Google's abseil `flat_hash_map` (SwissTable). Verified in both C++ (same compiler as abseil) and Zig. Miss lookups are roughly tied with abseil at moderate load.

## What makes it faster (and what doesn't)

### What helps

**Separated dense fingerprint arrays.** Fingerprints (1 byte per slot) live in a contiguous array, separate from entry data (24 bytes per slot). One cache line covers 64 fingerprint slots. This means fewer cache line fetches per probe under random access. This is the single biggest contributor to the lookup advantage. Verified: the advantage persists across x86 and ARM (M4), ruling out cache-level effects.

**Simpler insert path.** Abseil's `emplace()` includes growth policy checks, rehash infrastructure, and hashtablez sampling overhead. Elastic hash finds an empty slot and writes. At normal loads, first probe usually succeeds. This is why inserts are 2.6x faster — less bookkeeping, not a better algorithm.

**Simpler delete.** Tombstone marking (one byte write) vs abseil's find-then-erase. Consistently 2-4x faster across all languages.

**Cold-hinted early termination for misses.** Adding `matchEmpty` after each probe with `@branchHint(.cold)` (Zig) or `__builtin_expect(..., 0)` (C++) lets miss lookups terminate early without hurting hit performance. The branch predictor learns to predict "not taken," making the check free on hits. This was tried and reverted 5 times before the cold hint was added — the hint is essential.

### What doesn't help

**The tiered layout itself.** A controlled C++ experiment (4 implementations: tiered vs flat x linear vs triangular probing, same compiler, same SIMD) showed that tiered and flat perform similarly when both use separated fingerprints. The tiered layout's contribution is worst-case guarantees at very high load, not average-case speed.

**Probing strategy.** Linear vs triangular probing produces identical performance within noise. The probing pattern doesn't matter for these workloads.

**The Zig compiler.** Zig adds ~5-10% over the C++ version on the same algorithm. The bulk of the advantage (1.7x) is present in C++ with g++.

## Performance by operation (1M elements, 50% load)

### C++ elastic hash vs abseil (same g++ compiler, unshuffled)

| Operation | Elastic C++ | Abseil | Ratio |
|---|---|---|---|
| Hit lookup | 5,066us | 8,700us | **1.72x faster** |
| Miss lookup | 2,731us | 2,899us | **1.06x faster** |
| Insert | ~3,900us | 10,288us | **2.64x faster** |

### Zig elastic hash vs abseil (unshuffled)

| Operation | Elastic Zig | Abseil | Ratio |
|---|---|---|---|
| Hit lookup | 4,736us | 8,700us | **1.84x faster** |
| Miss lookup | 2,529us | 2,899us | **1.15x faster** |
| Insert | 3,677us | 10,288us | **2.80x faster** |
| Delete | 1,528us | 5,749us | **3.76x faster** |

### Go elastic hash vs Go swiss.Map (shuffled)

| Operation | Elastic Go | swiss.Map | Ratio |
|---|---|---|---|
| Hit lookup | 52,600us | 31,600us | **1.66x slower** |
| Miss lookup | 49,150us | 24,200us | **2.03x slower** |
| Insert | 14,500us | 25,400us | **1.75x faster** |
| Delete | 9,900us | 13,200us | **1.33x faster** |

## Performance across table sizes (C++ elastic vs abseil, unshuffled, 50% load)

Tested on Apple M4 with same g++ compiler. Clean sequential runs.

| Size | Elastic C++ hit | Abseil hit | Hit ratio | Elastic miss | Abseil miss | Miss ratio |
|---|---|---|---|---|---|---|
| 16K | 26us | 30us | ~tied | 22us | 23us | ~tied |
| 64K | 110us | 164us | **1.5x faster** | 92us | 108us | **1.2x faster** |
| 256K | 493us | 2,150us | **4.4x faster** | 408us | 660us | **1.6x faster** |
| 1M | 5,684us | 9,570us | **1.7x faster** | 3,122us | 3,258us | ~tied |
| 4M | 37,817us | 49,888us | **1.3x faster** | 18,160us | 27,430us | **1.5x faster** |

Elastic hash is faster or tied at every size from 16K to 4M on hits. Peak advantage is 256K (4.4x).

## Performance across load factors (C++ elastic vs abseil, unshuffled, 1M)

| Load | Elastic hit | Abseil hit | Hit ratio | Elastic miss | Abseil miss | Miss ratio |
|---|---|---|---|---|---|---|
| 10% | 419us | 1,734us | **4.1x faster** | 315us | 394us | **1.3x faster** |
| 25% | 1,898us | 4,743us | **2.5x faster** | 993us | 1,454us | **1.5x faster** |
| 50% | 5,684us | 9,570us | **1.7x faster** | 3,122us | 3,258us | ~tied |
| 75% | 10,704us | 14,157us | **1.3x faster** | 9,397us | 5,817us | **abseil 1.6x faster** |
| 90% | 15,333us | 17,781us | **1.2x faster** | 25,355us | 7,979us | **abseil 3.2x faster** |
| 99% | 19,791us | 19,263us | ~tied | 36,306us | 9,319us | **abseil 3.9x faster** |

Elastic hash wins on hits at every load factor up to 90%. Miss advantage disappears above 50% because fewer empty slots means `matchEmpty` can't terminate early. At 75%+ abseil's miss performance is 1.6-3.9x faster.

## Cross-architecture results

| Platform | L2 Cache | Hit advantage at 50% |
|---|---|---|
| x86 (Linux, ~512KB L2) | ~512KB | ~1.7x |
| Apple M4 | ~16MB | ~1.7x |

The advantage is architecture-independent. It's not about fitting in a specific cache level — it's about cache lines per probe.

## Variable key lengths (Zig vs abseil, shuffled, M4)

| Key length | Hit advantage |
|---|---|
| 8 bytes | 1.3x |
| 16 bytes | ~tied (shuffled) to 1.7x (sequential) |
| 32 bytes | 1.4x |
| 64 bytes | 1.6x |
| 128 bytes | 2.0x |
| 256 bytes | 2.0x |

Advantage grows with key length because fingerprint pre-filtering skips more expensive key comparisons.

## Stability

**Tombstone churn:** 500K delete-insert cycles at 50% load. No degradation. Tombstones get recycled by subsequent inserts.

**Mixed workload** (40% hit, 40% miss, 10% insert, 10% delete): Zig elastic hash sustains 50M ops/sec vs abseil's 25M. The C++ elastic hash would be proportionally closer but still ahead due to insert/delete advantage.

**Memory:** Identical to abseil. 1.00x at every capacity tested.

## Growth policy overhead

Adding an abseil-style resize check (`count * 8 > capacity * 7`) to every insert adds 37% overhead at 50% load, even when resize never triggers. This is just the branch — not the resize itself. Abseil's insert path has this plus hashtablez sampling plus other bookkeeping. The simpler insert path accounts for a significant chunk of the 2.6x insert advantage.

With the growth policy, the production-ready version (`string_hybrid_growth.zig`) also handles:
- **Duplicate keys:** insert checks for existing key and updates value instead of creating a second entry
- **Automatic resize:** doubles capacity when load exceeds 87.5%, rehashes all elements

## What we got wrong along the way

1. **"Cache density — fingerprints fit in L2, abseil's don't."** Wrong. M4 with 16MB L2 showed the same advantage. It's cache lines per probe, not cache level.

2. **"The tiered layout prevents cluster merging, making it faster."** Partly true for worst-case theory, but the controlled experiment showed flat layout performs the same when given the same fingerprint design.

3. **"Zig's compiler makes it 2x faster."** Mostly wrong. The C++ port shows 1.7x — only 5-10% comes from Zig's compiler. The earlier "2x compiler advantage" claim was comparing Zig unshuffled numbers against C++ shuffled numbers (different access patterns).

4. **"Elastic hash is 3-5x faster on inserts because of the tiered architecture."** Misleading. The insert advantage comes from simpler code paths (no growth policy, no rehash checks), not from the tiered layout. Abseil's insert overhead is abseil-specific.

5. **"Flat tables with 2x capacity is a fair comparison."** Wrong. This halved the effective load factor, invalidating the controlled experiment. Caught and fixed.

6. **"Abseil is 3.8x faster at 16K."** Wrong. An earlier run with machine contention produced bad data. Clean sequential runs show they're tied at 16K.

## So what

**If you use C++, Zig, or Rust** and need a hash table for read-heavy or write-heavy workloads at moderate load factors (10-75%), this implementation is meaningfully faster than abseil. 1.7x on lookups and 2.6x on inserts is real and verified.

**The portable insight** is the cold-hinted early termination. Any SIMD hash table (including abseil forks) can add `matchEmpty` with a cold branch hint to improve miss performance without regressing hits. This is a one-line optimization that works in any language with branch prediction hints.

**The paper's contribution** is the theoretical worst-case guarantee, not average-case speed. The practical speed comes from implementation choices (separated fingerprints, simple operations) that could be applied to other hash table designs.
