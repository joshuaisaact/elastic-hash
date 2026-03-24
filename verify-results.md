# Verification Results

## Check 1: Memory allocation comparison

**Finding: Abseil over-allocates by 2x, but so do we.**

| Side | reserve(1M) | Internal slots | Control/FP bytes | Entry/slot bytes | Total |
|------|------------|----------------|-----------------|-----------------|-------|
| Abseil | 1M | **2,097,151** | 2MB (ctrl) | 32MB (slots) | ~34MB |
| Elastic | 1M | **~2,097,152** (all tiers) | 2MB (all FPs) | 33.5MB (all entries) | ~35.5MB |

Total memory is comparable. But the **hot metadata size differs**:
- Abseil: all 2MB of control bytes are in the hot path (flat layout, any probe can touch any group)
- Elastic: only tier 0's 1MB fingerprints are in the hot path (tier 1+ rarely accessed)

At 10% load, abseil probes into a 2MB control byte array (L3 hit, ~30 cycles). We probe into a 1MB fingerprint array (L2 hit, ~10 cycles). This 20-cycle difference per probe is a genuine architectural advantage of the tiered layout, not a benchmarking artifact.

**Verdict: The capacity comparison is fair.** Both allocate ~2M slots for `reserve(1M)`. The performance difference comes from hot metadata density, not total allocation size.

At 99% load, both control arrays are similarly stressed (both exceed L2 at the working set level), which explains why the advantage disappears.

## Check 2: Shuffled lookup order

**Finding: The advantage shrinks significantly with shuffled access. Still real, but ~18% not ~50%.**

| Load | Ordered gap | Shuffled gap | Change |
|------|-----------|-------------|--------|
| 10% | 1.45 | **1.16** | -20% |
| 25% | 1.48 | **1.21** | -18% |
| 50% | 1.47 | **1.18** | -20% |
| 75% | 1.40 | **1.08** | -23% |
| 90% | 1.16 | 0.96 | reversed |
| 99% | 0.98 | 0.86 | worse |

The original ordered-lookup benchmark had a hidden advantage: sequential access to the keys[] array (4MB at 50% load, exceeds L2) benefits our prefetch-heavy architecture more than abseil's. With shuffled access, the key-array misses dominate for both sides, but our additional per-probe cache miss for entries is relatively more costly.

**Verdict: The low-load advantage is real but smaller than the ordered benchmark suggests.** At 50% load we're ~18% faster, not ~47%. At 75% we're ~8% faster. At 90%+ the advantage disappears. This is still a meaningful result — 18% at the load factors most hash tables operate at — but it's not the 40-65% headline from the ordered benchmark.

The ordered benchmark isn't "wrong" — sequential lookup of pre-known keys is a legitimate access pattern (e.g., iterating a cache). But it's not the only pattern, and the shuffled results are more representative of random-access workloads.

## Check 3: Size independence

Covered by the 50% load sweep across sizes (65K to 4M) in Check 2.

| Size | Ordered gap | Shuffled gap |
|------|-----------|-------------|
| 65K | 0.84 | 0.75 |
| 262K | 0.85 | 0.85 |
| 1M | 1.47 | 1.18 |
| 4M | 0.90 | 0.91 |

**Finding: The advantage is strongest at 1M.** At 65K (fits in L2), abseil wins. At 4M (exceeds L3), we're roughly tied. The sweet spot is when our tier-0 fingerprints fit in L2 but abseil's control bytes don't — around 512K-2M elements.

This confirms the advantage is about hot metadata density: our 1MB tier-0 fingerprints vs abseil's 2MB control bytes. At sizes where both fit in L2 (small) or neither fits (large), the advantage disappears.
