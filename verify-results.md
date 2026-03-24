# Verification Results

## Check 1: Memory allocation comparison

**Finding: Both allocate ~2M slots for reserve(1M). The performance difference is from hot metadata density.**

| Side | Internal slots | Control/FP (hot) | Total memory |
|------|---------------|-------------------|-------------|
| Abseil | 2,097,151 | 2MB (all in hot path) | ~34MB |
| Elastic | ~2,097,152 (all tiers) | 1MB (tier 0 only in hot path) | ~35MB |

At 10-50% load, abseil probes a 2MB control byte array (L3 miss). We probe a 1MB fingerprint array (L2 hit). This ~20-cycle difference per probe is a genuine architectural advantage of the tiered layout.

**Verdict: Fair comparison. Real advantage from metadata density.**

## Check 2: Shuffled lookup order

**Finding: The advantage shrinks from ~50% to ~18% with shuffled access.**

| Load | Ordered gap | Shuffled gap |
|------|-----------|-------------|
| 10% | 1.45 | **1.16** |
| 25% | 1.48 | **1.21** |
| 50% | 1.47 | **1.18** |
| 75% | 1.40 | **1.08** |
| 90% | 1.16 | 0.96 |
| 99% | 0.98 | 0.86 |

The ordered benchmark's sequential keys[] array access benefits our prefetch architecture disproportionately. With shuffled access (more representative of random-access workloads), the advantage is real but smaller.

**Verdict: Headline should be ~15-20% at normal loads, not 40-65%.**

## Check 3: Size dependence

| Size | Ordered gap (50% load) | Shuffled gap |
|------|----------------------|-------------|
| 65K | 0.84 | 0.75 |
| 262K | 0.85 | 0.85 |
| 1M | 1.47 | 1.18 |
| 4M | 0.90 | 0.91 |

The advantage exists only when our tier-0 fingerprints (1MB at 1M) fit in L2 but abseil's control bytes (2MB) don't. At 65K (both fit in L2) and 4M (neither fits), the advantage disappears.

**Verdict: Sweet spot is ~500K-2M elements. Not universal.**

## Check 4: Hash function cost

| Hash | Time (10M u64) | Per hash |
|------|---------------|---------|
| Elastic (multiply+xor-shift) | 3,387us | 0.3ns |
| Abseil (absl::Hash<u64>) | 3,935us | 0.4ns |
| Ratio | 1.16x | — |

Abseil's hash is only 16% slower. This contributes ~0.1ns per probe to our advantage — relevant but not the main factor (the metadata cache behavior dominates).

**Verdict: Hash cost is a minor contributor, not the primary explanation.**

## Check 5: Compiler comparison

- g++ (GCC) 15.2.1 for abseil
- Zig 0.16.0-dev (LLVM 19+ backend) for elastic hash
- clang++ not available for cross-check

Both use -O3 equivalent. The different compiler backends (GCC vs LLVM) could generate different code quality. This is a limitation we can't easily resolve without installing clang.

**Verdict: Unknown. A clang-compiled abseil might perform differently.**

## Check 6: Realistic workloads

### Mixed read/write (80% hit, 10% miss, 5% insert, 5% delete, 1M ops)

| Table size | Abseil (us) | Elastic (us) | Gap | Winner |
|-----------|------------|-------------|-----|--------|
| 100K | 5,693 | 7,427 | 0.77 | **Abseil** |
| 500K | 11,614 | 7,795 | **1.49** | **Elastic** |
| 1M | 12,999 | 13,294 | 0.98 | Tied |

### Hot-key / zipf-like lookup (80% top-20%, 1M ops)

| Table size | Abseil | Elastic | Gap | Winner |
|-----------|--------|---------|-----|--------|
| 100K | 1,844 | 2,555 | 0.72 | **Abseil** |
| 500K | 4,188 | 3,931 | **1.07** | Elastic |
| 1M | 9,186 | 7,139 | **1.29** | **Elastic** |

### Build-then-read (insert N, then 10N random lookups)

| Table size | Abseil read | Elastic read | Gap |
|-----------|------------|-------------|-----|
| 100K | 3,353 | 4,358 | 0.77 |
| 500K | 43,305 | 44,356 | 0.98 |
| 1M | 135,615 | 166,849 | 0.81 |

**Verdict: Mixed results.** Elastic wins on mixed read/write at 500K (1.49x) and hot-key at 1M (1.29x). Abseil wins on small tables (100K) and pure random read workloads. The practical advantage depends heavily on table size and access pattern.

## Overall assessment

**The claim "40-65% faster than abseil at normal loads" is overstated.** The verified results:

1. **~15-20% faster on random-access hit lookups** at 1M elements, 10-50% load. Real, but narrower than the ordered-access benchmark suggested.

2. **Sweet spot is 500K-2M elements** where our tier-0 fingerprints fit in L2 but abseil's control bytes don't. Outside this range, the advantage disappears.

3. **Realistic workloads are mixed.** We win on mixed read/write at 500K and hot-key at 1M. Abseil wins on small tables and pure random-read workloads.

4. **Delete is genuinely 2-3x faster everywhere.** This is robust and not dependent on access pattern or table size.

5. **Miss lookups remain 2-3x slower.** This is structural and won't change without architectural changes.

### What would be fair to claim

"At table sizes of 500K-2M u64 elements, elastic hash is 15-20% faster than abseil on hit lookups, up to 50% faster on mixed read/write workloads, 2-3x faster on deletes, and competitive on inserts. Abseil wins on miss lookups (2-3x faster), small tables (<100K), and large tables (>4M). The advantage comes from tiered metadata that keeps the hot fingerprint array in L2."
