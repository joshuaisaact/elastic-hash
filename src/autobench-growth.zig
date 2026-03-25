//! Growth policy overhead test.
//! Compares original StringElasticHash (pre-allocated) against
//! StringElasticHashGrowth (with abseil-style resize checks on every insert).
//! Both are pre-allocated to the same capacity, so resize never triggers —
//! this isolates the cost of the CHECK, not the resize itself.
const std = @import("std");
const Original = @import("string_hybrid.zig").StringElasticHash;
const Growth = @import("string_hybrid_growth.zig").StringElasticHashGrowth;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const TOTAL_RUNS: usize = 12;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;
const KEY_LEN: usize = 16;
const N: usize = 1_048_576;

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

fn now() i128 { return std.time.nanoTimestamp(); }
fn usElapsed(start: i128, end: i128) u64 { return @intCast(@divTrunc(end - start, 1_000)); }
fn median(arr: *[MEASURED]u64) u64 {
    sort.insertion(u64, arr, {}, sort.asc(u64));
    return arr[MEASURED / 2];
}

fn benchImpl(comptime MapType: type, name: []const u8, allocator: std.mem.Allocator, key_buf: [][KEY_LEN]u8, miss_buf: [][KEY_LEN]u8, fill: usize, load_pct: usize) void {
    var ins: [MEASURED]u64 = undefined;
    var lkp: [MEASURED]u64 = undefined;
    var mis: [MEASURED]u64 = undefined;
    var del: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = MapType.init(allocator, N) catch @panic("init");
        defer map.deinit();

        var start: i128 = now();
        for (0..fill) |i| map.insert(&key_buf[i], i);
        var end: i128 = now();
        const insert_us = usElapsed(start, end);

        start = now();
        for (0..fill) |i| std.mem.doNotOptimizeAway(map.get(&key_buf[i]));
        end = now();
        const lookup_us = usElapsed(start, end);

        start = now();
        for (0..fill) |i| std.mem.doNotOptimizeAway(map.get(&miss_buf[i]));
        end = now();
        const miss_us = usElapsed(start, end);

        start = now();
        for (0..fill / 2) |i| std.mem.doNotOptimizeAway(map.remove(&key_buf[i]));
        end = now();
        const delete_us = usElapsed(start, end);

        if (r >= WARMUP) {
            const mi = r - WARMUP;
            ins[mi] = insert_us;
            lkp[mi] = lookup_us;
            mis[mi] = miss_us;
            del[mi] = delete_us;
        }
    }

    std.debug.print("{s}\tn={d}\tload={d}\tinsert={d}\thit={d}\tmiss={d}\tdelete={d}\n", .{
        name, N, load_pct, median(&ins), median(&lkp), median(&mis), median(&del),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Growth Policy Overhead Test ===\n\n", .{});

    const load_pcts = [_]usize{ 10, 25, 50, 75 };

    for (load_pcts) |pct| {
        const fill = N * pct / 100;

        const key_buf = try allocator.alloc([KEY_LEN]u8, fill);
        defer allocator.free(key_buf);
        const miss_buf = try allocator.alloc([KEY_LEN]u8, fill);
        defer allocator.free(miss_buf);

        var ks: u64 = KEY_SEED;
        var ms: u64 = MISS_SEED;
        for (0..fill) |i| {
            u64ToHex(splitmix64(&ks), &key_buf[i]);
            u64ToHex(splitmix64(&ms), &miss_buf[i]);
        }

        benchImpl(Original, "original", allocator, key_buf, miss_buf, fill, pct);
        benchImpl(Growth, "growth", allocator, key_buf, miss_buf, fill, pct);
        std.debug.print("\n", .{});
    }

    std.debug.print("DONE\n", .{});
}
