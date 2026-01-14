//! Hybrid elastic hash: SIMD buckets + batch insertion from the paper.
//! Combines simd.zig's bucket scanning with main.zig's insertion strategy.
const std = @import("std");

pub const BUCKET_SIZE = 16;
const MAX_PROBES = 100;

pub const Bucket = struct {
    // Array for mutation, convert to vector for SIMD comparison
    fingerprints: [BUCKET_SIZE]u8 align(16) = [_]u8{0} ** BUCKET_SIZE,
    keys: [BUCKET_SIZE]u64 = undefined,
    values: [BUCKET_SIZE]u64 = undefined,

    const FpVector = @Vector(BUCKET_SIZE, u8);

    /// Returns bitmask of matching fingerprints
    inline fn matchFingerprint(self: *const Bucket, fp: u8) u16 {
        const fp_vec: FpVector = self.fingerprints;
        const needle: FpVector = @splat(fp);
        const matches = fp_vec == needle;
        return @bitCast(matches);
    }

    /// Returns bitmask of empty slots
    inline fn matchEmpty(self: *const Bucket) u16 {
        const fp_vec: FpVector = self.fingerprints;
        const zeros: FpVector = @splat(0);
        const empties = fp_vec == zeros;
        return @bitCast(empties);
    }

    /// Find key using SIMD + ctz. Returns slot index or null.
    pub fn findKey(self: *const Bucket, key: u64, fp: u8) ?usize {
        var mask = self.matchFingerprint(fp);
        while (mask != 0) {
            const slot = @ctz(mask);
            if (self.keys[slot] == key) {
                return slot;
            }
            mask &= mask - 1; // clear lowest bit
        }
        return null;
    }

    /// Find first empty slot using ctz
    pub fn findEmpty(self: *const Bucket) ?usize {
        const mask = self.matchEmpty();
        if (mask == 0) return null;
        return @ctz(mask);
    }

    pub fn insert(self: *Bucket, slot: usize, key: u64, value: u64, fp: u8) void {
        self.fingerprints[slot] = fp;
        self.keys[slot] = key;
        self.values[slot] = value;
    }
};

pub const HybridElasticHash = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    tiers: [][]Bucket,
    tier_bucket_counts: []usize,
    tier_slot_counts: []usize, // slots used per tier (for empty fraction)
    num_tiers: usize,
    count: usize = 0,
    current_batch: usize = 0,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Self {
        const capacity = std.math.ceilPowerOfTwo(usize, n) catch n;
        const tier0_buckets = @max(capacity / BUCKET_SIZE, 1);
        const num_tiers = @max(1, std.math.log2_int(usize, tier0_buckets) + 1);

        const tiers = try allocator.alloc([]Bucket, num_tiers);
        const tier_bucket_counts = try allocator.alloc(usize, num_tiers);
        const tier_slot_counts = try allocator.alloc(usize, num_tiers);

        var buckets_in_tier = tier0_buckets;
        for (0..num_tiers) |i| {
            buckets_in_tier = @max(buckets_in_tier, 1);
            tier_bucket_counts[i] = buckets_in_tier;
            tier_slot_counts[i] = 0;
            tiers[i] = try allocator.alloc(Bucket, buckets_in_tier);
            @memset(tiers[i], Bucket{});
            buckets_in_tier /= 2;
        }

        return .{
            .allocator = allocator,
            .tiers = tiers,
            .tier_bucket_counts = tier_bucket_counts,
            .tier_slot_counts = tier_slot_counts,
            .num_tiers = num_tiers,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.tiers) |tier| {
            self.allocator.free(tier);
        }
        self.allocator.free(self.tiers);
        self.allocator.free(self.tier_bucket_counts);
        self.allocator.free(self.tier_slot_counts);
    }

    inline fn hash(key: u64) u64 {
        // Fast mixing using multiply-xor with wyhash constants
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

    inline fn bucketIndex(h: u64, probe: usize, num_buckets: usize) usize {
        const mixed = h +% @as(u64, probe) *% 0x9e3779b97f4a7c15;
        return mixed & (num_buckets - 1); // power of 2
    }

    /// Returns empty fraction as percentage (0-100)
    fn getEmptyPercent(self: *const Self, tier: usize) usize {
        const used = self.tier_slot_counts[tier];
        const total = self.tier_bucket_counts[tier] * BUCKET_SIZE;
        return 100 - (used * 100 / total);
    }

    fn probeLimit(empty_pct: usize) usize {
        // Approximation of 2 * log2(100/empty_pct)^2
        // For empty_pct=50: ~8, for empty_pct=25: ~32, for empty_pct=10: ~100
        if (empty_pct >= 50) return 8;
        if (empty_pct >= 25) return 32;
        if (empty_pct >= 10) return 64;
        return MAX_PROBES;
    }

    /// Batch insertion logic from the paper
    pub fn insert(self: *Self, key: u64, value: u64) void {
        const h = hash(key);
        const fp = fingerprint(h);
        const i = self.current_batch;

        if (i == 0) {
            self.insertIntoTier(0, h, fp, key, value);
            if (self.getEmptyPercent(0) <= 25) {
                self.current_batch = 1;
            }
            return;
        }

        if (i >= self.num_tiers) {
            self.insertAnyTier(h, fp, key, value);
            return;
        }

        const ai = i - 1;
        const ai_next = i;
        const e1 = self.getEmptyPercent(ai);
        const e2 = self.getEmptyPercent(ai_next);

        // delta = 1% (from paper), so delta/2 = 0.5%
        if (e1 > 0 and e2 > 25) {
            if (!self.tryInsertWithLimit(ai, h, fp, key, value, probeLimit(e1))) {
                self.insertIntoTier(ai_next, h, fp, key, value);
            }
        } else if (e1 == 0) {
            self.insertIntoTier(ai_next, h, fp, key, value);
        } else {
            self.insertIntoTier(ai, h, fp, key, value);
        }

        if (e1 == 0 and e2 <= 25) {
            self.current_batch = @min(self.current_batch + 1, self.num_tiers - 1);
        }
    }

    fn insertIntoTier(self: *Self, tier: usize, h: u64, fp: u8, key: u64, value: u64) void {
        const num_buckets = self.tier_bucket_counts[tier];
        var probe: usize = 0;
        while (probe < num_buckets) : (probe += 1) {
            const bucket_idx = bucketIndex(h, probe, num_buckets);
            const bucket = &self.tiers[tier][bucket_idx];

            if (bucket.findEmpty()) |slot| {
                bucket.insert(slot, key, value, fp);
                self.tier_slot_counts[tier] += 1;
                self.count += 1;
                return;
            }
        }
        // Tier full - fallback
        self.insertAnyTier(h, fp, key, value);
    }

    fn tryInsertWithLimit(self: *Self, tier: usize, h: u64, fp: u8, key: u64, value: u64, limit: usize) bool {
        const num_buckets = self.tier_bucket_counts[tier];
        const max_probe = @min(limit, num_buckets);

        for (0..max_probe) |probe| {
            const bucket_idx = bucketIndex(h, probe, num_buckets);
            const bucket = &self.tiers[tier][bucket_idx];

            if (bucket.findEmpty()) |slot| {
                bucket.insert(slot, key, value, fp);
                self.tier_slot_counts[tier] += 1;
                self.count += 1;
                return true;
            }
        }
        return false;
    }

    fn insertAnyTier(self: *Self, h: u64, fp: u8, key: u64, value: u64) void {
        for (0..MAX_PROBES) |probe| {
            for (0..self.num_tiers) |tier| {
                const num_buckets = self.tier_bucket_counts[tier];
                if (probe >= num_buckets) continue;

                const bucket_idx = bucketIndex(h, probe, num_buckets);
                const bucket = &self.tiers[tier][bucket_idx];

                if (bucket.findEmpty()) |slot| {
                    bucket.insert(slot, key, value, fp);
                    self.tier_slot_counts[tier] += 1;
                    self.count += 1;
                    return;
                }
            }
        }
        // Table is full - silently drop (could return error in production)
    }

    pub fn get(self: *const Self, key: u64) ?u64 {
        const h = hash(key);
        const fp = fingerprint(h);

        for (0..MAX_PROBES) |probe| {
            for (0..self.num_tiers) |tier| {
                const num_buckets = self.tier_bucket_counts[tier];
                if (probe >= num_buckets) continue;

                const bucket_idx = bucketIndex(h, probe, num_buckets);
                const bucket = &self.tiers[tier][bucket_idx];

                if (bucket.findKey(key, fp)) |slot| {
                    return bucket.values[slot];
                }
            }
        }
        return null;
    }

    pub fn getWithProbes(self: *const Self, key: u64) struct { value: ?u64, bucket_probes: usize } {
        const h = hash(key);
        const fp = fingerprint(h);
        var bucket_probes: usize = 0;

        for (0..MAX_PROBES) |probe| {
            for (0..self.num_tiers) |tier| {
                const num_buckets = self.tier_bucket_counts[tier];
                if (probe >= num_buckets) continue;

                bucket_probes += 1;
                const bucket_idx = bucketIndex(h, probe, num_buckets);
                const bucket = &self.tiers[tier][bucket_idx];

                if (bucket.findKey(key, fp)) |slot| {
                    return .{ .value = bucket.values[slot], .bucket_probes = bucket_probes };
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
    const n = 1024;
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
