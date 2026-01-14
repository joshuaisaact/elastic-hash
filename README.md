# elastic-hash-zig

Elastic hashing implementation in Zig. Based on [Elastic Hashing](https://arxiv.org/pdf/2501.02305).

Requires Zig 0.14+ (tested on 0.16.0-dev).

See my blog post for a walkthrough: [www.joshtuddenham.dev/blog/hashmaps](https://www.joshtuddenham.dev/blog/hashmaps)

## Results

The hybrid implementation beats Zig's `std.HashMap` at 99% load factor. `std.HashMap` is based on Google's [SwissTable](https://abseil.io/about/design/swisstables) - the same design used in Abseil (C++), Go 1.24+, and Rust's `hashbrown`.

Benchmarks at 99% load, 10 runs averaged (ratio >1 = Hybrid faster):

| n | insert | lookup |
|---|--------|--------|
| 10k | **1.49x** | **1.29x** |
| 50k | **1.50x** | **1.13x** |
| 100k | **1.49x** | **1.10x** |
| 250k | **1.58x** | 0.43x |
| 500k | **1.47x** | 0.42x |
| 1M | **1.22x** | 0.47x |
| 2.5M | **1.10x** | **1.47x** |
| 5M | **1.25x** | **1.48x** |
| 10M | **1.23x** | **1.43x** |

**Insert** is 1.1-1.6x faster at all sizes.

**Lookup** has three regimes:
- Up to 100k: Hybrid wins (1.1-1.3x faster)
- 250k-1M: Hybrid loses (0.4-0.5x) - cache locality "valley"
- 2.5M+: Hybrid wins again (1.4-1.5x faster)

The "valley" occurs where cache effects from tiered probing hurt more than std.HashMap's long probe chains. At very large scale, std.HashMap's probe chains become so long that Hybrid's tiered structure wins again.

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

With custom number of runs (default 5):

```
zig build bench -- 10
```
