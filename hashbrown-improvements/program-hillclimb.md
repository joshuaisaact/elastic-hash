# autoresearch

This is an experiment to have Claude autonomously improve hashbrown's single-lookup performance.

## Setup

To set up a new experiment, work with the user to:

1. **Agree on a run tag**: propose a tag based on today's date. The branch `autoresearch/<tag>` must not already exist.
2. **Create the branch**: `git checkout -b autoresearch/<tag>` from current state.
3. **Read the in-scope files**:
   - `program-hillclimb.md` -- this file (your instructions)
   - `vendor/hashbrown/src/raw/mod.rs` -- the hot path (find, find_inner)
   - `vendor/hashbrown/src/map.rs` -- HashMap wrapper
   - `vendor/hashbrown/src/control/tag.rs` -- fingerprint encoding
   - `vendor/hashbrown/src/control/group/sse2.rs` -- SIMD matching
   - `src/bin/perf_hashbrown.rs` -- the benchmark (1M elements, 50% load, 16-byte string keys, shuffled hit lookups, 10 rounds)
   - `src/bin/perf_flat.rs` -- the reference implementation to beat (do NOT modify)
4. **Establish baseline**: Run both binaries with perf stat and record in results.tsv.
5. **Initialize results.tsv**: Header row only. Baseline is the first entry.
6. **Confirm and go**.

## Experimentation

Each experiment modifies the vendored hashbrown source, rebuilds, and measures with perf stat. Each run takes ~15 seconds.

After editing `vendor/hashbrown/src/raw/mod.rs` (or any vendored source), you MUST update the checksum before building:
```
python3 -c "
import json, hashlib, glob, os
ck_path = 'vendor/hashbrown/.cargo-checksum.json'
with open(ck_path) as f: data = json.load(f)
for rs in glob.glob('vendor/hashbrown/src/**/*.rs', recursive=True):
    key = os.path.relpath(rs, 'vendor/hashbrown/')
    with open(rs, 'rb') as f: data['files'][key] = hashlib.sha256(f.read()).hexdigest()
with open(ck_path, 'w') as f: json.dump(data, f)
"
```

Then build:
```
cargo build --release --bin perf_hashbrown
```

**What you CAN do:**
- Modify any file under `vendor/hashbrown/src/`. The hot path, the SIMD group ops, the tag encoding, the probing strategy, the memory layout -- everything is fair game.

**What you CANNOT do:**
- Modify `src/bin/perf_flat.rs` (the reference).
- Modify `src/bin/perf_hashbrown.rs` (the benchmark). It uses `hashbrown::HashMap` from the vendored crate with ahash.
- Break the `HashMap` public API (get, insert, remove must work correctly with the existing benchmark code).

**The goal: reduce cycles for single-lookup `get()`.** The benchmark does 10 rounds of 524,288 shuffled hit lookups in a table with 1M capacity at 50% load.

Current state:
- Stock hashbrown: ~860M cycles, IPC 0.62, L1 miss rate 26.8%
- Our flat hash (the target to beat): ~780M cycles, IPC 0.97, L1 miss rate 13%
- Best internal hashbrown patch so far: ~841M cycles (prefetch ctrl+data before find_inner, ~2-8% improvement)

The flat hash is faster because it has higher IPC -- its simpler loop structure gives the CPU more independent work between memory accesses. Hashbrown's abstraction layers (closures, Bucket indirection, ProbeSeq) create a tight instruction sequence that stalls on every cache miss.

**Simplicity criterion**: All else being equal, simpler is better. Removing abstraction and getting better results is a great outcome. A change that makes the code uglier for <1% improvement is not worth it. A change that simplifies AND improves is always worth it.

**The first run**: Establish the baseline with perf stat.

## Output format

Measure with:
```
taskset -c 0 perf stat -e cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/L1-dcache-load-misses/u,cpu_core/L1-dcache-loads/u,cpu_core/cache-references/u,cpu_core/branch-misses/u target/release/perf_hashbrown 2>&1 | tee run.log
```

Extract the key numbers:
```
grep "cycles\|instructions\|L1-dcache" run.log
```

Also run the reference to confirm it hasn't changed:
```
taskset -c 0 perf stat -e cpu_core/cycles/u,cpu_core/instructions/u target/release/perf_flat 2>&1
```

## Logging results

Log to `results.tsv` (tab-separated):

```
commit	cycles_M	ipc	l1_misses_M	status	description
```

- commit: short hash (7 chars)
- cycles_M: total cycles in millions (e.g. 854)
- ipc: instructions per cycle (e.g. 0.62)
- l1_misses_M: L1 data cache misses in millions (e.g. 29.8)
- status: `keep`, `discard`, or `crash`
- description: short text

## The experiment loop

LOOP FOREVER:

1. Look at the current git state and results.tsv
2. Edit vendored hashbrown source with an experimental idea
3. Update checksum (command above)
4. git commit
5. Run: `cargo build --release --bin perf_hashbrown && taskset -c 0 perf stat -e cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/L1-dcache-load-misses/u,cpu_core/L1-dcache-loads/u,cpu_core/cache-references/u,cpu_core/branch-misses/u target/release/perf_hashbrown 2>&1 | tee run.log`
6. Read: `grep "cycles\|instructions\|L1-dcache" run.log`
7. If crashed: `tail -50 run.log`, attempt fix or skip
8. Record in results.tsv (do NOT commit this file)
9. If cycles decreased: keep the commit
10. If worse or equal: git reset back to previous keep

Run each measurement 3 times and take the median to avoid noise. Pin to CPU 0.

**Timeout**: If a build+run exceeds 2 minutes, kill it.

**NEVER STOP**: Do NOT pause to ask. You are autonomous. If you run out of ideas, re-read the SIMD group code, the tag encoding, the probing logic. Look at how the Bucket abstraction works. Think about cache line alignment. Think about what instructions sit between a cache miss and the data access. The loop runs until the human interrupts you.
