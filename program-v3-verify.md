# Autoresearch v3-verify: Are these results real?

You are an autonomous verification agent. The elastic hash appears to beat abseil flat_hash_map by 40-65% on hit lookups at normal load factors. Before publishing this claim, we need to rule out every way the result could be wrong or misleading.

## The claim to verify

At n=1,048,576 with random keys and both sides using reserve(n) / init(n):
- Elastic hash is 55-65% faster than abseil on hit lookups at 10-50% load
- Elastic hash is 40-55% faster at 50-75% load
- Elastic hash is ~5% slower at 99% load
- Elastic hash is 2-3x faster on deletes at all loads
- Elastic hash is 2.5x slower on miss lookups at all loads

## Potential sources of error (investigate each one)

### 1. Is reserve(n) a fair comparison?

The biggest methodological question. When a user says "I need a hash map for up to 1M elements," they typically:
- In abseil: `map.reserve(1048576)` then insert elements over time
- In elastic hash: `init(allocator, 1048576)` then insert elements

But abseil's `reserve(n)` allocates internal capacity for AT LEAST n elements. Due to abseil's ~7/8 max load factor, `reserve(1M)` actually allocates ~1.14M internal slots.

Our `init(n)` allocates exactly n/BUCKET_SIZE = 65536 buckets = 1,048,576 tier-0 slots, plus tier 1-16 slots.

**Verification**: Print both tables' actual memory usage. Check if abseil is over-allocating and paying a cache penalty we're not paying.

Write a small C++ program that:
```cpp
absl::flat_hash_map<uint64_t, uint64_t> map;
map.reserve(n);
printf("capacity=%zu bucket_count=%zu\n", map.capacity(), map.bucket_count());
```

And compare to our total_buckets * BUCKET_SIZE.

### 2. Is abseil's hash function penalizing it?

absl::Hash is designed for generality (strings, structs, etc.). For u64 keys, it's likely more expensive than our single-multiply hash. If the win is just "we have a faster hash for integers," that's real but narrow.

**Verification**: Measure the hash function cost separately. Time just the hash computation for 1M random u64 keys in both implementations.

### 3. Does abseil's reserve(n) actually USE all that memory?

At 10% load with reserve(1M): abseil has a table of ~1.14M slots but only 100K are filled. The control bytes (1.14MB) and slots (18MB) are allocated but mostly unused. Page faults and TLB misses for the unused pages might penalize abseil.

Our elastic hash also allocates for 1M but our fingerprint array is 1MB (similar to abseil's control bytes) and entries are 16MB (similar to abseil's slots).

**Verification**: Check if abseil touches all pages during reserve(). If not, the OS may not map them, and the comparison is about page fault behavior, not the data structure.

### 4. Is our benchmark loop biased?

The benchmark inserts all elements, then looks them all up in insertion order. This means:
- The last-inserted elements are hottest in cache
- The lookup order matches insert order (temporal locality)

Abseil and elastic hash may benefit differently from this pattern.

**Verification**: Shuffle the lookup order. Use a random permutation of the keys for the lookup phase instead of the insertion order.

### 5. Does the result hold at different sizes?

We only show n=1M at various load factors. What about n=100K? n=10M?

**Verification**: Run the load factor sweep at n=65536, n=262144, n=1048576, n=4194304.

### 6. Does the result hold with string keys?

Our hash is specialized for u64. Real workloads often use strings.

**Verification**: This is harder to test (Zig strings vs C++ strings have different overhead). Note this as a limitation rather than testing it.

### 7. Is the compiler giving us an unfair advantage?

Zig with ReleaseFast uses `-O3` equivalent. Abseil is compiled with `-O3 -march=native`. Both should be maximal optimization. But Zig's LLVM pipeline might differ from g++'s.

**Verification**: Check compiler versions. Try compiling abseil with clang (same LLVM backend as Zig) to compare.

## Experiment plan

### Phase 1: Quick checks (do these first)
1. Print abseil's actual capacity vs our capacity at each test point
2. Shuffle the lookup order and re-run
3. Run at n=65536 and n=4194304 to check size independence

### Phase 2: Deeper investigation
4. Time hash function cost separately
5. Check abseil with clang compilation
6. Profile both to see where time is actually spent

### Phase 3: If results hold
7. Test with mixed hit/miss ratios (90/10, 50/50)
8. Test with non-uniform key distributions (zipf, sequential)
9. Memory usage comparison

## Constraints

### What you can create/edit
- `verify-capacity.cpp` — abseil capacity check
- `src/autobench.zig` — add shuffled lookup test (keep existing tests)
- `bench-abseil.cpp` — add shuffled lookup test (or create `bench-abseil-verify.cpp`)
- `verify-results.md` — findings document

### What you CANNOT edit
- `src/hybrid.zig` — the implementation is frozen for verification
- `bench-v2.sh` — keep the existing benchmark intact
- `program-v3-verify.md` — this file

### Rules
- Do NOT modify the hash table implementation during verification
- Do NOT cherry-pick which results to report
- Report ALL findings, especially negative ones
- If a verification check shows the result is misleading, say so clearly

## Output

Write findings to `verify-results.md` as you go. Be brutally honest.
