//! Memory overhead comparison.
//! Reports total bytes allocated by elastic hash at various capacities.
//! Compare against abseil's known allocation formula.
const std = @import("std");
const StringElasticHash = @import("string_hybrid.zig").StringElasticHash;
const BUCKET_SIZE = @import("string_hybrid.zig").BUCKET_SIZE;

const StringEntry = struct {
    key_ptr: [*]const u8,
    key_len: usize,
    value: u64,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== Memory Overhead Comparison ===\n\n", .{});
    std.debug.print("Elastic hash allocations for StringElasticHash (key_ptr + key_len + value):\n", .{});
    std.debug.print("Entry size: {d} bytes\n\n", .{@sizeOf(StringEntry)});

    const capacities = [_]usize{ 1_024, 16_384, 65_536, 262_144, 1_048_576, 4_194_304 };

    std.debug.print("{s:<12} {s:<12} {s:<14} {s:<14} {s:<14} {s:<10} {s:<14} {s:<10}\n", .{
        "capacity", "tier0_bkts", "fingerprints", "entries", "probe_depth", "other", "elastic_total", "abseil_est",
    });
    std.debug.print("{s}\n", .{"-" ** 110});

    for (capacities) |n| {
        var map = try StringElasticHash.init(allocator, n);
        defer map.deinit();

        // Calculate elastic hash memory
        const fp_bytes = map.fingerprints.len * BUCKET_SIZE; // [BUCKET_SIZE]u8 per bucket
        const entry_bytes = map.entries.len * BUCKET_SIZE * @sizeOf(StringEntry);
        const depth_bytes = map.max_probe_depth.len;
        const meta_bytes = map.tier_starts.len * @sizeOf(usize) * 3; // 3 tier arrays
        const elastic_total = fp_bytes + entry_bytes + depth_bytes + meta_bytes;

        // Abseil estimate: flat_hash_map with string_view keys
        // Layout: (ctrl byte + slot) per element, rounded up to groups of 16
        // ctrl: 1 byte per slot + 16 sentinel bytes (clamp group)
        // slot: sizeof(pair<string_view, uint64_t>) = 24 bytes on 64-bit
        // capacity after reserve(n) = next power of 2 that gives <87.5% load
        // Abseil uses Group::kWidth = 16, growth factor = 8/7
        const abseil_cap = std.math.ceilPowerOfTwo(usize, n * 8 / 7) catch n * 2;
        const abseil_ctrl = abseil_cap + 16; // ctrl bytes + sentinel
        const abseil_slot_size = 24; // pair<string_view(16), uint64_t(8)>
        const abseil_slots = abseil_cap * abseil_slot_size;
        const abseil_total = abseil_ctrl + abseil_slots;

        std.debug.print("{d:<12} {d:<12} {d:<14} {d:<14} {d:<14} {d:<10} {d:<14} {d:<10}\n", .{
            n,
            map.tier0_bucket_count,
            fp_bytes,
            entry_bytes,
            depth_bytes,
            meta_bytes,
            elastic_total,
            abseil_total,
        });
    }

    std.debug.print("\n", .{});

    // Summary ratios
    std.debug.print("{s:<12} {s:<14} {s:<14} {s:<8}\n", .{ "capacity", "elastic_MB", "abseil_MB", "ratio" });
    std.debug.print("{s}\n", .{"-" ** 50});

    for (capacities) |n| {
        var map = try StringElasticHash.init(allocator, n);
        defer map.deinit();

        const fp_bytes = map.fingerprints.len * BUCKET_SIZE;
        const entry_bytes = map.entries.len * BUCKET_SIZE * @sizeOf(StringEntry);
        const depth_bytes = map.max_probe_depth.len;
        const meta_bytes = map.tier_starts.len * @sizeOf(usize) * 3;
        const elastic_total = fp_bytes + entry_bytes + depth_bytes + meta_bytes;

        const abseil_cap = std.math.ceilPowerOfTwo(usize, n * 8 / 7) catch n * 2;
        const abseil_total = abseil_cap + 16 + abseil_cap * 24;

        const elastic_mb = @as(f64, @floatFromInt(elastic_total)) / (1024.0 * 1024.0);
        const abseil_mb = @as(f64, @floatFromInt(abseil_total)) / (1024.0 * 1024.0);
        const ratio = elastic_mb / abseil_mb;

        std.debug.print("{d:<12} {d:<14.2} {d:<14.2} {d:<8.2}x\n", .{ n, elastic_mb, abseil_mb, ratio });
    }

    std.debug.print("\n", .{});
}
