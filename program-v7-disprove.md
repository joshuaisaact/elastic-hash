# Autoresearch v7: Adversarial disproval of elastic hash advantage

You are an adversarial research agent. Your goal is to disprove the thesis that elastic hash is faster than abseil flat_hash_map and Rust's hashbrown. You should try every reasonable angle to close the performance gap or show the advantage is an artifact of unfair benchmarking.

## The thesis to attack

FINDINGS.md claims:
- 1.7x faster on hit lookups vs abseil (C++ same compiler, unshuffled)
- 2.6x faster on inserts
- 2-4x faster on deletes
- Advantage comes from "separated dense fingerprint arrays" (fewer cache lines per probe)

verify-results.md already showed:
- Shuffled access reduces hit advantage to 15-20% at 1M, 50% load
- Sweet spot is 500K-2M elements only
- Abseil wins at small tables (<100K) and large tables (>4M)
- Mixed results on realistic workloads

## Attack vectors

### Attack 1: Hash function fairness
abseil uses absl::Hash (general-purpose, seed-based). Elastic hash uses wyhash (fast, specialized). The hash function itself costs ~16% more for abseil. Give abseil wyhash via custom HashEq policy and re-measure. If the gap narrows by more than 16%, the hash is a confound.

### Attack 2: Comprehensive size sweep
Test at 8K, 16K, 32K, 64K, 128K, 256K, 512K, 1M, 2M, 4M, 8M, 16M at 50% load with shuffled access. Map the exact boundaries of the sweet spot. On this machine (i5-13600K, 2MB L2 per P-core), both 1MB fingerprints and 2MB control bytes may fit in L2, potentially eliminating the advantage entirely.

### Attack 3: Per-lookup latency distribution
Measure individual lookup latencies (rdtsc per lookup) to get p50/p90/p99/p99.9. Elastic hash has tier overflow -- elements that spill to tier 1+ require extra probes. This should show up as worse tail latency.

### Attack 4: Hot-set / temporal locality
Real workloads access a small working set repeatedly (Zipf distribution). Test with hot sets of 1K, 10K, 100K keys in a 1M table. With temporal locality, both implementations should have their hot data in L1/L2, and the structural advantage should vanish.

### Attack 5: Growth from empty
Real hashtables grow. Benchmark inserting N elements into a table that starts empty (no reserve/init to target capacity). Elastic hash's resize involves rehashing all elements across tiers.

## Machine context

- CPU: Intel i5-13600K (13th gen, Raptor Lake)
- L1d: 544 KiB (14 instances)
- L2: 20 MiB (8 instances, ~2MB per P-core)
- L3: 24 MiB shared
- Compiler: g++ 15.2.1, Zig 0.16.0-dev
- OS: Linux 6.19.6-arch1-1

## Constraints

### What you can create
- `bench-abseil-wyhash.cpp` -- abseil with custom wyhash policy
- `bench-disprove.cpp` -- unified adversarial benchmark (size sweep, latency, hot-set)
- `disprove-results.md` -- findings document
- Zig benchmark files as needed

### What you CANNOT edit
- `src/hybrid.zig` -- implementation is frozen
- `src/string_hybrid.zig` -- implementation is frozen
- `bench-elastic-cpp.cpp` -- existing benchmark is frozen
- Any existing program-*.md or results files

### Rules
- Do NOT modify the hash table implementations
- Do NOT cherry-pick results -- report everything
- If the elastic hash advantage holds under adversarial conditions, say so honestly
- Use identical methodology for both sides (same keys, shuffling, warmup, measurement)
- Pin to a single P-core with taskset to avoid E-core noise

## Methodology

- 12 total runs per configuration: 2 warmup + 10 measured, report median
- Keys: splitmix64(0xDEADBEEF12345678), miss keys: splitmix64(0xCAFEBABE87654321)
- Shuffled access order (Fisher-Yates with seed 42)
- String keys (16-byte hex) for apples-to-apples comparison
- Pin to CPU 0 with taskset -c 0
- Compile abseil: g++ -O3 -march=native -DABSL_HASHTABLEZ_SAMPLE_PARAMETER=0
- Compile elastic C++: g++ -O3 -march=native (same flags)
- Compile Zig: zig build -Doptimize=ReleaseFast

## Output format

Write all findings to `disprove-results.md` as experiments complete. Be adversarial but honest.
