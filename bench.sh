#!/bin/bash
# Autoresearch benchmark runner. DO NOT MODIFY.
# Builds and runs the focused autobench, captures output.
set -euo pipefail

echo "=== Building (ReleaseFast) ==="
zig build autobench -Doptimize=ReleaseFast 2>&1

echo "=== Running benchmark ==="
./zig-out/bin/autobench 2>&1 | tee bench.log

echo ""
echo "=== Primary metric (lookup_ratio at n=1048576) ==="
grep "RESULT" bench.log | grep "n=1048576" | grep -oP 'lookup_ratio=\K[0-9.]+'
