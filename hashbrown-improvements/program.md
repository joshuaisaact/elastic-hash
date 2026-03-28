# Autoresearch: Make hashbrown faster by fixing its memory stall

You are an autonomous research agent. Your goal is to modify hashbrown's actual source code to improve hit lookup performance by reducing memory stalls.

## The finding

`perf stat` comparison of hashbrown vs a minimal SIMD hash table doing the same work:

| Counter | Hashbrown | Minimal flat hash | Ratio |
|---------|-----------|-------------------|-------|
| Cycles | 853.7M | 773.4M | flat 10% fewer |
| Instructions | 529.4M | 748.4M | flat 41% MORE |
| IPC | 0.62 | 0.97 | flat 56% better |
| L1 miss rate | 26.8% | 13.0% | flat half the miss rate |

Hashbrown executes fewer instructions but is slower because it's memory-stalled. IPC of 0.62 means 38% of cycles are wasted waiting on cache misses.

The minimal flat hash achieves 0.97 IPC because it issues a software prefetch of the data slot at probe 0, and its loop structure has enough independent instructions between the prefetch and the data access for the memory system to respond. When we patched a simple prefetch into hashbrown, it didn't help because hashbrown's tighter code leaves no gap between the prefetch issue and the data access -- the prefetch can't complete in time.

## What has already been tried and FAILED

All of these were patched into hashbrown 0.15.5 source and benchmarked. None showed measurable improvement:

1. **Prefetch in find()**: Added `prefetcht0` of the data slot at initial probe position before calling `find_inner`. No effect.
2. **Linear probing**: Changed `move_next` to constant stride. No effect.
3. **Branch hint flip**: Changed `likely` to `unlikely` on the empty check in `find_inner`. No effect.
4. **Monomorphized find_inner**: Changed `dyn FnMut` to `impl FnMut`. No effect (LLVM already devirtualizes).
5. **All four combined**: No effect.

The problem is NOT the prefetch instruction itself -- it's that there aren't enough independent instructions between the prefetch and the data access for the prefetch to complete.

## What the agent should try

The core problem: hashbrown's `find_inner` loop is too tight. The ctrl byte check and the data comparison happen in sequence with no independent work between them. The CPU stalls waiting for data after a ctrl byte match.

### Approach 1: Speculative data prefetch with ctrl byte pre-scan

Scan the ctrl bytes for a match first, THEN prefetch the matched data slot, THEN do more ctrl scanning work (e.g., check the next probe group), THEN actually compare the data. This gives the prefetch time to complete.

### Approach 2: Dual-probe speculation

In `find_inner`, load ctrl bytes for probe 0 AND probe 1 simultaneously. While checking probe 0 for matches, the ctrl bytes for probe 1 are being fetched. If probe 0 has a match, prefetch its data slot while checking probe 1's ctrl bytes. This creates instruction-level parallelism.

### Approach 3: Batched find (find_many)

Instead of one lookup at a time, process 2-4 lookups simultaneously. Issue prefetches for all of them, then process results. This is what DataFusion's @Dandandan reported getting 2.4x from (hashbrown PR #677). The agent could add a `find_batch` method.

### Approach 4: Split the inner loop

Restructure `find_inner` into two passes:
1. First pass: scan ctrl bytes only, collect (probe_pos, matched_bit) pairs
2. Prefetch all matched data slots
3. Second pass: compare keys for each match

This maximizes the distance between prefetch and access.

### Approach 5: Explicit pipeline delay

After issuing a prefetch, insert non-dependent work (e.g., compute the hash for the NEXT probe position, or precompute the next group's ctrl pointer) before accessing the prefetched data. Even a few ALU instructions may be enough.

## Machine context

- CPU: Intel i5-13600K (Raptor Lake), 2MB L2/P-core, 24MB L3
- perf available: `perf stat -e cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/L1-dcache-load-misses/u,cpu_core/L1-dcache-loads/u`
- Pin to P-core: `taskset -c 0`
- Compiler: rustc (stable), release profile with LTO

## Files

### What you can edit
- `vendor/hashbrown/src/raw/mod.rs` -- the hot path is `find_inner` (line ~1895) and `find` (line ~1187)
- `src/bin/perf_hashbrown.rs` -- the perf benchmark binary (hit lookups only)
- `src/bin/perf_flat.rs` -- the baseline (do NOT modify, this is the reference)

### After each edit
1. Update the checksum: `python3 -c "import json,hashlib; f=open('vendor/hashbrown/.cargo-checksum.json'); d=json.load(f); f.close(); f2=open('vendor/hashbrown/src/raw/mod.rs','rb'); d['files']['src/raw/mod.rs']=hashlib.sha256(f2.read()).hexdigest(); f2.close(); f3=open('vendor/hashbrown/.cargo-checksum.json','w'); json.dump(d,f3); f3.close()"`
2. Build: `cargo build --release --bin perf_hashbrown`
3. Verify correctness: the perf binary should run without crashing
4. Measure: `taskset -c 0 perf stat -e cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/L1-dcache-load-misses/u,cpu_core/L1-dcache-loads/u,cpu_core/cache-references/u,cpu_core/branch-misses/u target/release/perf_hashbrown`
5. Compare against baseline: the flat hash numbers are cycles=773M, instructions=748M, IPC=0.97, L1-miss-rate=13%

### Success criteria
- Reduce hashbrown's cycles below 800M (currently 854M)
- Improve IPC above 0.75 (currently 0.62)
- Do NOT break the HashMap API or safety guarantees
- Changes should be plausibly upstreamable (no unsafe hacks that violate hashbrown's invariants)

### Keep/revert criteria
- KEEP: cycles decrease by >3% with no correctness regression
- REVERT: cycles increase, or correctness fails, or change requires breaking the public API
- After each experiment, commit with the results in the message

## Experiment log format

For each experiment, write:
```
## Experiment N: [one-line description]
Hypothesis: [what you expect]
Change: [what you modified]
Cycles: [before] → [after] ([+/-]%)
IPC: [before] → [after]
L1 miss rate: [before] → [after]
Verdict: KEEP / REVERT
```
