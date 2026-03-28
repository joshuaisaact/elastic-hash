//! Flat SIMD hash table with separated fingerprint metadata.
//! Same design as string_hybrid_growth.zig but NO tiers -- just one flat
//! array of buckets with linear probing. Purpose: prove the tiered
//! structure adds nothing to average-case performance.
const std = @import("std");
const Wyhash = std.hash.Wyhash;

pub const BUCKET_SIZE = 16;
const MAX_PROBES = 7;
const TOMBSTONE: u8 = 0xFF;

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

pub const FlatHash = struct {
    const Self = @This();

    // Hot path fields
    fingerprints: [][BUCKET_SIZE]u8,
    entries: [][BUCKET_SIZE]StringEntry,
    bucket_mask: usize,
    bucket_shift: u6,
    num_buckets: usize,

    // Management
    count: usize = 0,
    capacity: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Self {
        const capacity = std.math.ceilPowerOfTwo(usize, @max(n, BUCKET_SIZE * 2)) catch n;
        const num_buckets = capacity / BUCKET_SIZE;

        const fingerprints = try allocator.alloc([BUCKET_SIZE]u8, num_buckets);
        const entries = try allocator.alloc([BUCKET_SIZE]StringEntry, num_buckets);

        for (fingerprints) |*bucket_fps| {
            @memset(bucket_fps, 0);
        }

        return .{
            .allocator = allocator,
            .fingerprints = fingerprints,
            .entries = entries,
            .num_buckets = num_buckets,
            .bucket_mask = num_buckets - 1,
            .bucket_shift = @as(u6, @intCast(@min(63, 64 - @ctz(num_buckets)))),
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.fingerprints);
        self.allocator.free(self.entries);
    }

    inline fn hash(key: []const u8) u64 {
        return Wyhash.hash(0, key);
    }

    inline fn fingerprint(h: u64) u8 {
        const fp: u8 = @truncate(h >> 32);
        return if (fp == 0) 1 else if (fp == TOMBSTONE) 0xFE else fp;
    }

    inline fn findKeyInBucket(self: *const Self, bucket_idx: usize, key: []const u8, fp: u8) ?usize {
        var mask = matchFingerprint(&self.fingerprints[bucket_idx], fp);
        if (mask == 0) return null;
        const slot = @ctz(mask);
        if (std.mem.eql(u8, self.entries[bucket_idx][slot].key(), key)) return slot;
        mask &= mask - 1;
        while (mask != 0) {
            const s = @ctz(mask);
            if (std.mem.eql(u8, self.entries[bucket_idx][s].key(), key)) return s;
            mask &= mask - 1;
        }
        return null;
    }

    inline fn findValueInBucket(self: *const Self, bucket_idx: usize, key: []const u8, fp: u8) ?u64 {
        var mask = matchFingerprint(&self.fingerprints[bucket_idx], fp);
        if (mask == 0) return null;
        const slot = @ctz(mask);
        if (std.mem.eql(u8, self.entries[bucket_idx][slot].key(), key)) return self.entries[bucket_idx][slot].value;
        mask &= mask - 1;
        while (mask != 0) {
            const s = @ctz(mask);
            if (std.mem.eql(u8, self.entries[bucket_idx][s].key(), key)) return self.entries[bucket_idx][s].value;
            mask &= mask - 1;
        }
        return null;
    }

    fn needsResize(self: *const Self) bool {
        return self.count * 8 > self.capacity * 7;
    }

    fn resize(self: *Self) void {
        const old_fps = self.fingerprints;
        const old_entries = self.entries;
        const old_num_buckets = self.num_buckets;

        const new_capacity = self.capacity * 2;
        const new_num_buckets = new_capacity / BUCKET_SIZE;

        const new_fps = self.allocator.alloc([BUCKET_SIZE]u8, new_num_buckets) catch @panic("alloc");
        const new_entries = self.allocator.alloc([BUCKET_SIZE]StringEntry, new_num_buckets) catch @panic("alloc");
        for (new_fps) |*b| @memset(b, 0);

        self.fingerprints = new_fps;
        self.entries = new_entries;
        self.num_buckets = new_num_buckets;
        self.bucket_mask = new_num_buckets - 1;
        self.bucket_shift = @as(u6, @intCast(@min(63, 64 - @ctz(new_num_buckets))));
        self.capacity = new_capacity;
        self.count = 0;

        // Rehash all old elements
        for (0..old_num_buckets) |bi| {
            for (0..BUCKET_SIZE) |si| {
                const fp_val = old_fps[bi][si];
                if (fp_val != 0 and fp_val != TOMBSTONE) {
                    const entry = old_entries[bi][si];
                    self.insertNew(entry.key(), entry.value);
                }
            }
        }

        self.allocator.free(old_fps);
        self.allocator.free(old_entries);
    }

    /// Insert a key-value pair, updating the value if the key already exists.
    pub fn insert(self: *Self, key: []const u8, value: u64) void {
        if (self.needsResize()) {
            self.resize();
        }

        const h = hash(key);
        const fp = fingerprint(h);
        const bucket_base = h >> self.bucket_shift;

        var first_empty_bucket: usize = undefined;
        var first_empty_slot: usize = undefined;
        var found_empty = false;

        for (0..MAX_PROBES) |probe| {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & self.bucket_mask;

            // Check for existing key
            if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                self.entries[bucket_idx][slot].value = value;
                return;
            }

            // Track first available slot
            if (!found_empty) {
                const empty_mask = matchEmptyOrTombstone(&self.fingerprints[bucket_idx]);
                if (empty_mask != 0) {
                    first_empty_bucket = bucket_idx;
                    first_empty_slot = @ctz(empty_mask);
                    found_empty = true;
                }
            }

            // Early termination: if bucket has empty slots, key can't be further along
            if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) break;
        }

        if (found_empty) {
            self.fingerprints[first_empty_bucket][first_empty_slot] = fp;
            self.entries[first_empty_bucket][first_empty_slot] = .{
                .key_ptr = key.ptr,
                .key_len = key.len,
                .value = value,
            };
            self.count += 1;
            return;
        }

        // Fallback: scan all probes for any empty/tombstone slot
        self.insertNew(key, value);
    }

    fn insertNew(self: *Self, key: []const u8, value: u64) void {
        const h = hash(key);
        const fp = fingerprint(h);
        const bucket_base = h >> self.bucket_shift;

        for (0..MAX_PROBES) |probe| {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & self.bucket_mask;
            const empty_mask = matchEmptyOrTombstone(&self.fingerprints[bucket_idx]);
            if (empty_mask != 0) {
                const slot = @ctz(empty_mask);
                self.fingerprints[bucket_idx][slot] = fp;
                self.entries[bucket_idx][slot] = .{
                    .key_ptr = key.ptr,
                    .key_len = key.len,
                    .value = value,
                };
                self.count += 1;
                return;
            }
        }
        // Table is too full -- should have resized. Force resize and retry.
        self.resize();
        self.insertNew(key, value);
    }

    pub fn get(self: *const Self, key: []const u8) ?u64 {
        const h = hash(key);
        const fp = fingerprint(h);
        const bucket_base = h >> self.bucket_shift;

        @prefetch(@as([*]const u8, @ptrCast(&self.entries[bucket_base & self.bucket_mask])), .{ .rw = .read, .locality = 3 });

        for (0..MAX_PROBES) |probe| {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & self.bucket_mask;
            if (self.findValueInBucket(bucket_idx, key, fp)) |val| return val;
            if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) {
                @branchHint(.cold);
                return null;
            }
        }

        return null; // No tier overflow -- just not found
    }

    pub fn remove(self: *Self, key: []const u8) bool {
        const h = hash(key);
        const fp = fingerprint(h);
        const bucket_base = h >> self.bucket_shift;

        for (0..MAX_PROBES) |probe| {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & self.bucket_mask;
            if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                self.fingerprints[bucket_idx][slot] = TOMBSTONE;
                self.count -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn len(self: *const Self) usize {
        return self.count;
    }

    pub fn clear(self: *Self) void {
        for (self.fingerprints) |*bucket_fps| {
            @memset(bucket_fps, 0);
        }
        self.count = 0;
    }

    pub const GetOrPutResult = struct {
        value_ptr: *u64,
        found_existing: bool,
    };

    pub fn getOrPut(self: *Self, key: []const u8, default_value: u64) GetOrPutResult {
        if (self.needsResize()) {
            self.resize();
        }

        const h = hash(key);
        const fp = fingerprint(h);
        const bucket_base = h >> self.bucket_shift;

        for (0..MAX_PROBES) |probe| {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & self.bucket_mask;
            if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                return .{
                    .value_ptr = &self.entries[bucket_idx][slot].value,
                    .found_existing = true,
                };
            }
            if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) break;
        }

        self.insertNew(key, default_value);

        // Find the entry we just inserted
        for (0..MAX_PROBES) |probe| {
            const bucket_idx = (bucket_base +% @as(u64, probe)) & self.bucket_mask;
            if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                return .{
                    .value_ptr = &self.entries[bucket_idx][slot].value,
                    .found_existing = false,
                };
            }
        }

        unreachable;
    }

    pub const Entry = struct {
        key: []const u8,
        value: u64,
    };

    pub const Iterator = struct {
        table: *const Self,
        bucket_idx: usize,
        slot_idx: usize,

        pub fn next(self: *Iterator) ?Entry {
            while (self.bucket_idx < self.table.num_buckets) {
                while (self.slot_idx < BUCKET_SIZE) {
                    const si = self.slot_idx;
                    self.slot_idx += 1;
                    const fp = self.table.fingerprints[self.bucket_idx][si];
                    if (fp != 0 and fp != TOMBSTONE) {
                        const e = self.table.entries[self.bucket_idx][si];
                        return .{ .key = e.key(), .value = e.value };
                    }
                }
                self.bucket_idx += 1;
                self.slot_idx = 0;
            }
            return null;
        }
    };

    pub fn iterator(self: *const Self) Iterator {
        return .{ .table = self, .bucket_idx = 0, .slot_idx = 0 };
    }
};

test "flat basic" {
    var map = try FlatHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert("hello", 100);
    map.insert("world", 200);
    map.insert("foo", 300);

    try std.testing.expectEqual(@as(?u64, 100), map.get("hello"));
    try std.testing.expectEqual(@as(?u64, 200), map.get("world"));
    try std.testing.expectEqual(@as(?u64, 300), map.get("foo"));
    try std.testing.expectEqual(@as(?u64, null), map.get("missing"));
}

test "flat high load" {
    var map = try FlatHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    var buf: [900][16]u8 = undefined;
    for (0..900) |i| {
        _ = std.fmt.bufPrint(&buf[i], "{d:0>16}", .{i}) catch unreachable;
        map.insert(&buf[i], i);
    }

    for (0..900) |i| {
        try std.testing.expectEqual(@as(?u64, i), map.get(&buf[i]));
    }
}

test "flat resize" {
    var map = try FlatHash.init(std.testing.allocator, 16);
    defer map.deinit();

    var buf: [64][16]u8 = undefined;
    for (0..64) |i| {
        _ = std.fmt.bufPrint(&buf[i], "{d:0>16}", .{i}) catch unreachable;
        map.insert(&buf[i], i);
    }

    for (0..64) |i| {
        try std.testing.expectEqual(@as(?u64, i), map.get(&buf[i]));
    }
}

test "flat upsert" {
    var map = try FlatHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert("key", 100);
    try std.testing.expectEqual(@as(?u64, 100), map.get("key"));
    map.insert("key", 200);
    try std.testing.expectEqual(@as(?u64, 200), map.get("key"));
}

test "flat delete" {
    var map = try FlatHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert("a", 1);
    map.insert("b", 2);
    try std.testing.expect(map.remove("a"));
    try std.testing.expectEqual(@as(?u64, null), map.get("a"));
    try std.testing.expectEqual(@as(?u64, 2), map.get("b"));
    try std.testing.expect(!map.remove("a")); // already deleted
}
