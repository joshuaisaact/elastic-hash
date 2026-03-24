# Running benchmarks on Apple Silicon M4

## What we're testing

On x86 with ~512KB L2, elastic hash beats abseil by 36-97% on string lookups because our tier-0 fingerprints (1MB) fit in L2 while abseil's control bytes (2MB) spill to L3.

M4 has ~16MB shared L2. Both arrays should fit in L2. If the advantage disappears, the result is cache-density-specific. If it persists, something deeper is happening.

## Setup

### Install dependencies

```bash
# Zig
brew install zig

# Abseil
brew install abseil

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Go
brew install go
```

### Clone and checkout

```bash
git clone https://github.com/joshuaisaact/elastic-hash.git
cd elastic-hash
git checkout autoresearch/cross-language-bench
```

### Build everything

```bash
# Abseil benchmark
# Note: pkg-config paths may differ on macOS. Try:
g++ -O3 -march=native -DNDEBUG -DABSL_HASHTABLEZ_SAMPLE_PARAMETER=0 \
    bench-abseil-strings.cpp -o bench-abseil-strings \
    $(pkg-config --cflags --libs absl_hash absl_raw_hash_set absl_hashtablez_sampler)

# If pkg-config doesn't work, try:
# g++ -O3 -march=native -DNDEBUG -DABSL_HASHTABLEZ_SAMPLE_PARAMETER=0 \
#     bench-abseil-strings.cpp -o bench-abseil-strings \
#     -I/opt/homebrew/include -L/opt/homebrew/lib \
#     -labsl_hash -labsl_raw_hash_set -labsl_hashtablez_sampler \
#     -labsl_city -labsl_low_level_hash -labsl_strings -labsl_int128 \
#     -labsl_base -labsl_throw_delegate -labsl_raw_logging_internal

# Elastic hash (Zig)
zig build test                              # verify tests pass
zig build autobench-strings -Doptimize=ReleaseFast  # just to check it builds

# Rust
cd bench-rust && cargo build --release && cd ..

# Go
cd bench-go && go build -o bench-go . && cd ..
```

## Run the benchmarks

### Quick test (just abseil vs elastic at 1M 50%)

```bash
bash bench-strings.sh
```

### Full cross-language comparison

Run each one and save the output:

```bash
# Abseil
./bench-abseil-strings > results-m4-abseil.log 2>/dev/null
cat results-m4-abseil.log

# Elastic hash
zig build autobench-strings -Doptimize=ReleaseFast 2> results-m4-elastic.log
cat results-m4-elastic.log

# Rust (with ahash)
./bench-rust/target/release/bench-hashbrown > results-m4-rust.log 2>/dev/null
cat results-m4-rust.log

# Go
./bench-go/bench-go > results-m4-go.log 2>/dev/null
cat results-m4-go.log
```

### Shuffled verification (the most important test)

```bash
# Abseil shuffled
g++ -O3 -march=native -DNDEBUG -DABSL_HASHTABLEZ_SAMPLE_PARAMETER=0 \
    bench-strings-verify.cpp -o bench-strings-verify \
    $(pkg-config --cflags --libs absl_hash absl_raw_hash_set absl_hashtablez_sampler)
./bench-strings-verify

# Elastic hash shuffled (swap autobench temporarily)
cp src/autobench.zig src/autobench.zig.bak
cp src/autobench-strings-verify.zig src/autobench.zig
zig build autobench -Doptimize=ReleaseFast 2>&1 | grep ELASTIC
cp src/autobench.zig.bak src/autobench.zig
rm src/autobench.zig.bak
```

## What to look for

### Prediction: advantage shrinks or disappears on M4

M4's ~16MB L2 fits both our 1MB fingerprints AND abseil's 2MB control bytes. The L2 vs L3 cache density advantage that drives our x86 results should not apply.

If the shuffled hit lookup gap at 1M 50% is:
- **> 1.3x**: The advantage is NOT just cache density. Something else is going on.
- **1.0-1.3x**: Advantage shrinks as predicted. Cache density was the main factor.
- **< 1.0x**: Abseil wins on M4. Our architecture only helps on small-L2 x86.

### Also check

- Does the size-dependent pattern hold? (Advantage at 1M but not 100K or 4M?)
- Is Rust+ahash still faster than abseil on M4?
- Does Go's performance change relative to the native-compiled implementations?

## Results

### Shuffled hit lookup (the key test)

| Load | Elastic (Zig) | Abseil (C++) | M4 ratio | x86 ratio |
|------|--------------|-------------|----------|-----------|
| 10% | 719 | 2,861 | **3.98x** | 1.97x |
| 25% | 2,276 | 10,169 | **4.47x** | 1.86x |
| 50% | 8,863 | 22,984 | **2.59x** | 1.74x |
| 75% | 15,972 | 33,624 | **2.11x** | 1.61x |
| 90% | 22,118 | 41,671 | **1.88x** | 1.50x |
| 99% | 25,748 | 46,543 | **1.81x** | 1.36x |

### Verdict

The prediction was wrong. The advantage is **not** cache-density-specific. At 50% load the gap went from 1.74x on x86 to 2.59x on M4 -- it grew by 49%.

The mechanism is cache lines touched per probe, not which cache level the data lives in. Separated, dense fingerprint arrays mean fewer cache line fetches under random access, and this holds regardless of L2 size.

### x86 reference (from Linux, AMD/Intel ~512KB L2)

| Load | Elastic | Abseil | Rust+ahash | Go swiss |
|------|---------|--------|-----------|---------|
| 50% | 11,119 | 19,312 | 16,235 | 25,304 |
| 99% | 33,318 | 45,404 | 36,292 | 57,488 |

Gap at 50%: elastic 1.74x faster than abseil, 1.46x faster than Rust+ahash.

## Troubleshooting

### abseil won't build on macOS

Try `brew install abseil` then check `pkg-config --libs absl_hash`. If pkg-config can't find it:
```bash
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:$PKG_CONFIG_PATH"
```

### Zig SIMD on ARM

Zig's `@Vector` operations compile to ARM NEON on aarch64. The SIMD fingerprint matching should work without changes, but the generated instructions differ from SSE2. If tests fail, there may be an alignment or endianness issue.

### Go swiss.Map crashes

If `swiss.Map` crashes with a segfault, ensure you're using pre-allocated strings (the current code on this branch already does this).
