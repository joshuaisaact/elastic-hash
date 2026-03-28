//! Head-to-head benchmark: flat hash vs tiered elastic hash.
//! Same hash, same SIMD, same fingerprints, same growth policy.
//! Only difference: flat has no tiers, no bloom filter, no overflow.
const std = @import("std");
const FlatHash = @import("flat_hash.zig").FlatHash;
const StringElasticHashGrowth = @import("string_hybrid_growth.zig").StringElasticHashGrowth;
const Wyhash = std.hash.Wyhash;

const TOTAL_RUNS = 12;
const WARMUP = 2;
const MEASURED = TOTAL_RUNS - WARMUP;

fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

const hex_chars = "0123456789abcdef";

fn u64ToHex(val: u64, buf: *[16]u8) void {
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex_chars[@intCast(v & 0xF)];
        v >>= 4;
    }
}

fn median(arr: *[MEASURED]u64) u64 {
    std.mem.sort(u64, arr, {}, std.sort.asc(u64));
    return arr[MEASURED / 2];
}

fn now() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

// i5-13600K base ~3.5GHz, so ~3500 cycles/us. Use 3500 as conversion.
const CYCLES_PER_US = 3500;

fn elapsedUs(start: u64) u64 {
    return (now() - start) / CYCLES_PER_US;
}

fn doNotOptimize(val: anytype) void {
    const ptr: *const volatile @TypeOf(val) = &val;
    _ = ptr.*;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const sizes = [_]usize{ 16384, 65536, 262144, 1048576, 4194304 };
    const loads = [_]usize{ 25, 50, 75, 90, 99 };

    std.debug.print("=== FLAT vs TIERED: Zig head-to-head (string keys, shuffled) ===\n\n", .{});

    for (sizes) |n| {
        for (loads) |pct| {
            const fill = n * pct / 100;

            // Generate keys
            const key_buf = try allocator.alloc([16]u8, fill);
            defer allocator.free(key_buf);
            const miss_buf = try allocator.alloc([16]u8, fill);
            defer allocator.free(miss_buf);
            var ks: u64 = 0xDEADBEEF12345678;
            var ms: u64 = 0xCAFEBABE87654321;
            for (0..fill) |i| {
                u64ToHex(splitmix64(&ks), &key_buf[i]);
                u64ToHex(splitmix64(&ms), &miss_buf[i]);
            }

            // Shuffle order
            const order = try allocator.alloc(usize, fill);
            defer allocator.free(order);
            for (0..fill) |i| order[i] = i;
            var rng: u64 = 42;
            var i = fill;
            while (i > 1) {
                i -= 1;
                const j = splitmix64(&rng) % (i + 1);
                const tmp = order[i];
                order[i] = order[j];
                order[j] = tmp;
            }

            // Benchmark flat hash
            var flat_hit: [MEASURED]u64 = undefined;
            var flat_miss: [MEASURED]u64 = undefined;
            var flat_ins: [MEASURED]u64 = undefined;
            var flat_del: [MEASURED]u64 = undefined;

            for (0..TOTAL_RUNS) |r| {
                var map = try FlatHash.init(allocator, n);

                var t = now();
                for (0..fill) |idx| map.insert(&key_buf[idx], idx);
                const ins_us = elapsedUs(t);

                t = now();
                for (0..fill) |idx| doNotOptimize(map.get(&key_buf[order[idx]]));
                const hit_us = elapsedUs(t);

                t = now();
                for (0..fill) |idx| doNotOptimize(map.get(&miss_buf[order[idx]]));
                const miss_us = elapsedUs(t);

                t = now();
                for (0..fill / 2) |idx| doNotOptimize(map.remove(&key_buf[idx]));
                const del_us = elapsedUs(t);

                if (r >= WARMUP) {
                    const idx2 = r - WARMUP;
                    flat_ins[idx2] = ins_us;
                    flat_hit[idx2] = hit_us;
                    flat_miss[idx2] = miss_us;
                    flat_del[idx2] = del_us;
                }

                map.deinit();
            }

            // Benchmark tiered (elastic) hash
            var tier_hit: [MEASURED]u64 = undefined;
            var tier_miss: [MEASURED]u64 = undefined;
            var tier_ins: [MEASURED]u64 = undefined;
            var tier_del: [MEASURED]u64 = undefined;

            for (0..TOTAL_RUNS) |r| {
                var map = try StringElasticHashGrowth.init(allocator, n);

                var t = now();
                for (0..fill) |idx| map.insert(&key_buf[idx], idx);
                const ins_us = elapsedUs(t);

                t = now();
                for (0..fill) |idx| doNotOptimize(map.get(&key_buf[order[idx]]));
                const hit_us = elapsedUs(t);

                t = now();
                for (0..fill) |idx| doNotOptimize(map.get(&miss_buf[order[idx]]));
                const miss_us = elapsedUs(t);

                t = now();
                for (0..fill / 2) |idx| doNotOptimize(map.remove(&key_buf[idx]));
                const del_us = elapsedUs(t);

                if (r >= WARMUP) {
                    const idx2 = r - WARMUP;
                    tier_ins[idx2] = ins_us;
                    tier_hit[idx2] = hit_us;
                    tier_miss[idx2] = miss_us;
                    tier_del[idx2] = del_us;
                }

                map.deinit();
            }

            const fh = median(&flat_hit);
            const th = median(&tier_hit);
            const fm = median(&flat_miss);
            const tm = median(&tier_miss);
            const fi = median(&flat_ins);
            const ti = median(&tier_ins);
            const fd = median(&flat_del);
            const td = median(&tier_del);

            std.debug.print("n={d}\tload={d}\tflat_hit={d}\ttier_hit={d}\thit_ratio={d:.2}\tflat_miss={d}\ttier_miss={d}\tmiss_ratio={d:.2}\tflat_ins={d}\ttier_ins={d}\tins_ratio={d:.2}\tflat_del={d}\ttier_del={d}\tdel_ratio={d:.2}\n", .{
                n,                                                       pct,
                fh,                                                      th,
                @as(f64, @floatFromInt(fh)) / @as(f64, @floatFromInt(@max(th, 1))),
                fm,                                                      tm,
                @as(f64, @floatFromInt(fm)) / @as(f64, @floatFromInt(@max(tm, 1))),
                fi,                                                      ti,
                @as(f64, @floatFromInt(fi)) / @as(f64, @floatFromInt(@max(ti, 1))),
                fd,                                                      td,
                @as(f64, @floatFromInt(fd)) / @as(f64, @floatFromInt(@max(td, 1))),
            });
        }
        std.debug.print("\n", .{});
    }
}
