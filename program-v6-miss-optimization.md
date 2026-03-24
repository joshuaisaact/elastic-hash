# Autoresearch v6: Miss lookup optimization

You are an autonomous research agent. The elastic hash has a known weakness: miss lookups are 2-3x slower than abseil. Your goal is to reduce this gap without regressing hit lookup performance.

## Background

### Why misses are slow

Abseil's `find()` checks one 16-byte control group per probe. If ANY slot in the group is empty (0x80), it terminates immediately -- the key can't be further along the probe chain. At 50% load, most groups have empty slots, so misses terminate in 1-2 probes.

Elastic hash's `get()` scans all MAX_PROBES (7) buckets in tier 0, then all probes in tier 1, before returning null. This is because:
1. Tier 0 uses tombstone deletion (0xFF marks deleted slots). An empty slot at probe 3 doesn't mean the key isn't at probe 5 -- it could have been inserted before a tombstone appeared at probe 3.
2. The tiered structure means we can't know which tier an element is in without checking both.

### Current miss performance (M4, 1M elements, 50% load, shuffled)

- Elastic hash: ~20,000us
- Abseil: ~3,000us
- Gap: ~6.7x

### Previous attempts that were reverted

All of these were tried on the u64 key version and reverted because they regressed hit lookups:

1. **Early termination via matchEmpty in tier 0 probe loop** -- added an extra SIMD compare per probe. Helped misses, slowed hits by ~10%.
2. **Abseil-style control encoding (empty=0x80, 7-bit fps)** -- allows checking empty with a single bit test instead of a full comparison. More complex encoding hurt fingerprint matching speed.
3. **Minimal early termination (only check after all FP matches fail)** -- still added overhead to every probe.

### What hasn't been tried

1. **Separate miss-fast path**: If we can cheaply detect "definitely not in tier 0" without per-probe empty checks, we can skip tier 0 entirely for misses. For example, a bloom filter or summary fingerprint per bucket chain.

2. **Occupancy metadata**: A single bit per bucket saying "this bucket is full". If a bucket is NOT full and the fingerprint doesn't match, the key can't be further along (no displacement happened). This is weaker than abseil's per-slot empty check but might be cheaper.

3. **Tombstone-free deletion**: Abseil uses a "find the last element in the probe chain that hashes to an earlier position, swap it into the deleted slot, mark original as empty" approach. This eliminates tombstones, which means empty slots ARE reliable early termination signals. But this is complex and may slow down delete.

4. **Tier-0-only bloom filter**: A small bloom filter (separate from the main structure) that says "this hash is definitely NOT in tier 0". Size it so false positive rate is ~1%. This would let 99% of misses skip tier 0 entirely. Cost: one extra memory access for the bloom filter check, but saves 7 probe iterations.

5. **Probe chain length tracking**: Track the maximum probe depth used for each bucket's probe chain. Store max_probe per bucket (4 bits is enough for MAX_PROBES=7). A miss can terminate as soon as it exceeds the max probe depth for its starting bucket. Cost: 4 bits per bucket extra metadata.

6. **Empty slot early termination with conditional compilation**: Use `@branchHint(.cold)` or profile-guided approach where the empty check is predicted-not-taken. The branch predictor should learn that hits (the common case) never take the early exit, making it nearly free.

7. **Robin Hood-style displacement tracking**: Track how far each element was displaced from its home bucket. On lookup, if you encounter an element with a shorter displacement than your current probe depth, the key can't be further along. This gives early termination without needing empty slots.

## Experiment plan

### Phase 1: Measure the baseline precisely

Instrument the current code to understand WHERE time is spent on misses:
- What fraction of miss time is tier 0 vs tier 1?
- How many probes does a typical miss take?
- What's the cost of a single `findValueInBucket` call (FP match + key compare)?

### Phase 2: Low-risk experiments (don't change data structure)

Try these first since they don't require structural changes:

1. **Branch-hinted early termination**: Add `matchEmpty` check to tier 0 get() but with `.cold` branch hint so it doesn't pollute the hit path prediction.

2. **Conditional early termination**: Only check for empty slots at probes 3+ (the first few probes are likely full at any reasonable load factor, so checking early is wasted work).

3. **Batched empty check**: Instead of checking empty per-probe, load fingerprints for probes 0-3 together, check all four for the key, then check if any had empty slots.

### Phase 3: Structural experiments (change data structure)

4. **Per-bucket max probe depth** (4-bit metadata): Track insertion depth, terminate miss early.

5. **Tier-0 bloom filter**: Separate bit array, check before probing tier 0 for misses.

6. **Tombstone-free deletion**: Rewrite delete to backshift elements instead of tombstoning.

### Phase 4: Combinations

The best approaches from phases 2-3 may compose. For example, bloom filter + branch-hinted early termination.

## Constraints

### What you can modify
- `src/string_hybrid.zig` -- the hash table implementation
- `src/autobench-strings.zig` -- to add miss-focused benchmarks
- New files for experiments

### What you CANNOT change
- The benchmark methodology (shuffled access, splitmix64 keys, median of 10)
- The external competitor benchmarks (abseil, Rust, Go)

### Rules
- Measure BOTH hit AND miss performance after every change
- A change that improves misses by 2x but regresses hits by 10% is NOT acceptable
- Target: reduce miss gap from ~6.7x to <2x vs abseil while keeping hit advantage >1.5x
- Report all results honestly, including failures
- If a fundamentally different approach is needed (not tiered), say so

## Measurement

For each experiment, run the shuffled verification benchmark and report:

```
ELASTIC  n=1048576  load=50  hit_shuffled=XXXX  miss_shuffled=XXXX
ABSEIL   n=1048576  load=50  hit_shuffled=XXXX  miss_shuffled=XXXX
```

Compare hit and miss separately. The goal is to improve miss without regressing hit.
