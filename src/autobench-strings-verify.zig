//! Shuffled vs ordered string key lookup verification
const std = @import("std");
const StringElasticHash = @import("string_hybrid.zig").StringElasticHash;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
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
    inline while (i > 0) { i -= 1; buf[i] = hex_chars[@as(usize, @intCast(v & 0xF))]; v >>= 4; }
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

fn bench(allocator: std.mem.Allocator, n: usize, fill: usize, load_pct: usize) void {
    const key_buf = allocator.alloc([KEY_LEN]u8, fill) catch @panic("alloc");
    defer allocator.free(key_buf);
    var ks: u64 = KEY_SEED;
    for (0..fill) |i| u64ToHex(splitmix64(&ks), &key_buf[i]);

    const shuffle_order = allocator.alloc(usize, fill) catch @panic("alloc");
    defer allocator.free(shuffle_order);
    for (0..fill) |i| shuffle_order[i] = i;
    var rng: u64 = 42;
    var idx: usize = fill;
    while (idx > 1) { idx -= 1; const j = splitmix64(&rng) % (idx + 1); const tmp = shuffle_order[idx]; shuffle_order[idx] = shuffle_order[j]; shuffle_order[j] = tmp; }

    var lkp_ordered: [MEASURED]u64 = undefined;
    var lkp_shuffled: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = StringElasticHash.init(allocator, n) catch @panic("init");
        defer map.deinit();
        for (0..fill) |i| map.insert(&key_buf[i], i);

        var start: i128 = now();
        for (0..fill) |i| std.mem.doNotOptimizeAway(map.get(&key_buf[i]));
        var end: i128 = now();
        const ordered_us = usElapsed(start, end);

        start = now();
        for (0..fill) |i| std.mem.doNotOptimizeAway(map.get(&key_buf[shuffle_order[i]]));
        end = now();
        const shuffled_us = usElapsed(start, end);

        if (r >= WARMUP) { const mi = r - WARMUP; lkp_ordered[mi] = ordered_us; lkp_shuffled[mi] = shuffled_us; }
    }

    std.debug.print("ELASTIC\tn={d}\tload={d}\tordered={d}\tshuffled={d}\n", .{
        n, load_pct, median(&lkp_ordered), median(&lkp_shuffled),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const pcts = [_]usize{ 10, 25, 50, 75, 90, 99 };
    for (pcts) |pct| bench(allocator, 1_048_576, 1_048_576 * pct / 100, pct);
}
