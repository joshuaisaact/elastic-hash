# elastic-hash-zig

Elastic hashing implementation in Zig. Based on [Elastic Hashing](https://arxiv.org/pdf/2501.02305).

See my blog post for a walkthrough: [www.joshtuddenham.dev/blog/hashmaps](https://www.joshtuddenham.dev/blog/hashmaps)

## Files

- `src/simple.zig` - Minimal implementation (~100 lines). Start here if you're learning.
- `src/main.zig` - Optimized version with:
  - 7-bit fingerprinting to skip key comparisons
  - Batch insertion with empty-fraction thresholds
  - Bitwise masking instead of modulo (power-of-two sizes)
  - The φ priority function from the paper

## Build

```
zig build
```

## Run

```
zig build run
```

## Test

```
zig build test
```

For verbose output:

```
zig build test --summary all
```
