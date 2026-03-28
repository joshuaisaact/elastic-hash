//! Tombstone churn test: does delete/insert cycling degrade performance?
//!
//! Fills table to 50% load, then runs N cycles of (delete random key, insert new key).
//! Measures hit and miss lookup after 0, 10K, 50K, 100K, 500K churn cycles.
//! If tombstones accumulate and matchEmpty stops finding empty slots,
//! miss performance will regress back toward pre-optimization numbers.
const std = @import("std");
const StringElasticHash = @import("string_hybrid.zig").StringElasticHash;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const CHURN_SEED: u64 = 0xABCDABCD12345678;
const TOTAL_RUNS: usize = 8;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;
const KEY_LEN: usize = 16;

const N: usize = 1_048_576;
const FILL: usize = N / 2; // 50% load

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

fn median(arr: []u64) u64 {
    sort.insertion(u64, arr, {}, sort.asc(u64));
    return arr[arr.len / 2];
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

fn measureLookups(
    map: *const StringElasticHash,
    key_buf: [][KEY_LEN]u8,
    miss_buf: [][KEY_LEN]u8,
    hit_order: []usize,
    miss_order: []usize,
    count: usize,
) struct { hit_us: u64, miss_us: u64 } {
    // Hit lookup
    var start = now();
    for (0..count) |i| {
        std.mem.doNotOptimizeAway(map.get(&key_buf[hit_order[i]]));
    }
    var end = now();
    const hit_us = usElapsed(start, end);

    // Miss lookup
    start = now();
    for (0..count) |i| {
        std.mem.doNotOptimizeAway(map.get(&miss_buf[miss_order[i]]));
    }
    end = now();
    const miss_us = usElapsed(start, end);

    return .{ .hit_us = hit_us, .miss_us = miss_us };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Tombstone Churn Test (n={d}, 50% load, {d}-byte keys) ===\n", .{ N, KEY_LEN });
    std.debug.print("=== Each measurement: median of {d} runs, {d} warmup ===\n\n", .{ MEASURED, WARMUP });

    // Pre-generate all keys we'll ever need
    // Initial fill keys + enough churn keys for 500K cycles
    const max_churn: usize = 500_000;
    const total_keys = FILL + max_churn;

    const key_buf = try allocator.alloc([KEY_LEN]u8, total_keys);
    defer allocator.free(key_buf);
    var ks: u64 = KEY_SEED;
    for (0..total_keys) |i| u64ToHex(splitmix64(&ks), &key_buf[i]);

    const miss_buf = try allocator.alloc([KEY_LEN]u8, FILL);
    defer allocator.free(miss_buf);
    var ms: u64 = MISS_SEED;
    for (0..FILL) |i| u64ToHex(splitmix64(&ms), &miss_buf[i]);

    // Lookup orders (shuffled over the initial fill size)
    const hit_order = try allocator.alloc(usize, FILL);
    defer allocator.free(hit_order);
    for (0..FILL) |i| hit_order[i] = i;
    shuffle(hit_order, 42);

    const miss_order = try allocator.alloc(usize, FILL);
    defer allocator.free(miss_order);
    for (0..FILL) |i| miss_order[i] = i;
    shuffle(miss_order, 99);

    // Generate a random delete order over FILL keys
    const delete_order = try allocator.alloc(usize, max_churn);
    defer allocator.free(delete_order);
    var del_rng: u64 = CHURN_SEED;
    for (0..max_churn) |i| {
        delete_order[i] = splitmix64(&del_rng) % FILL;
    }

    const churn_points = [_]usize{ 0, 10_000, 50_000, 100_000, 500_000 };

    for (churn_points) |target_churn| {
        var hit_times: [MEASURED]u64 = undefined;
        var miss_times: [MEASURED]u64 = undefined;

        for (0..TOTAL_RUNS) |r| {
            var map = StringElasticHash.init(allocator, N) catch @panic("init");
            defer map.deinit();

            // Insert initial fill
            for (0..FILL) |i| map.insert(&key_buf[i], i);

            // Churn: delete random existing key, insert new key
            // We track which keys are "live" by swapping deleted keys with new ones
            // in the key_buf. This keeps count at FILL.
            var live_keys = try allocator.alloc(usize, FILL);
            defer allocator.free(live_keys);
            for (0..FILL) |i| live_keys[i] = i;
            var next_key: usize = FILL;

            for (0..target_churn) |c| {
                // Delete a random live key
                const victim_slot = delete_order[c] % FILL;
                const victim_key_idx = live_keys[victim_slot];
                _ = map.remove(&key_buf[victim_key_idx]);

                // Insert a new key
                if (next_key < total_keys) {
                    map.insert(&key_buf[next_key], next_key);
                    live_keys[victim_slot] = next_key;
                    next_key += 1;
                }
            }

            // Now measure lookups using the original hit_order/miss_order
            // Hit lookups use live_keys to find actual keys in the map
            // But for simplicity and consistency, we look up the INITIAL keys.
            // Some will be hits (still in map), some will be misses (deleted).
            // At 0 churn, all are hits. At high churn, many are misses.
            // This actually tests a realistic pattern.

            // Instead, let's just measure with the initial keys that are still live
            // and the miss keys that were never inserted.
            const result = measureLookups(&map, key_buf[0..FILL], miss_buf, hit_order, miss_order, FILL);

            if (r >= WARMUP) {
                const mi = r - WARMUP;
                hit_times[mi] = result.hit_us;
                miss_times[mi] = result.miss_us;
            }
        }

        std.debug.print("CHURN\tcycles={d}\thit_us={d}\tmiss_us={d}\tcount_after={d}\n", .{
            target_churn,
            median(&hit_times),
            median(&miss_times),
            FILL,
        });
    }

    std.debug.print("\nDONE\n", .{});
}
