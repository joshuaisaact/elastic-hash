# elastic-hash-zig

> **Disclaimer:** I'm still learning Zig and there may be memory crimes.

Elastic hashing implementation in Zig. Based on [Elastic Hashing](https://arxiv.org/pdf/2501.02305).

Requires Zig 0.14+ (tested on 0.16.0-dev).

See my blog post for a walkthrough: [www.joshtuddenham.dev/blog/hashmaps](https://www.joshtuddenham.dev/blog/hashmaps)

## Results

### True 99% Load Factor (of actual capacity)

The hybrid implementation compared to Zig's `std.HashMap` at **true 99% of actual capacity**. std.HashMap is based on Google's [SwissTable](https://abseil.io/about/design/swisstables).

| Capacity | Insert | Lookup |
|----------|--------|--------|
| 16k | **4.34x** | **1.15x** |
| 65k | **7.92x** | **1.68x** |
| 262k | **4.77x** | 0.75x |
| 524k | **4.33x** | 0.78x |
| 1M | **4.40x** | 0.77x |
| 2M | **4.44x** | 0.72x |

**Insert is 4-8x faster** across all sizes at true 99% load.

**Lookup** wins at smaller sizes (16k-65k), loses ~25% at larger sizes due to φ-ordering cache effects.

### Delete Performance

Delete at 99% load factor (deleting 50% of elements):

| Capacity | Delete |
|----------|--------|
| 16k | **1.72x** |
| 65k | **2.63x** |
| 262k | **1.29x** |
| 1M | **1.14x** |

**Delete is faster** across all sizes at high load, with bigger wins at smaller sizes.

### Comptime vs Runtime

When capacity is known at compile time, the comptime version significantly outperforms runtime:

| n | Insert | Lookup |
|---|--------|--------|
| 10k | **2.06x** | **4.63x** |
| 100k | **2.73x** | **6.71x** |
| 1M | **2.21x** | **2.36x** |

## Key Findings

### What Works

1. **Insert-heavy workloads at high load**: 4-8x faster than std.HashMap at 99% load
2. **Delete operations**: 1.1-2.6x faster than std.HashMap at high load
3. **Known-capacity scenarios**: Comptime version is 2-7x faster
4. **Small-to-medium datasets**: Both insert and lookup win up to ~65k elements
5. **Worst-case guarantees**: O(log²(1/ε)) expected probes from the paper

### What Doesn't Work

1. **Lookup at large sizes**: φ-ordering causes cache misses when jumping between tiers
2. **General-purpose replacement**: std.HashMap wins for typical mixed workloads
3. **Memory locality**: Tiered structure hurts cache performance vs flat Swiss table

### Why std.HashMap Still Wins on Lookup

std.HashMap uses SIMD too (Swiss table design), plus:
- Flat memory layout (better cache locality)
- No tier jumping during probes
- Optimized for typical 80% load factor

The elastic hash pays a cache penalty for the φ-ordering that provides worst-case guarantees.

### vs Google's Original SwissTable (abseil)

Benchmarked against `absl::flat_hash_map` using correct APIs (`emplace`/`find`/`erase(iterator)`), `-O3 -march=native -DNDEBUG`, hashtablez sampling disabled, 10 measured runs.

At 1M elements, 99% load (us, lower is better):

| Operation | Google SwissTable | Elastic Hash | Zig std.HashMap |
|-----------|-------------------|--------------|-----------------|
| Insert | 15,685 | 16,850 | 52,000 |
| Lookup | 8,200-8,850 | 8,550-9,000 | 43,000 |
| Delete | 8,200-8,400 | **2,100-2,200** | 4,000 |

At 99% load, lookup and insert are roughly tied with abseil. Elastic hash wins convincingly on delete (3.9x faster) due to O(1) tombstone marking vs abseil's rehash-on-delete.

At lower load factors (10-75%), abseil is faster on both lookup and insert -- its flat memory layout has better cache behavior when the table is sparse. The elastic hash tier overhead doesn't pay off until the table is nearly full.

At 2M+ elements, abseil pulls ahead on lookup again as our fingerprint array exceeds L2 cache.

**The takeaway**: Elastic hash matches abseil at extreme load and dominates on delete. Abseil wins at low-to-moderate load and at larger scales. See [results.md](results.md) for the full comparison.

### Why We Win on Insert

The batch insertion algorithm from the paper distributes elements efficiently:
- Fills tier 0 to 75%, then starts using tier 1
- Uses probe limits based on empty fraction (ε)
- Avoids long probe chains that hurt std.HashMap at high load

## Architecture

### Real Elastic Hashing

The implementation uses `tier0 = capacity/2` so elements actually spread across tiers:
- Tier 0: ~50% of elements
- Tier 1: ~25% of elements
- Tier 2: ~12.5% of elements
- etc.

This is "real" elastic hashing as described in the paper, not just a single-tier SIMD hash table.

### SIMD Fingerprint Scanning

- 16-byte buckets scanned with SIMD vector comparison
- 8-bit fingerprints (top byte of hash, 0=empty, 0xFF=tombstone)
- `@ctz` on bitmask for fast slot finding
- Tombstone-based deletion (like std.HashMap)

### Separated Memory Layout

Fingerprints, keys, and values stored in separate arrays:
- Fingerprint scanning doesn't pollute cache with keys/values
- 4 buckets' fingerprints fit in one 64-byte cache line

## Files

- `src/simple.zig` - Minimal implementation (~100 lines). Start here if you're learning.
- `src/main.zig` - Optimized version with fingerprinting, batch insertion, and the φ priority function from the paper.
- `src/hybrid.zig` - SIMD-accelerated version with:
  - `HybridElasticHash` - Runtime version
  - `ComptimeHybridElasticHash` - Compile-time version (faster when capacity is known)
- `src/bench.zig` - Benchmarks

## Usage

### Test

```
zig build test
```

### Benchmark

```
zig build bench
```

## Conclusion

**Is this useful?** Yes, for specific use cases:

| Use Case | Recommendation |
|----------|----------------|
| Write-heavy, high load (>95%) | **Use elastic hash** (4-8x insert win) |
| Delete-heavy, high load | **Use elastic hash** (1.1-2.6x delete win) |
| Known capacity at compile time | **Use ComptimeHybridElasticHash** (2-7x faster) |
| Small datasets (<65k) | **Use elastic hash** (wins both insert and lookup) |
| General purpose | Use std.HashMap |
| Read-heavy, large datasets | Use std.HashMap |

The elastic hash is not a drop-in replacement for std.HashMap, but it's a genuine win for write-heavy workloads at high load factors - which is exactly what the paper claimed.
