const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn ElasticHash(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime delta_inverse: u32,
) type {
    return struct {
        const Self = @This();
        pub const Hash = u64;

        const max_probes = 200;

        const Metadata = packed struct {
            const FingerPrint = u7;

            fingerprint: FingerPrint = 0,
            used: u1 = 0,

            pub fn isUsed(self: Metadata) bool {
                return self.used == 1;
            }

            pub fn isFree(self: Metadata) bool {
                return @as(u8, @bitCast(self)) == 0;
            }

            pub fn fill(self: *Metadata, fp: FingerPrint) void {
                self.used = 1;
                self.fingerprint = fp;
            }

            pub fn takeFingerprint(hash: Hash) FingerPrint {
                return @truncate(hash >> (64 - 7));
            }
        };

        allocator: Allocator,
        ctx: Context,
        keys: ?[*]K = null,
        values: ?[*]V = null,
        metadata: ?[*]Metadata = null,
        sub_array_starts: []usize = &[_]usize{},
        sub_array_sizes: []usize = &[_]usize{},
        sub_array_counts: []usize = &[_]usize{},
        current_batch: usize = 0,
        capacity: usize = 0,
        size: usize = 0,

        pub fn init(allocator: Allocator, n: usize) !Self {
            if (@sizeOf(Context) != 0) {
                @compileError("Context must be specified!");
            }

            // Round up to power of two
            const capacity = std.math.ceilPowerOfTwo(usize, n) catch n;
            const num_sub_arrays = std.math.log2_int(usize, capacity);

            const starts = try allocator.alloc(usize, num_sub_arrays);
            const sizes = try allocator.alloc(usize, num_sub_arrays);
            const counts = try allocator.alloc(usize, num_sub_arrays);

            var offset: usize = 0;
            var sub_size = capacity / 2; // Start with half
            for (0..num_sub_arrays) |i| {
                starts[i] = offset;
                sizes[i] = sub_size;
                counts[i] = 0;
                offset += sub_size;
                sub_size = @max(sub_size / 2, 1);
            }

            const keys = try allocator.alloc(K, capacity);
            const values = try allocator.alloc(V, capacity);
            const metadata = try allocator.alloc(Metadata, capacity);
            @memset(metadata, Metadata{});

            return .{
                .allocator = allocator,
                .ctx = undefined,
                .keys = keys.ptr,
                .values = values.ptr,
                .metadata = metadata.ptr,
                .sub_array_starts = starts,
                .sub_array_sizes = sizes,
                .sub_array_counts = counts,
                .current_batch = 0,
                .capacity = capacity,
                .size = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.keys) |keys| {
                self.allocator.free(keys[0..self.capacity]);
            }
            if (self.values) |values| {
                self.allocator.free(values[0..self.capacity]);
            }
            if (self.metadata) |metadata| {
                self.allocator.free(metadata[0..self.capacity]);
            }
            self.allocator.free(self.sub_array_starts);
            self.allocator.free(self.sub_array_sizes);
            self.allocator.free(self.sub_array_counts);
        }

        pub fn insert(self: *Self, key: K, value: V) void {
            const i = self.current_batch;

            if (i == 0) {
                self.insertIntoSubArray(0, key, value);
                if (self.getEmptyFraction(0) <= 0.25) {
                    self.current_batch = 1;
                }
                return;
            }

            const ai = i - 1;
            const ai_next = i;
            const e1 = self.getEmptyFraction(ai);
            const e2 = self.getEmptyFraction(ai_next);
            const delta = 1.0 / @as(f64, @floatFromInt(delta_inverse));

            if (e1 > delta / 2.0 and e2 > 0.25) {
                if (!self.tryInsertWithLimit(ai, key, value, self.probeLimit(e1))) {
                    self.insertIntoSubArray(ai_next, key, value);
                }
            } else if (e1 <= delta / 2.0) {
                self.insertIntoSubArray(ai_next, key, value);
            } else {
                self.insertIntoSubArray(ai, key, value);
            }

            if (e1 <= delta / 2.0 and e2 <= 0.25) {
                self.current_batch += 1;
            }
        }

        pub fn get(self: *Self, key: K) ?V {
            const h = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(h);
            const expected_meta = @as(u8, @bitCast(Metadata{ .used = 1, .fingerprint = fingerprint }));

            const num_arrays = self.sub_array_sizes.len;
            const metadata = self.metadata.?;
            const keys = self.keys.?;
            const values = self.values.?;
            const starts = self.sub_array_starts;
            const sizes = self.sub_array_sizes;

            const max_j = @min(sizes[0], max_probes);

            var j: usize = 1;
            while (j <= max_j) : (j += 1) {
                for (0..num_arrays) |array_idx| {
                    const size = sizes[array_idx];
                    if (j > size) continue;

                    const mixed = h ^ (@as(u64, array_idx) *% 0x517cc1b727220a95) ^ (@as(u64, j) *% 0x9e3779b97f4a7c15);
                    const mask = size - 1;
                    const idx = starts[array_idx] + (mixed & mask);

                    if (@as(u8, @bitCast(metadata[idx])) == expected_meta) {
                        if (self.ctx.eql(keys[idx], key)) {
                            return values[idx];
                        }
                    }
                }
            }
            return null;
        }

        fn getProbePositionWithHash(self: *Self, array_idx: usize, hash: u64, probe_num: usize) usize {
            const mixed = hash ^ (@as(u64, array_idx) *% 0x517cc1b727220a95) ^ (@as(u64, probe_num) *% 0x9e3779b97f4a7c15);
            const size = self.sub_array_sizes[array_idx];
            return self.sub_array_starts[array_idx] + (mixed & (size - 1)); // & instead of %
        }

        pub fn getWithProbeCount(self: *Self, key: K) struct { value: ?V, probes: usize } {
            const h = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(h);
            var probes: usize = 0;

            const num_arrays = self.sub_array_sizes.len;

            const ProbeCandidate = struct {
                phi_value: usize,
                array_idx: usize,
                probe_num: usize,

                fn lessThan(_: void, a: @This(), b: @This()) std.math.Order {
                    return std.math.order(a.phi_value, b.phi_value);
                }
            };

            var heap = std.PriorityQueue(ProbeCandidate, void, ProbeCandidate.lessThan).init(self.allocator, {});
            defer heap.deinit();

            for (0..num_arrays) |array_idx| {
                heap.add(.{
                    .phi_value = phi(array_idx + 1, 1),
                    .array_idx = array_idx,
                    .probe_num = 1,
                }) catch continue;
            }

            while (heap.removeOrNull()) |candidate| {
                const array_idx = candidate.array_idx;
                const probe_num = candidate.probe_num;

                if (probe_num > self.sub_array_sizes[array_idx]) continue;

                probes += 1;
                const idx = self.getProbePosition(array_idx, key, probe_num);
                const meta = self.metadata.?[idx];

                if (meta.isUsed() and meta.fingerprint == fingerprint) {
                    if (self.ctx.eql(self.keys.?[idx], key)) {
                        return .{ .value = self.values.?[idx], .probes = probes };
                    }
                }

                const next_probe = probe_num + 1;
                if (next_probe <= self.sub_array_sizes[array_idx]) {
                    heap.add(.{
                        .phi_value = phi(array_idx + 1, next_probe),
                        .array_idx = array_idx,
                        .probe_num = next_probe,
                    }) catch continue;
                }
            }

            return .{ .value = null, .probes = probes };
        }

        pub fn count(self: *const Self) usize {
            return self.size;
        }

        pub fn contains(self: *Self, key: K) bool {
            return self.get(key) != null;
        }

        pub fn put(self: *Self, key: K, value: V) void {
            const h = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(h);
            const expected_meta = @as(u8, @bitCast(Metadata{ .used = 1, .fingerprint = fingerprint }));

            const num_arrays = self.sub_array_sizes.len;
            const metadata = self.metadata.?;
            const keys = self.keys.?;
            const starts = self.sub_array_starts;
            const sizes = self.sub_array_sizes;

            var j: usize = 1;
            while (j <= max_probes) : (j += 1) {
                for (0..num_arrays) |array_idx| {
                    const size = sizes[array_idx];
                    if (j > size) continue;

                    const mixed = h ^ (@as(u64, array_idx) *% 0x517cc1b727220a95) ^ (@as(u64, j) *% 0x9e3779b97f4a7c15);
                    const idx = starts[array_idx] + (mixed & (size - 1));

                    if (@as(u8, @bitCast(metadata[idx])) == expected_meta) {
                        if (self.ctx.eql(keys[idx], key)) {
                            self.values.?[idx] = value;
                            return;
                        }
                    }
                }
            }

            self.insert(key, value);
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            const h = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(h);
            var probes: usize = 0;

            var j: usize = 1;
            outer: while (j <= self.capacity) : (j += 1) {
                for (0..self.sub_array_sizes.len) |array_idx| {
                    if (j > self.sub_array_sizes[array_idx]) continue;
                    probes += 1;
                    if (probes > max_probes) break :outer;

                    const idx = self.getProbePositionWithHash(array_idx, h, j);
                    const meta = self.metadata.?[idx];

                    if (meta.isUsed() and meta.fingerprint == fingerprint) {
                        if (self.ctx.eql(self.keys.?[idx], key)) {
                            return &self.values.?[idx];
                        }
                    }
                }
            }

            return null;
        }

        pub fn remove(self: *Self, key: K) bool {
            const h = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(h);
            var probes: usize = 0;

            var j: usize = 1;
            outer: while (j <= self.capacity) : (j += 1) {
                for (0..self.sub_array_sizes.len) |array_idx| {
                    if (j > self.sub_array_sizes[array_idx]) continue;
                    probes += 1;
                    if (probes > max_probes) break :outer;

                    const idx = self.getProbePositionWithHash(array_idx, h, j);
                    const meta = self.metadata.?[idx];

                    if (meta.isUsed() and meta.fingerprint == fingerprint) {
                        if (self.ctx.eql(self.keys.?[idx], key)) {
                            self.metadata.?[idx] = Metadata{};
                            self.keys.?[idx] = undefined;
                            self.values.?[idx] = undefined;
                            self.size -= 1;
                            self.sub_array_counts[array_idx] -= 1;
                            return true;
                        }
                    }
                }
            }

            return false;
        }

        fn getEmptyFraction(self: *Self, i: usize) f64 {
            const number = self.sub_array_counts[i];
            const size = self.sub_array_sizes[i];
            return 1.0 - (@as(f64, @floatFromInt(number)) / @as(f64, @floatFromInt(size)));
        }

        fn probeLimit(_: *Self, epsilon: f64) usize {
            const c: f64 = 2.0;
            const delta: f64 = 1.0 / @as(f64, @floatFromInt(delta_inverse));
            const log_inv_epsilon = @log2(1.0 / epsilon);
            const log_inv_delta = @log2(1.0 / delta);
            const result = c * @min(log_inv_epsilon * log_inv_epsilon, log_inv_delta);
            return @intFromFloat(@max(1.0, result));
        }

        fn getProbePosition(self: *Self, array_idx: usize, key: K, probe_num: usize) usize {
            const h = self.ctx.hash(key);
            const mixed = h ^ (@as(u64, array_idx) *% 0x517cc1b727220a95) ^ (@as(u64, probe_num) *% 0x9e3779b97f4a7c15);
            const size = self.sub_array_sizes[array_idx];
            return self.sub_array_starts[array_idx] + (mixed & (size - 1));
        }

        fn insertIntoSubArray(self: *Self, array_idx: usize, key: K, value: V) void {
            const h = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(h);

            var probe_num: usize = 1;
            while (true) : (probe_num += 1) {
                const idx = self.getProbePositionWithHash(array_idx, h, probe_num);
                if (self.metadata.?[idx].isFree()) {
                    self.metadata.?[idx].fill(fingerprint);
                    self.keys.?[idx] = key;
                    self.values.?[idx] = value;
                    self.sub_array_counts[array_idx] += 1;
                    self.size += 1;
                    return;
                }
            }
        }

        fn tryInsertWithLimit(self: *Self, array_idx: usize, key: K, value: V, probe_limit: usize) bool {
            const h = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(h);

            for (1..probe_limit + 1) |probe_num| {
                const idx = self.getProbePositionWithHash(array_idx, h, probe_num);
                if (self.metadata.?[idx].isFree()) {
                    self.metadata.?[idx].fill(fingerprint);
                    self.keys.?[idx] = key;
                    self.values.?[idx] = value;
                    self.sub_array_counts[array_idx] += 1;
                    self.size += 1;
                    return true;
                }
            }
            return false;
        }
    };
}

fn phi(i: usize, j: usize) usize {
    const j_bits = if (j == 0) 1 else std.math.log2_int(usize, j) + 1;

    var result: usize = 0;
    var pos: u6 = 0;

    for (0..j_bits) |b| {
        const j_bit = (j >> @intCast(b)) & 1;
        result |= (@as(usize, 1) << pos);
        pos += 1;
        result |= (j_bit << pos);
        pos += 1;
    }

    pos += 1;
    result |= (i << pos);

    return result;
}

pub fn main() !void {
    std.debug.print("ElasticHash module loaded.\n", .{});
}

test "basic insert and get" {
    const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
    var map = try Map.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert(1, 100);
    map.insert(2, 200);
    map.insert(3, 300);

    try std.testing.expectEqual(@as(?u32, 100), map.get(1));
    try std.testing.expectEqual(@as(?u32, 200), map.get(2));
    try std.testing.expectEqual(@as(?u32, 300), map.get(3));
    try std.testing.expectEqual(@as(?u32, null), map.get(999));
}

test "high load factor" {
    const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
    var map = try Map.init(std.testing.allocator, 1024);
    defer map.deinit();

    for (0..900) |i| {
        map.insert(@intCast(i), @intCast(i));
    }

    for (0..900) |i| {
        try std.testing.expectEqual(@as(?u32, @intCast(i)), map.get(@intCast(i)));
    }

    try std.testing.expectEqual(@as(usize, 900), map.size);
}

test "remove" {
    const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
    var map = try Map.init(std.testing.allocator, 1024);
    defer map.deinit();

    // Insert values
    for (0..100) |i| {
        map.insert(@intCast(i), @intCast(i * 10));
    }
    try std.testing.expectEqual(@as(usize, 100), map.count());

    // Remove some
    try std.testing.expect(map.remove(50));
    try std.testing.expect(map.remove(25));
    try std.testing.expect(map.remove(75));
    try std.testing.expectEqual(@as(usize, 97), map.count());

    // Verify removed
    try std.testing.expectEqual(@as(?u32, null), map.get(50));
    try std.testing.expectEqual(@as(?u32, null), map.get(25));
    try std.testing.expectEqual(@as(?u32, null), map.get(75));

    // Verify others still present
    try std.testing.expectEqual(@as(?u32, 0), map.get(0));
    try std.testing.expectEqual(@as(?u32, 990), map.get(99));
    try std.testing.expectEqual(@as(?u32, 510), map.get(51));

    // Remove non-existent
    try std.testing.expect(!map.remove(50)); // already removed
    try std.testing.expect(!map.remove(999)); // never existed
}

test "put updates existing" {
    const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
    var map = try Map.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.put(1, 100);
    try std.testing.expectEqual(@as(?u32, 100), map.get(1));

    map.put(1, 200); // update
    try std.testing.expectEqual(@as(?u32, 200), map.get(1));
    try std.testing.expectEqual(@as(usize, 1), map.count()); // still just 1 entry
}

test "remove then insert" {
    const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
    var map = try Map.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert(1, 100);
    try std.testing.expect(map.remove(1));
    try std.testing.expectEqual(@as(?u32, null), map.get(1));

    map.insert(1, 200);
    try std.testing.expectEqual(@as(?u32, 200), map.get(1));
}
