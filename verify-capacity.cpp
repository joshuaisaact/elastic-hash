#include <cstdint>
#include <cstdio>
#include "absl/container/flat_hash_map.h"

int main() {
    constexpr size_t sizes[] = {16384, 65536, 262144, 1048576, 2097152, 4194304};
    constexpr int load_pcts[] = {10, 25, 50, 75, 90, 99};

    printf("=== Abseil flat_hash_map internal capacity ===\n\n");
    printf("%-12s %-12s %-12s %-16s %-16s %-12s\n",
           "n", "reserve(n)", "capacity", "ctrl_bytes(KB)", "slot_bytes(KB)", "total(KB)");

    for (size_t n : sizes) {
        absl::flat_hash_map<uint64_t, uint64_t> map;
        map.reserve(n);
        size_t cap = map.capacity();
        // Control bytes: 1 per slot + 1 group of sentinel = cap + 16 rounded
        size_t ctrl_kb = (cap + 16) / 1024;
        // Slots: each is sizeof(pair<uint64_t,uint64_t>) = 16 bytes
        size_t slot_kb = (cap * 16) / 1024;
        printf("%-12zu %-12zu %-12zu %-16zu %-16zu %-12zu\n",
               n, n, cap, ctrl_kb, slot_kb, ctrl_kb + slot_kb);
    }

    printf("\n=== Load factor test: reserve(n) then fill to pct ===\n\n");
    printf("%-8s %-6s %-10s %-12s %-12s\n",
           "n", "load%", "fill", "capacity", "internal_load%");

    size_t n = 1048576;
    for (int pct : load_pcts) {
        size_t fill = n * pct / 100;
        absl::flat_hash_map<uint64_t, uint64_t> map;
        map.reserve(n);
        for (size_t i = 0; i < fill; i++) {
            map.emplace(i, i);
        }
        printf("%-8zu %-6d %-10zu %-12zu %-12.1f\n",
               n, pct, fill, map.capacity(),
               100.0 * fill / map.capacity());
    }

    // Also show what happens with reserve(fill) for comparison
    printf("\n=== Alternative: reserve(fill) instead of reserve(n) ===\n\n");
    printf("%-8s %-6s %-10s %-12s %-12s %-16s\n",
           "n", "load%", "fill", "cap_reserveN", "cap_reserveFill", "ratio");

    for (int pct : load_pcts) {
        size_t fill = n * pct / 100;

        absl::flat_hash_map<uint64_t, uint64_t> map_n, map_f;
        map_n.reserve(n);
        map_f.reserve(fill);

        printf("%-8zu %-6d %-10zu %-12zu %-12zu %-16.2f\n",
               n, pct, fill, map_n.capacity(), map_f.capacity(),
               (double)map_n.capacity() / map_f.capacity());
    }

    return 0;
}
