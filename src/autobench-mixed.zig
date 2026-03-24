//! Mixed read/write workload benchmark.
//!
//! Pre-fills table to target load, then runs N operations with distribution:
//! - 40% hit lookup (key exists)
//! - 40% miss lookup (key doesn't exist)
//! - 10% insert (new key)
//! - 10% delete (existing key)
//!
//! Keys are accessed in random order. This simulates a real cache/index workload
//! where reads dominate but writes happen continuously.
const std = @import("std");
const StringElasticHash = @import("string_hybrid.zig").StringElasticHash;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const OP_SEED: u64 = 0x1234ABCD5678EF01;
const TOTAL_RUNS: usize = 8;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;
const KEY_LEN: usize = 16;

const N: usize = 1_048_576;
const OPS_PER_RUN: usize = 1_000_000;

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

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Mixed Workload Benchmark ===\n", .{});
    std.debug.print("=== {d} ops per run, 40% hit / 40% miss / 10% insert / 10% delete ===\n", .{OPS_PER_RUN});
    std.debug.print("=== median of {d} runs, {d} warmup ===\n\n", .{ MEASURED, WARMUP });

    // Pre-generate a large pool of keys
    const key_pool_size = N * 2; // enough for inserts during the run
    const key_pool = try allocator.alloc([KEY_LEN]u8, key_pool_size);
    defer allocator.free(key_pool);
    var ks: u64 = KEY_SEED;
    for (0..key_pool_size) |i| u64ToHex(splitmix64(&ks), &key_pool[i]);

    // Miss keys (never inserted)
    const miss_pool = try allocator.alloc([KEY_LEN]u8, OPS_PER_RUN);
    defer allocator.free(miss_pool);
    var ms: u64 = MISS_SEED;
    for (0..OPS_PER_RUN) |i| u64ToHex(splitmix64(&ms), &miss_pool[i]);

    // Pre-generate operation sequence: 0-3 = hit, 4-7 = miss, 8 = insert, 9 = delete
    const ops = try allocator.alloc(u8, OPS_PER_RUN);
    defer allocator.free(ops);
    var op_rng: u64 = OP_SEED;
    for (0..OPS_PER_RUN) |i| {
        ops[i] = @intCast(splitmix64(&op_rng) % 10);
    }

    // Random indices for key selection
    const rand_indices = try allocator.alloc(u64, OPS_PER_RUN);
    defer allocator.free(rand_indices);
    var idx_rng: u64 = 0xFEDCBA9876543210;
    for (0..OPS_PER_RUN) |i| {
        rand_indices[i] = splitmix64(&idx_rng);
    }

    const load_pcts = [_]usize{ 25, 50, 75 };

    for (load_pcts) |pct| {
        const fill = N * pct / 100;
        var times: [MEASURED]u64 = undefined;

        for (0..TOTAL_RUNS) |r| {
            var map = StringElasticHash.init(allocator, N) catch @panic("init");
            defer map.deinit();

            // Fill to target load
            for (0..fill) |i| map.insert(&key_pool[i], i);

            var live_count: usize = fill;
            var next_insert: usize = fill;
            var miss_idx: usize = 0;

            const start = now();

            for (0..OPS_PER_RUN) |i| {
                const op = ops[i];
                if (op < 4) {
                    // Hit lookup: pick a random key from those inserted
                    if (live_count > 0) {
                        const ki = rand_indices[i] % live_count;
                        std.mem.doNotOptimizeAway(map.get(&key_pool[ki]));
                    }
                } else if (op < 8) {
                    // Miss lookup
                    std.mem.doNotOptimizeAway(map.get(&miss_pool[miss_idx % OPS_PER_RUN]));
                    miss_idx += 1;
                } else if (op == 8) {
                    // Insert new key
                    if (next_insert < key_pool_size) {
                        map.insert(&key_pool[next_insert], next_insert);
                        next_insert += 1;
                        live_count += 1;
                    }
                } else {
                    // Delete random existing key
                    if (live_count > 0) {
                        const ki = rand_indices[i] % live_count;
                        _ = map.remove(&key_pool[ki]);
                        // Note: live_count tracking is approximate since we don't
                        // track which specific keys are live. This is intentional —
                        // some "hit" lookups will become misses as keys are deleted,
                        // which is realistic.
                    }
                }
            }

            const end = now();
            const total_us = usElapsed(start, end);

            if (r >= WARMUP) {
                times[r - WARMUP] = total_us;
            }
        }

        const ops_per_sec = OPS_PER_RUN * 1_000_000 / median(&times);
        std.debug.print("MIXED\tload={d}\ttotal_us={d}\tops_per_sec={d}\n", .{
            pct, median(&times), ops_per_sec,
        });
    }

    std.debug.print("\nDONE\n", .{});
}
