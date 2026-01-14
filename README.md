# elastic-hash-zig

Elastic hashing implementation in Zig. Based on [Elastic Hashing](https://arxiv.org/pdf/2501.02305).

Requires Zig 0.14+ (tested on 0.16.0-dev).

See my blog post for a walkthrough: [www.joshtuddenham.dev/blog/hashmaps](https://www.joshtuddenham.dev/blog/hashmaps)

## Results

The hybrid implementation beats Zig's `std.HashMap` at 99% load factor. `std.HashMap` is based on Google's [SwissTable](https://abseil.io/about/design/swisstables) - the same design used in Abseil (C++), Go 1.24+, and Rust's `hashbrown`.

Benchmarks at 99% load, 5 runs averaged:

| n | operation | Hybrid | std.HashMap | speedup |
|---|-----------|--------|-------------|---------|
| 10k | insert | 1050us | 1545us | **1.47x** |
| 10k | lookup | 1077us | 1443us | **1.34x** |
| 100k | insert | 11432us | 16786us | **1.47x** |
| 100k | lookup | 13961us | 15348us | **1.10x** |
| 1M | insert | 183525us | 243100us | **1.32x** |
| 1M | lookup | 592077us | 280735us | 0.47x |

Insert is 1.3-1.5x faster at all sizes. Lookup is faster up to 100k elements, but loses at 1M due to cache locality effects from the tiered structure.

## Files

- `src/simple.zig` - Minimal implementation (~100 lines). Start here if you're learning.
- `src/main.zig` - Optimized version with fingerprinting, batch insertion, and the φ priority function from the paper.
- `src/hybrid.zig` - SIMD-accelerated version that combines:
  - 16-slot buckets with SIMD fingerprint scanning
  - `@ctz` bitmask for fast slot finding
  - Batch insertion logic from the paper
- `src/bench.zig` - Benchmarks

## Test

```
zig build test
```

## Benchmark

```
zig build bench
```
