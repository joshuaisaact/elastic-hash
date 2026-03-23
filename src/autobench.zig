//! Focused benchmark for autoresearch: hybrid elastic hash vs std.HashMap.
//! Outputs machine-parseable RESULT lines for the autoresearch loop.
//! DO NOT MODIFY - this is the evaluation harness.
const std = @import("std");
const HybridElasticHash = @import("hybrid.zig").HybridElasticHash;
const linux = std.os.linux;

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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const runs: usize = 5;

    const sizes = [_]usize{ 16_384, 65_536, 262_144, 1_048_576, 2_097_152 };

    std.debug.print("\n=== Autoresearch Benchmark: Hybrid vs std.HashMap (99% load, {d} runs) ===\n\n", .{runs});

    inline for (sizes) |n| {
        const fill = n * 99 / 100;

        var hybrid_insert_total: u64 = 0;
        var hybrid_lookup_total: u64 = 0;
        var hybrid_delete_total: u64 = 0;
        var std_insert_total: u64 = 0;
        var std_lookup_total: u64 = 0;
        var std_delete_total: u64 = 0;

        for (0..runs) |_| {
            // Hybrid
            {
                var map = try HybridElasticHash.init(allocator, n);
                defer map.deinit();

                var start = now();
                for (0..fill) |i| {
                    map.insert(i, i);
                }
                var end = now();
                hybrid_insert_total += usElapsed(start, end);

                start = now();
                for (0..fill) |i| {
                    std.mem.doNotOptimizeAway(map.get(i));
                }
                end = now();
                hybrid_lookup_total += usElapsed(start, end);

                start = now();
                for (0..fill / 2) |i| {
                    std.mem.doNotOptimizeAway(map.remove(i));
                }
                end = now();
                hybrid_delete_total += usElapsed(start, end);
            }

            // std.HashMap
            {
                const HighLoadHashMap = std.hash_map.HashMap(u64, u64, std.hash_map.AutoContext(u64), 99);
                var map = HighLoadHashMap.init(allocator);
                defer map.deinit();
                try map.ensureTotalCapacity(@intCast(fill));

                var start = now();
                for (0..fill) |i| {
                    map.putAssumeCapacity(i, i);
                }
                var end = now();
                std_insert_total += usElapsed(start, end);

                start = now();
                for (0..fill) |i| {
                    std.mem.doNotOptimizeAway(map.get(i));
                }
                end = now();
                std_lookup_total += usElapsed(start, end);

                start = now();
                for (0..fill / 2) |i| {
                    _ = map.fetchRemove(i);
                }
                end = now();
                std_delete_total += usElapsed(start, end);
            }
        }

        const h_ins = hybrid_insert_total / runs;
        const h_get = hybrid_lookup_total / runs;
        const h_del = hybrid_delete_total / runs;
        const s_ins = std_insert_total / runs;
        const s_get = std_lookup_total / runs;
        const s_del = std_delete_total / runs;

        const ins_ratio = @as(f64, @floatFromInt(s_ins)) / @as(f64, @floatFromInt(h_ins));
        const get_ratio = @as(f64, @floatFromInt(s_get)) / @as(f64, @floatFromInt(h_get));
        const del_ratio = @as(f64, @floatFromInt(s_del)) / @as(f64, @floatFromInt(h_del));

        std.debug.print("RESULT\tn={d}\tinsert_us={d}\tlookup_us={d}\tdelete_us={d}\tstd_insert_us={d}\tstd_lookup_us={d}\tstd_delete_us={d}\tinsert_ratio={d:.3}\tlookup_ratio={d:.3}\tdelete_ratio={d:.3}\n", .{
            n, h_ins, h_get, h_del, s_ins, s_get, s_del, ins_ratio, get_ratio, del_ratio,
        });
    }

    std.debug.print("\nDONE\n", .{});
}
