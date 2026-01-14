//! Benchmarks comparing elastic hashing vs linear probing.
//! Run with: zig build bench
//!
//! Probe count comparisons use naive linear probing (not std.HashMap) because:
//! 1. std.HashMap doesn't expose probe counts
//! 2. std.HashMap enforces max 80% load and auto-resizes (see hash_map.zig:118)
//!
//! The point is to show why elastic hashing helps in fixed-capacity scenarios
//! where you can't resize and must operate at high load factors.
const std = @import("std");
const ElasticHash = @import("main.zig").ElasticHash;
const SimpleElasticHash = @import("simple.zig").SimpleElasticHash;
const HybridElasticHash = @import("hybrid.zig").HybridElasticHash;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    try scalingComparison(allocator);
    try simpleComparison(allocator);
    try throughputComparison(allocator);
    try worstCaseLatency(allocator);
    try fixedCapacityComparison(allocator);
    try loadFactorComparison(allocator);
    try stdHashMapComparison(allocator);
    try hybridComparison(allocator);
}

fn scalingComparison(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Scaling comparison (99% load) ===\n", .{});
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

fn simpleComparison(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Simple elastic vs linear probing (99% load) ===\n", .{});
    std.debug.print("    n     | Elastic max | Linear max\n", .{});
    std.debug.print("----------|-------------|------------\n", .{});

    inline for ([_]usize{ 1000, 10000 }) |n| {
        const fill = n * 99 / 100;

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

fn throughputComparison(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Throughput comparison (100k operations) ===\n", .{});

    const n = 10000;
    const ops = 100000;

    // Elastic hash at 95% load
    {
        const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
        var map = try Map.init(allocator, n);
        defer map.deinit();

        for (0..n * 95 / 100) |i| {
            map.insert(@intCast(i), @intCast(i));
        }

        var timer = try std.time.Timer.start();

        for (0..ops) |i| {
            const key: u32 = @intCast(i % (n * 95 / 100));
            if (i % 5 == 0) {
                map.put(key, @intCast(i));
            } else {
                _ = map.get(key);
            }
        }

        const elapsed = timer.read();
        std.debug.print("Elastic (95% load): {} ops in {}us\n", .{ ops, elapsed / 1_000 });
    }

    // std.HashMap for comparison
    {
        var map = std.hash_map.AutoHashMap(u32, u32).init(allocator);
        defer map.deinit();

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
        std.debug.print("std.HashMap:        {} ops in {}us\n", .{ ops, elapsed / 1_000 });
    }
}

fn worstCaseLatency(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Worst case latency (single lookup, 99% load) ===\n", .{});

    const n = 10000;
    const fill = n * 99 / 100;

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

fn fixedCapacityComparison(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Fixed capacity (no resize allowed) ===\n", .{});

    const n = 10000;
    const fill = n * 99 / 100;

    // Elastic
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

        std.debug.print("Elastic:  insert={}us  lookup={}us\n", .{ insert_time / 1_000, lookup_time / 1_000 });
    }

    // Linear probing
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

        std.debug.print("Linear:   insert={}us  lookup={}us\n", .{ insert_time / 1_000, lookup_time / 1_000 });
    }
}

fn loadFactorComparison(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Load factor comparison (n=10000) ===\n", .{});
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
            elastic_insert = timer.read() / 1_000;

            timer.reset();
            for (0..fill) |i| {
                _ = map.get(@intCast(i));
            }
            elastic_lookup = timer.read() / 1_000;
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
            linear_insert = timer.read() / 1_000;

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
            linear_lookup = timer.read() / 1_000;
        }

        std.debug.print("  {d:>2}%  |        {d:>2}us / {d:<2}us    |       {d:>2}us / {d:<2}us\n", .{
            load_pct,
            elastic_insert,
            elastic_lookup,
            linear_insert,
            linear_lookup,
        });
    }
}

fn stdHashMapComparison(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Elastic vs std.HashMap at 99% load ===\n", .{});
    std.debug.print("(std.HashMap configured with max_load_percentage=99)\n\n", .{});

    const n = 10000;
    const fill = n * 99 / 100;

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
        elastic_insert = timer.read() / 1_000;

        timer.reset();
        for (0..fill) |i| {
            _ = map.get(@intCast(i));
        }
        elastic_lookup = timer.read() / 1_000;
    }

    // std.HashMap with 99% max load
    var std_insert: u64 = 0;
    var std_lookup: u64 = 0;
    {
        const HighLoadHashMap = std.hash_map.HashMap(
            u32,
            u32,
            std.hash_map.AutoContext(u32),
            99,
        );
        var map = HighLoadHashMap.init(allocator);
        defer map.deinit();

        // Pre-allocate to avoid measuring resize during insert
        try map.ensureTotalCapacity(@intCast(fill));

        var timer = try std.time.Timer.start();
        for (0..fill) |i| {
            map.putAssumeCapacity(@intCast(i), @intCast(i));
        }
        std_insert = timer.read() / 1_000;

        timer.reset();
        for (0..fill) |i| {
            _ = map.get(@intCast(i));
        }
        std_lookup = timer.read() / 1_000;
    }

    std.debug.print("Elastic:      insert={}us  lookup={}us\n", .{ elastic_insert, elastic_lookup });
    std.debug.print("std.HashMap:  insert={}us  lookup={}us\n", .{ std_insert, std_lookup });

    // Worst-case latency comparison
    std.debug.print("\nWorst-case single lookup:\n", .{});

    // Elastic worst case
    {
        const Map = ElasticHash(u32, u32, std.hash_map.AutoContext(u32), 100);
        var map = try Map.init(allocator, n);
        defer map.deinit();

        for (0..fill) |i| {
            map.insert(@intCast(i), @intCast(i));
        }

        var worst_time: u64 = 0;
        for (0..fill) |i| {
            var timer = try std.time.Timer.start();
            _ = map.get(@intCast(i));
            const elapsed = timer.read();
            worst_time = @max(worst_time, elapsed);
        }
        std.debug.print("Elastic:      {}ns\n", .{worst_time});
    }

    // std.HashMap worst case
    {
        const HighLoadHashMap = std.hash_map.HashMap(
            u32,
            u32,
            std.hash_map.AutoContext(u32),
            99,
        );
        var map = HighLoadHashMap.init(allocator);
        defer map.deinit();

        try map.ensureTotalCapacity(@intCast(fill));
        for (0..fill) |i| {
            map.putAssumeCapacity(@intCast(i), @intCast(i));
        }

        var worst_time: u64 = 0;
        for (0..fill) |i| {
            var timer = try std.time.Timer.start();
            _ = map.get(@intCast(i));
            const elapsed = timer.read();
            worst_time = @max(worst_time, elapsed);
        }
        std.debug.print("std.HashMap:  {}ns\n", .{worst_time});
    }
}

fn hybridComparison(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Hybrid vs std.HashMap (99% load, 5 runs averaged) ===\n", .{});

    const sizes = [_]usize{ 10_000, 100_000, 1_000_000 };
    const runs = 5;

    inline for (sizes) |n| {
        const fill = n * 99 / 100;

        var hybrid_insert_total: u64 = 0;
        var hybrid_lookup_total: u64 = 0;
        var hybrid_worst: u64 = 0;

        var std_insert_total: u64 = 0;
        var std_lookup_total: u64 = 0;
        var std_worst: u64 = 0;

        for (0..runs) |_| {
            // Hybrid
            {
                var map = try HybridElasticHash.init(allocator, n);
                defer map.deinit();

                var timer = try std.time.Timer.start();
                for (0..fill) |i| {
                    map.insert(i, i);
                }
                hybrid_insert_total += timer.read() / 1_000;

                timer.reset();
                for (0..fill) |i| {
                    std.mem.doNotOptimizeAway(map.get(i));
                }
                hybrid_lookup_total += timer.read() / 1_000;

                for (0..fill) |i| {
                    var t = try std.time.Timer.start();
                    std.mem.doNotOptimizeAway(map.get(i));
                    hybrid_worst = @max(hybrid_worst, t.read());
                }
            }

            // std.HashMap
            {
                const HighLoadHashMap = std.hash_map.HashMap(u64, u64, std.hash_map.AutoContext(u64), 99);
                var map = HighLoadHashMap.init(allocator);
                defer map.deinit();
                try map.ensureTotalCapacity(@intCast(fill));

                var timer = try std.time.Timer.start();
                for (0..fill) |i| {
                    map.putAssumeCapacity(i, i);
                }
                std_insert_total += timer.read() / 1_000;

                timer.reset();
                for (0..fill) |i| {
                    std.mem.doNotOptimizeAway(map.get(i));
                }
                std_lookup_total += timer.read() / 1_000;

                for (0..fill) |i| {
                    var t = try std.time.Timer.start();
                    std.mem.doNotOptimizeAway(map.get(i));
                    std_worst = @max(std_worst, t.read());
                }
            }
        }

        const h_ins = hybrid_insert_total / runs;
        const h_get = hybrid_lookup_total / runs;
        const s_ins = std_insert_total / runs;
        const s_get = std_lookup_total / runs;

        // Calculate speedup (>1 = hybrid faster, <1 = std faster)
        const ins_speedup = @as(f32, @floatFromInt(s_ins)) / @as(f32, @floatFromInt(h_ins));
        const get_speedup = @as(f32, @floatFromInt(s_get)) / @as(f32, @floatFromInt(h_get));

        std.debug.print("\nn = {}\n", .{n});
        std.debug.print("           |   Hybrid   |    std     |  speedup\n", .{});
        std.debug.print("-----------|------------|------------|----------\n", .{});
        std.debug.print("  insert   | {d:>7}us  | {d:>7}us  |  {d:.2}x\n", .{ h_ins, s_ins, ins_speedup });
        std.debug.print("  lookup   | {d:>7}us  | {d:>7}us  |  {d:.2}x\n", .{ h_get, s_get, get_speedup });
        std.debug.print("  worst ns | {d:>7}    | {d:>7}    |\n", .{ hybrid_worst, std_worst });
    }
}
