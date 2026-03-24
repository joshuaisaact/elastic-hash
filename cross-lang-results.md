# Cross-Language Hash Table Comparison

All tests: 1M capacity, 16-byte hex string keys, shuffled random access, median of 10 runs.

## Hit lookup times (us, lower is better)

| Load | Elastic Hash (Zig) | Abseil (C++) | Rust hashbrown | Go builtin | Go swiss.Map |
|------|-------------------|-------------|---------------|-----------|-------------|
| 10% | **950** | 1,867 | 4,663 | 3,108 | 8,737 |
| 25% | **3,828** | 7,137 | 14,335 | 10,317 | 27,010 |
| 50% | **11,119** | 19,312 | 33,177 | 26,480 | 69,715 |
| 75% | **20,425** | 32,964 | 53,249 | 45,578 | 115,572 |
| 90% | **27,227** | 40,753 | 66,997 | 57,952 | 140,874 |
| 99% | **33,318** | 45,404 | 74,860 | 63,739 | 157,142 |

## Gaps (competitor / elastic, >1 = elastic wins)

| Load | vs Abseil | vs Rust | vs Go builtin | vs Go swiss |
|------|----------|---------|--------------|------------|
| 10% | **1.97** | **4.91** | **3.27** | **9.20** |
| 25% | **1.86** | **3.74** | **2.70** | **7.06** |
| 50% | **1.74** | **2.98** | **2.38** | **6.27** |
| 75% | **1.61** | **2.61** | **2.23** | **5.66** |
| 90% | **1.50** | **2.46** | **2.13** | **5.17** |
| 99% | **1.36** | **2.25** | **1.91** | **4.72** |

## IMPORTANT fairness caveats

These numbers are NOT all apples-to-apples. The only fair comparison is against abseil.

### Rust hashbrown
Rust's std::HashMap uses **SipHash** as the default hasher. SipHash is designed for DoS resistance, not speed. It's deliberately ~3-4x slower than wyhash/abseil-hash. Rust developers who need performance use `ahash` or `FxHash` instead. The hashbrown data structure itself (SwissTable port) is fast — it's the hasher that's slow. A fair comparison would require `HashMap<&[u8], u64, BuildHasherDefault<AHasher>>`.

### Go swiss.Map and Go builtin
Go's `string(keys[i][:])` conversion **allocates a new string on every call** in the timed loop. This means each lookup includes a heap allocation + GC pressure. The Go numbers measure "hash table lookup + memory allocation + garbage collection", not just the hash table. A fair comparison would require pre-allocating strings or using unsafe string conversion (which crashed).

### Abseil
The only fair comparison. Both use fast hashing (wyhash vs abseil hash), both use slice/view semantics (no allocation), both compiled with -O3.

## The fair comparison (elastic hash vs abseil only)

| Load | Gap | Meaning |
|------|-----|---------|
| 10% | **1.97** | Elastic 97% faster |
| 50% | **1.74** | Elastic 74% faster |
| 99% | **1.36** | Elastic 36% faster |

This is the verified result. The advantage is from tiered metadata density (1MB fingerprints in L2 vs 2MB control bytes in L3), not from language or compiler differences.

## What this means

The elastic hash beats the most optimized SwissTable implementation (abseil) by 36-97% on string key lookups. Against less-optimized implementations (Rust default, Go), the gap is even larger, but that's mostly due to hasher/allocation overhead rather than data structure design.

The structural insight — tiered SIMD metadata with fingerprint-based filtering — is the differentiator. This insight could potentially be applied to improve hashbrown, Go's swiss.Map, or abseil itself.
