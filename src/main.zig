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
                sub_size /= 2;
                if (sub_size == 0) sub_size = 1; // Minimum size of 1
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
            const hash = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(hash);
            const expected_meta = @as(u8, @bitCast(Metadata{ .used = 1, .fingerprint = fingerprint }));

            const num_arrays = self.sub_array_sizes.len;
            const metadata = self.metadata.?;
            const keys = self.keys.?;
            const values = self.values.?;
            const starts = self.sub_array_starts;
            const sizes = self.sub_array_sizes;

            const max_j = @min(sizes[0], 200);

            var j: usize = 1;
            while (j <= max_j) : (j += 1) { // Hardcode max instead of tracking probes
                for (0..num_arrays) |array_idx| {
                    const size = sizes[array_idx];
                    if (j > size) continue;

                    const mixed = hash ^ (@as(u64, array_idx) *% 0x517cc1b727220a95) ^ (@as(u64, j) *% 0x9e3779b97f4a7c15);
                    const mask = size - 1; // size is power of two
                    const idx = starts[array_idx] + (mixed & mask); // & instead of %

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
            const hash = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(hash);
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
            const hash = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(hash);
            const expected_meta = @as(u8, @bitCast(Metadata{ .used = 1, .fingerprint = fingerprint }));

            const num_arrays = self.sub_array_sizes.len;
            const metadata = self.metadata.?;
            const keys = self.keys.?;
            const starts = self.sub_array_starts;
            const sizes = self.sub_array_sizes;

            var j: usize = 1;
            while (j <= 200) : (j += 1) {
                for (0..num_arrays) |array_idx| {
                    const size = sizes[array_idx];
                    if (j > size) continue;

                    const mixed = hash ^ (@as(u64, array_idx) *% 0x517cc1b727220a95) ^ (@as(u64, j) *% 0x9e3779b97f4a7c15);
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
            const hash = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(hash);
            const max_probes = 200;
            var probes: usize = 0;

            var j: usize = 1;
            outer: while (j <= self.capacity) : (j += 1) {
                for (0..self.sub_array_sizes.len) |array_idx| {
                    if (j > self.sub_array_sizes[array_idx]) continue;
                    probes += 1;
                    if (probes > max_probes) break :outer;

                    const idx = self.getProbePositionWithHash(array_idx, hash, j);
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
            const hash = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(hash);
            const max_probes = 200;
            var probes: usize = 0;

            var j: usize = 1;
            outer: while (j <= self.capacity) : (j += 1) {
                for (0..self.sub_array_sizes.len) |array_idx| {
                    if (j > self.sub_array_sizes[array_idx]) continue;
                    probes += 1;
                    if (probes > max_probes) break :outer;

                    const idx = self.getProbePositionWithHash(array_idx, hash, j);
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
            const base_hash = self.ctx.hash(key);
            const mixed = base_hash ^ (@as(u64, array_idx) *% 0x517cc1b727220a95) ^ (@as(u64, probe_num) *% 0x9e3779b97f4a7c15);
            const sub_array_size = self.sub_array_sizes[array_idx];
            const sub_array_start = self.sub_array_starts[array_idx];
            return sub_array_start + (mixed % sub_array_size);
        }

        fn insertIntoSubArray(self: *Self, array_idx: usize, key: K, value: V) void {
            const hash = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(hash);

            var probe_num: usize = 1;
            while (true) : (probe_num += 1) {
                const idx = self.getProbePositionWithHash(array_idx, hash, probe_num);
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

        fn tryInsertWithLimit(self: *Self, array_idx: usize, key: K, value: V, max_probes: usize) bool {
            const hash = self.ctx.hash(key);
            const fingerprint = Metadata.takeFingerprint(hash);

            for (1..max_probes + 1) |probe_num| {
                const idx = self.getProbePositionWithHash(array_idx, hash, probe_num); // Use hash version
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

test "scaling comparison" {
    const allocator = std.testing.allocator;

    std.debug.print("\n", .{});
    std.debug.print("=== Scaling comparison (99% load) ===\n", .{});
    std.debug.print("    n     | Elastic avg/max | Linear avg/max\n", .{});
    std.debug.print("----------|-----------------|----------------\n", .{});

    inline for ([_]usize{ 1000, 10000, 100000 }) |n| {
        const count = n * 99 / 100;

        const ElasticMap = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
        var elastic = try ElasticMap.init(allocator, n);
        defer elastic.deinit();

        for (0..count) |i| {
            elastic.insert(@intCast(i), @intCast(i));
        }

        var elastic_total: usize = 0;
        var elastic_max: usize = 0;
        for (0..count) |i| {
            const result = elastic.getWithProbeCount(@intCast(i));
            elastic_total += result.probes;
            elastic_max = @max(elastic_max, result.probes);
        }

        const slots = try allocator.alloc(?u32, n);
        defer allocator.free(slots);
        @memset(slots, null);

        for (0..count) |i| {
            const key: u32 = @intCast(i);
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key);
            var idx: usize = @truncate(h.final() % n);
            while (slots[idx] != null) {
                idx = (idx + 1) % n;
            }
            slots[idx] = key;
        }

        var linear_total: usize = 0;
        var linear_max: usize = 0;
        for (0..count) |i| {
            const key: u32 = @intCast(i);
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key);
            var idx: usize = @truncate(h.final() % n);
            var probes: usize = 1;
            while (slots[idx] != key) {
                probes += 1;
                idx = (idx + 1) % n;
            }
            linear_total += probes;
            linear_max = @max(linear_max, probes);
        }

        std.debug.print(" {d:>7}  |    {d:>4} / {d:<5} |   {d:>4} / {d:<5}\n", .{
            n,
            elastic_total / count,
            elastic_max,
            linear_total / count,
            linear_max,
        });
    }
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

test "heavy delete/insert cycles" {
    const allocator = std.testing.allocator;

    std.debug.print("\n", .{});
    std.debug.print("=== Delete/Insert cycles (n=1000) ===\n", .{});
    std.debug.print("Cycle | Size | avg probes | max probes\n", .{});
    std.debug.print("------|------|------------|------------\n", .{});

    const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
    var map = try Map.init(allocator, 1000);
    defer map.deinit();

    // Initial fill to 50%
    for (0..500) |i| {
        map.insert(@intCast(i), @intCast(i));
    }

    var next_key: u32 = 500;

    for (0..10) |cycle| {
        // Delete 100 random-ish keys
        var deleted: usize = 0;
        for (0..1000) |i| {
            if (deleted >= 100) break;
            const key: u32 = @intCast((i * 7) % next_key); // pseudo-random
            if (map.remove(key)) {
                deleted += 1;
            }
        }

        // Insert 100 new keys
        for (0..100) |_| {
            map.insert(next_key, next_key);
            next_key += 1;
        }

        // Measure probe counts
        var total: usize = 0;
        var max: usize = 0;
        var counted: usize = 0;
        for (0..next_key) |i| {
            const result = map.getWithProbeCount(@intCast(i));
            if (result.value != null) {
                total += result.probes;
                max = @max(max, result.probes);
                counted += 1;
            }
        }

        std.debug.print("  {d:<3}  | {d:<4} |     {d:<6} |     {d:<6}\n", .{
            cycle,
            map.count(),
            if (counted > 0) total / counted else 0,
            max,
        });
    }
}

test "throughput comparison" {
    const allocator = std.testing.allocator;

    std.debug.print("\n", .{});
    std.debug.print("=== Throughput comparison (1M operations) ===\n", .{});

    const n = 10000;
    const ops = 100000;

    // Elastic hash at 95% load
    {
        const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
        var map = try Map.init(allocator, n);
        defer map.deinit();

        // Fill to 95%
        for (0..n * 95 / 100) |i| {
            map.insert(@intCast(i), @intCast(i));
        }

        var timer = try std.time.Timer.start();

        // Mixed workload: 80% reads, 20% writes
        for (0..ops) |i| {
            const key: u32 = @intCast(i % (n * 95 / 100));
            if (i % 5 == 0) {
                map.put(key, @intCast(i));
            } else {
                _ = map.get(key);
            }
        }

        const elapsed = timer.read();
        std.debug.print("Elastic (95% load): {} ops in {}ms\n", .{ ops, elapsed / 1_000_000 });
    }

    // std.HashMap for comparison
    {
        var map = std.hash_map.AutoHashMap(u32, u32).init(allocator);
        defer map.deinit();

        // Fill to 95% of equivalent capacity
        for (0..n * 95 / 100) |i| {
            try map.put(@intCast(i), @intCast(i));
        }

        var timer = try std.time.Timer.start();

        for (0..ops) |i| {
            const key: u32 = @intCast(i % (n * 95 / 100));
            if (i % 5 == 0) {
                try map.put(key, @intCast(i));
            } else {
                _ = map.get(key);
            }
        }

        const elapsed = timer.read();
        std.debug.print("std.HashMap:        {} ops in {}ms\n", .{ ops, elapsed / 1_000_000 });
    }
}

test "worst case latency" {
    const allocator = std.testing.allocator;

    std.debug.print("\n", .{});
    std.debug.print("=== Worst case latency (single lookup, 99% load) ===\n", .{});

    const n = 10000;
    const fill = n * 99 / 100;

    // Find the slowest lookup in each

    // Elastic
    {
        const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
        var map = try Map.init(allocator, n);
        defer map.deinit();

        for (0..fill) |i| {
            map.insert(@intCast(i), @intCast(i));
        }

        var worst_time: u64 = 0;
        var worst_key: u32 = 0;

        for (0..fill) |i| {
            const key: u32 = @intCast(i);
            var timer = try std.time.Timer.start();
            _ = map.get(key);
            const elapsed = timer.read();
            if (elapsed > worst_time) {
                worst_time = elapsed;
                worst_key = key;
            }
        }

        std.debug.print("Elastic worst lookup: {}ns (key={})\n", .{ worst_time, worst_key });
    }

    // Linear probing
    {
        const slots = try allocator.alloc(?u32, n);
        defer allocator.free(slots);
        @memset(slots, null);

        for (0..fill) |i| {
            const key: u32 = @intCast(i);
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key);
            var idx: usize = @truncate(h.final() % n);
            while (slots[idx] != null) {
                idx = (idx + 1) % n;
            }
            slots[idx] = key;
        }

        var worst_time: u64 = 0;
        var worst_key: u32 = 0;

        for (0..fill) |i| {
            const key: u32 = @intCast(i);
            var timer = try std.time.Timer.start();

            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key);
            var idx: usize = @truncate(h.final() % n);
            while (slots[idx] != key) {
                idx = (idx + 1) % n;
            }

            const elapsed = timer.read();
            if (elapsed > worst_time) {
                worst_time = elapsed;
                worst_key = key;
            }
        }

        std.debug.print("Linear worst lookup:  {}ns (key={})\n", .{ worst_time, worst_key });
    }
}

test "fixed capacity comparison" {
    const allocator = std.testing.allocator;

    std.debug.print("\n", .{});
    std.debug.print("=== Fixed capacity (no resize allowed) ===\n", .{});

    const n = 10000;
    const fill = n * 99 / 100;

    // Elastic - designed for this
    {
        const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
        var map = try Map.init(allocator, n);
        defer map.deinit();

        var timer = try std.time.Timer.start();
        for (0..fill) |i| {
            map.insert(@intCast(i), @intCast(i));
        }
        const insert_time = timer.read();

        timer.reset();
        for (0..fill) |i| {
            _ = map.get(@intCast(i));
        }
        const lookup_time = timer.read();

        std.debug.print("Elastic:  insert={}ms  lookup={}ms\n", .{ insert_time / 1_000_000, lookup_time / 1_000_000 });
    }

    // Linear probing - no resize, just raw array
    {
        const slots_k = try allocator.alloc(?u32, n);
        const slots_v = try allocator.alloc(u32, n);
        defer allocator.free(slots_k);
        defer allocator.free(slots_v);
        @memset(slots_k, null);

        var timer = try std.time.Timer.start();
        for (0..fill) |i| {
            const key: u32 = @intCast(i);
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key);
            var idx: usize = @truncate(h.final() % n);
            while (slots_k[idx] != null) {
                idx = (idx + 1) % n;
            }
            slots_k[idx] = key;
            slots_v[idx] = key;
        }
        const insert_time = timer.read();

        timer.reset();
        for (0..fill) |i| {
            const key: u32 = @intCast(i);
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key);
            var idx: usize = @truncate(h.final() % n);
            while (slots_k[idx] != key) {
                idx = (idx + 1) % n;
            }
            _ = slots_v[idx];
        }
        const lookup_time = timer.read();

        std.debug.print("Linear:   insert={}ms  lookup={}ms\n", .{ insert_time / 1_000_000, lookup_time / 1_000_000 });
    }
}

test "low load factor comparison" {
    const allocator = std.testing.allocator;

    std.debug.print("\n", .{});
    std.debug.print("=== Load factor comparison (n=10000) ===\n", .{});
    std.debug.print("Load%  | Elastic insert/lookup | Linear insert/lookup\n", .{});
    std.debug.print("-------|----------------------|---------------------\n", .{});

    inline for ([_]usize{ 25, 50, 75, 90, 99 }) |load_pct| {
        const n = 10000;
        const fill = n * load_pct / 100;

        // Elastic
        var elastic_insert: u64 = 0;
        var elastic_lookup: u64 = 0;
        {
            const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
            var map = try Map.init(allocator, n);
            defer map.deinit();

            var timer = try std.time.Timer.start();
            for (0..fill) |i| {
                map.insert(@intCast(i), @intCast(i));
            }
            elastic_insert = timer.read() / 1_000_000;

            timer.reset();
            for (0..fill) |i| {
                _ = map.get(@intCast(i));
            }
            elastic_lookup = timer.read() / 1_000_000;
        }

        // Linear probing
        var linear_insert: u64 = 0;
        var linear_lookup: u64 = 0;
        {
            const slots_k = try allocator.alloc(?u32, n);
            const slots_v = try allocator.alloc(u32, n);
            defer allocator.free(slots_k);
            defer allocator.free(slots_v);
            @memset(slots_k, null);

            var timer = try std.time.Timer.start();
            for (0..fill) |i| {
                const key: u32 = @intCast(i);
                var h = std.hash.Wyhash.init(0);
                std.hash.autoHash(&h, key);
                var idx: usize = @truncate(h.final() % n);
                while (slots_k[idx] != null) {
                    idx = (idx + 1) % n;
                }
                slots_k[idx] = key;
                slots_v[idx] = key;
            }
            linear_insert = timer.read() / 1_000_000;

            timer.reset();
            for (0..fill) |i| {
                const key: u32 = @intCast(i);
                var h = std.hash.Wyhash.init(0);
                std.hash.autoHash(&h, key);
                var idx: usize = @truncate(h.final() % n);
                while (slots_k[idx] != key) {
                    idx = (idx + 1) % n;
                }
                _ = slots_v[idx];
            }
            linear_lookup = timer.read() / 1_000_000;
        }

        std.debug.print("  {d:>2}%  |        {d:>2}ms / {d:<2}ms    |       {d:>2}ms / {d:<2}ms\n", .{
            load_pct,
            elastic_insert,
            elastic_lookup,
            linear_insert,
            linear_lookup,
        });
    }
}
