//! String key verification: variable lengths, sizes, correctness
const std = @import("std");
const StringElasticHash = @import("string_hybrid.zig").StringElasticHash;
const Wyhash = std.hash.Wyhash;
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

const hex_chars = "0123456789abcdef";

fn genHexKey(val: u64, buf: []u8) void {
    var v = val;
    for (buf, 0..) |*b, i| {
        b.* = hex_chars[@as(usize, @intCast((v >> @as(u6, @intCast((i % 16) * 4))) & 0xF))];
        if (i % 16 == 15) v = v *% 0x517cc1b727220a95 +% i;
    }
}

fn now() linux.timespec {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return ts;
}

fn usElapsed(start: linux.timespec, end: linux.timespec) u64 {
    const s: u64 = @intCast(end.sec - start.sec);
    const ns_diff: i64 = @as(i64, @intCast(end.nsec)) - @as(i64, @intCast(start.nsec));
    return (s * 1_000_000_000 + @as(u64, @intCast(ns_diff))) / 1_000;
}

fn median(arr: *[MEASURED]u64) u64 {
    sort.insertion(u64, arr, {}, sort.asc(u64));
    return arr[MEASURED / 2];
}

fn benchShuffled(allocator: std.mem.Allocator, n: usize, fill: usize, klen: usize) u64 {
    const key_buf = allocator.alloc(u8, fill * klen) catch @panic("alloc");
    defer allocator.free(key_buf);

    var ks: u64 = KEY_SEED;
    for (0..fill) |i| {
        genHexKey(splitmix64(&ks), key_buf[i * klen .. (i + 1) * klen]);
    }

    const shuffle_order = allocator.alloc(usize, fill) catch @panic("alloc");
    defer allocator.free(shuffle_order);
    for (0..fill) |i| shuffle_order[i] = i;
    var rng: u64 = 42;
    var idx: usize = fill;
    while (idx > 1) { idx -= 1; const j = splitmix64(&rng) % (idx + 1); const tmp = shuffle_order[idx]; shuffle_order[idx] = shuffle_order[j]; shuffle_order[j] = tmp; }

    var times: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = StringElasticHash.init(allocator, n) catch @panic("init");
        defer map.deinit();
        for (0..fill) |i| {
            map.insert(key_buf[i * klen .. (i + 1) * klen], i);
        }

        const start = now();
        for (0..fill) |i| {
            const ki = shuffle_order[i];
            std.mem.doNotOptimizeAway(map.get(key_buf[ki * klen .. (ki + 1) * klen]));
        }
        const end = now();
        if (r >= WARMUP) times[r - WARMUP] = usElapsed(start, end);
    }

    return median(&times);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Test 1: Hash cost
    {
        std.debug.print("=== Test 1: Wyhash cost (16-byte strings) ===\n", .{});
        var keys: [1024][16]u8 = undefined;
        var ks: u64 = KEY_SEED;
        for (&keys) |*k| {
            const v = splitmix64(&ks);
            var val = v;
            comptime var i: usize = 16;
            inline while (i > 0) { i -= 1; k[i] = hex_chars[@as(usize, @intCast(val & 0xF))]; val >>= 4; }
        }
        var best: u64 = std.math.maxInt(u64);
        for (0..10) |_| {
            const start = now();
            var acc: u64 = 0;
            for (0..10_000_000) |i| {
                acc +%= Wyhash.hash(0, &keys[i & 1023]);
            }
            const end = now();
            std.mem.doNotOptimizeAway(acc);
            const us = usElapsed(start, end);
            if (us < best) best = us;
        }
        std.debug.print("  Wyhash(16B): {d} us ({d:.1} ns/hash)\n\n", .{ best, @as(f64, @floatFromInt(best)) * 1000.0 / 10_000_000 });
    }

    // Test 2: Variable key lengths (1M, 50% load, shuffled)
    {
        std.debug.print("=== Test 2: Variable key lengths (1M, 50% load, shuffled) ===\n", .{});
        const klens = [_]usize{ 8, 16, 32, 64, 128, 256 };
        for (klens) |klen| {
            const us = benchShuffled(allocator, 1_048_576, 524_288, klen);
            std.debug.print("  klen={d:>3}: {d} us\n", .{ klen, us });
        }
        std.debug.print("\n", .{});
    }

    // Test 3: Multiple sizes at 50% load, shuffled, 16-byte keys
    {
        std.debug.print("=== Test 3: Table sizes (50% load, shuffled, 16B keys) ===\n", .{});
        const sizes = [_]usize{ 100_000, 500_000, 1_000_000, 2_000_000, 4_000_000 };
        for (sizes) |n| {
            const fill = n / 2;
            const us = benchShuffled(allocator, n, fill, 16);
            std.debug.print("  n={d:>7} fill={d:>7}: {d} us\n", .{ n, fill, us });
        }
        std.debug.print("\n", .{});
    }

    // Test 4: Correctness check (1M, 99%, verify all values)
    {
        std.debug.print("=== Test 4: Correctness check (1M, 99%) ===\n", .{});
        const n: usize = 1_048_576;
        const fill = n * 99 / 100;
        const key_buf = allocator.alloc([16]u8, fill) catch @panic("alloc");
        defer allocator.free(key_buf);

        var ks: u64 = KEY_SEED;
        for (0..fill) |i| {
            const v = splitmix64(&ks);
            var val = v;
            comptime var j: usize = 16;
            inline while (j > 0) { j -= 1; key_buf[i][j] = hex_chars[@as(usize, @intCast(val & 0xF))]; val >>= 4; }
        }

        var map = try StringElasticHash.init(allocator, n);
        defer map.deinit();
        for (0..fill) |i| map.insert(&key_buf[i], i);

        var found: usize = 0;
        var correct: usize = 0;
        for (0..fill) |i| {
            if (map.get(&key_buf[i])) |v| {
                found += 1;
                if (v == i) correct += 1;
            }
        }
        std.debug.print("  Inserted: {d}\n", .{fill});
        std.debug.print("  Found:    {d} ({d:.1}%)\n", .{ found, @as(f64, @floatFromInt(found)) / @as(f64, @floatFromInt(fill)) * 100 });
        std.debug.print("  Correct:  {d} ({d:.1}%)\n\n", .{ correct, @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(fill)) * 100 });
    }

    std.debug.print("DONE\n", .{});
}
