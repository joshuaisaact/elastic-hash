#!/bin/bash
set -euo pipefail

echo "=== Building ==="
g++ -O3 -march=native -DNDEBUG -DABSL_HASHTABLEZ_SAMPLE_PARAMETER=0 \
    bench-abseil.cpp -o bench-abseil \
    $(pkg-config --cflags --libs absl_hash absl_raw_hash_set absl_hashtablez_sampler)

echo "=== Running Abseil ==="
./bench-abseil > abseil-v2.log 2>/dev/null

echo "=== Running Elastic Hash ==="
zig build autobench -Doptimize=ReleaseFast 2> elastic-v2.log

echo ""
echo "=== Results Comparison (median of 10 runs, random keys) ==="
echo "gap = abseil_time / elastic_time (>1.0 = elastic wins)"
echo ""
printf "%-8s  %-6s  %8s %8s %8s %8s  %8s %8s %8s %8s  %8s %8s %8s %8s\n" \
    "n" "load" "ab_ins" "ab_get" "ab_del" "ab_mis" "el_ins" "el_get" "el_del" "el_mis" "ins_gap" "get_gap" "del_gap" "mis_gap"
printf "%s\n" "--------------------------------------------------------------------------------------------------------------------------------------"

while IFS=$'\t' read -r _ an al ai ag ad am; do
    n_val="${an#n=}"
    load_val="${al#load=}"
    a_ins="${ai#insert_us=}"
    a_get="${ag#lookup_us=}"
    a_del="${ad#delete_us=}"
    a_miss="${am#miss_us=}"

    e_line=$(grep "n=${n_val}" elastic-v2.log | grep "load=${load_val}" | head -1) || true
    if [ -z "$e_line" ]; then continue; fi

    e_ins=$(echo "$e_line" | awk -F'\t' '{for(i=1;i<=NF;i++) if($i ~ /^insert_us=/) print substr($i,11)}')
    e_get=$(echo "$e_line" | awk -F'\t' '{for(i=1;i<=NF;i++) if($i ~ /^lookup_us=/) print substr($i,11)}')
    e_del=$(echo "$e_line" | awk -F'\t' '{for(i=1;i<=NF;i++) if($i ~ /^delete_us=/) print substr($i,11)}')
    e_miss=$(echo "$e_line" | awk -F'\t' '{for(i=1;i<=NF;i++) if($i ~ /^miss_us=/) print substr($i,9)}')

    if [ -n "$e_ins" ] && [ -n "$e_get" ] && [ -n "$e_del" ] && [ -n "$e_miss" ] && \
       [ "$e_ins" -gt 0 ] && [ "$e_get" -gt 0 ] && [ "$e_del" -gt 0 ] && [ "$e_miss" -gt 0 ]; then
        ins_gap=$(awk "BEGIN {printf \"%.3f\", $a_ins / $e_ins}")
        get_gap=$(awk "BEGIN {printf \"%.3f\", $a_get / $e_get}")
        del_gap=$(awk "BEGIN {printf \"%.3f\", $a_del / $e_del}")
        mis_gap=$(awk "BEGIN {printf \"%.3f\", $a_miss / $e_miss}")
        printf "%-8s  %-6s  %8s %8s %8s %8s  %8s %8s %8s %8s  %8s %8s %8s %8s\n" \
            "$n_val" "$load_val" "$a_ins" "$a_get" "$a_del" "$a_miss" "$e_ins" "$e_get" "$e_del" "$e_miss" "$ins_gap" "$get_gap" "$del_gap" "$mis_gap"
    fi
done < <(grep "^RESULT" abseil-v2.log)
