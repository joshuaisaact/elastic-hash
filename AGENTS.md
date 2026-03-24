# AGENTS.md

## Frozen files

`src/simple.zig` and `src/bench.zig` are reference implementations. Do not modify them.

## Autoresearch programs

`program.md` and `program-v2.md` are autonomous agent programs (not documentation). When asked to "start" or "run" one, read it fully and execute its loop. Each defines its own set of frozen files, editable files, and keep/revert criteria -- read before editing anything.

## Zig skills

The skills `zig-perf`, `zig-quality`, `zig-safety`, `zig-style`, and `zig-testing` are available globally.

## Abseil comparison benchmarks

The abseil benchmark (`bench-abseil.cpp`, created by program-v2) requires system-installed `abseil-cpp` with pkg-config modules: `absl_hash`, `absl_raw_hash_set`, `absl_hashtablez_sampler`.
