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
}
