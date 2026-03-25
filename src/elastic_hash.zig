//! Generic elastic hash table: SIMD fingerprint buckets + tiered batch insertion.
//! Parameterized over key type K, value type V, and a Context providing hash/eql.
//! Follows the same comptime Context pattern as std.HashMap.
const std = @import("std");
const math = std.math;
const Wyhash = std.hash.Wyhash;

pub const BUCKET_SIZE = 16;
const MAX_PROBES = 7;
const TOMBSTONE: u8 = 0xFF;

const DELTA: f64 = 0.01;
const DELTA_HALF: f64 = DELTA / 2.0;
const PROBE_CONSTANT: f64 = 16.0;

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
    const tombstone_bits: u16 = @bitCast(fp_vec == tombstones);
    return empty_bits | tombstone_bits;
}

inline fn fingerprint(h: u64) u8 {
    const fp: u8 = @truncate(h >> 32);
    return if (fp == 0) 1 else if (fp == TOMBSTONE) 0xFE else fp;
}

/// Bloom filter bits derived from the hash. Uses bits 40-47 (independent
/// from fingerprint which uses bits 32-39). Sets 2 bits in a byte.
inline fn bloomBits(h: u64) u8 {
    const b1: u3 = @truncate(h >> 40);
    const b2: u3 = @truncate(h >> 43);
    return (@as(u8, 1) << b1) | (@as(u8, 1) << b2);
}

inline fn bucketIndex(h: u64, probe: usize, num_buckets: usize) usize {
    const bits: u7 = @intCast(@ctz(num_buckets));
    const shift: u6 = @intCast(@min(64 - bits, 63));
    const base = h >> shift;
    return (base +% @as(u64, probe)) & (num_buckets - 1);
}

fn probeLimit(epsilon: f64) usize {
    if (epsilon <= 0.0) return MAX_PROBES;
    const log_inv_eps = @log(1.0 / epsilon);
    const log_inv_delta = @log(1.0 / DELTA);
    const limit = PROBE_CONSTANT * @min(log_inv_eps * log_inv_eps, log_inv_delta);
    return @min(@as(usize, @intFromFloat(@max(1.0, limit))), MAX_PROBES);
}

/// Auto-generates hash and eql for common key types, matching std.hash_map.AutoContext.
pub fn AutoContext(comptime K: type) type {
    return struct {
        const Self = @This();

        pub fn hash(_: Self, key: K) u64 {
            if (comptime isSlice(K)) {
                return Wyhash.hash(0, sliceAsBytes(K, key));
            } else if (comptime isArray(K)) {
                return Wyhash.hash(0, std.mem.asBytes(&key));
            } else {
                return Wyhash.hash(0, std.mem.asBytes(&key));
            }
        }

        pub fn eql(_: Self, a: K, b: K) bool {
            if (comptime isSlice(K)) {
                return std.mem.eql(SliceChild(K), a, b);
            } else if (comptime isArray(K)) {
                const A = @typeInfo(K).array;
                return std.mem.eql(A.child, &a, &b);
            } else {
                return a == b;
            }
        }
    };
}

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice,
        else => false,
    };
}

fn isArray(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => true,
        else => false,
    };
}

fn SliceChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => @compileError("not a slice"),
    };
}

fn sliceAsBytes(comptime K: type, key: K) []const u8 {
    const child = SliceChild(K);
    if (child == u8) return key;
    const ptr: [*]const u8 = @ptrCast(key.ptr);
    return ptr[0 .. key.len * @sizeOf(child)];
}

/// Convenience alias: ElasticHash with auto-generated hash/eql.
pub fn AutoElasticHash(comptime K: type, comptime V: type) type {
    return ElasticHash(K, V, AutoContext(K));
}

pub fn ElasticHash(comptime K: type, comptime V: type, comptime Context: type) type {
    comptime {
        if (!@hasDecl(Context, "hash")) @compileError("Context must provide fn hash(ctx: Context, key: K) u64");
        if (!@hasDecl(Context, "eql")) @compileError("Context must provide fn eql(ctx: Context, a: K, b: K) bool");
    }

    return struct {
        const Self = @This();

        const Entry = struct {
            key: K,
            value: V,
        };

        const GetOverflowFn = *const fn (*const Self, u64, K, u8) ?V;

        // Hot path fields
        fingerprints: [][BUCKET_SIZE]u8,
        entries: [][BUCKET_SIZE]Entry,
        tier0_bucket_mask: usize,
        tier0_bucket_shift: u6,
        get_overflow_fn: GetOverflowFn,
        max_probe_depth: []u8,
        overflow_bloom: []u8,

        // Insert/management fields
        tier_starts: []usize,
        tier_bucket_counts: []usize,
        tier_slot_counts: []usize,
        tier0_bucket_count: usize,
        num_tiers: usize,
        total_buckets: usize,
        count: usize = 0,
        current_batch: usize = 0,
        capacity: usize = 0,
        allocator: std.mem.Allocator,
        ctx: Context,

        pub fn init(allocator: std.mem.Allocator, n: usize) !Self {
            return initContext(allocator, n, undefined_ctx());
        }

        pub fn initContext(allocator: std.mem.Allocator, n: usize, ctx: Context) !Self {
            const cap = std.math.ceilPowerOfTwo(usize, n) catch n;
            const tier0_buckets = @max(cap / BUCKET_SIZE, 1);
            const num_tiers = @max(1, std.math.log2_int(usize, tier0_buckets) + 1);

            const tier_starts = try allocator.alloc(usize, num_tiers);
            const tier_bucket_counts = try allocator.alloc(usize, num_tiers);
            const tier_slot_counts = try allocator.alloc(usize, num_tiers);

            var total_buckets: usize = 0;
            var buckets_in_tier = tier0_buckets;
            for (0..num_tiers) |i| {
                buckets_in_tier = @max(buckets_in_tier, 1);
                tier_starts[i] = total_buckets;
                tier_bucket_counts[i] = buckets_in_tier;
                tier_slot_counts[i] = 0;
                total_buckets += buckets_in_tier;
                buckets_in_tier /= 2;
            }

            const fingerprints = try allocator.alloc([BUCKET_SIZE]u8, total_buckets);
            const entries = try allocator.alloc([BUCKET_SIZE]Entry, total_buckets);
            const max_probe_depth = try allocator.alloc(u8, tier0_buckets);
            const overflow_bloom = try allocator.alloc(u8, tier0_buckets);

            for (fingerprints) |*bucket_fps| {
                @memset(bucket_fps, 0);
            }
            @memset(max_probe_depth, 0);
            @memset(overflow_bloom, 0);

            return .{
                .allocator = allocator,
                .ctx = ctx,
                .fingerprints = fingerprints,
                .entries = entries,
                .max_probe_depth = max_probe_depth,
                .overflow_bloom = overflow_bloom,
                .tier_starts = tier_starts,
                .tier_bucket_counts = tier_bucket_counts,
                .tier_slot_counts = tier_slot_counts,
                .num_tiers = num_tiers,
                .total_buckets = total_buckets,
                .tier0_bucket_count = tier_bucket_counts[0],
                .tier0_bucket_mask = tier_bucket_counts[0] - 1,
                .tier0_bucket_shift = @as(u6, @intCast(@min(63, 64 - @as(usize, @ctz(tier_bucket_counts[0]))))),
                .get_overflow_fn = &defaultGetOverflow,
                .capacity = tier_bucket_counts[0] * BUCKET_SIZE,
            };
        }

        fn undefined_ctx() Context {
            // For zero-sized contexts (like AutoContext), this is fine.
            // For contexts with state, use initContext.
            if (@sizeOf(Context) == 0) {
                return undefined;
            } else {
                @compileError("Context has state; use initContext and pass a Context instance");
            }
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.fingerprints);
            self.allocator.free(self.entries);
            self.allocator.free(self.max_probe_depth);
            self.allocator.free(self.overflow_bloom);
            self.allocator.free(self.tier_starts);
            self.allocator.free(self.tier_bucket_counts);
            self.allocator.free(self.tier_slot_counts);
        }

        inline fn getBucketIdx(self: *const Self, tier: usize, bucket_idx_: usize) usize {
            return self.tier_starts[tier] + bucket_idx_;
        }

        inline fn hashKey(self: *const Self, key: K) u64 {
            return self.ctx.hash(key);
        }

        inline fn keysEqual(self: *const Self, a: K, b: K) bool {
            return self.ctx.eql(a, b);
        }

        inline fn findKeyInBucket(self: *const Self, bucket_abs_idx: usize, key: K, fp: u8) ?usize {
            var mask = matchFingerprint(&self.fingerprints[bucket_abs_idx], fp);
            if (mask == 0) return null;
            const slot = @ctz(mask);
            if (self.keysEqual(self.entries[bucket_abs_idx][slot].key, key)) return slot;
            mask &= mask - 1;
            while (mask != 0) {
                const s = @ctz(mask);
                if (self.keysEqual(self.entries[bucket_abs_idx][s].key, key)) return s;
                mask &= mask - 1;
            }
            return null;
        }

        inline fn findValueInBucket(self: *const Self, bucket_abs_idx: usize, key: K, fp: u8) ?V {
            var mask = matchFingerprint(&self.fingerprints[bucket_abs_idx], fp);
            if (mask == 0) return null;
            const slot = @ctz(mask);
            if (self.keysEqual(self.entries[bucket_abs_idx][slot].key, key)) return self.entries[bucket_abs_idx][slot].value;
            mask &= mask - 1;
            while (mask != 0) {
                const s = @ctz(mask);
                if (self.keysEqual(self.entries[bucket_abs_idx][s].key, key)) return self.entries[bucket_abs_idx][s].value;
                mask &= mask - 1;
            }
            return null;
        }

        inline fn findEmptyOrTombstoneInBucket(self: *const Self, bucket_abs_idx: usize) ?usize {
            const mask = matchEmptyOrTombstone(&self.fingerprints[bucket_abs_idx]);
            if (mask == 0) return null;
            return @ctz(mask);
        }

        inline fn insertAt(self: *Self, bucket_abs_idx: usize, slot: usize, key: K, value: V, fp: u8) void {
            self.fingerprints[bucket_abs_idx][slot] = fp;
            self.entries[bucket_abs_idx][slot] = .{ .key = key, .value = value };
        }

        fn needsResize(self: *const Self) bool {
            return self.count * 8 > self.capacity * 7;
        }

        fn getEmptyFraction(self: *const Self, tier: usize) f64 {
            const used: f64 = @floatFromInt(self.tier_slot_counts[tier]);
            const total: f64 = @floatFromInt(self.tier_bucket_counts[tier] * BUCKET_SIZE);
            return 1.0 - (used / total);
        }

        fn resize(self: *Self) void {
            const old_fps = self.fingerprints;
            const old_entries = self.entries;
            const old_total_buckets = self.total_buckets;
            const old_tier_starts = self.tier_starts;
            const old_tier_bucket_counts = self.tier_bucket_counts;
            const old_tier_slot_counts = self.tier_slot_counts;
            const old_max_probe_depth = self.max_probe_depth;
            const old_overflow_bloom = self.overflow_bloom;

            const new_capacity = self.capacity * 2;
            const new_t0_buckets = @max(new_capacity / BUCKET_SIZE, 1);
            const new_num_tiers = @max(1, std.math.log2_int(usize, new_t0_buckets) + 1);

            const new_tier_starts = self.allocator.alloc(usize, new_num_tiers) catch @panic("alloc");
            const new_tier_bucket_counts = self.allocator.alloc(usize, new_num_tiers) catch @panic("alloc");
            const new_tier_slot_counts = self.allocator.alloc(usize, new_num_tiers) catch @panic("alloc");

            var new_total: usize = 0;
            var bkt = new_t0_buckets;
            for (0..new_num_tiers) |ti| {
                bkt = @max(bkt, 1);
                new_tier_starts[ti] = new_total;
                new_tier_bucket_counts[ti] = bkt;
                new_tier_slot_counts[ti] = 0;
                new_total += bkt;
                bkt /= 2;
            }

            const new_fps = self.allocator.alloc([BUCKET_SIZE]u8, new_total) catch @panic("alloc");
            const new_entries = self.allocator.alloc([BUCKET_SIZE]Entry, new_total) catch @panic("alloc");
            const new_depth = self.allocator.alloc(u8, new_t0_buckets) catch @panic("alloc");
            const new_bloom = self.allocator.alloc(u8, new_t0_buckets) catch @panic("alloc");
            for (new_fps) |*b| @memset(b, 0);
            @memset(new_depth, 0);
            @memset(new_bloom, 0);

            self.fingerprints = new_fps;
            self.entries = new_entries;
            self.max_probe_depth = new_depth;
            self.overflow_bloom = new_bloom;
            self.tier_starts = new_tier_starts;
            self.tier_bucket_counts = new_tier_bucket_counts;
            self.tier_slot_counts = new_tier_slot_counts;
            self.num_tiers = new_num_tiers;
            self.total_buckets = new_total;
            self.tier0_bucket_count = new_tier_bucket_counts[0];
            self.tier0_bucket_mask = new_tier_bucket_counts[0] - 1;
            self.tier0_bucket_shift = @as(u6, @intCast(@min(63, 64 - @as(usize, @ctz(new_tier_bucket_counts[0])))));
            self.capacity = new_tier_bucket_counts[0] * BUCKET_SIZE;
            self.count = 0;
            self.current_batch = 0;

            for (0..old_total_buckets) |bi| {
                for (0..BUCKET_SIZE) |si| {
                    const fp_val = old_fps[bi][si];
                    if (fp_val != 0 and fp_val != TOMBSTONE) {
                        const entry = old_entries[bi][si];
                        const h = self.hashKey(entry.key);
                        const fp = fingerprint(h);
                        self.insertNew(h, fp, entry.key, entry.value);
                    }
                }
            }

            self.allocator.free(old_fps);
            self.allocator.free(old_entries);
            self.allocator.free(old_max_probe_depth);
            self.allocator.free(old_overflow_bloom);
            self.allocator.free(old_tier_starts);
            self.allocator.free(old_tier_bucket_counts);
            self.allocator.free(old_tier_slot_counts);
        }

        /// Insert a key-value pair, updating the value if the key already exists.
        /// Single-pass: searches for existing key and tracks first empty slot simultaneously.
        pub fn insert(self: *Self, key: K, value: V) void {
            if (self.needsResize()) {
                self.resize();
            }

            const h = self.hashKey(key);
            const fp = fingerprint(h);
            const mask = self.tier0_bucket_mask;
            const bucket_base = h >> self.tier0_bucket_shift;

            var first_empty_bucket: usize = undefined;
            var first_empty_slot: usize = undefined;
            var first_empty_probe: usize = undefined;
            var found_empty = false;

            for (0..MAX_PROBES) |probe| {
                const bucket_idx = (bucket_base +% @as(u64, probe)) & mask;

                if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                    self.entries[bucket_idx][slot].value = value;
                    return;
                }

                if (!found_empty) {
                    if (self.findEmptyOrTombstoneInBucket(bucket_idx)) |slot| {
                        first_empty_bucket = bucket_idx;
                        first_empty_slot = slot;
                        first_empty_probe = probe;
                        found_empty = true;
                    }
                }

                if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) break;
            }

            // Key not in tier 0. Check tier 1 before inserting.
            if (self.num_tiers > 1) {
                const num_buckets = self.tier_bucket_counts[1];
                const tier_start = self.tier_starts[1];
                for (0..@min(MAX_PROBES, num_buckets)) |probe| {
                    const abs_idx = tier_start + bucketIndex(h, probe, num_buckets);
                    if (self.findKeyInBucket(abs_idx, key, fp)) |slot| {
                        self.entries[abs_idx][slot].value = value;
                        return;
                    }
                    if (matchEmpty(&self.fingerprints[abs_idx]) != 0) break;
                }
            }

            if (found_empty) {
                self.insertAt(first_empty_bucket, first_empty_slot, key, value, fp);
                self.tier_slot_counts[0] += 1;
                self.count += 1;
                const home_bucket = bucket_base & mask;
                const depth: u8 = @intCast(first_empty_probe);
                if (depth > self.max_probe_depth[home_bucket]) {
                    self.max_probe_depth[home_bucket] = depth;
                }
                if (first_empty_probe > 0) {
                    self.overflow_bloom[home_bucket] |= bloomBits(h);
                }
                if (self.current_batch == 0 and self.getEmptyFraction(0) <= 0.12) {
                    self.current_batch = 1;
                }
                return;
            }

            self.insertNew(h, fp, key, value);
        }

        /// Internal: insert without duplicate check (used by resize rehash).
        fn insertNew(self: *Self, h: u64, fp: u8, key: K, value: V) void {
            const i = self.current_batch;

            if (i == 0) {
                self.insertIntoTier(0, h, fp, key, value);
                if (self.getEmptyFraction(0) <= 0.12) {
                    self.current_batch = 1;
                }
                return;
            }

            if (i >= self.num_tiers) {
                self.insertAnyTier(h, fp, key, value);
                return;
            }

            const primary = i - 1;
            const secondary = i;
            const e1 = self.getEmptyFraction(primary);
            const e2 = self.getEmptyFraction(secondary);

            if (e1 > DELTA_HALF and e2 > 0.25) {
                if (!self.tryInsertWithLimit(primary, h, fp, key, value, probeLimit(e1))) {
                    self.insertIntoTier(secondary, h, fp, key, value);
                }
            } else if (e1 <= DELTA_HALF) {
                self.insertIntoTier(secondary, h, fp, key, value);
            } else {
                self.insertIntoTier(primary, h, fp, key, value);
            }

            if (e1 <= DELTA_HALF and e2 <= 0.25 and i + 1 < self.num_tiers) {
                self.current_batch = i + 1;
            }
        }

        fn insertIntoTier(self: *Self, tier: usize, h: u64, fp: u8, key: K, value: V) void {
            const num_buckets = self.tier_bucket_counts[tier];
            const max_probe = @min(num_buckets, MAX_PROBES);
            const home_bucket = if (tier == 0) bucketIndex(h, 0, num_buckets) else 0;
            var probe: usize = 0;
            while (probe < max_probe) : (probe += 1) {
                const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
                const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);
                if (self.findEmptyOrTombstoneInBucket(abs_bucket_idx)) |slot| {
                    self.insertAt(abs_bucket_idx, slot, key, value, fp);
                    self.tier_slot_counts[tier] += 1;
                    self.count += 1;
                    if (tier == 0) {
                        const depth: u8 = @intCast(probe);
                        if (depth > self.max_probe_depth[home_bucket]) {
                            self.max_probe_depth[home_bucket] = depth;
                        }
                        if (probe > 0) {
                            self.overflow_bloom[home_bucket] |= bloomBits(h);
                        }
                    }
                    return;
                }
            }
            self.insertAnyTier(h, fp, key, value);
        }

        fn tryInsertWithLimit(self: *Self, tier: usize, h: u64, fp: u8, key: K, value: V, limit: usize) bool {
            const num_buckets = self.tier_bucket_counts[tier];
            const max_probe = @min(limit, num_buckets);
            const home_bucket = if (tier == 0) bucketIndex(h, 0, num_buckets) else 0;
            for (0..max_probe) |probe| {
                const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
                const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);
                if (self.findEmptyOrTombstoneInBucket(abs_bucket_idx)) |slot| {
                    self.insertAt(abs_bucket_idx, slot, key, value, fp);
                    self.tier_slot_counts[tier] += 1;
                    self.count += 1;
                    if (tier == 0) {
                        const depth: u8 = @intCast(probe);
                        if (depth > self.max_probe_depth[home_bucket]) {
                            self.max_probe_depth[home_bucket] = depth;
                        }
                        if (probe > 0) {
                            self.overflow_bloom[home_bucket] |= bloomBits(h);
                        }
                    }
                    return true;
                }
            }
            return false;
        }

        fn insertAnyTier(self: *Self, h: u64, fp: u8, key: K, value: V) void {
            var j: usize = 1;
            while (j <= MAX_PROBES) : (j += 1) {
                for (0..self.num_tiers) |tier| {
                    const probe = j - 1;
                    const num_buckets = self.tier_bucket_counts[tier];
                    if (probe >= num_buckets) continue;
                    const rel_bucket_idx = bucketIndex(h, probe, num_buckets);
                    const abs_bucket_idx = self.getBucketIdx(tier, rel_bucket_idx);
                    if (self.findEmptyOrTombstoneInBucket(abs_bucket_idx)) |slot| {
                        self.insertAt(abs_bucket_idx, slot, key, value, fp);
                        self.tier_slot_counts[tier] += 1;
                        self.count += 1;
                        return;
                    }
                }
            }
        }

        pub fn get(self: *const Self, key: K) ?V {
            const h = self.hashKey(key);
            const fp = fingerprint(h);
            const mask = self.tier0_bucket_mask;
            const bucket_base = h >> self.tier0_bucket_shift;

            @prefetch(@as([*]const u8, @ptrCast(&self.entries[bucket_base & mask])), .{ .rw = .read, .locality = 3 });

            for (0..MAX_PROBES) |probe| {
                const bucket_idx = (bucket_base +% @as(u64, probe)) & mask;
                if (self.findValueInBucket(bucket_idx, key, fp)) |val| return val;
                if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) {
                    @branchHint(.cold);
                    return null;
                }
            }

            return self.get_overflow_fn(self, h, key, fp);
        }

        fn defaultGetOverflow(self: *const Self, h: u64, key: K, fp: u8) ?V {
            if (self.num_tiers <= 1) return null;
            const num_buckets = self.tier_bucket_counts[1];
            const tier_start = self.tier_starts[1];
            for (0..@min(MAX_PROBES, num_buckets)) |probe| {
                const abs_idx = tier_start + bucketIndex(h, probe, num_buckets);
                if (self.findValueInBucket(abs_idx, key, fp)) |val| return val;
                if (matchEmpty(&self.fingerprints[abs_idx]) != 0) return null;
            }
            return null;
        }

        pub fn remove(self: *Self, key: K) bool {
            const h = self.hashKey(key);
            const fp = fingerprint(h);
            const mask = self.tier0_bucket_mask;
            const bucket_base = h >> self.tier0_bucket_shift;

            var probe: usize = 0;
            while (probe < MAX_PROBES) : (probe += 1) {
                const bucket_idx = (bucket_base +% @as(u64, probe)) & mask;
                if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                    self.fingerprints[bucket_idx][slot] = TOMBSTONE;
                    self.count -= 1;
                    return true;
                }
            }
            return false;
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn clear(self: *Self) void {
            for (self.fingerprints) |*bucket_fps| {
                @memset(bucket_fps, 0);
            }
            for (self.tier_slot_counts) |*sc| {
                sc.* = 0;
            }
            @memset(self.max_probe_depth, 0);
            @memset(self.overflow_bloom, 0);
            self.count = 0;
            self.current_batch = 0;
        }

        /// Insert if missing, return pointer to value either way.
        /// Returns .found_existing = true if the key was already present.
        pub const GetOrPutResult = struct {
            value_ptr: *V,
            found_existing: bool,
        };

        pub fn getOrPut(self: *Self, key: K, default_value: V) GetOrPutResult {
            if (self.needsResize()) {
                self.resize();
            }

            const h = self.hashKey(key);
            const fp = fingerprint(h);

            const mask = self.tier0_bucket_mask;
            const bucket_base = h >> self.tier0_bucket_shift;

            for (0..MAX_PROBES) |probe| {
                const bucket_idx = (bucket_base +% @as(u64, probe)) & mask;
                if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                    return .{
                        .value_ptr = &self.entries[bucket_idx][slot].value,
                        .found_existing = true,
                    };
                }
                if (matchEmpty(&self.fingerprints[bucket_idx]) != 0) break;
            }

            if (self.num_tiers > 1) {
                const num_buckets = self.tier_bucket_counts[1];
                const tier_start = self.tier_starts[1];
                for (0..@min(MAX_PROBES, num_buckets)) |probe| {
                    const abs_idx = tier_start + bucketIndex(h, probe, num_buckets);
                    if (self.findKeyInBucket(abs_idx, key, fp)) |slot| {
                        return .{
                            .value_ptr = &self.entries[abs_idx][slot].value,
                            .found_existing = true,
                        };
                    }
                    if (matchEmpty(&self.fingerprints[abs_idx]) != 0) break;
                }
            }

            self.insertNew(h, fp, key, default_value);

            // Find the entry we just inserted to return a pointer to its value
            for (0..MAX_PROBES) |probe| {
                const bucket_idx = (bucket_base +% @as(u64, probe)) & mask;
                if (self.findKeyInBucket(bucket_idx, key, fp)) |slot| {
                    return .{
                        .value_ptr = &self.entries[bucket_idx][slot].value,
                        .found_existing = false,
                    };
                }
            }

            if (self.num_tiers > 1) {
                const num_buckets = self.tier_bucket_counts[1];
                const tier_start = self.tier_starts[1];
                for (0..@min(MAX_PROBES, num_buckets)) |probe| {
                    const abs_idx = tier_start + bucketIndex(h, probe, num_buckets);
                    if (self.findKeyInBucket(abs_idx, key, fp)) |slot| {
                        return .{
                            .value_ptr = &self.entries[abs_idx][slot].value,
                            .found_existing = false,
                        };
                    }
                }
            }

            unreachable;
        }

        /// Iterator over all key-value pairs.
        pub const KV = struct {
            key: K,
            value: V,
        };

        pub const Iterator = struct {
            table: *const Self,
            bucket_idx: usize,
            slot_idx: usize,

            pub fn next(self: *Iterator) ?KV {
                while (self.bucket_idx < self.table.total_buckets) {
                    while (self.slot_idx < BUCKET_SIZE) {
                        const si = self.slot_idx;
                        self.slot_idx += 1;
                        const fp = self.table.fingerprints[self.bucket_idx][si];
                        if (fp != 0 and fp != TOMBSTONE) {
                            const e = self.table.entries[self.bucket_idx][si];
                            return .{ .key = e.key, .value = e.value };
                        }
                    }
                    self.bucket_idx += 1;
                    self.slot_idx = 0;
                }
                return null;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .table = self, .bucket_idx = 0, .slot_idx = 0 };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "u64 key — basic insert/get/remove" {
    var map = try AutoElasticHash(u64, u64).init(testing.allocator, 1024);
    defer map.deinit();

    map.insert(10, 100);
    map.insert(20, 200);
    map.insert(30, 300);

    try testing.expectEqual(@as(?u64, 100), map.get(10));
    try testing.expectEqual(@as(?u64, 200), map.get(20));
    try testing.expectEqual(@as(?u64, 300), map.get(30));
    try testing.expectEqual(@as(?u64, null), map.get(999));

    try testing.expect(map.remove(20));
    try testing.expectEqual(@as(?u64, null), map.get(20));
    try testing.expectEqual(@as(?u64, 100), map.get(10));
    try testing.expectEqual(@as(?u64, 300), map.get(30));
}

test "u64 key — duplicates update value" {
    var map = try AutoElasticHash(u64, u64).init(testing.allocator, 1024);
    defer map.deinit();

    map.insert(42, 100);
    try testing.expectEqual(@as(?u64, 100), map.get(42));
    try testing.expectEqual(@as(usize, 1), map.len());

    map.insert(42, 200);
    try testing.expectEqual(@as(?u64, 200), map.get(42));
    try testing.expectEqual(@as(usize, 1), map.len());

    map.insert(42, 300);
    try testing.expectEqual(@as(?u64, 300), map.get(42));
    try testing.expectEqual(@as(usize, 1), map.len());
}

test "u64 key — resize" {
    var map = try AutoElasticHash(u64, u64).init(testing.allocator, 16);
    defer map.deinit();

    for (0..64) |i| {
        map.insert(i, i * 10);
    }

    try testing.expectEqual(@as(usize, 64), map.len());
    for (0..64) |i| {
        const val = map.get(i);
        try testing.expect(val != null);
        try testing.expectEqual(@as(u64, i * 10), val.?);
    }
    try testing.expectEqual(@as(?u64, null), map.get(9999));
}

test "[]const u8 key — basic insert/get/remove" {
    var map = try AutoElasticHash([]const u8, u64).init(testing.allocator, 1024);
    defer map.deinit();

    map.insert("hello", 100);
    map.insert("world", 200);
    map.insert("foo", 300);

    try testing.expectEqual(@as(?u64, 100), map.get("hello"));
    try testing.expectEqual(@as(?u64, 200), map.get("world"));
    try testing.expectEqual(@as(?u64, 300), map.get("foo"));
    try testing.expectEqual(@as(?u64, null), map.get("missing"));

    try testing.expect(map.remove("world"));
    try testing.expectEqual(@as(?u64, null), map.get("world"));
    try testing.expectEqual(@as(?u64, 100), map.get("hello"));
}

test "[]const u8 key — duplicates" {
    var map = try AutoElasticHash([]const u8, u64).init(testing.allocator, 1024);
    defer map.deinit();

    map.insert("key", 100);
    try testing.expectEqual(@as(usize, 1), map.len());

    map.insert("key", 200);
    try testing.expectEqual(@as(?u64, 200), map.get("key"));
    try testing.expectEqual(@as(usize, 1), map.len());
}

test "[16]u8 key — fixed array keys" {
    var map = try AutoElasticHash([16]u8, u64).init(testing.allocator, 1024);
    defer map.deinit();

    var k1: [16]u8 = undefined;
    var k2: [16]u8 = undefined;
    @memset(&k1, 'a');
    @memset(&k2, 'b');

    map.insert(k1, 1);
    map.insert(k2, 2);

    try testing.expectEqual(@as(?u64, 1), map.get(k1));
    try testing.expectEqual(@as(?u64, 2), map.get(k2));

    var k3: [16]u8 = undefined;
    @memset(&k3, 'c');
    try testing.expectEqual(@as(?u64, null), map.get(k3));
}

test "contains, len, clear with u64 keys" {
    var map = try AutoElasticHash(u64, u64).init(testing.allocator, 1024);
    defer map.deinit();

    try testing.expectEqual(@as(usize, 0), map.len());
    try testing.expect(!map.contains(1));

    map.insert(1, 10);
    map.insert(2, 20);
    map.insert(3, 30);

    try testing.expectEqual(@as(usize, 3), map.len());
    try testing.expect(map.contains(1));
    try testing.expect(map.contains(2));
    try testing.expect(!map.contains(999));

    _ = map.remove(2);
    try testing.expectEqual(@as(usize, 2), map.len());
    try testing.expect(!map.contains(2));

    map.clear();
    try testing.expectEqual(@as(usize, 0), map.len());
    try testing.expect(!map.contains(1));
    try testing.expect(!map.contains(3));

    // Re-insert after clear
    map.insert(5, 50);
    try testing.expectEqual(@as(?u64, 50), map.get(5));
    try testing.expectEqual(@as(usize, 1), map.len());
}

test "getOrPut with u64 keys" {
    var map = try AutoElasticHash(u64, u64).init(testing.allocator, 1024);
    defer map.deinit();

    // New key
    const r1 = map.getOrPut(42, 100);
    try testing.expect(!r1.found_existing);
    try testing.expectEqual(@as(u64, 100), r1.value_ptr.*);
    try testing.expectEqual(@as(usize, 1), map.len());

    // Existing key — returns original value, ignores default
    const r2 = map.getOrPut(42, 999);
    try testing.expect(r2.found_existing);
    try testing.expectEqual(@as(u64, 100), r2.value_ptr.*);
    try testing.expectEqual(@as(usize, 1), map.len());

    // Modify via pointer
    r2.value_ptr.* = 777;
    try testing.expectEqual(@as(?u64, 777), map.get(42));
}

test "iterator with u64 keys" {
    var map = try AutoElasticHash(u64, u64).init(testing.allocator, 1024);
    defer map.deinit();

    // Empty iterator
    var it0 = map.iterator();
    try testing.expectEqual(@as(?AutoElasticHash(u64, u64).KV, null), it0.next());

    for (0..50) |i| {
        map.insert(i, i * 10);
    }

    var it = map.iterator();
    var count: usize = 0;
    var value_sum: u64 = 0;
    while (it.next()) |kv| {
        count += 1;
        value_sum += kv.value;
    }

    try testing.expectEqual(@as(usize, 50), count);
    // Sum of (0..50)*10 = 10*(0+1+...+49) = 10*1225 = 12250
    try testing.expectEqual(@as(u64, 12250), value_sum);
}

test "iterator skips tombstones" {
    var map = try AutoElasticHash(u64, u64).init(testing.allocator, 1024);
    defer map.deinit();

    for (0..20) |i| {
        map.insert(i, i);
    }

    // Delete the first 10
    for (0..10) |i| {
        _ = map.remove(i);
    }

    var it = map.iterator();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 10), count);
}
