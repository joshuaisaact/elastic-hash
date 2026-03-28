const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    _ = b.addModule("elastic_hash", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests for main implementation
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Tests for simple implementation
    const simple_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/simple.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Tests for hybrid implementation
    const hybrid_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hybrid.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
    test_step.dependOn(&b.addRunArtifact(simple_tests).step);
    test_step.dependOn(&b.addRunArtifact(hybrid_tests).step);

    // Benchmark executable
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Autoresearch benchmark (focused, machine-parseable output)
    const autobench = b.addExecutable(.{
        .name = "autobench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_autobench = b.addRunArtifact(autobench);
    const autobench_step = b.step("autobench", "Run autoresearch benchmark");
    autobench_step.dependOn(&run_autobench.step);

    // String-key tests
    const string_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/string_hybrid.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(string_tests).step);

    // String-key benchmark
    const autobench_strings = b.addExecutable(.{
        .name = "autobench-strings",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench-strings.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autobench_strings = b.addRunArtifact(autobench_strings);
    const autobench_strings_step = b.step("autobench-strings", "Run string key benchmarks");
    autobench_strings_step.dependOn(&run_autobench_strings.step);

    // Shuffled verification benchmark
    const autobench_verify = b.addExecutable(.{
        .name = "autobench-strings-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench-strings-verify.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autobench_verify = b.addRunArtifact(autobench_verify);
    const autobench_verify_step = b.step("autobench-strings-verify", "Run shuffled verification");
    autobench_verify_step.dependOn(&run_autobench_verify.step);

    // Hit + miss benchmark with shuffled access
    const autobench_miss = b.addExecutable(.{
        .name = "autobench-miss",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench-miss.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autobench_miss = b.addRunArtifact(autobench_miss);
    const autobench_miss_step = b.step("autobench-miss", "Run hit + miss shuffled benchmark");
    autobench_miss_step.dependOn(&run_autobench_miss.step);

    // Tombstone churn test
    const autobench_churn = b.addExecutable(.{
        .name = "autobench-churn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench-churn.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autobench_churn = b.addRunArtifact(autobench_churn);
    const autobench_churn_step = b.step("autobench-churn", "Run tombstone churn test");
    autobench_churn_step.dependOn(&run_autobench_churn.step);

    // Mixed workload benchmark
    const autobench_mixed = b.addExecutable(.{
        .name = "autobench-mixed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench-mixed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autobench_mixed = b.addRunArtifact(autobench_mixed);
    const autobench_mixed_step = b.step("autobench-mixed", "Run mixed workload benchmark");
    autobench_mixed_step.dependOn(&run_autobench_mixed.step);

    // Memory overhead
    const autobench_memory = b.addExecutable(.{
        .name = "autobench-memory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench-memory.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autobench_memory = b.addRunArtifact(autobench_memory);
    const autobench_memory_step = b.step("autobench-memory", "Report memory overhead");
    autobench_memory_step.dependOn(&run_autobench_memory.step);

    // Variable key length
    const autobench_keylen = b.addExecutable(.{
        .name = "autobench-keylen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench-keylen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autobench_keylen = b.addRunArtifact(autobench_keylen);
    const autobench_keylen_step = b.step("autobench-keylen", "Run variable key length benchmark");
    autobench_keylen_step.dependOn(&run_autobench_keylen.step);

    // Flat hash tests
    const flat_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flat_hash.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(flat_tests).step);

    // Flat vs tiered benchmark
    const bench_flat = b.addExecutable(.{
        .name = "bench-flat-vs-tiered",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_flat_vs_tiered.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bench_flat = b.addRunArtifact(bench_flat);
    const bench_flat_step = b.step("bench-flat", "Run flat vs tiered benchmark");
    bench_flat_step.dependOn(&run_bench_flat.step);

    // String hybrid growth tests
    const growth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/string_hybrid_growth.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(growth_tests).step);

    // Growth policy overhead test
    const autobench_growth = b.addExecutable(.{
        .name = "autobench-growth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/autobench-growth.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_autobench_growth = b.addRunArtifact(autobench_growth);
    const autobench_growth_step = b.step("autobench-growth", "Run growth policy overhead test");
    autobench_growth_step.dependOn(&run_autobench_growth.step);
}
