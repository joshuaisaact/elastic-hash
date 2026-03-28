//! Variable key length benchmark.
//! Tests hit and miss lookup with key lengths: 8, 16, 32, 64, 128, 256 bytes.
//! All at n=1M, 50% load, shuffled access.
const std = @import("std");
const StringElasticHash = @import("string_hybrid.zig").StringElasticHash;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const TOTAL_RUNS: usize = 10;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;

const N: usize = 1_048_576;
const FILL: usize = N / 2;

fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

const hex_chars = "0123456789abcdef";

fn fillHex(val: u64, buf: []u8) void {
    // Fill buf with hex from val, repeating as needed
    var v = val;
    for (buf, 0..) |*b, i| {
        if (i % 16 == 0 and i > 0) v = v *% 0x9e3779b97f4a7c15; // remix for longer keys
        b.* = hex_chars[@as(usize, @intCast(v & 0xF))];
        v >>= 4;
        if (v == 0) v = val *% (@as(u64, @intCast(i)) + 1);
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

fn benchKeyLen(allocator: std.mem.Allocator, key_len: usize) void {
    // Allocate key buffers
    const key_data = allocator.alloc(u8, FILL * key_len) catch @panic("alloc keys");
    defer allocator.free(key_data);
    const miss_data = allocator.alloc(u8, FILL * key_len) catch @panic("alloc miss");
    defer allocator.free(miss_data);

    var ks: u64 = KEY_SEED;
    var ms: u64 = MISS_SEED;
    for (0..FILL) |i| {
        fillHex(splitmix64(&ks), key_data[i * key_len .. (i + 1) * key_len]);
        fillHex(splitmix64(&ms), miss_data[i * key_len .. (i + 1) * key_len]);
    }

    const hit_order = allocator.alloc(usize, FILL) catch @panic("alloc");
    defer allocator.free(hit_order);
    for (0..FILL) |i| hit_order[i] = i;
    shuffle(hit_order, 42);

    const miss_order = allocator.alloc(usize, FILL) catch @panic("alloc");
    defer allocator.free(miss_order);
    for (0..FILL) |i| miss_order[i] = i;
    shuffle(miss_order, 99);

    var hit_times: [MEASURED]u64 = undefined;
    var miss_times: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = StringElasticHash.init(allocator, N) catch @panic("init");
        defer map.deinit();

        for (0..FILL) |i| {
            const k = key_data[i * key_len .. (i + 1) * key_len];
            map.insert(k, i);
        }

        // Shuffled hit
        var start = now();
        for (0..FILL) |i| {
            const ki = hit_order[i];
            const k = key_data[ki * key_len .. (ki + 1) * key_len];
            std.mem.doNotOptimizeAway(map.get(k));
        }
        var end = now();
        const hit_us = usElapsed(start, end);

        // Shuffled miss
        start = now();
        for (0..FILL) |i| {
            const ki = miss_order[i];
            const k = miss_data[ki * key_len .. (ki + 1) * key_len];
            std.mem.doNotOptimizeAway(map.get(k));
        }
        end = now();
        const miss_us = usElapsed(start, end);

        if (r >= WARMUP) {
            const mi = r - WARMUP;
            hit_times[mi] = hit_us;
            miss_times[mi] = miss_us;
        }
    }

    std.debug.print("KEYLEN\tlen={d}\thit_shuffled={d}\tmiss_shuffled={d}\n", .{
        key_len, median(&hit_times), median(&miss_times),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Variable Key Length Benchmark (n={d}, 50% load, shuffled) ===\n\n", .{N});

    const key_lens = [_]usize{ 8, 16, 32, 64, 128, 256 };
    for (key_lens) |kl| {
        benchKeyLen(allocator, kl);
    }

    std.debug.print("\nDONE\n", .{});
}
