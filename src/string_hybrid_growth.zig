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

pub const StringElasticHashGrowth = struct {
    const Self = @This();

    const GetOverflowFn = *const fn (*const Self, u64, []const u8, u8) ?u64;

    // Hot path fields
    fingerprints: [][BUCKET_SIZE]u8,
    entries: [][BUCKET_SIZE]StringEntry,
    tier0_bucket_mask: usize,
    tier0_bucket_shift: u6,
    get_overflow_fn: GetOverflowFn,
    max_probe_depth: []u8, // per home-bucket max probe depth in tier 0

    // Insert/management fields
    tier_starts: []usize,
    tier_bucket_counts: []usize,
    tier_slot_counts: []usize,
    tier0_bucket_count: usize,
    num_tiers: usize,
    total_buckets: usize,
    count: usize = 0,
    current_batch: usize = 0,
    capacity: usize = 0, // total slot capacity (for growth checks)
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
        const max_probe_depth = try allocator.alloc(u8, tier0_buckets);

        for (fingerprints) |*bucket_fps| {
            @memset(bucket_fps, 0);
        }
        @memset(max_probe_depth, 0);

        return .{
            .allocator = allocator,
            .fingerprints = fingerprints,
            .entries = entries,
            .max_probe_depth = max_probe_depth,
            .tier_starts = tier_starts,
            .tier_bucket_counts = tier_bucket_counts,
            .tier_slot_counts = tier_slot_counts,
            .num_tiers = num_tiers,
            .total_buckets = total_buckets,
            .tier0_bucket_count = tier_bucket_counts[0],
            .tier0_bucket_mask = tier_bucket_counts[0] - 1,
            .tier0_bucket_shift = @as(u6, @intCast(64 - @ctz(tier_bucket_counts[0]))),
            .get_overflow_fn = &defaultGetOverflow,
            .capacity = tier_bucket_counts[0] * BUCKET_SIZE,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.fingerprints);
        self.allocator.free(self.entries);
        self.allocator.free(self.max_probe_depth);
        self.allocator.free(self.tier_starts);
        self.allocator.free(self.tier_bucket_counts);
        self.allocator.free(self.tier_slot_counts);
    }

    inline fn getBucketIdx(self: *const Self, tier: usize, bucket_idx: usize) usize {
        return self.tier_starts[tier] + bucket_idx;
    }

    inline fn hash(key: []const u8) u64 {
        return Wyhash.hash(0, key);
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

    fn needsResize(self: *const Self) bool {
        // Abseil-style: resize when count > capacity * 7/8 (87.5%)
        return self.count * 8 > self.capacity * 7;
    }

    fn resize(self: *Self) void {
        // Save old data
        const old_fps = self.fingerprints;
        const old_entries = self.entries;
        const old_total_buckets = self.total_buckets;
        const old_tier_starts = self.tier_starts;
        const old_tier_bucket_counts = self.tier_bucket_counts;
        const old_tier_slot_counts = self.tier_slot_counts;
        const old_max_probe_depth = self.max_probe_depth;


        // Double capacity
        const new_capacity = self.capacity * 2;
        const new_t0_buckets = @max(new_capacity / BUCKET_SIZE, 1);
        const new_num_tiers = @max(1, std.math.log2_int(usize, new_t0_buckets) + 1);

        const new_tier_starts = self.allocator.alloc(usize, new_num_tiers) catch @panic("alloc");
        const new_tier_bucket_counts = self.allocator.alloc(usize, new_num_tiers) catch @panic("alloc");
        const new_tier_slot_counts = self.allocator.alloc(usize, new_num_tiers) catch @panic("alloc");

        var new_total: usize = 0;
        var bkt = new_t0_buckets;
        for (0..new_num_tiers) |ti| {
            bkt = @max(bkt, 1);
            new_tier_starts[ti] = new_total;
            new_tier_bucket_counts[ti] = bkt;
            new_tier_slot_counts[ti] = 0;
            new_total += bkt;
            bkt /= 2;
        }

        const new_fps = self.allocator.alloc([BUCKET_SIZE]u8, new_total) catch @panic("alloc");
        const new_entries = self.allocator.alloc([BUCKET_SIZE]StringEntry, new_total) catch @panic("alloc");
        const new_depth = self.allocator.alloc(u8, new_t0_buckets) catch @panic("alloc");
        for (new_fps) |*b| @memset(b, 0);
        @memset(new_depth, 0);

        // Swap in new arrays
        self.fingerprints = new_fps;
        self.entries = new_entries;
        self.max_probe_depth = new_depth;
        self.tier_starts = new_tier_starts;
        self.tier_bucket_counts = new_tier_bucket_counts;
        self.tier_slot_counts = new_tier_slot_counts;
        self.num_tiers = new_num_tiers;
        self.total_buckets = new_total;
        self.tier0_bucket_count = new_tier_bucket_counts[0];
        self.tier0_bucket_mask = new_tier_bucket_counts[0] - 1;
        self.tier0_bucket_shift = @as(u6, @intCast(64 - @ctz(new_tier_bucket_counts[0])));
        self.capacity = new_tier_bucket_counts[0] * BUCKET_SIZE;
        self.count = 0;
        self.current_batch = 0;

        // Rehash all old elements (use insertNew — no duplicate check needed,
        // and avoids triggering needsResize during rehash)
        for (0..old_total_buckets) |bi| {
            for (0..BUCKET_SIZE) |si| {
                const fp_val = old_fps[bi][si];
                if (fp_val != 0 and fp_val != TOMBSTONE) {
                    const entry = old_entries[bi][si];
                    const h = hash(entry.key());
                    const fp = fingerprint(h);
                    self.insertNew(h, fp, entry.key(), entry.value);
                }
            }
        }

        // Free old arrays
        self.allocator.free(old_fps);
        self.allocator.free(old_entries);
        self.allocator.free(old_max_probe_depth);
        self.allocator.free(old_tier_starts);
        self.allocator.free(old_tier_bucket_counts);
        self.allocator.free(old_tier_slot_counts);
    }

    /// Find an existing key and update its value. Returns true if found.
    fn updateExisting(self: *Self, h: u64, key: []const u8, value: u64, fp: u8) bool {
        const mask = self.tier0_bucket_mask;
        const bucket_base = h >> self.tier0_bucket_shift;

        // Search tier 0
        for (0..MAX_PROBES) |probe| {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & mask;
            if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                self.entries[bucket_idx][slot].value = value;
                return true;
            }
            if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) break;
        }

        // Search tier 1
        if (self.num_tiers > 1) {
            const num_buckets = self.tier_bucket_counts[1];
            const tier_start = self.tier_starts[1];
            for (0..@min(MAX_PROBES, num_buckets)) |probe| {
                const abs_idx = tier_start + bucketIndex(h, probe, num_buckets);
                if (self.findKeyInBucket(abs_idx, key, fp)) |slot| {
                    self.entries[abs_idx][slot].value = value;
                    return true;
                }
                if (matchEmpty(&self.fingerprints[abs_idx]) != 0) break;
            }
        }

        return false;
    }

    /// Insert a key-value pair, updating the value if the key already exists.
    pub fn insert(self: *Self, key: []const u8, value: u64) void {
        if (self.needsResize()) {
            self.resize();
        }

        const h = hash(key);
        const fp = fingerprint(h);

        // Check for existing key first
        if (self.updateExisting(h, key, value, fp)) return;

        self.insertNew(h, fp, key, value);
    }

    /// Internal: insert without duplicate check (used by resize rehash).
    fn insertNew(self: *Self, h: u64, fp: u8, key: []const u8, value: u64) void {
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
        const home_bucket = if (tier == 0) bucketIndex(h, 0, num_buckets) else 0;
        var probe: usize = 0;
        while (probe < max_probe) : (probe += 1) {
            const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
            const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);
            if (self.findEmptyOrTombstoneInBucket(abs_bucket_idx)) |slot| {
                self.insertAt(abs_bucket_idx, slot, key, value, fp);
                self.tier_slot_counts[tier] += 1;
                self.count += 1;
                if (tier == 0) {
                    const depth: u8 = @intCast(probe);
                    if (depth > self.max_probe_depth[home_bucket]) {
                        self.max_probe_depth[home_bucket] = depth;
                    }
                }
                return;
            }
        }
        self.insertAnyTier(h, fp, key, value);
    }

    fn tryInsertWithLimit(self: *Self, tier: usize, h: u64, fp: u8, key: []const u8, value: u64, limit: usize) bool {
        const num_buckets = self.tier_bucket_counts[tier];
        const max_probe = @min(limit, num_buckets);
        const home_bucket = if (tier == 0) bucketIndex(h, 0, num_buckets) else 0;
        for (0..max_probe) |probe| {
            const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
            const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);
            if (self.findEmptyOrTombstoneInBucket(abs_bucket_idx)) |slot| {
                self.insertAt(abs_bucket_idx, slot, key, value, fp);
                self.tier_slot_counts[tier] += 1;
                self.count += 1;
                if (tier == 0) {
                    const depth: u8 = @intCast(probe);
                    if (depth > self.max_probe_depth[home_bucket]) {
                        self.max_probe_depth[home_bucket] = depth;
                    }
                }
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
            if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) {
                @branchHint(.cold);
                return null;
            }
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
    var map = try StringElasticHashGrowth.init(std.testing.allocator, 1024);
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
    var map = try StringElasticHashGrowth.init(std.testing.allocator, 1024);
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
    var map = try StringElasticHashGrowth.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert("a", 1);
    map.insert("b", 2);
    map.insert("c", 3);

    try std.testing.expect(map.remove("b"));
    try std.testing.expectEqual(@as(?u64, null), map.get("b"));
    try std.testing.expectEqual(@as(?u64, 1), map.get("a"));
    try std.testing.expectEqual(@as(?u64, 3), map.get("c"));
}

test "duplicate key updates value" {
    var map = try StringElasticHashGrowth.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert("key", 100);
    try std.testing.expectEqual(@as(?u64, 100), map.get("key"));
    try std.testing.expectEqual(@as(usize, 1), map.count);

    // Insert same key with different value — should update, not create duplicate
    map.insert("key", 200);
    try std.testing.expectEqual(@as(?u64, 200), map.get("key"));
    try std.testing.expectEqual(@as(usize, 1), map.count);

    // Third update
    map.insert("key", 300);
    try std.testing.expectEqual(@as(?u64, 300), map.get("key"));
    try std.testing.expectEqual(@as(usize, 1), map.count);
}

test "duplicate keys at scale" {
    var map = try StringElasticHashGrowth.init(std.testing.allocator, 1024);
    defer map.deinit();

    // Insert 500 unique keys
    var buf: [500][16]u8 = undefined;
    for (0..500) |i| {
        _ = std.fmt.bufPrint(&buf[i], "{d:0>16}", .{i}) catch unreachable;
        map.insert(&buf[i], i);
    }
    try std.testing.expectEqual(@as(usize, 500), map.count);

    // Re-insert all 500 with new values — count should stay 500
    for (0..500) |i| {
        map.insert(&buf[i], i + 1000);
    }
    try std.testing.expectEqual(@as(usize, 500), map.count);

    // Verify updated values
    for (0..500) |i| {
        try std.testing.expectEqual(@as(?u64, i + 1000), map.get(&buf[i]));
    }
}

test "resize triggers and preserves data" {
    // Start with tiny capacity so resize actually triggers
    var map = try StringElasticHashGrowth.init(std.testing.allocator, 16);
    defer map.deinit();

    // Insert enough to trigger resize (capacity=16, threshold=87.5% = 14 elements)
    var buf: [64][16]u8 = undefined;
    for (0..64) |i| {
        _ = std.fmt.bufPrint(&buf[i], "{d:0>16}", .{i}) catch unreachable;
        map.insert(&buf[i], i);
    }

    // Verify all 64 elements survived resize(s)
    try std.testing.expectEqual(@as(usize, 64), map.count);
    for (0..64) |i| {
        const val = map.get(&buf[i]);
        try std.testing.expect(val != null);
        try std.testing.expectEqual(@as(u64, i), val.?);
    }

    // Verify miss keys still return null
    var miss_buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&miss_buf, "{d:0>16}", .{@as(usize, 9999)}) catch unreachable;
    try std.testing.expectEqual(@as(?u64, null), map.get(&miss_buf));
}

test "resize with duplicates" {
    var map = try StringElasticHashGrowth.init(std.testing.allocator, 16);
    defer map.deinit();

    var buf: [32][16]u8 = undefined;
    for (0..32) |i| {
        _ = std.fmt.bufPrint(&buf[i], "{d:0>16}", .{i}) catch unreachable;
        map.insert(&buf[i], i);
    }

    // Update all values — this should not increase count
    for (0..32) |i| {
        map.insert(&buf[i], i + 500);
    }
    try std.testing.expectEqual(@as(usize, 32), map.count);

    // Verify updated values
    for (0..32) |i| {
        try std.testing.expectEqual(@as(?u64, i + 500), map.get(&buf[i]));
    }
}

test "resize then delete then insert" {
    var map = try StringElasticHashGrowth.init(std.testing.allocator, 16);
    defer map.deinit();

    var buf: [64][16]u8 = undefined;
    for (0..64) |i| {
        _ = std.fmt.bufPrint(&buf[i], "{d:0>16}", .{i}) catch unreachable;
        map.insert(&buf[i], i);
    }
    try std.testing.expectEqual(@as(usize, 64), map.count);

    // Delete half
    for (0..32) |i| {
        try std.testing.expect(map.remove(&buf[i]));
    }
    try std.testing.expectEqual(@as(usize, 32), map.count);

    // Verify deleted keys return null
    for (0..32) |i| {
        try std.testing.expectEqual(@as(?u64, null), map.get(&buf[i]));
    }

    // Verify surviving keys
    for (32..64) |i| {
        try std.testing.expectEqual(@as(?u64, i), map.get(&buf[i]));
    }

    // Re-insert deleted keys with new values
    for (0..32) |i| {
        map.insert(&buf[i], i + 2000);
    }
    try std.testing.expectEqual(@as(usize, 64), map.count);

    for (0..32) |i| {
        try std.testing.expectEqual(@as(?u64, i + 2000), map.get(&buf[i]));
    }
}
