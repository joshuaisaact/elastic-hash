# Autoresearch: Elastic Hash Lookup Optimization

You are an autonomous research agent optimizing a Zig elastic hash table implementation. Your goal is to improve **lookup performance at large sizes (1M+ elements, 99% load factor)** without regressing insert performance.

## Background

Elastic hashing (based on [this paper](https://arxiv.org/pdf/2501.02305)) distributes elements across geometrically-decreasing tiers. It's 4-8x faster than std.HashMap on insert at 99% load. But lookup at 1M+ elements is ~25% slower than std.HashMap due to tier-jumping cache misses.

The architecture: tier 0 holds ~50% of elements, tier 1 ~25%, tier 2 ~12.5%, etc. Each tier has SIMD fingerprint buckets (16 bytes). Lookups probe across all tiers in phi-priority order, which destroys cache locality at large sizes because it jumps between distant memory regions.

std.HashMap (SwissTable design) wins on lookup because it has a flat memory layout with no tier jumping.

## Objective

Maximize `lookup_ratio` at `n=1048576` (1M elements, 99% load).

- `lookup_ratio` = std.HashMap lookup time / elastic hash lookup time
- Currently ~0.77 (elastic is 25% slower than std.HashMap)
- Values > 1.0 mean elastic hash wins
- Target: get lookup_ratio >= 1.0 at 1M

## Constraints

### What you can edit
- `src/hybrid.zig` — the SIMD/comptime implementation (primary optimization target)
- `src/main.zig` — the base implementation (hybrid.zig imports from it for bench.zig)

### What you CANNOT edit
- `src/autobench.zig` — the evaluation harness (frozen)
- `src/bench.zig` — the full benchmark suite (frozen)
- `src/simple.zig` — reference implementation (frozen)
- `build.zig` — build configuration (frozen)
- `build.zig.zon` — package manifest (frozen)
- `bench.sh` — benchmark runner (frozen)
- `program.md` — this file (frozen)

### Rules
- All tests must pass: `zig build test`
- No external dependencies (no new imports, no package additions)
- The API must remain compatible: `init`, `get`, `insert`, `remove`, `deinit`, `getWithProbes`
- Do not hardcode benchmark values or game the evaluation

### Keep/revert criteria
- **KEEP** if `lookup_ratio` at n=1048576 improved AND `insert_ratio` at n=1048576 did not regress by more than 5%
- **KEEP** if you deleted code and all metrics stayed the same or improved (simplicity wins)
- **REVERT** if tests fail
- **REVERT** if any metric regressed beyond the 5% threshold
- **REVERT** if the build fails

## Experiment loop

Run this loop forever. NEVER STOP. NEVER ask for confirmation. The human expects you to continue working indefinitely until manually stopped.

### For each experiment:

1. **Read current state.** Check `results.tsv` for recent experiments. Read the code you're about to modify.

2. **Form a hypothesis.** What specific change do you think will improve lookup? Write one sentence.

3. **Edit the code.** Make a single, focused change to `src/hybrid.zig` and/or `src/main.zig`.

4. **Run tests.** `zig build test 2>&1`. If tests fail, fix or revert immediately.

5. **Commit.** `git add src/hybrid.zig src/main.zig && git commit -m "<short description of change>"`. Commit BEFORE benchmarking so you have a clean revert point.

6. **Benchmark.** `bash bench.sh > bench.log 2>&1`. Read bench.log for results.

7. **Evaluate.** Extract the RESULT line for n=1048576. Compare lookup_ratio and insert_ratio to the previous best.

8. **Decide.**
   - If improved: log as "keep" in results.tsv
   - If not improved or regressed: `git revert HEAD --no-edit` and log as "revert" in results.tsv

9. **Log.** Append a line to `results.tsv`:
   ```
   <commit_hash>\t<lookup_ratio_1M>\t<insert_ratio_1M>\t<delete_ratio_1M>\t<keep|revert|crash>\t<description>
   ```

10. **Repeat.** Go to step 1.

### Every 10 experiments:

Review results.tsv. Write a brief analysis to `insights.md`: what patterns are working, what's failing, what to try next.

## Strategy hints (ordered by expected impact)

### Quick wins
- **Prefetch optimization.** The current `@prefetch` in `get()` only prefetches the first probe. Prefetching the next tier's location while processing the current one could hide memory latency.
- **Tier search order.** Currently probes all tiers at each probe depth (j). Since tier 0 holds ~50% of elements, checking tier 0 more aggressively before touching other tiers could improve average case.
- **Early termination.** If a tier's bucket has empty slots (no fingerprint match AND empty slots present), the key can't be deeper in that tier. Stop probing that tier early.
- **Hash function.** The current wyhash variant might not distribute well for sequential integer keys. Try different mixing constants or a different hash entirely.

### Architectural changes
- **Flatten hot tiers.** The first 2-3 tiers hold 87.5% of elements. Interleaving their memory could improve cache locality for the common case.
- **Bloom filter per tier.** A small bloom filter before each tier's probe could skip entire tiers when the key isn't there, avoiding cold memory accesses.
- **Cuckoo-style relocation.** After initial insertion, relocate elements to reduce probe depth for lookup. This trades insert time (which we have headroom on) for lookup time.
- **Two-level indexing.** A small top-level index that maps hash ranges to likely tiers, avoiding the scan-all-tiers pattern.

### Deep changes
- **Alternative tier structure.** Instead of geometric halving, use a different size distribution tuned for cache line boundaries.
- **Robin Hood insertion.** Reorder elements during insertion to minimize worst-case probe depth, at the cost of insert speed.
- **Separate hot/cold paths.** Inline the tier-0 lookup (most common case) and call out to a cold function for deeper tiers.

## Hardware context

This will run on a typical x86_64 Linux machine. Assume:
- L1 cache: 32-48 KB per core
- L2 cache: 256-512 KB per core
- L3 cache: shared, several MB
- Cache line: 64 bytes
- SIMD: SSE2/AVX2 available (Zig's @Vector will use what's available)

At 1M elements, the fingerprint array alone is ~128 KB (fits in L2 but not L1). Keys and values are each ~1 MB (spills to L3). Cache behavior dominates at this scale.

## What NOT to do

- Don't add complexity that yields tiny improvements. A 0.01 improvement from 30 lines of code is not worth it.
- Don't "clean up" or refactor without measuring. Every change must be benchmarked.
- Don't change the public API signatures.
- Don't try to beat std.HashMap on insert — we already win 4-8x there. Focus entirely on lookup.
- Don't get conservative after finding improvements. Be bold. Try rewrites. 76% of experiments getting reverted is normal and healthy.
