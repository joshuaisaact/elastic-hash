#!/bin/bash
set -e
cd "$(dirname "$0")"

MODRS="vendor/hashbrown/src/raw/mod.rs"
CKSUM="vendor/hashbrown/.cargo-checksum.json"

update_checksum() {
    python3 -c "
import json, hashlib
with open('$CKSUM') as f: data = json.load(f)
with open('$MODRS', 'rb') as f: data['files']['src/raw/mod.rs'] = hashlib.sha256(f.read()).hexdigest()
with open('$CKSUM', 'w') as f: json.dump(data, f)
"
}

# Save originals
cp "$MODRS" /tmp/hashbrown_mod_original.rs

# --- Stock ---
echo "Building: stock"
update_checksum
cargo build --release 2>&1 | grep -E "^error" || true
cp target/release/hashbrown-improvements /tmp/hb_stock

# --- Linear probing only ---
echo "Building: linear probing"
cp /tmp/hashbrown_mod_original.rs "$MODRS"
# Change triangular to linear: instead of stride += WIDTH, pos += stride,
# just do pos += WIDTH (constant stride)
sed -i 's/self\.stride += Group::WIDTH;/\/\/ LINEAR: constant stride/;s/self\.pos += self\.stride;/self.pos += Group::WIDTH;/' "$MODRS"
update_checksum
cargo build --release 2>&1 | grep -E "^error" || true
cp target/release/hashbrown-improvements /tmp/hb_linear

# --- Prefetch only ---
echo "Building: prefetch"
cp /tmp/hashbrown_mod_original.rs "$MODRS"
# Add prefetch to find()
sed -i '/pub fn find(&self, hash: u64, mut eq: impl FnMut(&T) -> bool) -> Option<Bucket<T>> {/,/let result = self/{
    /let result = self/i\
            // Prefetch data slot at initial probe position\
            #[cfg(target_arch = "x86_64")]\
            {\
                let index = h1(hash) \& self.table.bucket_mask;\
                let bucket: Bucket<T> = self.bucket(index);\
                core::arch::asm!(\
                    "prefetcht0 [{}]",\
                    in(reg) bucket.as_ptr(),\
                    options(nostack, readonly, preserves_flags)\
                );\
            }
}' "$MODRS"
update_checksum
cargo build --release 2>&1 | grep -E "^error" || true
cp target/release/hashbrown-improvements /tmp/hb_prefetch

# --- Both linear + prefetch ---
echo "Building: linear + prefetch"
cp /tmp/hashbrown_mod_original.rs "$MODRS"
sed -i 's/self\.stride += Group::WIDTH;/\/\/ LINEAR: constant stride/;s/self\.pos += self\.stride;/self.pos += Group::WIDTH;/' "$MODRS"
sed -i '/pub fn find(&self, hash: u64, mut eq: impl FnMut(&T) -> bool) -> Option<Bucket<T>> {/,/let result = self/{
    /let result = self/i\
            // Prefetch data slot at initial probe position\
            #[cfg(target_arch = "x86_64")]\
            {\
                let index = h1(hash) \& self.table.bucket_mask;\
                let bucket: Bucket<T> = self.bucket(index);\
                core::arch::asm!(\
                    "prefetcht0 [{}]",\
                    in(reg) bucket.as_ptr(),\
                    options(nostack, readonly, preserves_flags)\
                );\
            }
}' "$MODRS"
update_checksum
cargo build --release 2>&1 | grep -E "^error" || true
cp target/release/hashbrown-improvements /tmp/hb_both

# Restore original
cp /tmp/hashbrown_mod_original.rs "$MODRS"
update_checksum

echo "All 4 variants built."
