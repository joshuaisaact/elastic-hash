//! Rust port of the flat SIMD hash table with separated fingerprint metadata.
//! Same design as the Zig flat_hash.zig: separated fingerprint + entry arrays,
//! linear probing, 8-bit fingerprints, cold-hinted early termination.
//!
//! Uses ahash (same as the hashbrown benchmark) for a fair comparison.

use std::hash::{BuildHasher, Hash, Hasher};

const BUCKET_SIZE: usize = 16;
const MAX_PROBES: usize = 7;
const TOMBSTONE: u8 = 0xFF;

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[inline]
#[cfg(target_arch = "x86_64")]
unsafe fn match_fingerprint(fps: *const u8, fp: u8) -> u16 {
    let v = _mm_loadu_si128(fps as *const __m128i);
    let needle = _mm_set1_epi8(fp as i8);
    let cmp = _mm_cmpeq_epi8(v, needle);
    _mm_movemask_epi8(cmp) as u16
}

#[inline]
#[cfg(target_arch = "x86_64")]
unsafe fn match_empty(fps: *const u8) -> u16 {
    match_fingerprint(fps, 0)
}

#[inline]
#[cfg(target_arch = "x86_64")]
unsafe fn match_empty_or_tombstone(fps: *const u8) -> u16 {
    match_empty(fps) | match_fingerprint(fps, TOMBSTONE)
}

// Portable fallback for non-x86
#[cfg(not(target_arch = "x86_64"))]
unsafe fn match_fingerprint(fps: *const u8, fp: u8) -> u16 {
    let mut mask: u16 = 0;
    for i in 0..BUCKET_SIZE {
        if *fps.add(i) == fp { mask |= 1 << i; }
    }
    mask
}

#[cfg(not(target_arch = "x86_64"))]
unsafe fn match_empty(fps: *const u8) -> u16 { match_fingerprint(fps, 0) }

#[cfg(not(target_arch = "x86_64"))]
unsafe fn match_empty_or_tombstone(fps: *const u8) -> u16 {
    match_empty(fps) | match_fingerprint(fps, TOMBSTONE)
}

pub struct FlatHash<'a, H: BuildHasher> {
    fingerprints: Vec<[u8; BUCKET_SIZE]>,
    entries: Vec<[Entry<'a>; BUCKET_SIZE]>,
    bucket_mask: usize,
    bucket_shift: u32,
    num_buckets: usize,
    count: usize,
    hasher: H,
}

#[derive(Clone, Copy)]
struct Entry<'a> {
    key: &'a [u8],
    value: u64,
}

impl<'a> Default for Entry<'a> {
    fn default() -> Self {
        Entry { key: &[], value: 0 }
    }
}

impl<'a, H: BuildHasher> FlatHash<'a, H> {
    pub fn with_capacity_and_hasher(n: usize, hasher: H) -> Self {
        let capacity = n.next_power_of_two().max(BUCKET_SIZE * 2);
        let num_buckets = capacity / BUCKET_SIZE;
        FlatHash {
            fingerprints: vec![[0u8; BUCKET_SIZE]; num_buckets],
            entries: vec![[Entry::default(); BUCKET_SIZE]; num_buckets],
            bucket_mask: num_buckets - 1,
            bucket_shift: (64 - num_buckets.trailing_zeros()).min(63),
            num_buckets,
            count: 0,
            hasher,
        }
    }

    #[inline]
    fn hash_key(&self, key: &[u8]) -> u64 {
        let mut h = self.hasher.build_hasher();
        key.hash(&mut h);
        h.finish()
    }

    #[inline]
    fn fingerprint(h: u64) -> u8 {
        let fp = (h >> 32) as u8;
        if fp == 0 { 1 } else if fp == TOMBSTONE { 0xFE } else { fp }
    }

    pub fn insert(&mut self, key: &'a [u8], value: u64) {
        let h = self.hash_key(key);
        let fp = Self::fingerprint(h);
        let base = h >> self.bucket_shift;

        for probe in 0..MAX_PROBES {
            let bi = (base.wrapping_add(probe as u64) as usize) & self.bucket_mask;
            let mask = unsafe { match_empty_or_tombstone(self.fingerprints[bi].as_ptr()) };
            if mask != 0 {
                let slot = mask.trailing_zeros() as usize;
                self.fingerprints[bi][slot] = fp;
                self.entries[bi][slot] = Entry { key, value };
                self.count += 1;
                return;
            }
        }
    }

    #[inline]
    pub fn get(&self, key: &[u8]) -> Option<u64> {
        let h = self.hash_key(key);
        let fp = Self::fingerprint(h);
        let base = h >> self.bucket_shift;

        // Prefetch entry data for probe 0
        let probe0_bi = (base as usize) & self.bucket_mask;
        unsafe {
            #[cfg(target_arch = "x86_64")]
            _mm_prefetch(
                self.entries[probe0_bi].as_ptr() as *const i8,
                _MM_HINT_T0,
            );
        }

        for probe in 0..MAX_PROBES {
            let bi = (base.wrapping_add(probe as u64) as usize) & self.bucket_mask;
            let mut mask = unsafe { match_fingerprint(self.fingerprints[bi].as_ptr(), fp) };
            while mask != 0 {
                let s = mask.trailing_zeros() as usize;
                let entry = &self.entries[bi][s];
                if entry.key == key {
                    return Some(entry.value);
                }
                mask &= mask - 1;
            }
            if unsafe { match_empty(self.fingerprints[bi].as_ptr()) } != 0 {
                return None;
            }
        }
        None
    }

    pub fn remove(&mut self, key: &[u8]) -> bool {
        let h = self.hash_key(key);
        let fp = Self::fingerprint(h);
        let base = h >> self.bucket_shift;

        for probe in 0..MAX_PROBES {
            let bi = (base.wrapping_add(probe as u64) as usize) & self.bucket_mask;
            let mut mask = unsafe { match_fingerprint(self.fingerprints[bi].as_ptr(), fp) };
            while mask != 0 {
                let s = mask.trailing_zeros() as usize;
                if self.entries[bi][s].key == key {
                    self.fingerprints[bi][s] = TOMBSTONE;
                    self.count -= 1;
                    return true;
                }
                mask &= mask - 1;
            }
        }
        false
    }
}
