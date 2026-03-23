# Autoresearch v2: Insights

## Final status after 35 experiments (two benchmark phases)

### Phase 1: Sequential keys, reserve(fill) for abseil
- 20 experiments, 7 kept
- Lookup_gap_99 reached ~1.55 (misleading — sequential keys flattered our hash)

### Phase 2: Random keys, reserve(n) for both, median of 10
- 15 experiments, 1 kept (xor-shift restore)
- Lookup_gap_99 stabilized at ~1.05

## Honest results at n=1,048,576 (random keys, fair capacity, median of 10)

| Operation | Load | Gap | Meaning |
|-----------|------|-----|---------|
| Hit lookup | 99% | **1.05** | Elastic ~5% faster |
| Hit lookup | 90% | **1.25** | Elastic 25% faster |
| Hit lookup | 50% | **1.69** | Elastic 69% faster |
| Hit lookup | 10% | **1.64** | Elastic 64% faster |
| Miss lookup | 99% | 0.50 | Abseil 2x faster |
| Miss lookup | 10% | 0.78 | Abseil 28% faster |
| Insert | 99% | 1.07 | Roughly tied |
| Delete | 99% | **3.48** | Elastic 3.5x faster |

## Where elastic hash wins and why

**Hit lookups at all loads (1.05-1.69x):** Our cheaper hash function (single multiply + xor-shift vs abseil's multi-step hash) saves ~2-4 cycles per lookup. The entry prefetch hides DRAM latency. Interleaved entries make value loads free.

**Low-to-moderate load hit lookups (1.5-2.1x):** With fair capacity (both reserve(n)), both tables are similarly sized. Our 16-slot SIMD buckets have good cache behavior when sparse — one 16-byte load checks 16 slots. Abseil's flat layout with triangular probing is less cache-friendly at low occupancy.

**Delete (3.5x):** Tombstone marking is O(1) per element. Abseil's erase requires find + potential rehash.

## Where abseil wins and why

**Miss lookups (2x faster):** Abseil's early termination on empty control byte groups terminates miss lookups after 1-2 probes at moderate load. We scan all MAX_PROBES=7 probes regardless. This is a structural limitation of our architecture — every attempt to add early termination (experiments 7, 11, 29, 30) hurt hit performance more than it helped miss performance at 99% load.

**Small tables (16K-65K):** Abseil's minimal overhead (no tier system, flat arrays) wins when everything fits in L1. Our tier metadata and two-level addressing add constant overhead that matters when each probe is only ~2-3 cycles.

## The early termination dilemma

The biggest takeaway from v2 is that early termination and fingerprint quality are in fundamental tension:

1. **Abseil's approach:** 7-bit fingerprints (128 values) + early termination on empty groups. The reduced fingerprint space increases false positives, but early termination compensates by stopping misses quickly.

2. **Our approach:** 8-bit fingerprints (253 values), no early termination. Fewer false positives mean fewer wasted key comparisons per probe, but misses exhaust all probes.

3. **The hybrid we tried:** 7-bit fingerprints + early termination (exp 29). At 99% load, the doubled false positive rate was catastrophic because: (a) buckets are nearly full, so more slots match, and (b) early termination rarely fires (few empty slots). The worst of both worlds.

For early termination to work at 99% load, you need a way to detect "key not here" without reducing fingerprint quality. Abseil manages this because their flat layout guarantees that any empty slot in the probe sequence means the key can't be deeper. Our bucket-based layout with tiers can't make this guarantee as cheaply.

## Optimizations that worked (honest benchmark)

1. **Interleaved entries (+28%)** — Key + value in same cache line
2. **Upper-bit bucket indexing (+varies)** — Better distribution from multiply's carry propagation
3. **Entry prefetch for probe 0 (+14%)** — Hides DRAM latency for random entry access
4. **MAX_PROBES 8->7 (+17%)** — Tighter loop
5. **findValueInBucket (+6%)** — Direct value return
6. **Merged probe loop (+5%)** — Smaller code, better I-cache
7. **Restored xor-shift (+3% with random keys)** — Better mixing for non-sequential inputs

## Dead ends (both phases combined)

- Any form of early termination at 99% load (adds per-probe overhead, rarely fires)
- Reduced fingerprint space (7-bit or fewer — false positives dominate)
- Multiple prefetches (compete for prefetch queue)
- Per-probe prefetch without early termination (wastes bandwidth on misses)
- Stronger/extra hash functions (critical path latency)
- Batch threshold tuning (0.12 is robustly optimal)
- Inline for / forced inlining (I-cache pressure)
- Branchless fingerprint (changes compiler code layout)
- Probe stride > 1 (extra multiply, no clustering reduction)
