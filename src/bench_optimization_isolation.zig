//! Optimization isolation: test each of our 3 advantages independently.
//!
//! Variants:
//!   A. ALL ON:  8-bit FP + entry prefetch + cold-hinted matchEmpty (our current design)
//!   B. NO PREFETCH: 8-bit FP + cold-hinted matchEmpty, but no entry prefetch
//!   C. 7-BIT FP: 7-bit fingerprints (like hashbrown) + entry prefetch + cold matchEmpty
//!   D. NONE: 7-bit FP, no prefetch, no cold hint (mimics hashbrown's approach in our layout)
//!
//! This tells us exactly how much each optimization contributes.
const std = @import("std");
const Wyhash = std.hash.Wyhash;

const BUCKET_SIZE = 16;
const MAX_PROBES = 7;
const TOMBSTONE: u8 = 0xFF;
const FpVector = @Vector(BUCKET_SIZE, u8);

inline fn matchFp(fps: *const [BUCKET_SIZE]u8, fp: u8) u16 {
    const v: FpVector = fps.*;
    const n: FpVector = @splat(fp);
    return @bitCast(v == n);
}

inline fn matchEmptyVec(fps: *const [BUCKET_SIZE]u8) u16 {
    const v: FpVector = fps.*;
    const z: FpVector = @splat(0);
    return @bitCast(v == z);
}

inline fn matchEmptyOrTomb(fps: *const [BUCKET_SIZE]u8) u16 {
    const v: FpVector = fps.*;
    const z: FpVector = @splat(0);
    const t: FpVector = @splat(TOMBSTONE);
    const eb: u16 = @bitCast(v == z);
    const tb: u16 = @bitCast(v == t);
    return eb | tb;
}

const Entry = struct {
    key_ptr: [*]const u8,
    key_len: usize,
    value: u64,
    fn key(self: Entry) []const u8 { return self.key_ptr[0..self.key_len]; }
};

inline fn doHash(k: []const u8) u64 { return Wyhash.hash(0, k); }

// 8-bit fingerprint: uses full byte, avoids 0 and 0xFF
inline fn fp8(h: u64) u8 {
    const fp: u8 = @truncate(h >> 32);
    return if (fp == 0) 1 else if (fp == TOMBSTONE) 0xFE else fp;
}

// 7-bit fingerprint: 128 unique values (vs 253 for 8-bit).
// Uses bits 32-38 (same region as fp8, just fewer bits) to ensure
// independence from bucket index (which uses the top bits).
// Range: 1-128. Avoids 0 (empty) and 0xFF (tombstone).
inline fn fp7(h: u64) u8 {
    const raw: u8 = @truncate(h >> 32);
    return (raw & 0x7F) + 1; // 1-128
}

fn GenericFlatHash(comptime use_8bit_fp: bool, comptime use_prefetch: bool, comptime use_cold_hint: bool) type {
    return struct {
        const Self = @This();
        fingerprints: [][BUCKET_SIZE]u8,
        entries: [][BUCKET_SIZE]Entry,
        bucket_mask: usize,
        bucket_shift: u6,
        num_buckets: usize,
        count: usize = 0,

        fn init(allocator: std.mem.Allocator, n: usize) !Self {
            const cap = std.math.ceilPowerOfTwo(usize, @max(n, BUCKET_SIZE * 2)) catch n;
            const nb = cap / BUCKET_SIZE;
            const fps = try allocator.alloc([BUCKET_SIZE]u8, nb);
            const ents = try allocator.alloc([BUCKET_SIZE]Entry, nb);
            for (fps) |*b| @memset(b, 0);
            return .{
                .fingerprints = fps, .entries = ents, .num_buckets = nb,
                .bucket_mask = nb - 1,
                .bucket_shift = @intCast(@min(63, 64 - @ctz(nb))),
            };
        }
        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.fingerprints);
            allocator.free(self.entries);
        }

        inline fn makeFp(h: u64) u8 {
            return if (use_8bit_fp) fp8(h) else fp7(h);
        }

        fn insert(self: *Self, k: []const u8, value: u64) void {
            const h = doHash(k);
            const fp = makeFp(h);
            const base = h >> self.bucket_shift;
            for (0..MAX_PROBES) |probe| {
                const bi = (base +% @as(u64, probe)) & self.bucket_mask;
                const m = matchEmptyOrTomb(&self.fingerprints[bi]);
                if (m != 0) {
                    const slot = @ctz(m);
                    self.fingerprints[bi][slot] = fp;
                    self.entries[bi][slot] = .{ .key_ptr = k.ptr, .key_len = k.len, .value = value };
                    self.count += 1;
                    return;
                }
            }
        }

        fn get(self: *const Self, k: []const u8) ?u64 {
            const h = doHash(k);
            const fp = makeFp(h);
            const base = h >> self.bucket_shift;

            if (use_prefetch) {
                @prefetch(@as([*]const u8, @ptrCast(&self.entries[base & self.bucket_mask])), .{ .rw = .read, .locality = 3 });
            }

            for (0..MAX_PROBES) |probe| {
                const bi = (base +% @as(u64, probe)) & self.bucket_mask;
                var m = matchFp(&self.fingerprints[bi], fp);
                while (m != 0) {
                    const s = @ctz(m);
                    if (std.mem.eql(u8, self.entries[bi][s].key(), k)) return self.entries[bi][s].value;
                    m &= m - 1;
                }
                if (matchEmptyVec(&self.fingerprints[bi]) != 0) {
                    if (use_cold_hint) {
                        @branchHint(.cold);
                    }
                    return null;
                }
            }
            return null;
        }

        fn remove(self: *Self, k: []const u8) bool {
            const h = doHash(k);
            const fp = makeFp(h);
            const base = h >> self.bucket_shift;
            for (0..MAX_PROBES) |probe| {
                const bi = (base +% @as(u64, probe)) & self.bucket_mask;
                var m = matchFp(&self.fingerprints[bi], fp);
                while (m != 0) {
                    const s = @ctz(m);
                    if (std.mem.eql(u8, self.entries[bi][s].key(), k)) {
                        self.fingerprints[bi][s] = TOMBSTONE;
                        self.count -= 1;
                        return true;
                    }
                    m &= m - 1;
                }
            }
            return false;
        }
    };
}

// Four variants
const AllOn = GenericFlatHash(true, true, true);      // Our design
const NoPrefetch = GenericFlatHash(true, false, true); // Remove prefetch
const SevenBitFp = GenericFlatHash(false, true, true); // 7-bit FP like hashbrown
const NoneOn = GenericFlatHash(false, false, false);   // Mimic hashbrown's approach

// ---- Harness ----
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
    while (i > 0) { i -= 1; buf[i] = hex_chars[@intCast(v & 0xF)]; v >>= 4; }
}

fn median(arr: *[MEASURED]u64) u64 {
    std.mem.sort(u64, arr, {}, std.sort.asc(u64));
    return arr[MEASURED / 2];
}

fn doNotOptimize(val: anytype) void {
    const ptr: *const volatile @TypeOf(val) = &val;
    _ = ptr.*;
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc" : [lo] "={eax}" (lo), [hi] "={edx}" (hi));
    return (@as(u64, hi) << 32) | lo;
}

const CYC_PER_US = 3500;

fn benchVariant(comptime T: type, comptime name: []const u8, allocator: std.mem.Allocator, n: usize, fill: usize, pct: usize, key_buf: [][16]u8, miss_buf: [][16]u8, order: []usize) void {
    var hit_arr: [MEASURED]u64 = undefined;
    var miss_arr: [MEASURED]u64 = undefined;
    var ins_arr: [MEASURED]u64 = undefined;
    var del_arr: [MEASURED]u64 = undefined;

    for (0..TOTAL_RUNS) |r| {
        var map = T.init(allocator, n) catch @panic("init");

        var t = rdtsc();
        for (0..fill) |idx| map.insert(&key_buf[idx], idx);
        const ins = (rdtsc() - t) / CYC_PER_US;

        t = rdtsc();
        for (0..fill) |idx| doNotOptimize(map.get(&key_buf[order[idx]]));
        const hit = (rdtsc() - t) / CYC_PER_US;

        t = rdtsc();
        for (0..fill) |idx| doNotOptimize(map.get(&miss_buf[order[idx]]));
        const miss = (rdtsc() - t) / CYC_PER_US;

        t = rdtsc();
        for (0..fill / 2) |idx| doNotOptimize(map.remove(&key_buf[idx]));
        const del = (rdtsc() - t) / CYC_PER_US;

        if (r >= WARMUP) {
            const ri = r - WARMUP;
            ins_arr[ri] = ins;
            hit_arr[ri] = hit;
            miss_arr[ri] = miss;
            del_arr[ri] = del;
        }
        map.deinit(allocator);
    }

    std.debug.print("{s}\tn={d}\tload={d}\thit={d}\tmiss={d}\tins={d}\tdel={d}\n", .{
        name, n, pct,
        median(&hit_arr), median(&miss_arr),
        median(&ins_arr), median(&del_arr),
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Test at sizes that matter: small (cold), medium (sweet spot), large
    const configs = [_]struct { n: usize, pct: usize }{
        .{ .n = 256, .pct = 50 },       // tiny - fits in L1
        .{ .n = 1024, .pct = 50 },      // small - fits in L1
        .{ .n = 16384, .pct = 50 },     // medium-small
        .{ .n = 65536, .pct = 50 },     // medium
        .{ .n = 262144, .pct = 50 },    // medium-large
        .{ .n = 1048576, .pct = 50 },   // large (sweet spot)
        .{ .n = 4194304, .pct = 50 },   // very large
        // High load tests at 1M
        .{ .n = 1048576, .pct = 75 },
        .{ .n = 1048576, .pct = 90 },
        .{ .n = 1048576, .pct = 99 },
    };

    std.debug.print("=== OPTIMIZATION ISOLATION (string keys, shuffled) ===\n", .{});
    std.debug.print("all_on = 8-bit FP + prefetch + cold hint\n", .{});
    std.debug.print("no_prefetch = 8-bit FP + cold hint, NO prefetch\n", .{});
    std.debug.print("7bit_fp = 7-bit FP + prefetch + cold hint\n", .{});
    std.debug.print("none = 7-bit FP, no prefetch, no cold hint (hashbrown-like)\n\n", .{});

    for (configs) |cfg| {
        const n = cfg.n;
        const pct = cfg.pct;
        const fill = n * pct / 100;
        if (fill == 0) continue;

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
        const order = try allocator.alloc(usize, fill);
        defer allocator.free(order);
        for (0..fill) |i| order[i] = i;
        var rng: u64 = 42;
        var ii = fill;
        while (ii > 1) { ii -= 1; const j = splitmix64(&rng) % (ii + 1); const tmp = order[ii]; order[ii] = order[j]; order[j] = tmp; }

        benchVariant(AllOn, "all_on", allocator, n, fill, pct, key_buf, miss_buf, order);
        benchVariant(NoPrefetch, "no_prefetch", allocator, n, fill, pct, key_buf, miss_buf, order);
        benchVariant(SevenBitFp, "7bit_fp", allocator, n, fill, pct, key_buf, miss_buf, order);
        benchVariant(NoneOn, "none", allocator, n, fill, pct, key_buf, miss_buf, order);
        std.debug.print("\n", .{});
    }
}
