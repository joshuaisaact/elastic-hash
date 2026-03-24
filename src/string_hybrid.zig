//! String-key elastic hash: SIMD buckets + batch insertion.
//! Adapted from hybrid.zig for []const u8 keys and u64 values.
//! Uses wyhash for string hashing, same tiered architecture.
const std = @import("std");
const math = std.math;
const Wyhash = std.hash.Wyhash;

pub const BUCKET_SIZE = 16;
const MAX_PROBES = 7;
const TOMBSTONE: u8 = 0xFF;

const DELTA: f64 = 0.01;
const DELTA_HALF: f64 = DELTA / 2.0;
const PROBE_CONSTANT: f64 = 16.0;

const FpVector = @Vector(BUCKET_SIZE, u8);

inline fn matchFingerprint(fps: *const [BUCKET_SIZE]u8, fp: u8) u16 {
    const fp_vec: FpVector = fps.*;
    const needle: FpVector = @splat(fp);
    return @bitCast(fp_vec == needle);
}

inline fn matchEmpty(fps: *const [BUCKET_SIZE]u8) u16 {
    const fp_vec: FpVector = fps.*;
    const zeros: FpVector = @splat(0);
    return @bitCast(fp_vec == zeros);
}

inline fn matchEmptyOrTombstone(fps: *const [BUCKET_SIZE]u8) u16 {
    const fp_vec: FpVector = fps.*;
    const zeros: FpVector = @splat(0);
    const tombstones: FpVector = @splat(TOMBSTONE);
    const empty_bits: u16 = @bitCast(fp_vec == zeros);
    const tombstone_bits: u16 = @bitCast(fp_vec == tombstones);
    return empty_bits | tombstone_bits;
}

const StringEntry = struct {
    key_ptr: [*]const u8,
    key_len: usize,
    value: u64,

    fn key(self: StringEntry) []const u8 {
        return self.key_ptr[0..self.key_len];
    }
};

pub const StringElasticHash = struct {
    const Self = @This();

    const GetOverflowFn = *const fn (*const Self, u64, []const u8, u8) ?u64;

    // Hot path fields
    fingerprints: [][BUCKET_SIZE]u8,
    entries: [][BUCKET_SIZE]StringEntry,
    tier0_bucket_mask: usize,
    tier0_bucket_shift: u6,
    get_overflow_fn: GetOverflowFn,

    // Insert/management fields
    tier_starts: []usize,
    tier_bucket_counts: []usize,
    tier_slot_counts: []usize,
    tier0_bucket_count: usize,
    num_tiers: usize,
    total_buckets: usize,
    count: usize = 0,
    current_batch: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Self {
        const capacity = std.math.ceilPowerOfTwo(usize, n) catch n;
        const tier0_buckets = @max(capacity / BUCKET_SIZE, 1);
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
        const entries = try allocator.alloc([BUCKET_SIZE]StringEntry, total_buckets);

        for (fingerprints) |*bucket_fps| {
            @memset(bucket_fps, 0);
        }

        return .{
            .allocator = allocator,
            .fingerprints = fingerprints,
            .entries = entries,
            .tier_starts = tier_starts,
            .tier_bucket_counts = tier_bucket_counts,
            .tier_slot_counts = tier_slot_counts,
            .num_tiers = num_tiers,
            .total_buckets = total_buckets,
            .tier0_bucket_count = tier_bucket_counts[0],
            .tier0_bucket_mask = tier_bucket_counts[0] - 1,
            .tier0_bucket_shift = @as(u6, @intCast(64 - @ctz(tier_bucket_counts[0]))),
            .get_overflow_fn = &defaultGetOverflow,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.fingerprints);
        self.allocator.free(self.entries);
        self.allocator.free(self.tier_starts);
        self.allocator.free(self.tier_bucket_counts);
        self.allocator.free(self.tier_slot_counts);
    }

    inline fn getBucketIdx(self: *const Self, tier: usize, bucket_idx: usize) usize {
        return self.tier_starts[tier] + bucket_idx;
    }

    inline fn hash(key: []const u8) u64 {
        return fastStringHash(key);
    }

    /// Fast string hash inspired by abseil's MixingHashState.
    /// For 9-16 byte keys: read two overlapping u64s, single 128-bit multiply.
    /// For other sizes: fall back to wyhash.
    inline fn fastStringHash(key: []const u8) u64 {
        const kMul: u64 = 0x79d5f9e0de1e8cf5;
        // Precomputed from pi digits, matches abseil's kStaticRandomData
        const kRandomData = [5]u64{
            0x243f6a8885a308d3, 0x13198a2e03707344,
            0xa4093822299f31d0, 0x082efa98ec4e6c89,
            0x452821e638d01377,
        };

        const len = key.len;
        if (len >= 9 and len <= 16) {
            // Abseil's fast path for 9-16 byte keys
            const state = @as(u64, @bitCast(
                @as([8]u8, @as(*const [8]u8, @ptrCast(&kRandomData)).*),
            )) ^ len;
            _ = state;

            const first8 = std.mem.readInt(u64, key[0..8], .little);
            const last8 = std.mem.readInt(u64, key[len - 8 ..][0..8], .little);

            // Mix: 128-bit multiply, XOR high and low
            const seed: u64 = kRandomData[0] ^ len;
            const r = @as(u128, seed ^ first8) *% @as(u128, kMul ^ last8);
            return @as(u64, @truncate(r)) ^ @as(u64, @truncate(r >> 64));
        } else if (len <= 8) {
            // Small keys: read what we can, mix
            if (len >= 4) {
                const a = std.mem.readInt(u32, key[0..4], .little);
                const b = std.mem.readInt(u32, key[len - 4 ..][0..4], .little);
                const combined = @as(u64, a) | (@as(u64, b) << 32);
                const seed: u64 = kRandomData[0] ^ len;
                const r = @as(u128, seed ^ combined) *% @as(u128, kMul);
                return @as(u64, @truncate(r)) ^ @as(u64, @truncate(r >> 64));
            } else if (len > 0) {
                const a: u64 = key[0];
                const b: u64 = key[len / 2];
                const c: u64 = key[len - 1];
                const combined = a | (b << 8) | (c << 16) | (len << 24);
                const r = @as(u128, combined *% kMul) *% @as(u128, kRandomData[0]);
                return @as(u64, @truncate(r)) ^ @as(u64, @truncate(r >> 64));
            } else {
                return kRandomData[0];
            }
        } else {
            // >16 bytes: fall back to wyhash
            return Wyhash.hash(0, key);
        }
    }

    inline fn fingerprint(h: u64) u8 {
        const fp: u8 = @truncate(h >> 32);
        return if (fp == 0) 1 else if (fp == TOMBSTONE) 0xFE else fp;
    }

    inline fn bucketIndex(h: u64, probe: usize, num_buckets: usize) usize {
        const bits: u7 = @intCast(@ctz(num_buckets));
        const shift: u6 = @intCast(@min(64 - bits, 63));
        const base = h >> shift;
        return (base +% @as(u64, probe)) & (num_buckets - 1);
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

    inline fn findKeyInBucket(self: *const Self, bucket_abs_idx: usize, key: []const u8, fp: u8) ?usize {
        var mask = matchFingerprint(&self.fingerprints[bucket_abs_idx], fp);
        if (mask == 0) return null;
        const slot = @ctz(mask);
        if (std.mem.eql(u8, self.entries[bucket_abs_idx][slot].key(), key)) return slot;
        mask &= mask - 1;
        while (mask != 0) {
            const s = @ctz(mask);
            if (std.mem.eql(u8, self.entries[bucket_abs_idx][s].key(), key)) return s;
            mask &= mask - 1;
        }
        return null;
    }

    inline fn findValueInBucket(self: *const Self, bucket_abs_idx: usize, key: []const u8, fp: u8) ?u64 {
        var mask = matchFingerprint(&self.fingerprints[bucket_abs_idx], fp);
        if (mask == 0) return null;
        const slot = @ctz(mask);
        if (std.mem.eql(u8, self.entries[bucket_abs_idx][slot].key(), key)) return self.entries[bucket_abs_idx][slot].value;
        mask &= mask - 1;
        while (mask != 0) {
            const s = @ctz(mask);
            if (std.mem.eql(u8, self.entries[bucket_abs_idx][s].key(), key)) return self.entries[bucket_abs_idx][s].value;
            mask &= mask - 1;
        }
        return null;
    }

    inline fn findEmptyOrTombstoneInBucket(self: *const Self, bucket_abs_idx: usize) ?usize {
        const mask = matchEmptyOrTombstone(&self.fingerprints[bucket_abs_idx]);
        if (mask == 0) return null;
        return @ctz(mask);
    }

    inline fn insertAt(self: *Self, bucket_abs_idx: usize, slot: usize, key: []const u8, value: u64, fp: u8) void {
        self.fingerprints[bucket_abs_idx][slot] = fp;
        self.entries[bucket_abs_idx][slot] = .{ .key_ptr = key.ptr, .key_len = key.len, .value = value };
    }

    pub fn insert(self: *Self, key: []const u8, value: u64) void {
        const h = hash(key);
        const fp = fingerprint(h);
        const i = self.current_batch;

        if (i == 0) {
            self.insertIntoTier(0, h, fp, key, value);
            if (self.getEmptyFraction(0) <= 0.12) {
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

    fn insertIntoTier(self: *Self, tier: usize, h: u64, fp: u8, key: []const u8, value: u64) void {
        const num_buckets = self.tier_bucket_counts[tier];
        const max_probe = @min(num_buckets, MAX_PROBES);
        var probe: usize = 0;
        while (probe < max_probe) : (probe += 1) {
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

    fn tryInsertWithLimit(self: *Self, tier: usize, h: u64, fp: u8, key: []const u8, value: u64, limit: usize) bool {
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

    fn insertAnyTier(self: *Self, h: u64, fp: u8, key: []const u8, value: u64) void {
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

    pub fn get(self: *const Self, key: []const u8) ?u64 {
        const h = hash(key);
        const fp = fingerprint(h);
        const mask = self.tier0_bucket_mask;
        const bucket_base = h >> self.tier0_bucket_shift;

        @prefetch(@as([*]const u8, @ptrCast(&self.entries[bucket_base & mask])), .{ .rw = .read, .locality = 3 });

        for (0..MAX_PROBES) |probe| {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & mask;
            if (self.findValueInBucket(bucket_idx, key, fp)) |val| return val;
        }

        return self.get_overflow_fn(self, h, key, fp);
    }

    fn defaultGetOverflow(self: *const Self, h: u64, key: []const u8, fp: u8) ?u64 {
        if (self.num_tiers <= 1) return null;
        const num_buckets = self.tier_bucket_counts[1];
        const tier_start = self.tier_starts[1];
        for (0..@min(MAX_PROBES, num_buckets)) |probe| {
            const abs_idx = tier_start + bucketIndex(h, probe, num_buckets);
            if (self.findValueInBucket(abs_idx, key, fp)) |val| return val;
            if (matchEmpty(&self.fingerprints[abs_idx]) != 0) return null;
        }
        return null;
    }

    pub fn remove(self: *Self, key: []const u8) bool {
        const h = hash(key);
        const fp = fingerprint(h);
        const mask = self.tier0_bucket_mask;
        const bucket_base = h >> self.tier0_bucket_shift;

        var probe: usize = 0;
        while (probe < MAX_PROBES) : (probe += 1) {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & mask;
            if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                self.fingerprints[bucket_idx][slot] = TOMBSTONE;
                self.count -= 1;
                return true;
            }
        }
        return false;
    }
};

test "string basic" {
    var map = try StringElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert("hello", 100);
    map.insert("world", 200);
    map.insert("foo", 300);

    try std.testing.expectEqual(@as(?u64, 100), map.get("hello"));
    try std.testing.expectEqual(@as(?u64, 200), map.get("world"));
    try std.testing.expectEqual(@as(?u64, 300), map.get("foo"));
    try std.testing.expectEqual(@as(?u64, null), map.get("missing"));
}

test "string high load" {
    var map = try StringElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    var buf: [900][16]u8 = undefined;
    for (0..900) |i| {
        _ = std.fmt.bufPrint(&buf[i], "{d:0>16}", .{i}) catch unreachable;
        map.insert(&buf[i], i);
    }

    for (0..900) |i| {
        try std.testing.expectEqual(@as(?u64, i), map.get(&buf[i]));
    }
    try std.testing.expectEqual(@as(usize, 900), map.count);
}

test "string remove" {
    var map = try StringElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert("a", 1);
    map.insert("b", 2);
    map.insert("c", 3);

    try std.testing.expect(map.remove("b"));
    try std.testing.expectEqual(@as(?u64, null), map.get("b"));
    try std.testing.expectEqual(@as(?u64, 1), map.get("a"));
    try std.testing.expectEqual(@as(?u64, 3), map.get("c"));
}
