//! Allocation isolation test: does putting fingerprints and entries in
//! ONE contiguous allocation vs TWO separate allocations matter?
//!
//! Both implementations are identical flat hash tables with:
//! - Same SIMD fingerprint matching
//! - Same linear probing (MAX_PROBES=7)
//! - Same hash function (wyhash)
//! - Same 8-bit fingerprints
//! - Same cold-hinted matchEmpty
//! - Same entry prefetch at probe 0
//!
//! The ONLY difference is allocation strategy.
const std = @import("std");
const Wyhash = std.hash.Wyhash;

const BUCKET_SIZE = 16;
const MAX_PROBES = 7;
const TOMBSTONE: u8 = 0xFF;
const FpVector = @Vector(BUCKET_SIZE, u8);

inline fn matchFingerprint(fps: *const [BUCKET_SIZE]u8, fp: u8) u16 {
    const fp_vec: FpVector = fps.*;
    const needle: FpVector = @splat(fp);
    return @bitCast(fp_vec == needle);
}

inline fn matchEmpty(fps: *const [BUCKET_SIZE]u8) u16 {
    const fp_vec: FpVector = fps.*;
    const zeros: FpVector = @splat(0);
    return @bitCast(fp_vec == zeros);
}

inline fn matchEmptyOrTombstone(fps: *const [BUCKET_SIZE]u8) u16 {
    const fp_vec: FpVector = fps.*;
    const zeros: FpVector = @splat(0);
    const tombstones: FpVector = @splat(TOMBSTONE);
    const empty_bits: u16 = @bitCast(fp_vec == zeros);
    const tomb_bits: u16 = @bitCast(fp_vec == tombstones);
    return empty_bits | tomb_bits;
}

const StringEntry = struct {
    key_ptr: [*]const u8,
    key_len: usize,
    value: u64,
    fn key(self: StringEntry) []const u8 {
        return self.key_ptr[0..self.key_len];
    }
};

inline fn hash(k: []const u8) u64 {
    return Wyhash.hash(0, k);
}

inline fn fingerprint(h: u64) u8 {
    const fp: u8 = @truncate(h >> 32);
    return if (fp == 0) 1 else if (fp == TOMBSTONE) 0xFE else fp;
}

// ============================================================
// Version A: TWO SEPARATE ALLOCATIONS (our current approach)
// ============================================================
const SeparateAllocHash = struct {
    const Self = @This();
    fingerprints: [][BUCKET_SIZE]u8,
    entries: [][BUCKET_SIZE]StringEntry,
    bucket_mask: usize,
    bucket_shift: u6,
    num_buckets: usize,
    count: usize = 0,

    fn init(allocator: std.mem.Allocator, n: usize) !Self {
        const capacity = std.math.ceilPowerOfTwo(usize, @max(n, BUCKET_SIZE * 2)) catch n;
        const num_buckets = capacity / BUCKET_SIZE;
        const fingerprints = try allocator.alloc([BUCKET_SIZE]u8, num_buckets);
        const entries = try allocator.alloc([BUCKET_SIZE]StringEntry, num_buckets);
        for (fingerprints) |*b| @memset(b, 0);
        return .{
            .fingerprints = fingerprints,
            .entries = entries,
            .num_buckets = num_buckets,
            .bucket_mask = num_buckets - 1,
            .bucket_shift = @intCast(@min(63, 64 - @ctz(num_buckets))),
        };
    }
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.fingerprints);
        allocator.free(self.entries);
    }
    fn insert(self: *Self, k: []const u8, value: u64) void {
        const h = hash(k);
        const fp = fingerprint(h);
        const base = h >> self.bucket_shift;
        for (0..MAX_PROBES) |probe| {
            const bi = (base +% @as(u64, probe)) & self.bucket_mask;
            const m = matchEmptyOrTombstone(&self.fingerprints[bi]);
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
        const h = hash(k);
        const fp = fingerprint(h);
        const base = h >> self.bucket_shift;
        @prefetch(@as([*]const u8, @ptrCast(&self.entries[base & self.bucket_mask])), .{ .rw = .read, .locality = 3 });
        for (0..MAX_PROBES) |probe| {
            const bi = (base +% @as(u64, probe)) & self.bucket_mask;
            var m = matchFingerprint(&self.fingerprints[bi], fp);
            while (m != 0) {
                const s = @ctz(m);
                if (std.mem.eql(u8, self.entries[bi][s].key(), k)) return self.entries[bi][s].value;
                m &= m - 1;
            }
            if (matchEmpty(&self.fingerprints[bi]) != 0) {
                @branchHint(.cold);
                return null;
            }
        }
        return null;
    }
    fn remove(self: *Self, k: []const u8) bool {
        const h = hash(k);
        const fp = fingerprint(h);
        const base = h >> self.bucket_shift;
        for (0..MAX_PROBES) |probe| {
            const bi = (base +% @as(u64, probe)) & self.bucket_mask;
            var m = matchFingerprint(&self.fingerprints[bi], fp);
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

// ============================================================
// Version B: ONE CONTIGUOUS ALLOCATION (abseil's approach)
// Fingerprints first, then entries, in a single mmap/alloc.
// ============================================================
const SingleAllocHash = struct {
    const Self = @This();
    // Single backing allocation
    backing: []u8,
    // Pointers into the backing allocation
    fingerprints: [*][BUCKET_SIZE]u8,
    entries: [*][BUCKET_SIZE]StringEntry,
    bucket_mask: usize,
    bucket_shift: u6,
    num_buckets: usize,
    count: usize = 0,

    fn init(allocator: std.mem.Allocator, n: usize) !Self {
        const capacity = std.math.ceilPowerOfTwo(usize, @max(n, BUCKET_SIZE * 2)) catch n;
        const num_buckets = capacity / BUCKET_SIZE;

        // Calculate layout: [fingerprints][padding][entries]
        const fp_size = num_buckets * BUCKET_SIZE;
        // Align entries to 64 bytes (cache line) after fingerprints
        const entry_offset = std.mem.alignForward(usize, fp_size, 64);
        const entry_size = num_buckets * BUCKET_SIZE * @sizeOf(StringEntry);
        const total_size = entry_offset + entry_size;

        const backing = try allocator.alloc(u8, total_size);
        @memset(backing[0..fp_size], 0); // zero fingerprints

        const fp_ptr: [*][BUCKET_SIZE]u8 = @ptrCast(@alignCast(backing.ptr));
        const entry_ptr: [*][BUCKET_SIZE]StringEntry = @ptrCast(@alignCast(backing.ptr + entry_offset));

        return .{
            .backing = backing,
            .fingerprints = fp_ptr,
            .entries = entry_ptr,
            .num_buckets = num_buckets,
            .bucket_mask = num_buckets - 1,
            .bucket_shift = @intCast(@min(63, 64 - @ctz(num_buckets))),
        };
    }
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.backing);
    }
    fn insert(self: *Self, k: []const u8, value: u64) void {
        const h = hash(k);
        const fp = fingerprint(h);
        const base = h >> self.bucket_shift;
        for (0..MAX_PROBES) |probe| {
            const bi = (base +% @as(u64, probe)) & self.bucket_mask;
            const m = matchEmptyOrTombstone(&self.fingerprints[bi]);
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
        const h = hash(k);
        const fp = fingerprint(h);
        const base = h >> self.bucket_shift;
        @prefetch(@as([*]const u8, @ptrCast(&self.entries[base & self.bucket_mask])), .{ .rw = .read, .locality = 3 });
        for (0..MAX_PROBES) |probe| {
            const bi = (base +% @as(u64, probe)) & self.bucket_mask;
            var m = matchFingerprint(&self.fingerprints[bi], fp);
            while (m != 0) {
                const s = @ctz(m);
                if (std.mem.eql(u8, self.entries[bi][s].key(), k)) return self.entries[bi][s].value;
                m &= m - 1;
            }
            if (matchEmpty(&self.fingerprints[bi]) != 0) {
                @branchHint(.cold);
                return null;
            }
        }
        return null;
    }
    fn remove(self: *Self, k: []const u8) bool {
        const h = hash(k);
        const fp = fingerprint(h);
        const base = h >> self.bucket_shift;
        for (0..MAX_PROBES) |probe| {
            const bi = (base +% @as(u64, probe)) & self.bucket_mask;
            var m = matchFingerprint(&self.fingerprints[bi], fp);
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

// ============================================================
// Benchmark harness
// ============================================================
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

const CYCLES_PER_US = 3500;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const sizes = [_]usize{ 16384, 65536, 262144, 1048576, 4194304 };
    const loads = [_]usize{ 25, 50, 75, 90 };

    std.debug.print("=== ALLOCATION ISOLATION: separate vs single (identical code otherwise) ===\n\n", .{});

    for (sizes) |n| {
        for (loads) |pct| {
            const fill = n * pct / 100;

            const key_buf = try allocator.alloc([16]u8, fill);
            defer allocator.free(key_buf);
            const miss_buf = try allocator.alloc([16]u8, fill);
            defer allocator.free(miss_buf);
            var ks: u64 = 0xDEADBEEF12345678;
            var ms: u64 = 0xCAFEBABE87654321;
            for (0..fill) |idx| {
                u64ToHex(splitmix64(&ks), &key_buf[idx]);
                u64ToHex(splitmix64(&ms), &miss_buf[idx]);
            }

            const order = try allocator.alloc(usize, fill);
            defer allocator.free(order);
            for (0..fill) |idx| order[idx] = idx;
            var rng: u64 = 42;
            var ii = fill;
            while (ii > 1) { ii -= 1; const j = splitmix64(&rng) % (ii + 1); const tmp = order[ii]; order[ii] = order[j]; order[j] = tmp; }

            // Bench separate allocation
            var sep_hit: [MEASURED]u64 = undefined;
            var sep_miss: [MEASURED]u64 = undefined;
            var sep_ins: [MEASURED]u64 = undefined;
            for (0..TOTAL_RUNS) |r| {
                var map = try SeparateAllocHash.init(allocator, n);
                var t = rdtsc();
                for (0..fill) |idx| map.insert(&key_buf[idx], idx);
                const ins = (rdtsc() - t) / CYCLES_PER_US;
                t = rdtsc();
                for (0..fill) |idx| doNotOptimize(map.get(&key_buf[order[idx]]));
                const hit = (rdtsc() - t) / CYCLES_PER_US;
                t = rdtsc();
                for (0..fill) |idx| doNotOptimize(map.get(&miss_buf[order[idx]]));
                const miss = (rdtsc() - t) / CYCLES_PER_US;
                if (r >= WARMUP) { const ri = r - WARMUP; sep_ins[ri] = ins; sep_hit[ri] = hit; sep_miss[ri] = miss; }
                map.deinit(allocator);
            }

            // Bench single allocation
            var single_hit: [MEASURED]u64 = undefined;
            var single_miss: [MEASURED]u64 = undefined;
            var single_ins: [MEASURED]u64 = undefined;
            for (0..TOTAL_RUNS) |r| {
                var map = try SingleAllocHash.init(allocator, n);
                var t = rdtsc();
                for (0..fill) |idx| map.insert(&key_buf[idx], idx);
                const ins = (rdtsc() - t) / CYCLES_PER_US;
                t = rdtsc();
                for (0..fill) |idx| doNotOptimize(map.get(&key_buf[order[idx]]));
                const hit = (rdtsc() - t) / CYCLES_PER_US;
                t = rdtsc();
                for (0..fill) |idx| doNotOptimize(map.get(&miss_buf[order[idx]]));
                const miss = (rdtsc() - t) / CYCLES_PER_US;
                if (r >= WARMUP) { const ri = r - WARMUP; single_ins[ri] = ins; single_hit[ri] = hit; single_miss[ri] = miss; }
                map.deinit(allocator);
            }

            const sh = median(&sep_hit);
            const gh = median(&single_hit);
            const sm = median(&sep_miss);
            const gm = median(&single_miss);
            const si = median(&sep_ins);
            const gi = median(&single_ins);
            std.debug.print("n={d}\tload={d}\tsep_hit={d}\tsingle_hit={d}\thit_ratio={d:.3}\tsep_miss={d}\tsingle_miss={d}\tmiss_ratio={d:.3}\tsep_ins={d}\tsingle_ins={d}\tins_ratio={d:.3}\n", .{
                n, pct,
                sh, gh, @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(@max(gh, 1))),
                sm, gm, @as(f64, @floatFromInt(sm)) / @as(f64, @floatFromInt(@max(gm, 1))),
                si, gi, @as(f64, @floatFromInt(si)) / @as(f64, @floatFromInt(@max(gi, 1))),
            });
        }
        std.debug.print("\n", .{});
    }
}
