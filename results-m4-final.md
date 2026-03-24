# Final M4 benchmark: elastic hash with miss optimization

Apple M4, ~16MB shared L2. All tests: 16-byte hex string keys, splitmix64, median of 10 runs, 2 warmup.

The miss optimization: `matchEmpty` check per probe with `@branchHint(.cold)` in tier-0 get(). Three lines of code.

## Headline: elastic hash now beats abseil on BOTH hits and misses

### Unshuffled, 1M elements

| Load | | Elastic | Abseil | Rust+ahash | Go swiss | Go builtin |
|------|-|---------|--------|-----------|---------|-----------|
| 10% | hit | **469** | 1,334 | 1,693 | 3,185 | 3,555 |
| | miss | **256** | 365 | 720 | 2,663 | 3,150 |
| 25% | hit | **1,307** | 4,389 | 6,208 | 11,739 | 13,024 |
| | miss | **729** | 1,124 | 1,895 | 8,521 | 10,233 |
| 50% | hit | **4,725** | 14,616 | 16,135 | 28,459 | 31,959 |
| | miss | **2,473** | 7,079 | 4,986 | 22,643 | 25,831 |
| 75% | hit | **8,452** | 17,833 | 25,762 | 44,603 | 50,818 |
| | miss | 8,107 | **6,988** | 10,292 | 34,845 | 39,999 |
| 90% | hit | **13,133** | 20,852 | 34,259 | 66,265 | 77,017 |
| | miss | 23,879 | **10,168** | 16,156 | 55,995 | 56,964 |
| 99% | hit | **15,303** | 17,426 | 34,901 | 62,033 | 72,002 |
| | miss | 31,344 | **8,354** | 15,879 | 48,953 | 57,474 |

### Gaps vs abseil (unshuffled, 1M)

| Load | Hit gap | Miss gap |
|------|---------|----------|
| 10% | **2.84x** | **1.43x** |
| 25% | **3.36x** | **1.54x** |
| 50% | **3.09x** | **2.86x** |
| 75% | **2.11x** | 0.86x (abseil wins) |
| 90% | **1.59x** | 0.43x (abseil wins) |
| 99% | **1.14x** | 0.27x (abseil wins) |

Elastic hash wins hits at every load factor. Misses are faster at 10-50%, abseil pulls ahead at 75%+ where tier 0 fills up and empty slots become rare.

### Shuffled hit lookup, 1M elements

| Load | Elastic | Abseil | Ratio |
|------|---------|--------|-------|
| 10% | **613** | 3,088 | **5.04x** |
| 25% | **2,575** | 12,280 | **4.77x** |
| 50% | **9,368** | 31,626 | **3.38x** |
| 75% | **17,257** | 37,708 | **2.18x** |
| 90% | **21,139** | 42,320 | **2.00x** |
| 99% | **25,574** | 44,923 | **1.76x** |

### Size sweep at 50% load, shuffled hit lookup

| Size | Elastic | Abseil | Rust+ahash | Go swiss | Go builtin |
|------|---------|--------|-----------|---------|-----------|
| 16K | **34** | 45 | 39 | 64 | 75 |
| 64K | **157** | 206 | 187 | 286 | 459 |
| 256K | **699** | 1,167 | 960 | 2,770 | 7,214 |
| 1M | **9,579** | 20,071 | 15,248 | 29,272 | 37,406 |
| 4M | **59,021** | 104,760 | 94,685 | 140,889 | 159,881 |

| Size | vs Abseil | vs Rust+ahash | vs Go swiss |
|------|----------|--------------|------------|
| 16K | **1.32x** | 1.15x | 1.88x |
| 64K | **1.31x** | 1.19x | 1.82x |
| 256K | **1.67x** | 1.37x | 3.96x |
| 1M | **2.09x** | 1.59x | 3.05x |
| 4M | **1.77x** | 1.60x | 2.39x |

### Insert performance (unshuffled, 1M)

| Load | Elastic | Abseil | Rust+ahash | Go swiss |
|------|---------|--------|-----------|---------|
| 10% | **1,518** | 1,980 | 1,609 | 4,971 |
| 25% | **2,309** | 5,010 | 4,156 | 12,099 |
| 50% | **3,835** | 21,845 | 9,603 | 26,344 |
| 75% | **5,335** | 19,732 | 14,952 | 36,257 |
| 99% | **10,539** | 20,898 | 19,963 | 50,178 |

### Delete performance (unshuffled, 1M)

| Load | Elastic | Abseil | Rust+ahash | Go swiss |
|------|---------|--------|-----------|---------|
| 50% | **1,461** | 9,030 | 7,407 | 12,959 |
| 99% | **4,315** | 11,565 | 14,841 | 25,478 |

Elastic hash is 6x faster than abseil on deletes at 50% load.

## Ranking at 50% load (the most common comparison point)

### Shuffled hit lookup
1. **Elastic Hash (Zig)**: 9,579us
2. Rust hashbrown + ahash: 15,248us (1.59x slower)
3. Abseil (C++): 20,071us (2.09x slower)
4. Go swiss.Map: 29,272us (3.05x slower)
5. Go builtin map: 37,406us (3.90x slower)

### Unshuffled miss lookup
1. **Elastic Hash (Zig)**: 2,473us
2. Rust hashbrown + ahash: 4,986us (2.02x slower)
3. Abseil (C++): 7,079us (2.86x slower)
4. Go swiss.Map: 22,643us (9.16x slower)

### Insert
1. **Elastic Hash (Zig)**: 3,835us
2. Rust hashbrown + ahash: 9,603us (2.50x slower)
3. Abseil (C++): 21,845us (5.70x slower)
4. Go swiss.Map: 26,344us (6.87x slower)

### Delete
1. **Elastic Hash (Zig)**: 1,461us
2. Rust hashbrown + ahash: 7,407us (5.07x slower)
3. Abseil (C++): 9,030us (6.18x slower)
4. Go swiss.Map: 12,959us (8.87x slower)

## What changed from the previous benchmark

The miss optimization (`matchEmpty` + `@branchHint(.cold)`) fixed the only operation where abseil was faster at normal load factors:

| Operation (50% load) | Before | After | Change |
|----------------------|--------|-------|--------|
| Hit (unshuffled) | 8,404us | 4,725us | **44% faster** |
| Miss (unshuffled) | 12,343us | 2,473us | **80% faster** |
| vs abseil miss | 4.1x slower | **2.9x faster** | flipped |

## Where abseil still wins

- Miss lookups at 75%+ load (tier 0 fills up, fewer empty slots for early termination)
- 99% load factor across the board (tier 0 is saturated)

## Platform details

- Apple M4, macOS
- Zig 0.15.2, ReleaseFast
- Apple Clang (g++) -std=c++17 -O3 -march=native
- Rust 1.94.0, release profile
- Go 1.26.0
- abseil 20260107.1 via Homebrew
