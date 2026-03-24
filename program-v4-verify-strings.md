# Autoresearch v4: Verify string key results

The elastic hash appears to beat abseil by 36-97% on string key lookups. This is an extraordinary claim. Systematically try to disprove it.

## Things that could be wrong

### 1. Our wyhash vs abseil's hash
Zig's std.hash.Wyhash may differ from abseil's internal hash for string_view. If our hash is faster, that's a hash function win, not a data structure win. Measure hash-only cost for 16-byte strings.

### 2. string_view vs []const u8 semantics
Both are pointer+length, no copy. But Zig's []const u8 is 16 bytes (ptr + usize) while C++ string_view is also 16 bytes (ptr + size_t). Should be equivalent, but verify.

### 3. Key length matters
We tested 16-byte keys. What about 8-byte? 64-byte? 256-byte? Short keys favor fast hashing, long keys favor fewer comparisons (where our fingerprints help more).

### 4. Different table sizes
We only tested 1M. Need 100K, 500K, 2M, 4M.

### 5. The key buffer layout
Our keys are in a contiguous [fill][16]u8 array. Abseil's are in a contiguous vector<char>. Both have good locality for the key buffer itself. But our StringEntry stores a pointer INTO this buffer - if the pointer chase to the key data is different from abseil's, that matters.

### 6. Entry size difference
Our StringEntry is {ptr: 8, len: 8, value: 8} = 24 bytes. Abseil's slot for string_view+u64 is {string_view: 16, u64: 8} = 24 bytes. Same size. Good.

### 7. Are we actually comparing the keys correctly?
If our fingerprint matching is wrong and we're returning garbage, the lookup would appear fast but incorrect. Run a correctness check.

### 8. Abseil with std::string (owning) keys
Real-world abseil usage often has std::string keys, not string_view. The std::string version may perform differently due to SSO (small string optimization) keeping short strings inline.

## Experiments to run

1. Hash function cost: time wyhash vs absl::Hash for 16-byte strings
2. Variable key lengths: 8, 16, 32, 64, 128, 256 bytes
3. Multiple table sizes: 100K, 500K, 1M, 2M at 50% load, shuffled
4. Correctness check: verify all inserted keys are found with correct values
5. std::string keys (owning) comparison
6. Run 3 times to verify consistency
