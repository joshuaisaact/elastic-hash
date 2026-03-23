# Autoresearch v2: Insights

## Final status after 26 experiments

Kept: 7 (27%), Reverted: 19 (73%).

### Performance vs abseil at n=1,048,576

| Operation | Load | Elastic (us) | Abseil (us) | Gap | vs Baseline |
|-----------|------|-------------|-------------|-----|-------------|
| **Lookup** | 99% | ~5,200 | ~8,000 | **1.55** | +96% (was 0.789) |
| **Lookup** | 90% | ~4,200 | ~7,100 | **1.70** | - |
| **Lookup** | 50% | ~2,300 | ~2,400 | **1.05** | +42% (was 0.737) |
| **Insert** | 99% | ~7,800 | ~15,500 | **2.0** | +100% (was 1.0) |
| **Delete** | 99% | ~2,200 | ~7,800 | **3.6** | maintained |

### All program targets met

| Target | Baseline | Final | Goal | Status |
|--------|----------|-------|------|--------|
| Lookup @ 1M, 99% | 0.789 | **1.55** | > 1.2 | 55% faster than abseil |
| Lookup @ 1M, 50% | 0.737 | **~1.05** | > 1.0 | At parity or better |
| Lookup @ 2M, 99% | 0.666 | **0.92** | > 0.9 | Gap closed from 33% to 8% |

### The 7 optimizations that stuck (in order of impact)

1. **Multiply-only hash + upper-bit bucket index (+45%)**
   Remove the xor-shift mixing step; use `h = key * const` directly. For the bucket index, use the UPPER bits of the multiply result (`h >> shift`) instead of the lower bits (`h & mask`). Upper bits have more carry propagation = better distribution. Two fewer instructions on the critical path AND better probe depth distribution.

2. **Interleaved key-value entries (+28%)**
   Combined separate `keys[]` and `values[]` into `entries: []Entry { key, value }`. After the key comparison (8B load from entries), the value (next 8B, same cache line) is free. Eliminates one L3/DRAM round trip per successful lookup.

3. **MAX_PROBES 8 -> 7 (+17%)**
   Tighter probe loop. The improved hash distribution means 7 probes covers 99% of elements at 99% load. Reduces worst-case work for miss lookups.

4. **Software prefetch for entries at probe 0 (+14%)**
   `@prefetch(entries[bucket0])` issued before the fingerprint SIMD check. Entries are accessed randomly (hash-dependent), so the hardware prefetcher can't predict them. The ~15 cycles of fingerprint processing hide the L3/DRAM latency for the entry load.

   Why this worked when round 1 found all prefetching harmful: round 1 prefetched FINGERPRINTS (sequential access the hardware prefetcher already handles). This prefetches ENTRIES (random access only software prefetch can help with). Only ONE prefetch at a time works; two compete destructively.

5. **Return value directly from findValueInBucket (+6%)**
   Returns the value instead of a slot index. Avoids recomputing the entry address in the caller.

6. **Merged probe loop (+5%)**
   With the prefetch before the loop, the separate probe 0 path is unnecessary. One loop from probe 0 to MAX_PROBES-1 is smaller code = better I-cache.

7. **for range loop (code cleanup)**
   `for (0..MAX_PROBES)` instead of `while (probe < MAX_PROBES)`. Same performance, cleaner code.

### Dead ends (confirmed in v2)

| Category | Experiments | Lesson |
|----------|-------------|--------|
| Extra SIMD per bucket | Early termination (2x) | Even with L1-cached data, the extra pcmpeqb + branch adds ~3 cycles per probe. Only saves on the ~10% of misses. Not worth it. |
| Stronger hash | Two-multiply, different constants | Extra computation > distribution improvement. Single multiply is already excellent with upper-bit extraction. |
| Batch threshold | 0.08, 0.10, 0.14 | 0.12 (88%) is the Goldilocks zone. Higher fill = more probes. Lower fill = more misses. |
| Forced inlining | `inline fn get()` | I-cache pressure. The function must be < ~2 I-cache lines. |
| Branchless fingerprint | `@max/@min` | Changes LLVM code layout, affecting register allocation across the function. |
| Multiple prefetches | Probe 0 + probe 1, fp + entries | Two concurrent prefetches compete for the prefetch queue and cause cache pollution. |
| Probe stride > 1 | Stride 3 | No clustering reduction observed; extra multiply per probe. |
| Loop unrolling | `inline for` | 7 unrolled copies bloat code for no measurable gain. |

### Architectural insight

The elastic hash now beats abseil at high load (90-99%) because:
1. Cheaper hash (1 multiply vs abseil's multi-step hash)
2. Software prefetch hides the entry load latency (abseil can't easily add prefetch to its hot path without restructuring)
3. Interleaved entries give free value loads
4. The tiered architecture degrades gracefully — even at 99% fill, most elements are in tier 0 at shallow probe depth

Abseil still wins at low load (10-25%) due to its flatter memory layout (control bytes + slots in one allocation). At low load, both tables are sparse, and abseil's simpler addressing wins.
