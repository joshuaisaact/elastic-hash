/// Rust port of elastic hash — faithful to the Zig implementation.
/// Raw pointers for key storage (no bounds-checked slices on hot path).
/// Explicit SIMD via std::arch where available.
use std::hint::black_box;
use std::time::Instant;

const BUCKET_SIZE: usize = 16;
const MAX_PROBES: usize = 7;
const TOMBSTONE: u8 = 0xFF;
const KEY_LEN: usize = 16;
const DELTA: f64 = 0.01;
const DELTA_HALF: f64 = DELTA / 2.0;
const PROBE_CONSTANT: f64 = 16.0;

// ---- wyhash (matching Zig's std.hash.Wyhash for <= 16 byte keys) ----
#[inline(always)]
fn wymix(a: u64, b: u64) -> u64 {
    let r = (a as u128).wrapping_mul(b as u128);
    ((r >> 64) as u64) ^ (r as u64)
}

#[inline(always)]
fn wyr8(p: *const u8) -> u64 {
    unsafe { (p as *const u64).read_unaligned() }
}

#[inline(always)]
fn wyhash(key: *const u8, len: usize) -> u64 {
    let s0: u64 = 0xa0761d6478bd642f;
    let s1: u64 = 0xe7037ed1a0b428db;
    let seed = s0;
    let (a, b);

    if len <= 16 {
        if len >= 4 {
            let shift = (len >> 3) << 2;
            unsafe {
                a = (wyr8(key) << 32) | (wyr8(key.add(shift)) >> 32);
                b = (wyr8(key.add(len - 8)) << 32) | (wyr8(key.add(len - 4 - shift)) >> 32);
            }
        } else if len > 0 {
            unsafe {
                a = ((*key) as u64) << 16 | ((*key.add(len >> 1)) as u64) << 8 | (*key.add(len - 1)) as u64;
            }
            b = 0;
        } else {
            a = 0;
            b = 0;
        }
    } else {
        a = 0;
        b = 0;
    }

    wymix(s1 ^ (len as u64), wymix(a ^ s1, b ^ seed))
}

// ---- SIMD fingerprint matching ----
#[cfg(target_arch = "aarch64")]
#[inline(always)]
fn match_fingerprint(fps: *const [u8; BUCKET_SIZE], fp: u8) -> u16 {
    use std::arch::aarch64::*;
    unsafe {
        let v = vld1q_u8(fps as *const u8);
        let needle = vdupq_n_u8(fp);
        let cmp = vceqq_u8(v, needle);
        // Extract bitmask: shift each lane to a unique bit position
        let shift_table: [u8; 16] = [1,2,4,8,16,32,64,128,1,2,4,8,16,32,64,128];
        let shift = vld1q_u8(shift_table.as_ptr());
        let bits = vandq_u8(cmp, shift);
        let lo = vget_low_u8(bits);
        let hi = vget_high_u8(bits);
        let lo = vpadd_u8(lo, lo);
        let lo = vpadd_u8(lo, lo);
        let lo = vpadd_u8(lo, lo);
        let hi = vpadd_u8(hi, hi);
        let hi = vpadd_u8(hi, hi);
        let hi = vpadd_u8(hi, hi);
        let lo_val = vget_lane_u8(lo, 0) as u16;
        let hi_val = vget_lane_u8(hi, 0) as u16;
        (hi_val << 8) | lo_val
    }
}

#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
fn match_fingerprint(fps: *const [u8; BUCKET_SIZE], fp: u8) -> u16 {
    unsafe {
        let mut mask: u16 = 0;
        for i in 0..BUCKET_SIZE {
            if (*fps)[i] == fp {
                mask |= 1 << i;
            }
        }
        mask
    }
}

#[inline(always)]
fn match_empty(fps: *const [u8; BUCKET_SIZE]) -> u16 {
    match_fingerprint(fps, 0)
}

#[inline(always)]
fn match_empty_or_tombstone(fps: *const [u8; BUCKET_SIZE]) -> u16 {
    match_empty(fps) | match_fingerprint(fps, TOMBSTONE)
}

// ---- Data structures ----
#[derive(Clone, Copy)]
struct StringEntry {
    key_ptr: *const u8,
    key_len: usize,
    value: u64,
}

impl Default for StringEntry {
    fn default() -> Self {
        StringEntry {
            key_ptr: std::ptr::null(),
            key_len: 0,
            value: 0,
        }
    }
}

struct ElasticHashRust {
    fingerprints: *mut [u8; BUCKET_SIZE],
    entries: *mut [StringEntry; BUCKET_SIZE],
    tier0_bucket_mask: usize,
    tier0_bucket_shift: u32,
    tier_starts: Vec<usize>,
    tier_bucket_counts: Vec<usize>,
    tier_slot_counts: Vec<usize>,
    num_tiers: usize,
    total_buckets: usize,
    count: usize,
    current_batch: usize,
}

impl ElasticHashRust {
    fn new(n: usize) -> Self {
        let capacity = n.next_power_of_two();
        let t0_buckets = (capacity / BUCKET_SIZE).max(1);
        let num_tiers = (usize::BITS - t0_buckets.leading_zeros()) as usize;

        let mut tier_starts = vec![0usize; num_tiers];
        let mut tier_bucket_counts = vec![0usize; num_tiers];
        let tier_slot_counts = vec![0usize; num_tiers];

        let mut total_buckets = 0usize;
        let mut bkt = t0_buckets;
        for i in 0..num_tiers {
            bkt = bkt.max(1);
            tier_starts[i] = total_buckets;
            tier_bucket_counts[i] = bkt;
            total_buckets += bkt;
            bkt /= 2;
        }

        let fp_layout = std::alloc::Layout::array::<[u8; BUCKET_SIZE]>(total_buckets).unwrap();
        let entry_layout = std::alloc::Layout::array::<[StringEntry; BUCKET_SIZE]>(total_buckets).unwrap();
        let fingerprints;
        let entries;
        unsafe {
            fingerprints = std::alloc::alloc_zeroed(fp_layout) as *mut [u8; BUCKET_SIZE];
            entries = std::alloc::alloc_zeroed(entry_layout) as *mut [StringEntry; BUCKET_SIZE];
        }

        let shift = 64 - t0_buckets.trailing_zeros();

        ElasticHashRust {
            fingerprints,
            entries,
            tier0_bucket_mask: t0_buckets - 1,
            tier0_bucket_shift: shift,
            tier_starts,
            tier_bucket_counts,
            tier_slot_counts,
            num_tiers,
            total_buckets,
            count: 0,
            current_batch: 0,
        }
    }

    #[inline(always)]
    fn hash(key: *const u8, len: usize) -> u64 {
        wyhash(key, len)
    }

    #[inline(always)]
    fn fingerprint(h: u64) -> u8 {
        let fp = (h >> 32) as u8;
        if fp == 0 { 1 } else if fp == TOMBSTONE { 0xFE } else { fp }
    }

    #[inline(always)]
    fn bucket_index(h: u64, probe: usize, num_buckets: usize) -> usize {
        let bits = num_buckets.trailing_zeros();
        let shift = (64 - bits).min(63);
        let base = h >> shift;
        (base.wrapping_add(probe as u64) as usize) & (num_buckets - 1)
    }

    fn get_empty_fraction(&self, tier: usize) -> f64 {
        let used = self.tier_slot_counts[tier] as f64;
        let total = (self.tier_bucket_counts[tier] * BUCKET_SIZE) as f64;
        1.0 - used / total
    }

    fn probe_limit(epsilon: f64) -> usize {
        if epsilon <= 0.0 { return MAX_PROBES; }
        let log_inv_eps = (1.0 / epsilon).ln();
        let log_inv_delta = (1.0 / DELTA).ln();
        let limit = PROBE_CONSTANT * (log_inv_eps * log_inv_eps).min(log_inv_delta);
        (limit.max(1.0) as usize).min(MAX_PROBES)
    }

    fn try_insert_with_limit(&mut self, tier: usize, h: u64, fp: u8,
                              key: *const u8, key_len: usize, value: u64, limit: usize) -> bool {
        let num_buckets = self.tier_bucket_counts[tier];
        let max_probe = limit.min(num_buckets);
        for probe in 0..max_probe {
            let rel = Self::bucket_index(h, probe, num_buckets);
            let abs_idx = self.tier_starts[tier] + rel;
            unsafe {
                let mask = match_empty_or_tombstone(self.fingerprints.add(abs_idx));
                if mask != 0 {
                    let slot = mask.trailing_zeros() as usize;
                    (*self.fingerprints.add(abs_idx))[slot] = fp;
                    (*self.entries.add(abs_idx))[slot] = StringEntry { key_ptr: key, key_len, value };
                    self.tier_slot_counts[tier] += 1;
                    self.count += 1;
                    return true;
                }
            }
        }
        false
    }

    fn insert(&mut self, key: *const u8, key_len: usize, value: u64) {
        let h = Self::hash(key, key_len);
        let fp = Self::fingerprint(h);
        let i = self.current_batch;

        if i == 0 {
            self.insert_into_tier(0, h, fp, key, key_len, value);
            if self.get_empty_fraction(0) <= 0.12 {
                self.current_batch = 1;
            }
            return;
        }

        if i >= self.num_tiers {
            self.insert_any_tier(h, fp, key, key_len, value);
            return;
        }

        let primary = i - 1;
        let secondary = i;
        let e1 = self.get_empty_fraction(primary);
        let e2 = self.get_empty_fraction(secondary);

        if e1 > DELTA_HALF && e2 > 0.25 {
            if !self.try_insert_with_limit(primary, h, fp, key, key_len, value, Self::probe_limit(e1)) {
                self.insert_into_tier(secondary, h, fp, key, key_len, value);
            }
        } else if e1 <= DELTA_HALF {
            self.insert_into_tier(secondary, h, fp, key, key_len, value);
        } else {
            self.insert_into_tier(primary, h, fp, key, key_len, value);
        }

        if e1 <= DELTA_HALF && e2 <= 0.25 && i + 1 < self.num_tiers {
            self.current_batch = i + 1;
        }
    }

    fn insert_into_tier(&mut self, tier: usize, h: u64, fp: u8,
                         key: *const u8, key_len: usize, value: u64) {
        let num_buckets = self.tier_bucket_counts[tier];
        let max_probe = num_buckets.min(MAX_PROBES);
        for probe in 0..max_probe {
            let rel = Self::bucket_index(h, probe, num_buckets);
            let abs_idx = self.tier_starts[tier] + rel;
            unsafe {
                let mask = match_empty_or_tombstone(self.fingerprints.add(abs_idx));
                if mask != 0 {
                    let slot = mask.trailing_zeros() as usize;
                    (*self.fingerprints.add(abs_idx))[slot] = fp;
                    (*self.entries.add(abs_idx))[slot] = StringEntry { key_ptr: key, key_len, value };
                    self.tier_slot_counts[tier] += 1;
                    self.count += 1;
                    return;
                }
            }
        }
        self.insert_any_tier(h, fp, key, key_len, value);
    }

    fn insert_any_tier(&mut self, h: u64, fp: u8, key: *const u8, key_len: usize, value: u64) {
        for j in 1..=MAX_PROBES {
            for t in 0..self.num_tiers {
                let nb = self.tier_bucket_counts[t];
                if j - 1 >= nb { continue; }
                let rel = Self::bucket_index(h, j - 1, nb);
                let abs_idx = self.tier_starts[t] + rel;
                unsafe {
                    let mask = match_empty_or_tombstone(self.fingerprints.add(abs_idx));
                    if mask != 0 {
                        let slot = mask.trailing_zeros() as usize;
                        (*self.fingerprints.add(abs_idx))[slot] = fp;
                        (*self.entries.add(abs_idx))[slot] = StringEntry { key_ptr: key, key_len, value };
                        self.tier_slot_counts[t] += 1;
                        self.count += 1;
                        return;
                    }
                }
            }
        }
    }

    #[inline(never)]
    fn get_overflow(&self, h: u64, key: *const u8, key_len: usize, fp: u8) -> Option<u64> {
        if self.num_tiers <= 1 { return None; }
        let nb = self.tier_bucket_counts[1];
        let ts = self.tier_starts[1];
        let max_p = MAX_PROBES.min(nb);
        for probe in 0..max_p {
            let abs_idx = ts + Self::bucket_index(h, probe, nb);
            unsafe {
                let mut mask = match_fingerprint(self.fingerprints.add(abs_idx), fp);
                while mask != 0 {
                    let slot = mask.trailing_zeros() as usize;
                    let e = &(*self.entries.add(abs_idx))[slot];
                    if e.key_len == key_len &&
                       std::slice::from_raw_parts(e.key_ptr, e.key_len) ==
                       std::slice::from_raw_parts(key, key_len) {
                        return Some(e.value);
                    }
                    mask &= mask - 1;
                }
                if match_empty(self.fingerprints.add(abs_idx)) != 0 {
                    return None;
                }
            }
        }
        None
    }

    #[inline(always)]
    fn get(&self, key: *const u8, key_len: usize) -> Option<u64> {
        let h = Self::hash(key, key_len);
        let fp = Self::fingerprint(h);
        let mask = self.tier0_bucket_mask;
        let bucket_base = (h >> self.tier0_bucket_shift) as usize;

        // Prefetch entry data for probe 0
        unsafe {
            let ptr = self.entries.add(bucket_base & mask) as *const u8;
            std::arch::asm!("prfm pldl1keep, [{ptr}]", ptr = in(reg) ptr, options(nostack, preserves_flags));
        }

        for probe in 0..MAX_PROBES {
            let bucket_idx = (bucket_base + probe) & mask;
            unsafe {
                let mut fpmask = match_fingerprint(self.fingerprints.add(bucket_idx), fp);
                while fpmask != 0 {
                    let slot = fpmask.trailing_zeros() as usize;
                    let e = &(*self.entries.add(bucket_idx))[slot];
                    if e.key_len == key_len &&
                       std::slice::from_raw_parts(e.key_ptr, e.key_len) ==
                       std::slice::from_raw_parts(key, key_len) {
                        return Some(e.value);
                    }
                    fpmask &= fpmask - 1;
                }
                // Early termination (cold path)
                if match_empty(self.fingerprints.add(bucket_idx)) != 0 {
                    return None;
                }
            }
        }

        self.get_overflow(h, key, key_len, fp)
    }

    fn remove(&mut self, key: *const u8, key_len: usize) -> bool {
        let h = Self::hash(key, key_len);
        let fp = Self::fingerprint(h);
        let mask = self.tier0_bucket_mask;
        let bucket_base = (h >> self.tier0_bucket_shift) as usize;

        for probe in 0..MAX_PROBES {
            let bucket_idx = (bucket_base + probe) & mask;
            unsafe {
                let mut fpmask = match_fingerprint(self.fingerprints.add(bucket_idx), fp);
                while fpmask != 0 {
                    let slot = fpmask.trailing_zeros() as usize;
                    let e = &(*self.entries.add(bucket_idx))[slot];
                    if e.key_len == key_len &&
                       std::slice::from_raw_parts(e.key_ptr, e.key_len) ==
                       std::slice::from_raw_parts(key, key_len) {
                        (*self.fingerprints.add(bucket_idx))[slot] = TOMBSTONE;
                        self.count -= 1;
                        return true;
                    }
                    fpmask &= fpmask - 1;
                }
            }
        }
        false
    }
}

impl Drop for ElasticHashRust {
    fn drop(&mut self) {
        unsafe {
            let fp_layout = std::alloc::Layout::array::<[u8; BUCKET_SIZE]>(self.total_buckets).unwrap();
            let entry_layout = std::alloc::Layout::array::<[StringEntry; BUCKET_SIZE]>(self.total_buckets).unwrap();
            std::alloc::dealloc(self.fingerprints as *mut u8, fp_layout);
            std::alloc::dealloc(self.entries as *mut u8, entry_layout);
        }
    }
}

// ---- Benchmark harness ----
fn splitmix64(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9e3779b97f4a7c15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}

const HEX: &[u8; 16] = b"0123456789abcdef";

fn u64_to_hex(val: u64, buf: &mut [u8; 16]) {
    let mut v = val;
    for i in (0..16).rev() {
        buf[i] = HEX[(v & 0xF) as usize];
        v >>= 4;
    }
}

fn median(arr: &mut [u64]) -> u64 {
    arr.sort();
    arr[arr.len() / 2]
}

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const TOTAL_RUNS: usize = 12;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;

fn bench(n: usize, fill: usize, load_pct: usize) {
    let mut key_buf: Vec<[u8; KEY_LEN]> = vec![[0u8; KEY_LEN]; fill];
    let mut miss_buf: Vec<[u8; KEY_LEN]> = vec![[0u8; KEY_LEN]; fill];
    let mut ks = KEY_SEED;
    let mut ms = MISS_SEED;
    for i in 0..fill {
        u64_to_hex(splitmix64(&mut ks), &mut key_buf[i]);
        u64_to_hex(splitmix64(&mut ms), &mut miss_buf[i]);
    }

    let mut order: Vec<usize> = (0..fill).collect();
    let mut rng = 42u64;
    for i in (1..fill).rev() {
        let j = (splitmix64(&mut rng) as usize) % (i + 1);
        order.swap(i, j);
    }

    let mut ins = [0u64; MEASURED];
    let mut lkp = [0u64; MEASURED];
    let mut del = [0u64; MEASURED];
    let mut mis = [0u64; MEASURED];

    for r in 0..TOTAL_RUNS {
        let mut map = ElasticHashRust::new(n);

        let start = Instant::now();
        for i in 0..fill {
            map.insert(key_buf[i].as_ptr(), KEY_LEN, i as u64);
        }
        let insert_us = start.elapsed().as_micros() as u64;

        // Shuffled hit lookup
        let start = Instant::now();
        for i in 0..fill {
            black_box(map.get(key_buf[order[i]].as_ptr(), KEY_LEN));
        }
        let lookup_us = start.elapsed().as_micros() as u64;

        // Shuffled miss lookup
        let start = Instant::now();
        for i in 0..fill {
            black_box(map.get(miss_buf[order[i]].as_ptr(), KEY_LEN));
        }
        let miss_us = start.elapsed().as_micros() as u64;

        // Delete half
        let start = Instant::now();
        for i in 0..fill / 2 {
            black_box(map.remove(key_buf[i].as_ptr(), KEY_LEN));
        }
        let delete_us = start.elapsed().as_micros() as u64;

        if r >= WARMUP {
            let idx = r - WARMUP;
            ins[idx] = insert_us;
            lkp[idx] = lookup_us;
            del[idx] = delete_us;
            mis[idx] = miss_us;
        }
    }

    println!(
        "ELASTIC-RS\tn={}\tload={}\tinsert_us={}\tlookup_us={}\tdelete_us={}\tmiss_us={}",
        n, load_pct,
        median(&mut ins), median(&mut lkp), median(&mut del), median(&mut mis)
    );
}

fn main() {
    eprintln!("=== Elastic Hash Rust port (raw pointers, NEON SIMD) ===");

    for pct in [10, 25, 50, 75, 90, 99] {
        bench(1_048_576, 1_048_576 * pct / 100, pct);
    }

    eprintln!("DONE");
}
