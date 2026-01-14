//! A minimal elastic hash implementation for learning.
//! For explanation of the algorithm: www.joshtuddenham.dev/blog/hashmaps
//! For the optimized version: main.zig
const std = @import("std");

pub const SimpleElasticHash = struct {
    const Self = @This();
    const empty_key: u64 = std.math.maxInt(u64);

    allocator: std.mem.Allocator,
    keys: []u64,
    values: []u64,
    starts: []usize, // where each tier begins in the array
    sizes: []usize, // size of each tier
    capacity: usize,
    num_tiers: usize,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Self {
        // Round up to power of two
        const capacity = std.math.ceilPowerOfTwo(usize, n) catch n;
        const num_tiers = std.math.log2_int(usize, capacity);

        const starts = try allocator.alloc(usize, num_tiers);
        const sizes = try allocator.alloc(usize, num_tiers);

        // Split capacity into tiers: 512 + 256 + 128 + ... + 1
        var offset: usize = 0;
        var size = capacity / 2;
        for (0..num_tiers) |i| {
            starts[i] = offset;
            sizes[i] = size;
            offset += size;
            size = @max(size / 2, 1);
        }

        const keys = try allocator.alloc(u64, capacity);
        const values = try allocator.alloc(u64, capacity);
        @memset(keys, empty_key);

        return .{
            .allocator = allocator,
            .keys = keys,
            .values = values,
            .starts = starts,
            .sizes = sizes,
            .capacity = capacity,
            .num_tiers = num_tiers,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.keys);
        self.allocator.free(self.values);
        self.allocator.free(self.starts);
        self.allocator.free(self.sizes);
    }

    fn hash(key: u64) u64 {
        // Simple hash using wyhash
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHash(&h, key);
        return h.final();
    }

    fn slotIndex(self: *Self, tier: usize, h: u64, probe: usize) usize {
        // Mix hash with probe number to spread probes
        const mixed = h +% probe *% 0x9e3779b97f4a7c15;
        return self.starts[tier] + (mixed % self.sizes[tier]);
    }

    pub fn insert(self: *Self, key: u64, value: u64) void {
        const h = hash(key);
        const max_probes = self.sizes[0];

        // Same interleaved pattern as lookup:
        // check all tiers at probe 1, then all tiers at probe 2, etc.
        for (1..max_probes + 1) |probe| {
            for (0..self.num_tiers) |tier| {
                if (probe > self.sizes[tier]) continue;

                const idx = self.slotIndex(tier, h, probe);
                if (self.keys[idx] == empty_key) {
                    self.keys[idx] = key;
                    self.values[idx] = value;
                    self.count += 1;
                    return;
                }
            }
        }
    }

    pub fn get(self: *Self, key: u64) ?u64 {
        const h = hash(key);
        const max_probes = self.sizes[0];

        // Outer loop: probe offset (1, 2, 3...)
        // Inner loop: ALL tiers at this offset before incrementing
        for (1..max_probes + 1) |probe| {
            for (0..self.num_tiers) |tier| {
                if (probe > self.sizes[tier]) continue;

                const idx = self.slotIndex(tier, h, probe);
                if (self.keys[idx] == key) {
                    return self.values[idx];
                }
            }
        }
        return null;
    }

    /// Same as get() but also returns probe count for benchmarking
    pub fn getWithProbes(self: *Self, key: u64) struct { value: ?u64, probes: usize } {
        const h = hash(key);
        const max_probes = self.sizes[0];
        var probes: usize = 0;

        for (1..max_probes + 1) |probe| {
            for (0..self.num_tiers) |tier| {
                if (probe > self.sizes[tier]) continue;

                probes += 1;
                const idx = self.slotIndex(tier, h, probe);
                if (self.keys[idx] == key) {
                    return .{ .value = self.values[idx], .probes = probes };
                }
            }
        }
        return .{ .value = null, .probes = probes };
    }
};

// --- Tests ---

test "basic insert and get" {
    var map = try SimpleElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    map.insert(1, 100);
    map.insert(2, 200);
    map.insert(3, 300);

    try std.testing.expectEqual(@as(?u64, 100), map.get(1));
    try std.testing.expectEqual(@as(?u64, 200), map.get(2));
    try std.testing.expectEqual(@as(?u64, 300), map.get(3));
    try std.testing.expectEqual(@as(?u64, null), map.get(999));
}

test "high load factor" {
    var map = try SimpleElasticHash.init(std.testing.allocator, 1024);
    defer map.deinit();

    for (0..900) |i| {
        map.insert(i, i * 10);
    }

    for (0..900) |i| {
        try std.testing.expectEqual(@as(?u64, i * 10), map.get(i));
    }
}

test "probe count comparison" {
    const allocator = std.testing.allocator;

    std.debug.print("\n", .{});
    std.debug.print("=== Simple elastic vs linear probing (99% load) ===\n", .{});
    std.debug.print("    n     | Elastic max | Linear max\n", .{});
    std.debug.print("----------|-------------|------------\n", .{});

    inline for ([_]usize{ 1000, 10000 }) |n| {
        const fill = n * 99 / 100;

        // Elastic
        var elastic = try SimpleElasticHash.init(allocator, n);
        defer elastic.deinit();

        for (0..fill) |i| {
            elastic.insert(i, i);
        }

        var elastic_max: usize = 0;
        for (0..fill) |i| {
            const result = elastic.getWithProbes(i);
            elastic_max = @max(elastic_max, result.probes);
        }

        // Linear probing baseline
        const slots = try allocator.alloc(?u64, n);
        defer allocator.free(slots);
        @memset(slots, null);

        for (0..fill) |i| {
            var idx = SimpleElasticHash.hash(i) % n;
            while (slots[idx] != null) {
                idx = (idx + 1) % n;
            }
            slots[idx] = i;
        }

        var linear_max: usize = 0;
        for (0..fill) |i| {
            var idx = SimpleElasticHash.hash(i) % n;
            var probes: usize = 1;
            while (slots[idx] != i) {
                probes += 1;
                idx = (idx + 1) % n;
            }
            linear_max = @max(linear_max, probes);
        }

        std.debug.print(" {d:>7}  |     {d:<5}   |    {d:<5}\n", .{ n, elastic_max, linear_max });
    }
}
