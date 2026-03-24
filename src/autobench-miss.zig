//! Hit + miss benchmark with shuffled access patterns.
//! Designed for comparing miss optimization experiments.
const std = @import("std");
const StringElasticHash = @import("string_hybrid.zig").StringElasticHash;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const TOTAL_RUNS: usize = 12;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;
const KEY_LEN: usize = 16;

fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

const hex_chars = "0123456789abcdef";

fn u64ToHex(val: u64, buf: *[KEY_LEN]u8) void {
    var v = val;
    comptime var i: usize = KEY_LEN;
    inline while (i > 0) {
        i -= 1;
        buf[i] = hex_chars[@as(usize, @intCast(v & 0xF))];
        v >>= 4;
    }
}

fn now() i128 {
    return std.time.nanoTimestamp();
}

fn usElapsed(start: i128, end: i128) u64 {
    return @intCast(@divTrunc(end - start, 1_000));
}

fn median(arr: *[MEASURED]u64) u64 {
    sort.insertion(u64, arr, {}, sort.asc(u64));
    return arr[MEASURED / 2];
}

fn shuffle(order: []usize, seed: u64) void {
    var rng: u64 = seed;
    var idx: usize = order.len;
    while (idx > 1) {
        idx -= 1;
        const j = splitmix64(&rng) % (idx + 1);
        const tmp = order[idx];
        order[idx] = order[j];
        order[j] = tmp;
    }
}

fn bench(allocator: std.mem.Allocator, n: usize, fill: usize, load_pct: usize) void {
    // Generate hit keys
    const key_buf = allocator.alloc([KEY_LEN]u8, fill) catch @panic("alloc keys");
    defer allocator.free(key_buf);
    var ks: u64 = KEY_SEED;
    for (0..fill) |i| u64ToHex(splitmix64(&ks), &key_buf[i]);

    // Generate miss keys (different seed, guaranteed different from hit keys)
    const miss_buf = allocator.alloc([KEY_LEN]u8, fill) catch @panic("alloc miss");
    defer allocator.free(miss_buf);
    var ms: u64 = MISS_SEED;
    for (0..fill) |i| u64ToHex(splitmix64(&ms), &miss_buf[i]);

    // Shuffled access orders
    const hit_order = allocator.alloc(usize, fill) catch @panic("alloc hit_order");
    defer allocator.free(hit_order);
    for (0..fill) |i| hit_order[i] = i;
    shuffle(hit_order, 42);

    const miss_order = allocator.alloc(usize, fill) catch @panic("alloc miss_order");
    defer allocator.free(miss_order);
    for (0..fill) |i| miss_order[i] = i;
    shuffle(miss_order, 99);

    var hit_times: [MEASURED]u64 = undefined;
    var miss_times: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = StringElasticHash.init(allocator, n) catch @panic("init");
        defer map.deinit();
        for (0..fill) |i| map.insert(&key_buf[i], i);

        // Shuffled hit lookups
        var start = now();
        for (0..fill) |i| {
            std.mem.doNotOptimizeAway(map.get(&key_buf[hit_order[i]]));
        }
        var end = now();
        const hit_us = usElapsed(start, end);

        // Shuffled miss lookups
        start = now();
        for (0..fill) |i| {
            std.mem.doNotOptimizeAway(map.get(&miss_buf[miss_order[i]]));
        }
        end = now();
        const miss_us = usElapsed(start, end);

        if (r >= WARMUP) {
            const mi = r - WARMUP;
            hit_times[mi] = hit_us;
            miss_times[mi] = miss_us;
        }
    }

    std.debug.print("ELASTIC\tn={d}\tload={d}\thit_shuffled={d}\tmiss_shuffled={d}\n", .{
        n, load_pct, median(&hit_times), median(&miss_times),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Hit + Miss Benchmark (median of {d}, {d} warmup, shuffled, {d}-byte keys) ===\n\n", .{ MEASURED, WARMUP, KEY_LEN });

    const n: usize = 1_048_576;
    const load_pcts = [_]usize{ 10, 25, 50, 75, 90, 99 };
    for (load_pcts) |pct| {
        bench(allocator, n, n * pct / 100, pct);
    }

    std.debug.print("\nDONE\n", .{});
}
