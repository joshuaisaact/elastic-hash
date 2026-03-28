# Autoresearch v5: Cross-language hash table benchmark

You are an autonomous research agent. Benchmark the elastic hash against every major SwissTable-family hash map: abseil (C++), Meta's F14 (C++), Rust's hashbrown, and Go's swiss.Map. The goal is to answer: "is the tiered metadata advantage specific to abseil, or does it hold against the entire SwissTable family?"

## Background

We've verified that elastic hash beats abseil by 20-60% on string-key hit lookups at medium table sizes (500K-2M) with shuffled random access. The advantage comes from tiered fingerprint metadata that keeps the hot array in L2 while abseil's control bytes spill to L3.

But abseil is just one SwissTable implementation. Each variant has different optimizations:
- **abseil**: The original. 7-bit H2 fingerprints, triangular probing, early termination on empty groups.
- **Meta F14**: 14-way probing (larger groups), different chunk layout, optimized for Meta's workloads.
- **Rust hashbrown**: Adapted for Rust's ownership model, uses SIMD where available, falls back to portable.
- **Go swiss.Map**: Adapted for Go's runtime, garbage collector aware.

If we only beat abseil but lose to F14 or hashbrown, the result is less interesting. If we beat ALL of them, the structural insight is significant.

## What to benchmark

### Competitors

1. **abseil flat_hash_map** (already done, keep as baseline)
   - C++, g++ -O3
   - `absl::flat_hash_map<std::string_view, uint64_t>`

2. **Rust hashbrown** (std::collections::HashMap)
   - Rust, `cargo build --release`
   - `HashMap<&str, u64>` or `HashMap<String, u64>`
   - Use the standard library HashMap (which IS hashbrown since Rust 1.36)

3. **Go swiss.Map** (cockroachdb/swiss)
   - Go, `go build`
   - `swiss.Map[string, uint64]`
   - Requires: `go get github.com/cockroachdb/swiss`

### Test matrix

All tests use the SAME keys (splitmix64 seed 0xDEADBEEF12345678, hex-encoded to 16-byte strings).

| Test | Parameters |
|------|-----------|
| String hit lookup, shuffled | n=1M, load=50%, 16-byte keys |
| String hit lookup, shuffled | n=1M, load=99%, 16-byte keys |
| String hit lookup, shuffled | n=500K, load=50%, 16-byte keys |
| String miss lookup, shuffled | n=1M, load=50%, 16-byte keys |
| Insert | n=1M, fill to 50% |
| Delete | n=1M, delete 50% of elements |
| Variable key length | n=1M, load=50%, 64-byte keys |
| Variable key length | n=1M, load=50%, 256-byte keys |

All benchmarks: median of 10 runs, 2 warmup, shuffled access where applicable.

### Implementation approach

Each benchmark is a standalone program in its respective language:
- `bench-abseil-strings.cpp` (already exists)
- `bench-f14-strings.cpp` (new, if folly available)
- `bench-rust/src/main.rs` (new cargo project)
- `bench-go/main.go` (new go module)

All programs output the same tab-delimited RESULT format:
```
RESULT	impl={name}	n={n}	load={pct}	klen={len}	insert_us={us}	lookup_us={us}	miss_us={us}	delete_us={us}
```

A runner script `bench-cross-lang.sh` builds everything, runs all benchmarks, and produces a comparison table.

### Key generation consistency

All implementations MUST use the same splitmix64 function with the same seed to generate identical key sequences. Verify by printing the first 5 keys from each implementation and comparing.

## Constraints

### What you can create
- `bench-rust/` (cargo project)
- `bench-go/` (go module)
- `bench-cross-lang.sh`
- `cross-lang-results.md`

### What you CANNOT edit
- `src/hybrid.zig`, `src/string_hybrid.zig` — frozen
- `bench-abseil-strings.cpp` — frozen (already correct)
- `src/autobench-strings.zig` — frozen

### Rules
- Same keys, same seeds, same operations across all implementations
- Same capacity reservation semantics (reserve(n) or equivalent)
- Same access pattern (shuffled for lookups)
- Report ALL results, even if unfavorable
- Note any implementation differences that affect fairness (e.g., Go's GC, Rust's ownership)

## Experiment loop

1. Check which competitors are installable (folly, rust, go)
2. Implement benchmarks for available competitors
3. Verify key consistency (first 5 keys must match)
4. Run full test matrix
5. Compile comparison table
6. Write analysis to cross-lang-results.md
7. If any competitor beats us, analyze WHY and note whether it's a data structure advantage or language/compiler advantage
