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

cp "$MODRS" /tmp/hashbrown_mod_original.rs

# --- Stock ---
echo "Building: stock"
update_checksum
cargo build --release 2>&1 | grep "^error" || true
cp target/release/hashbrown-improvements /tmp/hb2_stock

# --- Branch hint flip (likely → unlikely on empty check in find_inner) ---
echo "Building: cold-empty (flip empty check from likely to unlikely)"
cp /tmp/hashbrown_mod_original.rs "$MODRS"
# The exact line: if likely(group.match_empty().any_bit_set()) {
sed -i 's/if likely(group\.match_empty()\.any_bit_set())/if unlikely(group.match_empty().any_bit_set())/' "$MODRS"
update_checksum
cargo build --release 2>&1 | grep "^error" || true
cp target/release/hashbrown-improvements /tmp/hb2_cold_empty

# --- Prefetch + cold-empty ---
echo "Building: prefetch + cold-empty"
cp /tmp/hashbrown_mod_original.rs "$MODRS"
sed -i 's/if likely(group\.match_empty()\.any_bit_set())/if unlikely(group.match_empty().any_bit_set())/' "$MODRS"
sed -i '/pub fn find(&self, hash: u64, mut eq: impl FnMut(&T) -> bool) -> Option<Bucket<T>> {/,/let result = self/{
    /let result = self/i\
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
cargo build --release 2>&1 | grep "^error" || true
cp target/release/hashbrown-improvements /tmp/hb2_prefetch_cold

# --- All three: linear + prefetch + cold-empty ---
echo "Building: linear + prefetch + cold-empty"
cp /tmp/hashbrown_mod_original.rs "$MODRS"
sed -i 's/if likely(group\.match_empty()\.any_bit_set())/if unlikely(group.match_empty().any_bit_set())/' "$MODRS"
sed -i 's/self\.stride += Group::WIDTH;/\/\/ LINEAR/;s/self\.pos += self\.stride;/self.pos += Group::WIDTH;/' "$MODRS"
sed -i '/pub fn find(&self, hash: u64, mut eq: impl FnMut(&T) -> bool) -> Option<Bucket<T>> {/,/let result = self/{
    /let result = self/i\
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
cargo build --release 2>&1 | grep "^error" || true
cp target/release/hashbrown-improvements /tmp/hb2_all

# Restore
cp /tmp/hashbrown_mod_original.rs "$MODRS"
update_checksum

echo "All variants built."
