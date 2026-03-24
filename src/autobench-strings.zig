//! String-key benchmark: elastic hash with []const u8 keys vs abseil with string_view.
const std = @import("std");
const StringElasticHash = @import("string_hybrid.zig").StringElasticHash;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const TOTAL_RUNS: usize = 12;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;
const KEY_LEN: usize = 16; // 16-byte hex strings

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

fn benchOne(allocator: std.mem.Allocator, n: usize, fill: usize, load_pct: usize) void {
    // Pre-generate key strings
    const key_buf = allocator.alloc([KEY_LEN]u8, fill) catch @panic("alloc keys");
    defer allocator.free(key_buf);
    const miss_buf = allocator.alloc([KEY_LEN]u8, fill) catch @panic("alloc miss");
    defer allocator.free(miss_buf);

    var ks: u64 = KEY_SEED;
    var ms: u64 = MISS_SEED;
    for (0..fill) |i| {
        u64ToHex(splitmix64(&ks), &key_buf[i]);
        u64ToHex(splitmix64(&ms), &miss_buf[i]);
    }

    var ins: [MEASURED]u64 = undefined;
    var lkp: [MEASURED]u64 = undefined;
    var del: [MEASURED]u64 = undefined;
    var mis: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = StringElasticHash.init(allocator, n) catch @panic("init");
        defer map.deinit();

        var start: i128 = now();
        for (0..fill) |i| {
            map.insert(&key_buf[i], i);
        }
        var end: i128 = now();
        const insert_us = usElapsed(start, end);

        start = now();
        for (0..fill) |i| {
            std.mem.doNotOptimizeAway(map.get(&key_buf[i]));
        }
        end = now();
        const lookup_us = usElapsed(start, end);

        start = now();
        for (0..fill) |i| {
            std.mem.doNotOptimizeAway(map.get(&miss_buf[i]));
        }
        end = now();
        const miss_us = usElapsed(start, end);

        start = now();
        for (0..fill / 2) |i| {
            std.mem.doNotOptimizeAway(map.remove(&key_buf[i]));
        }
        end = now();
        const delete_us = usElapsed(start, end);

        if (r >= WARMUP) {
            const idx = r - WARMUP;
            ins[idx] = insert_us;
            lkp[idx] = lookup_us;
            del[idx] = delete_us;
            mis[idx] = miss_us;
        }
    }

    std.debug.print("RESULT\tn={d}\tload={d}\tinsert_us={d}\tlookup_us={d}\tdelete_us={d}\tmiss_us={d}\n", .{
        n, load_pct, median(&ins), median(&lkp), median(&del), median(&mis),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== String-key Benchmark (median of {d}, {d} warmup, {d}-byte keys) ===\n\n", .{ MEASURED, WARMUP, KEY_LEN });

    const sizes = [_]usize{ 16_384, 65_536, 262_144, 1_048_576 };
    for (sizes) |n| {
        benchOne(allocator, n, n * 99 / 100, 99);
    }

    const load_pcts = [_]usize{ 10, 25, 50, 75, 90 };
    const n: usize = 1_048_576;
    for (load_pcts) |pct| {
        benchOne(allocator, n, n * pct / 100, pct);
    }

    std.debug.print("\nDONE\n", .{});
}
