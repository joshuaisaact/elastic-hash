# elastic-hash-zig

Elastic hashing implementation in Zig. Based on [Elastic Hashing](https://arxiv.org/pdf/2501.02305).

Requires Zig 0.14+ (tested on 0.16.0-dev).

See my blog post for a walkthrough: [www.joshtuddenham.dev/blog/hashmaps](https://www.joshtuddenham.dev/blog/hashmaps)

## Files

- `src/simple.zig` - Minimal implementation (~100 lines). Start here if you're learning.
- `src/main.zig` - Optimized version with:
  - 7-bit fingerprinting to skip key comparisons
  - Batch insertion with empty-fraction thresholds
  - Bitwise masking instead of modulo (power-of-two sizes)
  - The φ priority function from the paper
- `src/bench.zig` - Benchmarks comparing elastic hashing vs linear probing

## Test

```
zig build test
```

## Benchmark

```
zig build bench
```

Runs scaling comparisons, throughput tests, and worst-case latency measurements.
