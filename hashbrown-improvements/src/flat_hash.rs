/// Flat SIMD hash table with configurable probing and prefetch.
/// Used to isolate each optimization against hashbrown.
use std::hash::{BuildHasher, Hash, Hasher};

const BUCKET_SIZE: usize = 16;
const MAX_PROBES: usize = 7;
const TOMBSTONE: u8 = 0xFF;

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[inline]
#[cfg(target_arch = "x86_64")]
unsafe fn match_fingerprint(fps: *const u8, fp: u8) -> u16 {
    unsafe {
        let v = _mm_loadu_si128(fps as *const __m128i);
        let needle = _mm_set1_epi8(fp as i8);
        let cmp = _mm_cmpeq_epi8(v, needle);
        _mm_movemask_epi8(cmp) as u16
    }
}

#[inline]
#[cfg(target_arch = "x86_64")]
unsafe fn match_empty(fps: *const u8) -> u16 {
    unsafe { match_fingerprint(fps, 0) }
}

#[inline]
#[cfg(target_arch = "x86_64")]
unsafe fn match_empty_or_tombstone(fps: *const u8) -> u16 {
    unsafe { match_empty(fps) | match_fingerprint(fps, TOMBSTONE) }
}

#[derive(Clone, Copy)]
pub struct Entry<'a> {
    key: &'a [u8],
    value: u64,
}

impl<'a> Default for Entry<'a> {
    fn default() -> Self {
        Entry { key: &[], value: 0 }
    }
}

/// Probing strategy
#[derive(Clone, Copy)]
pub enum Probing {
    Linear,
    Triangular,
}

pub struct FlatHash<'a, H: BuildHasher> {
    fingerprints: Vec<[u8; BUCKET_SIZE]>,
    entries: Vec<[Entry<'a>; BUCKET_SIZE]>,
    bucket_mask: usize,
    bucket_shift: u32,
    count: usize,
    capacity: usize,
    hasher: H,
    probing: Probing,
    use_prefetch: bool,
}

impl<'a, H: BuildHasher> FlatHash<'a, H> {
    pub fn new(n: usize, hasher: H, probing: Probing, use_prefetch: bool) -> Self {
        let capacity = n.next_power_of_two().max(BUCKET_SIZE * 2);
        let num_buckets = capacity / BUCKET_SIZE;
        FlatHash {
            fingerprints: vec![[0u8; BUCKET_SIZE]; num_buckets],
            entries: vec![[Entry::default(); BUCKET_SIZE]; num_buckets],
            bucket_mask: num_buckets - 1,
            bucket_shift: (64 - num_buckets.trailing_zeros()).min(63),
            count: 0,
            capacity,
            hasher,
            probing,
            use_prefetch,
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

    #[inline]
    fn needs_resize(&self) -> bool {
        self.count * 8 > self.capacity * 7
    }

    fn resize(&mut self) {
        let new_capacity = self.capacity * 2;
        let new_num_buckets = new_capacity / BUCKET_SIZE;
        let old_fps = std::mem::replace(
            &mut self.fingerprints,
            vec![[0u8; BUCKET_SIZE]; new_num_buckets],
        );
        let old_entries = std::mem::replace(
            &mut self.entries,
            vec![[Entry::default(); BUCKET_SIZE]; new_num_buckets],
        );
        let old_num_buckets = old_fps.len();
        self.bucket_mask = new_num_buckets - 1;
        self.bucket_shift = (64 - new_num_buckets.trailing_zeros()).min(63);
        self.capacity = new_capacity;
        self.count = 0;

        for bi in 0..old_num_buckets {
            for si in 0..BUCKET_SIZE {
                let fp = old_fps[bi][si];
                if fp != 0 && fp != TOMBSTONE {
                    let entry = old_entries[bi][si];
                    self.insert_inner(entry.key, entry.value);
                }
            }
        }
    }

    fn insert_inner(&mut self, key: &'a [u8], value: u64) {
        let h = self.hash_key(key);
        let fp = Self::fingerprint(h);
        let base = (h >> self.bucket_shift) as usize;
        let mut pos = base & self.bucket_mask;
        let mut stride: usize = 0;

        for _ in 0..MAX_PROBES {
            let mask = unsafe { match_empty_or_tombstone(self.fingerprints[pos].as_ptr()) };
            if mask != 0 {
                let slot = mask.trailing_zeros() as usize;
                self.fingerprints[pos][slot] = fp;
                self.entries[pos][slot] = Entry { key, value };
                self.count += 1;
                return;
            }
            match self.probing {
                Probing::Linear => pos = (pos + 1) & self.bucket_mask,
                Probing::Triangular => {
                    stride += 1;
                    pos = (pos + stride) & self.bucket_mask;
                }
            }
        }
    }

    pub fn insert(&mut self, key: &'a [u8], value: u64) {
        if self.needs_resize() {
            self.resize();
        }
        self.insert_inner(key, value);
    }

    #[inline]
    pub fn get(&self, key: &[u8]) -> Option<u64> {
        let h = self.hash_key(key);
        let fp = Self::fingerprint(h);
        let base = (h >> self.bucket_shift) as usize;
        let mut pos = base & self.bucket_mask;
        let mut stride: usize = 0;

        if self.use_prefetch {
            #[cfg(target_arch = "x86_64")]
            unsafe {
                _mm_prefetch(
                    self.entries[pos].as_ptr() as *const i8,
                    _MM_HINT_T0,
                );
            }
        }

        for _ in 0..MAX_PROBES {
            let mut m = unsafe { match_fingerprint(self.fingerprints[pos].as_ptr(), fp) };
            while m != 0 {
                let s = m.trailing_zeros() as usize;
                let entry = &self.entries[pos][s];
                if entry.key == key {
                    return Some(entry.value);
                }
                m &= m - 1;
            }
            if unsafe { match_empty(self.fingerprints[pos].as_ptr()) } != 0 {
                return None;
            }
            match self.probing {
                Probing::Linear => pos = (pos + 1) & self.bucket_mask,
                Probing::Triangular => {
                    stride += 1;
                    pos = (pos + stride) & self.bucket_mask;
                }
            }
        }
        None
    }

    pub fn remove(&mut self, key: &[u8]) -> bool {
        let h = self.hash_key(key);
        let fp = Self::fingerprint(h);
        let base = (h >> self.bucket_shift) as usize;
        let mut pos = base & self.bucket_mask;
        let mut stride: usize = 0;

        for _ in 0..MAX_PROBES {
            let mut m = unsafe { match_fingerprint(self.fingerprints[pos].as_ptr(), fp) };
            while m != 0 {
                let s = m.trailing_zeros() as usize;
                if self.entries[pos][s].key == key {
                    self.fingerprints[pos][s] = TOMBSTONE;
                    self.count -= 1;
                    return true;
                }
                m &= m - 1;
            }
            match self.probing {
                Probing::Linear => pos = (pos + 1) & self.bucket_mask,
                Probing::Triangular => {
                    stride += 1;
                    pos = (pos + stride) & self.bucket_mask;
                }
            }
        }
        false
    }

    pub fn len(&self) -> usize {
        self.count
    }
}
