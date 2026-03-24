# Autoresearch v2: Beat Google's abseil flat_hash_map

You are an autonomous research agent optimizing a Zig elastic hash table implementation. Your target is **Google's `absl::flat_hash_map`** — the original SwissTable, one of the fastest hash maps ever built.

## Background

In the previous round (62 experiments, see `results.md` and `insights.md`), we optimized lookup from 25% slower than Zig's std.HashMap to 5x faster. We now roughly match abseil at 99% load on lookup.

### Current performance vs abseil at n=1,048,576

| Operation | Elastic Hash (us) | Abseil (us) | Gap |
|-----------|-------------------|-------------|-----|
| Lookup @ 99% load | 8,500-9,000 | 8,200-8,850 | Tied |
| Lookup @ 50% load | 3,100-3,400 | 2,300-2,750 | Abseil 1.3x faster |
| Lookup @ 10% load | 575-594 | 222-233 | Abseil 2.5x faster |
| Insert @ 99% load | 16,800 | 15,685 | Abseil 7% faster |
| Delete @ 99% load | **2,100** | 8,200 | **Elastic 3.9x faster** |

### Current architecture (after v1 optimizations)

```
get(key):
    h = key * 0x517cc1b727220a95; h ^= h >> 32
    fp = (h >> 32) clamped to 1-254
    mask = self.tier0_bucket_mask  (cached in struct)

    bucket0 = h & mask             (probe 0 separated from loop)
    if findKeyInBucket(bucket0, key, fp): return value

    for probe 1..7:                (comptime MAX_PROBES=8)
        bucket = (h + probe) & mask
        if findKeyInBucket(bucket, key, fp): return value
    return null

findKeyInBucket:
    SIMD compare 16 fingerprints
    if single match: check key directly (fast path)
    else: iterate remaining matches (rare)
```

Key parameters: BUCKET_SIZE=16, MAX_PROBES=8, tier 0 = capacity/BUCKET_SIZE, linear probing, single-tier lookup, no prefetch.

## Objective

Beat abseil on **lookup** across all load factors and sizes.

Primary metric: `lookup_gap` = abseil lookup time / elastic hash lookup time. Values > 1.0 mean we're faster.

| Target | Current | Goal |
|--------|---------|------|
| Lookup @ 1M, 99% load | ~1.0 (tied) | > 1.2 (20% faster) |
| Lookup @ 1M, 50% load | ~0.75 (25% slower) | > 1.0 (match or beat) |
| Lookup @ 2M, 99% load | ~0.70 (30% slower) | > 0.9 (close the gap) |

Secondary: don't regress insert by more than 10% vs abseil, and maintain the delete advantage.

## Constraints

### What you can edit
- `src/hybrid.zig` — the SIMD/comptime implementation (primary optimization target)
- `src/main.zig` — the base implementation

### What you CANNOT edit
- `src/bench.zig`, `src/simple.zig` — reference implementations (frozen)
- `build.zig`, `build.zig.zon` — build config (frozen)
- `program-v2.md` — this file (frozen)
- The abseil benchmark binary (you build it once, then it's frozen)

### What you CAN create/edit
- `src/autobench.zig` — you may modify the Zig-side benchmark harness
- `bench-abseil.cpp` — the C++ abseil benchmark (create once, then freeze)
- `bench-v2.sh` — benchmark runner that runs both and compares
- `results-v2.tsv` — experiment log for this round
- `insights-v2.md` — analysis notes

### Rules
- All tests must pass: `zig build test`
- No external dependencies in the Zig code
- The API must remain compatible: `init`, `get`, `insert`, `remove`, `deinit`, `getWithProbes`
- Do not hardcode benchmark values or game the evaluation
- The abseil benchmark must use correct APIs: `emplace()` for insert, `find()` for lookup, `erase(iterator)` for delete
- Both benchmarks must use the same element counts and access patterns

### Keep/revert criteria
- **KEEP** if `lookup_gap` at n=1048576 improved at ANY load factor AND no metric regressed by more than 10% at the primary load factor (99%)
- **KEEP** if you deleted code and all metrics stayed the same or improved
- **REVERT** if tests fail
- **REVERT** if any metric regressed beyond threshold
- **REVERT** if builds fail

## Setup (do this once before starting the loop)

### 1. Create the abseil benchmark

Write `bench-abseil.cpp` that benchmarks `absl::flat_hash_map<uint64_t, uint64_t>`:
- Uses `emplace(key, value)` for insert
- Uses `find(key)` for lookup, with `do_not_optimize` on the result
- Uses `erase(iterator)` for delete
- Reserves capacity with `reserve(fill)`
- Tests sizes: 16384, 65536, 262144, 1048576, 2097152
- Tests load factors at 1M: 10%, 25%, 50%, 75%, 90%, 99%
- 5 runs per configuration, reports mean
- Outputs machine-parseable RESULT lines in the same format as the Zig bench
- Compile flags: `g++ -O3 -march=native -DNDEBUG -DABSL_HASHTABLEZ_SAMPLE_PARAMETER=0`
- Link: `$(pkg-config --libs absl_hash absl_raw_hash_set absl_hashtablez_sampler)`

### 2. Create bench-v2.sh

Runs both benchmarks and outputs comparison. Something like:
```bash
#!/bin/bash
set -euo pipefail
echo "=== Building ==="
g++ -O3 -march=native -DNDEBUG -DABSL_HASHTABLEZ_SAMPLE_PARAMETER=0 \
    -o bench-abseil bench-abseil.cpp $(pkg-config --libs absl_hash absl_raw_hash_set absl_hashtablez_sampler)
zig build autobench -Doptimize=ReleaseFast
echo "=== Abseil ==="
./bench-abseil 2>&1 | tee abseil.log
echo "=== Elastic Hash ==="
zig build autobench -Doptimize=ReleaseFast 2>&1 | tee elastic.log
```

### 3. Initialize results-v2.tsv

```
commit\tlookup_gap_99\tlookup_gap_50\tinsert_gap_99\tstatus\tdescription
```

Where `gap` = abseil_time / elastic_time (>1.0 means elastic wins).

## Experiment loop

Run this loop forever. NEVER STOP. NEVER ask for confirmation.

### For each experiment:

1. **Read current state.** Check `results-v2.tsv`. Read the code you're about to modify.

2. **Form a hypothesis.** One sentence about what you'll change and why it should close the gap with abseil.

3. **Edit the code.** Single focused change to `src/hybrid.zig` and/or `src/main.zig`.

4. **Run tests.** `zig build test 2>&1`. Fix or revert immediately on failure.

5. **Commit.** `git add src/hybrid.zig src/main.zig && git commit -m "<description>"`. Commit BEFORE benchmarking.

6. **Benchmark.** Run `bash bench-v2.sh > bench-v2.log 2>&1`. Read the log.

7. **Evaluate.** Compare lookup_gap at 99% and 50% load. Compare insert_gap.

8. **Decide.**
   - If lookup_gap improved at any load factor without regression: keep
   - Otherwise: `git revert HEAD --no-edit`

9. **Log.** Append to `results-v2.tsv`.

10. **Repeat.**

### Every 10 experiments:

Review results-v2.tsv. Write analysis to `insights-v2.md`.

## Strategy hints

These are informed by 62 experiments in round 1. Do NOT retry things marked as "confirmed dead" unless you have a specific reason.

### Confirmed dead ends (do not retry)
- Software prefetching (any form — fingerprint, key, value, cross-tier)
- Extra branches/bitmasks in the hot loop (early exit tracking, tier-done masks)
- Inline-for loop unrolling (instruction cache pressure)
- Noinline on hot functions (function call overhead)
- Reduced fingerprint bits (higher false positive rate)
- Larger BUCKET_SIZE=32 (no gain at 1M)
- Quadratic probing (no gain over linear)
- Splitmix64 hash (slower than current single-multiply)
- Fixed-size arrays in struct (struct too large, cache regression)
- Larger tier 0 (2x capacity — fingerprints exceed L2)

### Where abseil beats us and why

1. **Low load lookup (2.5x gap at 10%)**: Abseil's flat layout means one memory region to scan. We have tier overhead even when tier 0 is sparse. The fix might be a fundamentally different layout at low fill — or accepting the tier cost and optimizing the per-probe path.

2. **Large table lookup (1.4x gap at 2M)**: Our fingerprint array (1MB at 1M, 2MB at 2M) exceeds L2. Abseil packs metadata more densely (1 byte per slot in a flat array). Possible approaches:
   - Denser metadata (4-bit fingerprints? pack two per byte?)
   - Smaller tier 0 that fits in L2, with a fast tier-1 fallback
   - Different memory layout that's more cache-line aligned

3. **Insert at all loads**: Abseil's insert is a single probe + write. Ours has batch logic, tier selection, empty fraction computation. Simplifying the insert path would help.

### Fresh ideas to try

- **Flat mode for low load**: If fill < 50%, skip tier logic entirely and use a flat SwissTable-style layout. Switch to tiered mode as load increases.
- **Compressed fingerprints**: Pack fingerprints more densely so the metadata fits in L2 at larger sizes.
- **Cuckoo relocation**: Move elements during insert to minimize probe depth. We have insert headroom.
- **Robin Hood insertion**: Order elements by probe distance to improve worst-case lookup.
- **Group-based probing**: Instead of per-bucket SIMD, use abseil-style control byte groups that pack more metadata per cache line.
- **Two-hash scheme**: Use one hash for bucket index and a completely independent hash for fingerprint. Current single-multiply may not have enough entropy.
- **Batched/amortized rehash**: Periodically compact elements into optimal positions during quiet periods.
- **Profile-guided**: Add a profiling mode that measures actual probe depth distribution, then tune parameters based on real data.

### What abseil does that we don't

Study abseil's design for ideas:
- **1-byte control metadata per slot** (not per bucket). 7-bit hash + 1 empty/deleted/full bit. Much denser than our 1-byte-per-slot-in-16-byte-buckets.
- **Group-width SIMD** (16 bytes = 16 control bytes = 16 slots). One SSE comparison checks 16 slots' metadata simultaneously.
- **Triangular probing**: probe(i) = i*(i+1)/2, which guarantees visiting all groups when table size is power of 2.
- **Tombstone-to-empty conversion on insert**: Keeps the table cleaner over time.

The key architectural difference: abseil scans 16 **slots** per SIMD op, we scan 16 **fingerprints in one bucket**. Abseil's approach maps more naturally to flat memory. Ours couples fingerprints to fixed-size buckets.

## Hardware context

x86_64 Linux. L1: 32-48 KB, L2: 256-512 KB, L3: several MB. Cache line: 64 bytes. SIMD: SSE2/AVX2.

At 1M elements: fingerprint array = 1MB (L2/L3 boundary). Keys = 8MB, values = 8MB (L3/main memory).

## What NOT to do

- Don't retry confirmed dead ends without a genuinely new angle.
- Don't add complexity for < 2% improvement. Target 5%+ per experiment.
- Don't change the public API signatures.
- Don't game benchmarks or use different patterns for abseil vs elastic hash.
- Don't get conservative. Architectural rewrites are encouraged if the hypothesis is sound. 70%+ revert rate is expected.
