//! Autoresearch v2 benchmark: elastic hash timing for comparison against abseil.
//! Uses random keys (splitmix64, same seed as bench-abseil.cpp), median of 10 runs.
const std = @import("std");
const HybridElasticHash = @import("hybrid.zig").HybridElasticHash;
const linux = std.os.linux;
const sort = std.sort;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
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

fn benchOne(allocator: std.mem.Allocator, n: usize, fill: usize, load_pct: usize) void {
    // Pre-generate keys (identical to bench-abseil.cpp)
    const keys = allocator.alloc(u64, fill) catch @panic("alloc keys");
    defer allocator.free(keys);
    const miss_keys = allocator.alloc(u64, fill) catch @panic("alloc miss_keys");
    defer allocator.free(miss_keys);

    var ks: u64 = KEY_SEED;
    var ms: u64 = MISS_SEED;
    for (0..fill) |i| {
        keys[i] = splitmix64(&ks);
        miss_keys[i] = splitmix64(&ms);
    }

    var ins: [MEASURED]u64 = undefined;
    var lkp: [MEASURED]u64 = undefined;
    var del: [MEASURED]u64 = undefined;
    var mis: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = HybridElasticHash.init(allocator, n) catch @panic("init failed");
        defer map.deinit();

        var start = now();
        for (0..fill) |i| {
            map.insert(keys[i], i);
        }
        var end = now();
        const insert_us = usElapsed(start, end);

        start = now();
        for (0..fill) |i| {
            std.mem.doNotOptimizeAway(map.get(keys[i]));
        }
        end = now();
        const lookup_us = usElapsed(start, end);

        start = now();
        for (0..fill) |i| {
            std.mem.doNotOptimizeAway(map.get(miss_keys[i]));
        }
        end = now();
        const miss_us = usElapsed(start, end);

        // One-time tier/probe distribution print (BEFORE delete)
        if (r == 0 and load_pct == 99 and n == 1_048_576) {
            std.debug.print("--- Distribution at n={d}, fill={d} ---\n", .{ n, fill });
            for (0..map.num_tiers) |t| {
                if (map.tier_slot_counts[t] > 0)
                    std.debug.print("  tier {d}: {d} elements in {d} buckets\n", .{ t, map.tier_slot_counts[t], map.tier_bucket_counts[t] });
            }
            // Count by findability
            var found_get: usize = 0;
            var found_probes: usize = 0;
            for (0..fill) |i| {
                if (map.get(keys[i]) != null) found_get += 1;
                const r2 = map.getWithProbes(keys[i]);
                if (r2.value != null) found_probes += 1;
            }
            std.debug.print("  get() finds:          {d}/{d} ({d:.1}%)\n", .{ found_get, fill, @as(f64, @floatFromInt(found_get)) / @as(f64, @floatFromInt(fill)) * 100 });
            std.debug.print("  getWithProbes() finds: {d}/{d} ({d:.1}%)\n", .{ found_probes, fill, @as(f64, @floatFromInt(found_probes)) / @as(f64, @floatFromInt(fill)) * 100 });
            // Trace first unfindable element
            var trace_ks: u64 = KEY_SEED;
            for (0..fill) |ii| {
                const k = splitmix64(&trace_ks);
                const r2 = map.getWithProbes(k);
                if (r2.value == null) {
                    const hh = k *% 0x517cc1b727220a95;
                    const hx = hh ^ (hh >> 32);
                    const fpp: u8 = @truncate(hx >> 32);
                    const expected_fp = if (fpp == 0) @as(u8, 1) else if (fpp == 0xFF) @as(u8, 0xFE) else fpp;
                    std.debug.print("  MISS: i={d} key={x} hash={x} fp={d}\n", .{ ii, k, hx, expected_fp });
                    // Brute-force scan to find where this key is stored
                    var scan_found = false;
                    for (0..map.total_buckets) |b| {
                        for (0..16) |s| {
                            if (map.entries[b][s].key == k) {
                                std.debug.print("  FOUND at bucket={d} slot={d} stored_fp={d}\n\n", .{ b, s, map.fingerprints[b][s] });
                                scan_found = true;
                            }
                        }
                    }
                    if (!scan_found) std.debug.print("  NOT IN TABLE AT ALL\n\n", .{});
                    break;
                }
            }
        }

        start = now();
        for (0..fill / 2) |i| {
            std.mem.doNotOptimizeAway(map.remove(keys[i]));
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

    std.debug.print("\n=== Autoresearch v2 Benchmark (median of {d}, {d} warmup) ===\n\n", .{ MEASURED, WARMUP });

    // All sizes at 99% load
    const sizes = [_]usize{ 16_384, 65_536, 262_144, 1_048_576, 2_097_152 };
    for (sizes) |n| {
        benchOne(allocator, n, n * 99 / 100, 99);
    }

    // Multiple load factors at 1M
    const load_pcts = [_]usize{ 10, 25, 50, 75, 90 };
    const n: usize = 1_048_576;
    for (load_pcts) |pct| {
        benchOne(allocator, n, n * pct / 100, pct);
    }

    std.debug.print("\nDONE\n", .{});
}
