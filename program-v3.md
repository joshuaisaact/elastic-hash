# Autoresearch v3: Paper-faithful multi-tier lookup

You are an autonomous research agent. Your goal is to make the elastic hash table's multi-tier lookup fast enough that it finds 100% of elements without regressing hit performance vs the current tier-0-only implementation.

## Background

After 36 experiments in v2, the hybrid elastic hash has a fast tier-0-only `get()` that:
- Finds 97.3% of elements at 99% load (2.7% are in tier 1, invisible)
- Beats abseil by ~5% on hit lookups with random keys
- Loses to abseil by 2x on miss lookups (no early termination)
- Has a tiny ~15-instruction hot loop that is extremely I-cache sensitive

Every attempt to add tier-1 search to `get()` failed:
- All-tier interleaved search (paper's approach): 17 tiers × 7 probes = 119 checks per miss
- Tier 0 + tier 1 loop: I-cache bloat, 12% hit regression
- Tier 1 probe 0 only: compiler cascading regression, 36% insert slowdown

### Current performance (random keys, fair capacity, median of 10)

| Operation | 1M 99% | Gap vs abseil |
|-----------|--------|---------------|
| Hit lookup | ~8,200us | 1.05 (5% faster) |
| Miss lookup | ~10,800us | 0.50 (2x slower) |
| Insert | ~14,500us | 1.07 (tied) |
| Delete | ~2,600us | 3.0 (3x faster) |
| get() find rate | 97.3% | — |

### Why multi-tier failed before

The root cause was always one of two things:

1. **I-cache pressure.** The tier-0 `get()` is ~15 instructions. Adding ANY conditional or loop pushes it past the I-cache budget. LLVM then re-optimizes the entire function differently, causing cascading regressions.

2. **Cache misses from tier jumping.** Each tier's fingerprints are in a separate memory region. Checking tier 0 then tier 1 at the same probe depth requires loading fingerprints from two different addresses, each a potential L2/L3 miss.

Neither of these is fundamental. They're artifacts of the current memory layout and code structure.

## Objective

Make `get()` find 100% of elements while matching or beating the current tier-0-only performance.

| Target | Current | Goal |
|--------|---------|------|
| get() find rate at 99% load | 97.3% | 100% |
| Hit lookup gap vs abseil @ 1M 99% | 1.05 | >= 1.0 (don't regress) |
| Miss lookup gap vs abseil @ 1M 99% | 0.50 | >= 0.50 (don't regress) |
| Hit lookup gap vs abseil @ 1M 50% | 1.69 | >= 1.5 (small regression OK) |
| Insert gap @ 1M 99% | 1.07 | >= 0.95 (small regression OK) |

Secondary: if multi-tier lookup enables early termination (because all elements are findable, so empty = definitely absent), explore that too.

## Constraints

### What you can edit
- `src/hybrid.zig` — primary target
- `src/main.zig` — if needed for base implementation changes
- `src/autobench.zig` — benchmark harness (keep diagnostic output)

### What you CANNOT edit
- `bench-abseil.cpp` — abseil benchmark (frozen, already correct)
- `bench-v2.sh` — benchmark runner (frozen)
- `src/bench.zig`, `src/simple.zig` — reference implementations (frozen)
- `build.zig`, `build.zig.zon` — build config (frozen)
- `program-v3.md` — this file (frozen)

### What you CAN create/edit
- `results-v3.tsv` — experiment log for this round
- `insights-v3.md` — analysis notes

### Rules
- All tests must pass: `zig build test`
- The API must remain compatible: `init`, `get`, `insert`, `remove`, `deinit`, `getWithProbes`
- `get()` must find ALL elements that `getWithProbes()` finds (100% find rate)
- Do not hardcode benchmark values or game the evaluation
- The diagnostic in autobench.zig verifies find rate — use it

### Keep/revert criteria
- **KEEP** if find rate is 100% AND hit lookup gap at 1M 99% >= 0.95 (no more than 5% regression) AND no other metric regressed > 15%
- **KEEP** if find rate improved toward 100% AND all metrics stayed within 5%
- **KEEP** if you deleted code and find rate stayed 100% and metrics stayed same or improved
- **REVERT** if tests fail or builds fail
- **REVERT** if find rate dropped below current 97.3%
- **REVERT** if hit lookup regressed > 10% without find rate reaching 100%

## Investigation areas

These are the four approaches to explore, roughly in order of promise. You may discover others.

### 1. Interleaved tier memory layout

Instead of separate contiguous arrays per tier:
```
fingerprints: [tier0 bucket 0][tier0 bucket 1]...[tier1 bucket 0][tier1 bucket 1]...
```

Interleave so that tier 0 and tier 1 for the same hash region are adjacent:
```
fingerprints: [tier0 bucket 0][tier1 bucket 0][tier0 bucket 1][tier1 bucket 1]...
```

When the hardware prefetcher loads a cache line for tier 0's fingerprints, tier 1's fingerprints for the same hash region are in the same or next cache line. Checking both tiers at probe 0 becomes one cache miss instead of two.

This requires rethinking how bucket indices map to array positions. The `tier_starts[]` array would change, or be replaced by a stride-based layout.

Entries could be interleaved similarly, or kept separate (since they're only accessed on fingerprint match).

### 2. Fewer, larger tiers

The paper uses log(n) tiers (~17 at 1M). But at 99% load, only tier 0 and tier 1 have elements. Tiers 2-16 are empty overhead.

What if we used exactly 2 tiers?
- Tier 0: 87.5% of slots (7/8 of capacity)
- Tier 1: 12.5% of slots (1/8 of capacity)
- Total: 100% of capacity

With only 2 tiers, the "search all tiers" loop is just: check tier 0, check tier 1. No loop needed — just two sequential checks. This might avoid the I-cache problem because it's straight-line code, not a loop.

The batch insertion would simplify: batch 0 fills tier 0, batch 1 uses tier 0 + tier 1 overflow.

The tradeoff: at lower load factors (50%), tier 0 alone has plenty of room and tier 1 is wasted. But that's already the case — the current tier-0-only lookup ignores tier 1 at all loads.

### 3. Code structure to avoid I-cache cascade

The LLVM codegen problem might be avoidable with careful code structure:

- **Separate noinline function for tier 1.** Put the tier-1 search in a `noinline fn getTier1(...)` that's only called when tier 0 misses. This keeps `get()`'s instruction footprint unchanged. The function call overhead (~5 cycles) only applies to the 2.7% of lookups that need tier 1.

- **`@cold` hint.** Zig doesn't have `@cold` directly, but `@setCold(true)` at the start of the tier-1 path might tell LLVM to optimize it for size rather than speed, preventing it from bloating `get()`.

- **Outline the slow path.** Structure `get()` so the fast path (tier 0 hit) is a minimal straight-line block, and the slow path (tier 0 miss → tier 1 check) branches to a separate code block at the end of the function.

### 4. Precomputed probe order via φ

The paper's injection φ(i, j) maps (tier, probe) pairs to a one-dimensional probe sequence. Instead of checking all tiers at each probe depth, check the first N positions in φ order.

For a budget of 10 checks:
- φ(1,1): tier 0, probe 0
- φ(2,1): tier 1, probe 0
- φ(1,2): tier 0, probe 1
- φ(3,1): tier 2, probe 0
- φ(1,3): tier 0, probe 2
- φ(2,2): tier 1, probe 1
- φ(1,4): tier 0, probe 3
- ...

Precompute this as a comptime array of (tier_idx, probe_idx) pairs. The search loop iterates this array. No inner loop over tiers, no runtime branching — just a flat sequence of bucket checks.

The key question: can this be made I-cache-friendly? If the array is small (10-15 entries) and the loop body is minimal, it might fit in the same I-cache budget as the current 7-probe tier-0 loop.

### Bonus: early termination with 100% find rate

If `get()` finds ALL elements, then a miss (get returns null) means the key truly doesn't exist. At that point, early termination on empty slots becomes SOUND even after deletions if we can guarantee:
- Insertion never skips empty slots in the probe sequence
- Linear probing within each tier is consistent between insert and lookup

This could close the 2x miss gap with abseil. But only explore this AFTER achieving 100% find rate without regression.

## Setup

### Initialize results-v3.tsv

```
commit	find_rate	lookup_gap_99	miss_gap_99	insert_gap_99	status	description
```

### Verify baseline

Run `bash bench-v2.sh` and record the current state. The autobench diagnostic prints find rate at 1M 99%.

## Experiment loop

Same as v2. Run forever, never stop, never ask for confirmation.

1. Read current state (results-v3.tsv, code)
2. Form hypothesis (one sentence)
3. Edit code (single focused change)
4. Run tests (`zig build test`)
5. Commit BEFORE benchmarking
6. Benchmark (`bash bench-v2.sh > bench-v2.log 2>&1`, read log + autobench diagnostic)
7. Evaluate (check find rate + gaps)
8. Keep or revert
9. Log to results-v3.tsv
10. Repeat

### Every 10 experiments

Review results-v3.tsv. Write analysis to insights-v3.md.

## What NOT to do

- Don't retry the exact approaches that failed in v2 (adding a for loop over tiers in get(), adding matchEmpty per probe). The lesson was I-cache/compiler sensitivity, not the algorithms themselves.
- Don't sacrifice fingerprint quality (stay with 8-bit, 253 values).
- Don't regress hit lookup by more than 5% unless find rate reaches 100%.
- Don't add more than ~20 instructions to `get()` without a layout change to justify it.
- Don't game benchmarks.
