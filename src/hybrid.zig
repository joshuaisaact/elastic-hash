//! Hybrid elastic hash: SIMD buckets + batch insertion from the paper.
//! Optimized with separated memory layout for cache efficiency.
//! Includes comptime version for when capacity is known at compile time.
const std = @import("std");
const math = std.math;

pub const BUCKET_SIZE = 16;
const MAX_PROBES = 20;
const TOMBSTONE: u8 = 0xFF;

// Paper parameters
const DELTA: f64 = 0.01; // δ = 1% slack parameter
const DELTA_HALF: f64 = DELTA / 2.0; // δ/2 threshold for case 2
const PROBE_CONSTANT: f64 = 16.0; // c constant for probe limit function

/// Comptime hybrid elastic hash - capacity known at compile time.
/// All tier metadata is computed at comptime, loops are unrolled.
pub fn ComptimeHybridElasticHash(comptime capacity: usize) type {
    const actual_capacity = std.math.ceilPowerOfTwo(usize, capacity) catch capacity;
    const tier0_buckets = @max(actual_capacity / BUCKET_SIZE, 1);
    const num_tiers = @max(1, std.math.log2_int(usize, tier0_buckets) + 1);

    // Compute tier metadata at comptime
    const TierInfo = struct {
        start: usize,
        bucket_count: usize,
    };

    const tier_info: [num_tiers]TierInfo = comptime blk: {
        var info: [num_tiers]TierInfo = undefined;
        var total: usize = 0;
        var buckets = tier0_buckets;
        for (0..num_tiers) |i| {
            buckets = @max(buckets, 1);
            info[i] = .{ .start = total, .bucket_count = buckets };
            total += buckets;
            buckets /= 2;
        }
        break :blk info;
    };

    const total_buckets = comptime blk: {
        var total: usize = 0;
        for (tier_info) |t| total += t.bucket_count;
        break :blk total;
    };

    return struct {
        const Self = @This();

        // Separated memory layout
        fingerprints: *[total_buckets][BUCKET_SIZE]u8,
        keys: *[total_buckets][BUCKET_SIZE]u64,
        values: *[total_buckets][BUCKET_SIZE]u64,

        tier_slot_counts: [num_tiers]usize = [_]usize{0} ** num_tiers,
        count: usize = 0,
        current_batch: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const fingerprints = try allocator.create([total_buckets][BUCKET_SIZE]u8);
            @memset(fingerprints, [_]u8{0} ** BUCKET_SIZE);

            const keys = try allocator.create([total_buckets][BUCKET_SIZE]u64);
            const values = try allocator.create([total_buckets][BUCKET_SIZE]u64);

            return .{
                .fingerprints = fingerprints,
                .keys = keys,
                .values = values,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self.fingerprints);
            self.allocator.destroy(self.keys);
            self.allocator.destroy(self.values);
        }

        inline fn hash(key: u64) u64 {
            var a = key ^ 0xa0761d6478bd642f;
            var b = key ^ 0xe7037ed1a0b428db;
            const r = @as(u128, a) *% @as(u128, b);
            a = @truncate(r);
            b = @truncate(r >> 64);
            return a ^ b;
        }

        inline fn fingerprint(h: u64) u8 {
            const fp: u8 = @truncate(h >> 56);
            return if (fp == 0) 1 else fp;
        }

        inline fn bucketIndex(h: u64, probe: usize, comptime num_buckets: usize) usize {
            const mixed = h +% @as(u64, probe) *% 0x9e3779b97f4a7c15;
            return mixed & (num_buckets - 1);
        }

        inline fn simdMatchFp(fps: *const [BUCKET_SIZE]u8, fp: u8) u16 {
            const Vec = @Vector(BUCKET_SIZE, u8);
            const fp_vec: Vec = fps.*;
            const needle: Vec = @splat(fp);
            return @bitCast(fp_vec == needle);
        }

        inline fn simdMatchEmpty(fps: *const [BUCKET_SIZE]u8) u16 {
            const Vec = @Vector(BUCKET_SIZE, u8);
            const fp_vec: Vec = fps.*;
            const zeros: Vec = @splat(0);
            return @bitCast(fp_vec == zeros);
        }

        inline fn findKeyInBucket(self: *const Self, comptime tier: usize, rel_idx: usize, key: u64, fp: u8) ?usize {
            const abs_idx = tier_info[tier].start + rel_idx;
            var mask = simdMatchFp(&self.fingerprints[abs_idx], fp);
            while (mask != 0) {
                const slot = @ctz(mask);
                if (self.keys[abs_idx][slot] == key) {
                    return slot;
                }
                mask &= mask - 1;
            }
            return null;
        }

        inline fn findEmptyInBucket(self: *const Self, comptime tier: usize, rel_idx: usize) ?usize {
            const abs_idx = tier_info[tier].start + rel_idx;
            const mask = simdMatchEmpty(&self.fingerprints[abs_idx]);
            if (mask == 0) return null;
            return @ctz(mask);
        }

        inline fn insertAt(self: *Self, comptime tier: usize, rel_idx: usize, slot: usize, key: u64, value: u64, fp: u8) void {
            const abs_idx = tier_info[tier].start + rel_idx;
            self.fingerprints[abs_idx][slot] = fp;
            self.keys[abs_idx][slot] = key;
            self.values[abs_idx][slot] = value;
        }

        inline fn getEmptyFraction(self: *const Self, comptime tier: usize) f64 {
            const used: f64 = @floatFromInt(self.tier_slot_counts[tier]);
            const total: f64 = @floatFromInt(tier_info[tier].bucket_count * BUCKET_SIZE);
            return 1.0 - (used / total);
        }

        fn probeLimit(epsilon: f64) usize {
            if (epsilon <= 0.0) return MAX_PROBES;
            const log_inv_eps = @log(1.0 / epsilon);
            const log_inv_delta = @log(1.0 / DELTA);
            const limit = PROBE_CONSTANT * @min(log_inv_eps * log_inv_eps, log_inv_delta);
            return @min(@as(usize, @intFromFloat(@max(1.0, limit))), MAX_PROBES);
        }

        pub fn insert(self: *Self, key: u64, value: u64) void {
            const h = hash(key);
            const fp = fingerprint(h);
            const batch = self.current_batch;

            // Batch 0: fill tier 0 until it reaches 75% full
            if (batch == 0) {
                self.insertIntoTier(0, h, fp, key, value);
                if (self.getEmptyFraction(0) <= 0.25) {
                    self.current_batch = 1;
                }
                return;
            }

            if (batch >= num_tiers) {
                self.insertAnyTier(h, fp, key, value);
                return;
            }

            // Use runtime dispatch for batch-dependent tier selection
            self.insertWithBatch(batch, h, fp, key, value);
        }

        fn insertWithBatch(self: *Self, batch: usize, h: u64, fp: u8, key: u64, value: u64) void {
            inline for (1..num_tiers) |b| {
                if (batch == b) {
                    const primary = b - 1;
                    const secondary = b;
                    const e1 = self.getEmptyFraction(primary);
                    const e2 = self.getEmptyFraction(secondary);

                    // Paper's three cases:
                    if (e1 > DELTA_HALF and e2 > 0.25) {
                        // Case 1: Both have space - try primary with limited probes
                        if (!self.tryInsertWithLimit(primary, h, fp, key, value, probeLimit(e1))) {
                            self.insertIntoTier(secondary, h, fp, key, value);
                        }
                    } else if (e1 <= DELTA_HALF) {
                        // Case 2: Primary effectively full
                        self.insertIntoTier(secondary, h, fp, key, value);
                    } else {
                        // Case 3: Secondary too full - must use primary
                        self.insertIntoTier(primary, h, fp, key, value);
                    }

                    // Advance batch when primary effectively full AND secondary getting full
                    if (e1 <= DELTA_HALF and e2 <= 0.25 and b + 1 < num_tiers) {
                        self.current_batch = b + 1;
                    }
                    return;
                }
            }
        }

        fn insertIntoTier(self: *Self, comptime tier: usize, h: u64, fp: u8, key: u64, value: u64) void {
            const num_buckets = tier_info[tier].bucket_count;
            for (0..num_buckets) |probe| {
                const rel_idx = bucketIndex(h, probe, num_buckets);
                if (self.findEmptyInBucket(tier, rel_idx)) |slot| {
                    self.insertAt(tier, rel_idx, slot, key, value, fp);
                    self.tier_slot_counts[tier] += 1;
                    self.count += 1;
                    return;
                }
            }
            // Tier full - try next tier
            if (tier + 1 < num_tiers) {
                self.insertIntoTier(tier + 1, h, fp, key, value);
            }
        }

        fn tryInsertWithLimit(self: *Self, comptime tier: usize, h: u64, fp: u8, key: u64, value: u64, limit: usize) bool {
            const num_buckets = tier_info[tier].bucket_count;
            const max_probe = @min(limit, num_buckets);

            for (0..max_probe) |probe| {
                const rel_idx = bucketIndex(h, probe, num_buckets);
                if (self.findEmptyInBucket(tier, rel_idx)) |slot| {
                    self.insertAt(tier, rel_idx, slot, key, value, fp);
                    self.tier_slot_counts[tier] += 1;
                    self.count += 1;
                    return true;
                }
            }
            return false;
        }

        fn insertAnyTier(self: *Self, h: u64, fp: u8, key: u64, value: u64) void {
            for (0..MAX_PROBES) |probe| {
                inline for (0..num_tiers) |tier| {
                    const num_buckets = tier_info[tier].bucket_count;
                    if (probe < num_buckets) {
                        const rel_idx = bucketIndex(h, probe, num_buckets);
                        if (self.findEmptyInBucket(tier, rel_idx)) |slot| {
                            self.insertAt(tier, rel_idx, slot, key, value, fp);
                            self.tier_slot_counts[tier] += 1;
                            self.count += 1;
                            return;
                        }
                    }
                }
            }
        }

        pub fn get(self: *const Self, key: u64) ?u64 {
            const h = hash(key);
            const fp = fingerprint(h);

            for (0..MAX_PROBES) |probe| {
                // Unrolled tier loop - all tier metadata is comptime
                inline for (0..num_tiers) |tier| {
                    const num_buckets = comptime tier_info[tier].bucket_count;
                    const tier_start = comptime tier_info[tier].start;
                    if (probe < num_buckets) {
                        const rel_idx = bucketIndex(h, probe, num_buckets);
                        const abs_idx = tier_start + rel_idx;

                        var mask = simdMatchFp(&self.fingerprints[abs_idx], fp);
                        while (mask != 0) {
                            const slot = @ctz(mask);
                            if (self.keys[abs_idx][slot] == key) {
                                return self.values[abs_idx][slot];
                            }
                            mask &= mask - 1;
                        }
                    }
                }
            }
            return null;
        }
    };
}

const FpVector = @Vector(BUCKET_SIZE, u8);

/// SIMD fingerprint matching on a 16-byte aligned chunk
inline fn matchFingerprint(fps: *const [BUCKET_SIZE]u8, fp: u8) u16 {
    const fp_vec: FpVector = fps.*;
    const needle: FpVector = @splat(fp);
    const matches = fp_vec == needle;
    return @bitCast(matches);
}

/// SIMD empty slot matching
inline fn matchEmpty(fps: *const [BUCKET_SIZE]u8) u16 {
    const fp_vec: FpVector = fps.*;
    const zeros: FpVector = @splat(0);
    const empties = fp_vec == zeros;
    return @bitCast(empties);
}

/// SIMD empty or tombstone matching (for insertion)
inline fn matchEmptyOrTombstone(fps: *const [BUCKET_SIZE]u8) u16 {
    const fp_vec: FpVector = fps.*;
    const zeros: FpVector = @splat(0);
    const tombstones: FpVector = @splat(TOMBSTONE);
    const empty_mask = fp_vec == zeros;
    const tombstone_mask = fp_vec == tombstones;
    const empty_bits: u16 = @bitCast(empty_mask);
    const tombstone_bits: u16 = @bitCast(tombstone_mask);
    return empty_bits | tombstone_bits;
}

pub const HybridElasticHash = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    // Separated memory layout for cache efficiency
    fingerprints: [][BUCKET_SIZE]u8,
    keys: [][BUCKET_SIZE]u64,
    values: [][BUCKET_SIZE]u64,

    tier_starts: []usize,
    tier_bucket_counts: []usize,
    tier_slot_counts: []usize,
    num_tiers: usize,
    total_buckets: usize,
    count: usize = 0,
    current_batch: usize = 0,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Self {
        const capacity = std.math.ceilPowerOfTwo(usize, n) catch n;
        // Tier 0 = capacity/2 (must be power of 2 for bucket indexing!)
        // This forces elements to spread across tiers (real elastic hashing)
        const tier0_buckets = @max(capacity / BUCKET_SIZE / 2, 1);
        const num_tiers = @max(1, std.math.log2_int(usize, tier0_buckets) + 1);

        const tier_starts = try allocator.alloc(usize, num_tiers);
        const tier_bucket_counts = try allocator.alloc(usize, num_tiers);
        const tier_slot_counts = try allocator.alloc(usize, num_tiers);

        var total_buckets: usize = 0;
        var buckets_in_tier = tier0_buckets;
        for (0..num_tiers) |i| {
            buckets_in_tier = @max(buckets_in_tier, 1);
            tier_starts[i] = total_buckets;
            tier_bucket_counts[i] = buckets_in_tier;
            tier_slot_counts[i] = 0;
            total_buckets += buckets_in_tier;
            buckets_in_tier /= 2;
        }

        const fingerprints = try allocator.alloc([BUCKET_SIZE]u8, total_buckets);
        const keys = try allocator.alloc([BUCKET_SIZE]u64, total_buckets);
        const values = try allocator.alloc([BUCKET_SIZE]u64, total_buckets);

        for (fingerprints) |*bucket_fps| {
            @memset(bucket_fps, 0);
        }

        return .{
            .allocator = allocator,
            .fingerprints = fingerprints,
            .keys = keys,
            .values = values,
            .tier_starts = tier_starts,
            .tier_bucket_counts = tier_bucket_counts,
            .tier_slot_counts = tier_slot_counts,
            .num_tiers = num_tiers,
            .total_buckets = total_buckets,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.fingerprints);
        self.allocator.free(self.keys);
        self.allocator.free(self.values);
        self.allocator.free(self.tier_starts);
        self.allocator.free(self.tier_bucket_counts);
        self.allocator.free(self.tier_slot_counts);
    }

    inline fn getBucketIdx(self: *const Self, tier: usize, bucket_idx: usize) usize {
        return self.tier_starts[tier] + bucket_idx;
    }

    inline fn hash(key: u64) u64 {
        var a = key ^ 0xa0761d6478bd642f;
        var b = key ^ 0xe7037ed1a0b428db;
        const r = @as(u128, a) *% @as(u128, b);
        a = @truncate(r);
        b = @truncate(r >> 64);
        return a ^ b;
    }

    inline fn fingerprint(h: u64) u8 {
        const fp: u8 = @truncate(h >> 56);
        // 0 = empty, 0xFF = tombstone, so valid range is 1-254
        return if (fp == 0) 1 else if (fp == TOMBSTONE) 0xFE else fp;
    }

    inline fn bucketIndex(h: u64, probe: usize, num_buckets: usize) usize {
        return (h +% @as(u64, probe)) & (num_buckets - 1);
    }

    fn getEmptyFraction(self: *const Self, tier: usize) f64 {
        const used: f64 = @floatFromInt(self.tier_slot_counts[tier]);
        const total: f64 = @floatFromInt(self.tier_bucket_counts[tier] * BUCKET_SIZE);
        return 1.0 - (used / total);
    }

    fn probeLimit(epsilon: f64) usize {
        if (epsilon <= 0.0) return MAX_PROBES;
        const log_inv_eps = @log(1.0 / epsilon);
        const log_inv_delta = @log(1.0 / DELTA);
        const limit = PROBE_CONSTANT * @min(log_inv_eps * log_inv_eps, log_inv_delta);
        return @min(@as(usize, @intFromFloat(@max(1.0, limit))), MAX_PROBES);
    }

    inline fn findKeyInBucket(self: *const Self, bucket_abs_idx: usize, key: u64, fp: u8) ?usize {
        var mask = matchFingerprint(&self.fingerprints[bucket_abs_idx], fp);
        while (mask != 0) {
            const slot = @ctz(mask);
            if (self.keys[bucket_abs_idx][slot] == key) {
                return slot;
            }
            mask &= mask - 1;
        }
        return null;
    }

    inline fn findEmptyInBucket(self: *const Self, bucket_abs_idx: usize) ?usize {
        const mask = matchEmpty(&self.fingerprints[bucket_abs_idx]);
        if (mask == 0) return null;
        return @ctz(mask);
    }

    inline fn findEmptyOrTombstoneInBucket(self: *const Self, bucket_abs_idx: usize) ?usize {
        const mask = matchEmptyOrTombstone(&self.fingerprints[bucket_abs_idx]);
        if (mask == 0) return null;
        return @ctz(mask);
    }

    inline fn insertAt(self: *Self, bucket_abs_idx: usize, slot: usize, key: u64, value: u64, fp: u8) void {
        self.fingerprints[bucket_abs_idx][slot] = fp;
        self.keys[bucket_abs_idx][slot] = key;
        self.values[bucket_abs_idx][slot] = value;
    }

    pub fn insert(self: *Self, key: u64, value: u64) void {
        const h = hash(key);
        const fp = fingerprint(h);
        const i = self.current_batch;

        // Prefetch first probe location
        if (self.num_tiers > 0) {
            const first_bucket = self.getBucketIdx(0, bucketIndex(h, 0, self.tier_bucket_counts[0]));
            @prefetch(&self.fingerprints[first_bucket], .{ .rw = .write, .locality = 3, .cache = .data });
        }

        if (i == 0) {
            self.insertIntoTier(0, h, fp, key, value);
            if (self.getEmptyFraction(0) <= 0.25) {
                self.current_batch = 1;
            }
            return;
        }

        if (i >= self.num_tiers) {
            self.insertAnyTier(h, fp, key, value);
            return;
        }

        const primary = i - 1;
        const secondary = i;
        const e1 = self.getEmptyFraction(primary);
        const e2 = self.getEmptyFraction(secondary);

        if (e1 > DELTA_HALF and e2 > 0.25) {
            if (!self.tryInsertWithLimit(primary, h, fp, key, value, probeLimit(e1))) {
                self.insertIntoTier(secondary, h, fp, key, value);
            }
        } else if (e1 <= DELTA_HALF) {
            self.insertIntoTier(secondary, h, fp, key, value);
        } else {
            self.insertIntoTier(primary, h, fp, key, value);
        }

        if (e1 <= DELTA_HALF and e2 <= 0.25 and i + 1 < self.num_tiers) {
            self.current_batch = i + 1;
        }
    }

    fn insertIntoTier(self: *Self, tier: usize, h: u64, fp: u8, key: u64, value: u64) void {
        const num_buckets = self.tier_bucket_counts[tier];
        var probe: usize = 0;
        while (probe < num_buckets) : (probe += 1) {
            const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
            const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);

            if (self.findEmptyOrTombstoneInBucket(abs_bucket_idx)) |slot| {
                self.insertAt(abs_bucket_idx, slot, key, value, fp);
                self.tier_slot_counts[tier] += 1;
                self.count += 1;
                return;
            }
        }
        self.insertAnyTier(h, fp, key, value);
    }

    fn tryInsertWithLimit(self: *Self, tier: usize, h: u64, fp: u8, key: u64, value: u64, limit: usize) bool {
        const num_buckets = self.tier_bucket_counts[tier];
        const max_probe = @min(limit, num_buckets);

        for (0..max_probe) |probe| {
            const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
            const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);

            if (self.findEmptyOrTombstoneInBucket(abs_bucket_idx)) |slot| {
                self.insertAt(abs_bucket_idx, slot, key, value, fp);
                self.tier_slot_counts[tier] += 1;
                self.count += 1;
                return true;
            }
        }
        return false;
    }

    fn insertAnyTier(self: *Self, h: u64, fp: u8, key: u64, value: u64) void {
        var j: usize = 1;
        while (j <= MAX_PROBES) : (j += 1) {
            for (0..self.num_tiers) |tier| {
                const probe = j - 1;
                const num_buckets = self.tier_bucket_counts[tier];
                if (probe >= num_buckets) continue;

                const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
                const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);

                if (self.findEmptyOrTombstoneInBucket(abs_bucket_idx)) |slot| {
                    self.insertAt(abs_bucket_idx, slot, key, value, fp);
                    self.tier_slot_counts[tier] += 1;
                    self.count += 1;
                    return;
                }
            }
        }
    }

    const MAX_LOOKUP_TIERS = 8;

    pub fn get(self: *const Self, key: u64) ?u64 {
        const h = hash(key);
        const fp = fingerprint(h);
        const search_tiers = @min(self.num_tiers, MAX_LOOKUP_TIERS);

        // Bitmask: tiers where we found an empty slot (can stop probing)
        var tier_done: u8 = 0;

        var j: usize = 1;
        while (j <= MAX_PROBES) : (j += 1) {
            for (0..search_tiers) |tier| {
                if (tier_done & (@as(u8, 1) << @intCast(tier)) != 0) continue;

                const probe = j - 1;
                const num_buckets = self.tier_bucket_counts[tier];
                if (probe >= num_buckets) continue;

                const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
                const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);

                // Single SIMD load, two comparisons from same vector
                const Vec = @Vector(BUCKET_SIZE, u8);
                const fp_vec: Vec = self.fingerprints[abs_bucket_idx];
                const needle: Vec = @splat(fp);
                const zeros: Vec = @splat(0);

                var fp_mask: u16 = @bitCast(fp_vec == needle);
                while (fp_mask != 0) {
                    const slot = @ctz(fp_mask);
                    if (self.keys[abs_bucket_idx][slot] == key) {
                        return self.values[abs_bucket_idx][slot];
                    }
                    fp_mask &= fp_mask - 1;
                }

                // Check for empty from same loaded vector
                if (@as(u16, @bitCast(fp_vec == zeros)) != 0) {
                    tier_done |= @as(u8, 1) << @intCast(tier);
                }
            }
        }
        return null;
    }

    pub fn remove(self: *Self, key: u64) bool {
        const h = hash(key);
        const fp = fingerprint(h);

        var j: usize = 1;
        while (j <= MAX_PROBES) : (j += 1) {
            for (0..self.num_tiers) |tier| {
                const probe = j - 1;
                const num_buckets = self.tier_bucket_counts[tier];
                if (probe >= num_buckets) continue;

                const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
                const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);

                if (self.findKeyInBucket(abs_bucket_idx, key, fp)) |slot| {
                    self.fingerprints[abs_bucket_idx][slot] = TOMBSTONE;
                    self.count -= 1;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn getWithProbes(self: *const Self, key: u64) struct { value: ?u64, bucket_probes: usize } {
        const h = hash(key);
        const fp = fingerprint(h);
        var bucket_probes: usize = 0;

        var j: usize = 1;
        while (j <= MAX_PROBES) : (j += 1) {
            for (0..self.num_tiers) |tier| {
                const probe = j - 1;
                const num_buckets = self.tier_bucket_counts[tier];
                if (probe >= num_buckets) continue;

                bucket_probes += 1;
                const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
                const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);

                if (self.findKeyInBucket(abs_bucket_idx, key, fp)) |slot| {
                    return .{ .value = self.values[abs_bucket_idx][slot], .bucket_probes = bucket_probes };
                }
            }
        }
        return .{ .value = null, .bucket_probes = bucket_probes };
    }
};

test "hybrid basic" {
    var map = try HybridElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert(1, 100);
    map.insert(2, 200);
    map.insert(3, 300);

    try std.testing.expectEqual(@as(?u64, 100), map.get(1));
    try std.testing.expectEqual(@as(?u64, 200), map.get(2));
    try std.testing.expectEqual(@as(?u64, 300), map.get(3));
    try std.testing.expectEqual(@as(?u64, null), map.get(999));
}

test "hybrid high load" {
    var map = try HybridElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    for (0..900) |i| {
        map.insert(i, i * 10);
    }

    for (0..900) |i| {
        try std.testing.expectEqual(@as(?u64, i * 10), map.get(i));
    }

    try std.testing.expectEqual(@as(usize, 900), map.count);
}

test "hybrid 99% load" {
    const n = 2048;
    const fill = n * 99 / 100;

    var map = try HybridElasticHash.init(std.testing.allocator, n);
    defer map.deinit();

    for (0..fill) |i| {
        map.insert(i, i);
    }

    for (0..fill) |i| {
        const result = map.getWithProbes(i);
        try std.testing.expect(result.value != null);
        try std.testing.expectEqual(@as(u64, i), result.value.?);
    }

    try std.testing.expectEqual(@as(usize, fill), map.count);
}

test "hybrid remove" {
    var map = try HybridElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert(1, 100);
    map.insert(2, 200);
    map.insert(3, 300);

    try std.testing.expectEqual(@as(usize, 3), map.count);
    try std.testing.expectEqual(@as(?u64, 200), map.get(2));

    // Remove key 2
    try std.testing.expect(map.remove(2));
    try std.testing.expectEqual(@as(usize, 2), map.count);
    try std.testing.expectEqual(@as(?u64, null), map.get(2));

    // Other keys still accessible
    try std.testing.expectEqual(@as(?u64, 100), map.get(1));
    try std.testing.expectEqual(@as(?u64, 300), map.get(3));

    // Remove non-existent key
    try std.testing.expect(!map.remove(999));
    try std.testing.expectEqual(@as(usize, 2), map.count);
}

test "hybrid remove and reinsert" {
    var map = try HybridElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    // Insert, remove, reinsert
    map.insert(1, 100);
    try std.testing.expect(map.remove(1));
    try std.testing.expectEqual(@as(?u64, null), map.get(1));

    map.insert(1, 999);
    try std.testing.expectEqual(@as(?u64, 999), map.get(1));
    try std.testing.expectEqual(@as(usize, 1), map.count);
}

test "hybrid remove at high load" {
    var map = try HybridElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    // Fill to 80%
    for (0..800) |i| {
        map.insert(i, i * 10);
    }

    // Remove every other element
    for (0..400) |i| {
        try std.testing.expect(map.remove(i * 2));
    }

    try std.testing.expectEqual(@as(usize, 400), map.count);

    // Verify remaining elements
    for (0..400) |i| {
        const key = i * 2 + 1;
        try std.testing.expectEqual(@as(?u64, key * 10), map.get(key));
    }

    // Verify removed elements are gone
    for (0..400) |i| {
        try std.testing.expectEqual(@as(?u64, null), map.get(i * 2));
    }
}
