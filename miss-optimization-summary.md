# Miss optimization: `@branchHint(.cold)` + `matchEmpty`

## The problem

Elastic hash's biggest weakness was miss lookups — 2-6x slower than abseil at normal load factors. The tier-0 `get()` loop scanned all 7 probe positions unconditionally, even though at 50% load most buckets have empty slots that prove the key can't exist.

Five previous attempts to add early termination were reverted because they regressed hit performance by 10-30%.

## The fix

Three lines in `get()`:

```zig
if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) {
    @branchHint(.cold);
    return null;
}
```

After each fingerprint check, we SIMD-compare the bucket's fingerprints against zero. If any slot is empty, the key can't be further along the probe chain — return null.

`@branchHint(.cold)` tells LLVM this branch is almost never taken. The CPU's branch predictor learns to predict "not taken" on every iteration. For hits, the prediction is always correct (the key is found before any empty slot matters), so the check costs ~0 cycles. For misses, the branch is taken early — at 50% load, most buckets have empty slots, so misses terminate in 1-2 probes instead of 7.

This is identical to the approach that was tried and reverted 5 times. The only difference is the compiler hint.

## Results

### Before and after (M4, 1M elements, unshuffled)

| Load | Hit before | Hit after | Miss before | Miss after |
|------|-----------|----------|------------|-----------|
| 10% | - | 469 | - | 256 |
| 25% | - | 1,307 | - | 729 |
| 50% | 8,404 | 4,725 | 12,343 | 2,473 |
| 75% | - | 8,452 | - | 8,107 |
| 90% | - | 13,133 | - | 23,879 |

### vs abseil (50% load)

| Operation | Elastic | Abseil | Ratio |
|-----------|---------|--------|-------|
| Hit (unshuffled) | 4,725 | 14,616 | 3.09x faster |
| Miss (unshuffled) | 2,473 | 7,079 | 2.86x faster |
| Hit (shuffled) | 9,368 | 31,626 | 3.38x faster |
| Insert | 3,835 | 21,845 | 5.70x faster |
| Delete | 1,461 | 9,030 | 6.18x faster |

Misses went from 4x slower than abseil to 2.9x faster.

### Cross-language ranking at 50% load

Elastic hash is #1 on every operation against abseil, Rust hashbrown+ahash, Go swiss.Map, and Go builtin map.

## Tombstone churn: verified stable

Concern: tombstones from deletes might fill empty slots over time, degrading the `matchEmpty` optimization.

Test: fill to 50%, then run up to 500K cycles of (delete random, insert new). Measure hit and miss after each milestone.

| Churn cycles | Hit (us) | Miss (us) |
|-------------|---------|----------|
| 0 | 10,343 | 5,173 |
| 10,000 | 10,079 | 4,673 |
| 100,000 | 10,318 | 5,266 |
| 500,000 | 8,807 | 5,600 |

No degradation. Tombstones get recycled by subsequent inserts, keeping the empty slot ratio stable.

## Where abseil still wins

- Miss lookups at 75%+ load: tier 0 fills up, empty slots become rare, `matchEmpty` can't terminate early.
- 99% load factor across the board.

## Remaining validation gaps

1. ~~Tombstone accumulation under churn~~ -- tested, stable
2. Memory overhead comparison vs abseil
3. Mixed read/write workloads (interleaved get/insert/delete)
4. High-load miss behavior under churn (75%+ load)
5. Variable key lengths (8, 32, 64, 128, 256 bytes)
