# elastic-hash-zig

SIMD hash table in Zig, inspired by [Optimal Bounds for Open Addressing Without Reordering](https://arxiv.org/abs/2501.02305) (Farach-Colton, Krapivin, Kuszmaul 2025). Uses the paper's tiered batch insertion and multi-tier lookup via opaque overflow.

Requires Zig 0.14+ (tested on 0.16.0-dev).

See my blog post for a walkthrough: [www.joshtuddenham.dev/blog/hashmaps](https://www.joshtuddenham.dev/blog/hashmaps)

## vs Google's abseil `flat_hash_map`

Benchmarked against `absl::flat_hash_map` (the original SwissTable) with u64 keys. Both sides use `reserve(n)` / `init(n)` for the same target capacity. Random keys via splitmix64, median of 10 runs, 2 warmup discards. Full methodology and verification in `verify-results.md`.

### Hit lookup (shuffled random access, n=1,048,576)

| Load | Gap (abseil/elastic) | Winner |
|------|---------------------|--------|
| 10% | **1.16** | Elastic 16% faster |
| 25% | **1.21** | Elastic 21% faster |
| 50% | **1.18** | Elastic 18% faster |
| 75% | **1.08** | Elastic 8% faster |
| 90% | 0.96 | Roughly tied |
| 99% | 0.86 | Abseil 14% faster |

### Realistic workloads

| Workload | 100K | 500K | 1M |
|----------|------|------|-----|
| Mixed r/w (80% hit, 10% miss, 5% ins, 5% del) | 0.77 | **1.49** | 0.98 |
| Hot-key / zipf-like lookup | 0.72 | **1.07** | **1.29** |
| Build-then-read (insert N, 10N random reads) | 0.77 | 0.98 | 0.81 |

### Delete performance

2-3x faster than abseil at all sizes and loads. O(1) tombstone marking vs abseil's find-then-erase.

### Where elastic hash wins

**Hit lookups at 500K-2M elements, 10-75% load.** The tiered architecture keeps hot fingerprint metadata (1MB for tier 0) in L2 cache, while abseil's flat control byte array (2MB after reserve) spills to L3. This gives a ~15-20% advantage on random-access hit lookups in the sweet spot.

**Mixed read/write workloads at 500K.** Up to 50% faster when the access pattern includes inserts and deletes alongside lookups.

**Delete at all sizes.** 2-3x faster consistently.

### Where abseil wins

**Miss lookups: 2-3x faster.** Abseil's early termination on empty control byte groups stops miss probing after 1-2 groups. Our tiered structure scans 7 probes in tier 0 + 7 in tier 1 before concluding a miss.

**Small tables (<100K).** Everything fits in L1, our tier overhead costs more than it saves.

**Large tables (>4M).** Neither side's metadata fits in L2; abseil's flat layout has slightly less overhead.

**High load (99%).** Tier 0 is nearly full, probe depths increase, and the metadata density advantage disappears.

### Cross-architecture: x86 vs Apple Silicon M4

| Platform | L2 cache | Shuffled hit gap at 50% |
|----------|----------|------------------------|
| x86 (Linux) | ~512KB | **1.74x** |
| Apple M4 | ~16MB | **2.59x** |

The advantage is not cache-level-specific. On M4, both fingerprint arrays fit in L2, yet the gap *grew*. The win comes from cache lines touched per probe: separated, dense fingerprints mean fewer fetches under random access regardless of cache hierarchy. Full M4 results in `cross-lang-results.md`.

### Caveats

- Tested with u64 and 16-byte string keys.
- Compiled with g++ (abseil) vs Zig/LLVM (elastic hash). Different compiler backends may generate different code quality.

## Architecture

### Relationship to the paper

**Insertion** follows the paper: tiered arrays with geometrically decreasing sizes, batch insertion with three cases based on tier fullness, and probe limits from the f(epsilon) function.

**Lookup** searches tier 0 (fast inline path), then calls through an opaque function pointer to check tier 1 (cold overflow path). The function pointer boundary prevents LLVM from cascading optimizations that bloat the hot loop. At 99% load, `get()` finds 100% of elements (97.3% in tier 0, 2.7% in tier 1 via overflow). Early termination on empty slots in the overflow function reduces miss cost in tier 1.

### SIMD bucketed probing

- 16-element buckets scanned with SSE2 vector comparison
- 8-bit fingerprints (bits 32-39 of hash), 0=empty, 0xFF=tombstone
- `@ctz` on bitmask for fast slot finding
- Linear probing across buckets with upper-bit hash indexing

### Memory layout

- Fingerprints: separate dense array (1MB at 1M elements, fits in L2)
- Entries: interleaved key-value pairs (value load is free after key check -- same cache line)
- Software prefetch for entries at probe 0 (hides L3/DRAM latency for random access)

### Key parameters

| Parameter | Value | Why |
|-----------|-------|-----|
| BUCKET_SIZE | 16 | One SSE2 comparison per bucket |
| MAX_PROBES | 7 | Minimum for 99% load correctness |
| Batch threshold | 0.12 | 88% fill in tier 0 before tier 1 |
| Hash | `key * c ^ (key * c >> 32)` | Single multiply, upper bits for bucket index |

## Files

- `src/simple.zig` - Minimal implementation (~100 lines). Start here.
- `src/main.zig` - Base implementation with fingerprinting and batch insertion.
- `src/hybrid.zig` - SIMD-accelerated version:
  - `HybridElasticHash` - Runtime version (primary optimization target)
  - `ComptimeHybridElasticHash` - Compile-time version
- `src/bench.zig` - Full benchmark suite
- `src/autobench.zig` - Focused benchmark for abseil comparison
- `bench-abseil.cpp` - Abseil benchmark (identical keys/capacity)
- `bench-realistic.cpp` - Realistic workload benchmarks
- `bench-v2.sh` - Runner that builds and compares both
- `verify-results.md` - Verification methodology and findings

## Usage

```
zig build test       # run tests
zig build bench      # full benchmark
bash bench-v2.sh     # comparison vs abseil (requires abseil-cpp)
```

## Optimization log

40+ experiments across three rounds. See `results-v2.tsv`, `results-v3.tsv` for logs and `insights-v2.md`, `insights-v3.md`, `verify-results.md` for analysis.
