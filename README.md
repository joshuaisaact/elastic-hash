# elastic-hash-zig

Elastic hashing implementation in Zig. Based on [Optimal Bounds for Open Addressing Without Reordering](https://arxiv.org/abs/2501.02305) (Farach-Colton, Krapivin, Kuszmaul 2025).

Requires Zig 0.14+ (tested on 0.16.0-dev).

See my blog post for a walkthrough: [www.joshtuddenham.dev/blog/hashmaps](https://www.joshtuddenham.dev/blog/hashmaps)

## vs Google's abseil `flat_hash_map`

Benchmarked against `absl::flat_hash_map` (the original SwissTable) using random keys, identical table capacity for both sides, median of 10 measured runs with 2 warmup discards. Both compiled with `-O3 -march=native -DNDEBUG`. See `bench-abseil.cpp` and `src/autobench.zig` for the full harness.

### At n=1,048,576

| Operation | Load | Gap (abseil/elastic) | Winner |
|-----------|------|---------------------|--------|
| Hit lookup | 99% | **1.05** | Elastic ~5% faster |
| Hit lookup | 90% | **1.25** | Elastic 25% faster |
| Hit lookup | 50% | **1.69** | Elastic 69% faster |
| Hit lookup | 10% | **1.64** | Elastic 64% faster |
| Miss lookup | 99% | 0.50 | Abseil 2x faster |
| Insert | 99% | 1.07 | Tied |
| Delete | 99% | **3.48** | Elastic 3.5x faster |

### Across sizes at 99% load

| Size | Hit Lookup | Insert | Delete |
|------|-----------|--------|--------|
| 16K | 0.37 | 0.33 | **2.6x** |
| 65K | 0.41 | 0.44 | **2.5x** |
| 262K | 0.44 | 0.80 | **2.1x** |
| 1M | **1.05** | 1.07 | **3.0x** |
| 2M | 0.83 | 1.07 | **2.1x** |

### Where elastic hash wins

**Hit lookups at all load factors when capacity is matched.** With equal table capacity, elastic hash is faster than abseil for successful lookups across all load factors (10-99%). The advantage comes from a cheaper hash function (single multiply vs abseil's multi-step), entry prefetching that hides DRAM latency for random access, and interleaved key-value storage.

**Delete: 2-3.5x faster at all sizes.** Tombstone marking is O(1) vs abseil's find-then-erase.

### Where abseil wins

**Miss lookups: 2x faster at 99% load.** Abseil's flat SwissTable layout supports early termination on empty control byte groups -- when a probe finds an empty slot, it knows the key can't exist deeper. Our tiered bucket structure scans all MAX_PROBES=7 buckets regardless. This is a structural limitation of the architecture.

**Small tables (16K-65K).** Abseil's minimal overhead wins when everything fits in L1. Our tier metadata and two-level addressing add constant overhead per probe.

## Architecture

### Relationship to the paper

The insertion algorithm follows the paper: tiered arrays (A_1, A_2, ...) with geometrically decreasing sizes, batch insertion with three cases based on tier fullness, and probe limits from the f(epsilon) function.

The lookup diverges for performance: `get()` searches only tier 0, where ~97% of elements reside at 99% load. The remaining ~3% in tier 1 are invisible to `get()`. This is a deliberate tradeoff -- adding tier 1 search to `get()` causes the function to exceed the I-cache budget, regressing all lookups by 10%+. `getWithProbes()` provides the paper-faithful multi-tier search for callers that need completeness.

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
- `bench-v2.sh` - Runner that builds and compares both

## Usage

```
zig build test       # run tests
zig build bench      # full benchmark
bash bench-v2.sh     # comparison vs abseil (requires abseil-cpp)
```

## Optimization log

36 experiments across two benchmark phases. See `results-v2.tsv` for the full log and `insights-v2.md` for analysis. Key wins:

1. Interleaved key-value entries (+28%)
2. Upper-bit bucket indexing from multiply hash (+45% with sequential keys, less with random)
3. Software prefetch for entries at probe 0 (+14%)
4. MAX_PROBES 8 -> 7 (+17%)

70%+ revert rate, consistent with the program's expectation.
