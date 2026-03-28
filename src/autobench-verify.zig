//! Verification benchmark: shuffled lookup order + multiple sizes
const std = @import("std");
const HybridElasticHash = @import("hybrid.zig").HybridElasticHash;
const linux = std.os.linux;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const TOTAL_RUNS: usize = 12;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;

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
    const total_ns: u64 = s * 1_000_000_000 + @as(u64, @intCast(ns_diff));
    return total_ns / 1_000;
}

fn median(arr: *[MEASURED]u64) u64 {
    sort.insertion(u64, arr, {}, sort.asc(u64));
    return arr[MEASURED / 2];
}

fn bench(allocator: std.mem.Allocator, n: usize, fill: usize, label: []const u8) void {
    const keys = allocator.alloc(u64, fill) catch @panic("alloc");
    defer allocator.free(keys);

    var ks: u64 = KEY_SEED;
    for (0..fill) |i| keys[i] = splitmix64(&ks);

    // Fisher-Yates shuffle with fixed seed
    const lookup_order = allocator.alloc(usize, fill) catch @panic("alloc");
    defer allocator.free(lookup_order);
    for (0..fill) |i| lookup_order[i] = i;
    var rng_state: u64 = 42;
    var idx: usize = fill;
    while (idx > 1) {
        idx -= 1;
        const j = splitmix64(&rng_state) % (idx + 1);
        const tmp = lookup_order[idx];
        lookup_order[idx] = lookup_order[j];
        lookup_order[j] = tmp;
    }

    var lkp_ordered: [MEASURED]u64 = undefined;
    var lkp_shuffled: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = HybridElasticHash.init(allocator, n) catch @panic("init");
        defer map.deinit();
        for (0..fill) |i| map.insert(keys[i], i);

        // Ordered lookup
        var start = now();
        for (0..fill) |i| {
            std.mem.doNotOptimizeAway(map.get(keys[i]));
        }
        var end = now();
        const ordered_us = usElapsed(start, end);

        // Shuffled lookup
        start = now();
        for (0..fill) |i| {
            std.mem.doNotOptimizeAway(map.get(keys[lookup_order[i]]));
        }
        end = now();
        const shuffled_us = usElapsed(start, end);

        if (r >= WARMUP) {
            const mi = r - WARMUP;
            lkp_ordered[mi] = ordered_us;
            lkp_shuffled[mi] = shuffled_us;
        }
    }

    std.debug.print("ELASTIC\t{s}\tn={d}\tload={d}\tordered_us={d}\tshuffled_us={d}\n", .{
        label, n, fill * 100 / n, median(&lkp_ordered), median(&lkp_shuffled),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Elastic hash verification: ordered vs shuffled lookup ===\n\n", .{});

    // Multiple sizes at 50% load
    const sizes = [_]usize{ 65_536, 262_144, 1_048_576, 4_194_304 };
    for (sizes) |n| {
        bench(allocator, n, n / 2, "50pct");
    }

    // 1M at multiple loads
    const pcts = [_]usize{ 10, 25, 50, 75, 90, 99 };
    for (pcts) |pct| {
        bench(allocator, 1_048_576, 1_048_576 * pct / 100, "1M");
    }

    std.debug.print("\nDONE\n", .{});
}
