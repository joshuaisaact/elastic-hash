#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Running verification..."
./verify
echo ""

echo "Running benchmarks..."
> results.tsv

echo "--- elastic + linear (our approach) ---"
./impl_elastic_linear | tee -a results.tsv

echo ""
echo "--- flat + triangular (abseil's approach) ---"
./impl_flat_triangular | tee -a results.tsv

echo ""
echo "--- elastic + triangular (isolate probing) ---"
./impl_elastic_triangular | tee -a results.tsv

echo ""
echo "--- flat + linear (isolate layout) ---"
./impl_flat_linear | tee -a results.tsv

echo ""
echo "Results written to results.tsv"
