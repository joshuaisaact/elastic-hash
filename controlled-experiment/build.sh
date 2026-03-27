#!/bin/bash
set -e
cd "$(dirname "$0")"
FLAGS="-std=c++17 -O3 -march=native -DNDEBUG"

echo "Building all implementations..."
g++ $FLAGS impl_elastic_linear.cpp -o impl_elastic_linear
g++ $FLAGS impl_flat_triangular.cpp -o impl_flat_triangular
g++ $FLAGS impl_elastic_triangular.cpp -o impl_elastic_triangular
g++ $FLAGS impl_flat_linear.cpp -o impl_flat_linear
g++ $FLAGS verify.cpp -o verify
echo "Build complete."
