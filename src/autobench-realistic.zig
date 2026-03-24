//! Realistic workload benchmarks for elastic hash
const std = @import("std");
const HybridElasticHash = @import("hybrid.zig").HybridElasticHash;
const linux = std.os.linux;
const sort = std.sort;

const RUNS: usize = 8;
const WARMUP_RUNS: usize = 2;
const MEASURED: usize = RUNS - WARMUP_RUNS;

fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn now() linux.timespec {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts;
}

fn usElapsed(start: linux.timespec, end: linux.timespec) u64 {
    const s: u64 = @intCast(end.sec - start.sec);
    const ns_diff: i64 = @as(i64, @intCast(end.nsec)) - @as(i64, @intCast(start.nsec));
    return s * 1_000_000_000 + @as(u64, @intCast(ns_diff)) / 1_000;
}

fn median(arr: *[MEASURED]u64) u64 {
    sort.insertion(u64, arr, {}, sort.asc(u64));
    return arr[MEASURED / 2];
}

// Workload 1: Mixed read/write (80% hit lookup, 10% miss, 5% insert, 5% delete)
fn benchMixed(allocator: std.mem.Allocator, initial_size: usize) void {
    const OPS: usize = 1_000_000;
    var times: [MEASURED]u64 = undefined;

    var ks: u64 = 0xDEADBEEF12345678;
    const initial_keys = allocator.alloc(u64, initial_size) catch @panic("alloc");
    defer allocator.free(initial_keys);
    for (0..initial_size) |i| initial_keys[i] = splitmix64(&ks);

    const op_keys = allocator.alloc(u64, OPS) catch @panic("alloc");
    defer allocator.free(op_keys);
    const op_types = allocator.alloc(u8, OPS) catch @panic("alloc");
    defer allocator.free(op_types);

    var rng: u64 = 12345;
    for (0..OPS) |i| {
        const r = splitmix64(&rng) % 100;
        if (r < 80) { // 80% hit lookup
            op_types[i] = 0;
            op_keys[i] = initial_keys[splitmix64(&rng) % initial_size];
        } else if (r < 90) { // 10% miss lookup
            op_types[i] = 1;
            op_keys[i] = splitmix64(&ks);
        } else if (r < 95) { // 5% insert
            op_types[i] = 2;
            op_keys[i] = splitmix64(&ks);
        } else { // 5% delete
            op_types[i] = 3;
            op_keys[i] = initial_keys[splitmix64(&rng) % initial_size];
        }
    }

    for (0..RUNS) |r| {
        var map = HybridElasticHash.init(allocator, initial_size * 2) catch @panic("init");
        defer map.deinit();
        for (0..initial_size) |i| map.insert(initial_keys[i], i);

        const start = now();
        for (0..OPS) |i| {
            switch (op_types[i]) {
                0 => std.mem.doNotOptimizeAway(map.get(op_keys[i])), // hit
                1 => std.mem.doNotOptimizeAway(map.get(op_keys[i])), // miss
                2 => map.insert(op_keys[i], i),
                3 => std.mem.doNotOptimizeAway(map.remove(op_keys[i])),
                else => {},
            }
        }
        const end = now();

        if (r >= WARMUP_RUNS) times[r - WARMUP_RUNS] = usElapsed(start, end);
    }

    std.debug.print("ELASTIC\tmixed_rw\tn={d}\tops={d}\tus={d}\n", .{
        initial_size, OPS, median(&times),
    });
}

// Workload 2: Hot-key lookup (zipf-like: 80% of lookups hit top 20% of keys)
fn benchHotkey(allocator: std.mem.Allocator, n: usize) void {
    const OPS: usize = 1_000_000;
    var times: [MEASURED]u64 = undefined;

    var ks: u64 = 0xDEADBEEF12345678;
    const keys = allocator.alloc(u64, n) catch @panic("alloc");
    defer allocator.free(keys);
    for (0..n) |i| keys[i] = splitmix64(&ks);

    const lookup_keys = allocator.alloc(u64, OPS) catch @panic("alloc");
    defer allocator.free(lookup_keys);
    const hot_count = n / 5;
    var rng: u64 = 42;
    for (0..OPS) |i| {
        if (splitmix64(&rng) % 100 < 80) {
            lookup_keys[i] = keys[splitmix64(&rng) % hot_count];
        } else {
            lookup_keys[i] = keys[splitmix64(&rng) % n];
        }
    }

    for (0..RUNS) |r| {
        var map = HybridElasticHash.init(allocator, n) catch @panic("init");
        defer map.deinit();
        for (0..n) |i| map.insert(keys[i], i);

        const start = now();
        for (0..OPS) |i| {
            std.mem.doNotOptimizeAway(map.get(lookup_keys[i]));
        }
        const end = now();

        if (r >= WARMUP_RUNS) times[r - WARMUP_RUNS] = usElapsed(start, end);
    }

    std.debug.print("ELASTIC\thotkey\tn={d}\tops={d}\tus={d}\n", .{ n, OPS, median(&times) });
}

// Workload 3: Build-then-read (insert N, then 10N random lookups)
fn benchBuildRead(allocator: std.mem.Allocator, n: usize) void {
    const READ_MULT: usize = 10;
    var build_times: [MEASURED]u64 = undefined;
    var read_times: [MEASURED]u64 = undefined;

    var ks: u64 = 0xDEADBEEF12345678;
    const keys = allocator.alloc(u64, n) catch @panic("alloc");
    defer allocator.free(keys);
    for (0..n) |i| keys[i] = splitmix64(&ks);

    const read_order = allocator.alloc(usize, n * READ_MULT) catch @panic("alloc");
    defer allocator.free(read_order);
    var rng: u64 = 99;
    for (0..n * READ_MULT) |i| read_order[i] = splitmix64(&rng) % n;

    for (0..RUNS) |r| {
        var map = HybridElasticHash.init(allocator, n) catch @panic("init");
        defer map.deinit();

        var start = now();
        for (0..n) |i| map.insert(keys[i], i);
        var end = now();
        if (r >= WARMUP_RUNS) build_times[r - WARMUP_RUNS] = usElapsed(start, end);

        start = now();
        for (0..n * READ_MULT) |i| {
            std.mem.doNotOptimizeAway(map.get(keys[read_order[i]]));
        }
        end = now();
        if (r >= WARMUP_RUNS) read_times[r - WARMUP_RUNS] = usElapsed(start, end);
    }

    std.debug.print("ELASTIC\tbuild_read\tn={d}\tbuild_us={d}\tread_us={d}\n", .{
        n, median(&build_times), median(&read_times),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("=== Realistic workload benchmarks (elastic hash) ===\n\n", .{});

    const sizes = [_]usize{ 100_000, 500_000, 1_000_000 };

    for (sizes) |n| benchMixed(allocator, n);
    for (sizes) |n| benchHotkey(allocator, n);
    for (sizes) |n| benchBuildRead(allocator, n);

    std.debug.print("\nDONE\n", .{});
}
