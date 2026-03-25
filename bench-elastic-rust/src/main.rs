/// Rust port of elastic hash — same algorithm, same layout.
/// Purpose: isolate data structure advantage from language/compiler effects.
///
/// Uses a simple wyhash-style hash to keep the comparison fair.
use std::hint::black_box;
use std::time::Instant;

const BUCKET_SIZE: usize = 16;
const MAX_PROBES: usize = 7;
const TOMBSTONE: u8 = 0xFF;
const KEY_LEN: usize = 16;

// ---- Simple wyhash-style multiply-mix hash ----
#[inline(always)]
fn wymix(a: u64, b: u64) -> u64 {
    let r = (a as u128).wrapping_mul(b as u128);
    ((r >> 64) as u64) ^ (r as u64)
}

#[inline(always)]
fn wyr8(p: &[u8]) -> u64 {
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&p[..8]);
    u64::from_le_bytes(buf)
}

fn wyhash(key: &[u8]) -> u64 {
    let s0: u64 = 0xa0761d6478bd642f;
    let s1: u64 = 0xe7037ed1a0b428db;

    let mut seed = s0;
    let len = key.len();
    let (a, b);

    if len <= 16 {
        if len >= 4 {
            let shift = (len >> 3) << 2;
            a = (wyr8(key) << 32) | (wyr8(&key[shift..]) >> 32);
            b = (wyr8(&key[len - 8..]) << 32) | (wyr8(&key[len - 4 - shift..]) >> 32);
        } else if len > 0 {
            a = ((key[0] as u64) << 16) | ((key[len >> 1] as u64) << 8) | key[len - 1] as u64;
            b = 0;
        } else {
            a = 0;
            b = 0;
        }
    } else {
        // Simplified: only handling <= 16 byte keys for this benchmark
        a = 0;
        b = 0;
    }

    wymix(s1 ^ (len as u64), wymix(a ^ s1, b ^ seed))
}

// ---- SIMD fingerprint matching ----
// On ARM, use NEON intrinsics. On x86, use SSE2.
// For portability, we use a scalar fallback that auto-vectorizes well.
#[inline(always)]
fn match_fingerprint(fps: &[u8; BUCKET_SIZE], fp: u8) -> u16 {
    let mut mask: u16 = 0;
    for i in 0..BUCKET_SIZE {
        if fps[i] == fp {
            mask |= 1 << i;
        }
    }
    mask
}

#[inline(always)]
fn match_empty(fps: &[u8; BUCKET_SIZE]) -> u16 {
    match_fingerprint(fps, 0)
}

#[inline(always)]
fn match_empty_or_tombstone(fps: &[u8; BUCKET_SIZE]) -> u16 {
    match_empty(fps) | match_fingerprint(fps, TOMBSTONE)
}

// ---- Data structures ----
#[derive(Clone, Copy)]
struct StringEntry {
    key_offset: usize, // index into key buffer
    key_len: usize,
    value: u64,
}

impl Default for StringEntry {
    fn default() -> Self {
        StringEntry {
            key_offset: 0,
            key_len: 0,
            value: 0,
        }
    }
}

struct ElasticHashRust {
    fingerprints: Vec<[u8; BUCKET_SIZE]>,
    entries: Vec<[StringEntry; BUCKET_SIZE]>,
    tier0_bucket_mask: usize,
    tier0_bucket_shift: u32,
    tier_starts: Vec<usize>,
    tier_bucket_counts: Vec<usize>,
    tier_slot_counts: Vec<usize>,
    num_tiers: usize,
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

        let fingerprints = vec![[0u8; BUCKET_SIZE]; total_buckets];
        let entries = vec![[StringEntry::default(); BUCKET_SIZE]; total_buckets];

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
            count: 0,
            current_batch: 0,
        }
    }

    #[inline(always)]
    fn hash(key: &[u8]) -> u64 {
        wyhash(key)
    }

    #[inline(always)]
    fn fingerprint(h: u64) -> u8 {
        let fp = (h >> 32) as u8;
        if fp == 0 {
            1
        } else if fp == TOMBSTONE {
            0xFE
        } else {
            fp
        }
    }

    #[inline(always)]
    fn bucket_index(h: u64, probe: usize, num_buckets: usize) -> usize {
        let bits = num_buckets.trailing_zeros();
        let shift = (64 - bits).min(63);
        let base = h >> shift;
        (base.wrapping_add(probe as u64) as usize) & (num_buckets - 1)
    }

    fn insert(&mut self, key_offset: usize, key: &[u8], value: u64) {
        let h = Self::hash(key);
        let fp = Self::fingerprint(h);

        if self.current_batch == 0 {
            self.insert_into_tier(0, h, fp, key_offset, key.len(), value);
            let used = self.tier_slot_counts[0] as f64;
            let total = (self.tier_bucket_counts[0] * BUCKET_SIZE) as f64;
            if 1.0 - used / total <= 0.12 {
                self.current_batch = 1;
            }
            return;
        }
        self.insert_into_tier(0, h, fp, key_offset, key.len(), value);
    }

    fn insert_into_tier(
        &mut self,
        tier: usize,
        h: u64,
        fp: u8,
        key_offset: usize,
        key_len: usize,
        value: u64,
    ) {
        let num_buckets = self.tier_bucket_counts[tier];
        let max_probe = num_buckets.min(MAX_PROBES);
        for probe in 0..max_probe {
            let rel = Self::bucket_index(h, probe, num_buckets);
            let abs_idx = self.tier_starts[tier] + rel;
            let mask = match_empty_or_tombstone(&self.fingerprints[abs_idx]);
            if mask != 0 {
                let slot = mask.trailing_zeros() as usize;
                self.fingerprints[abs_idx][slot] = fp;
                self.entries[abs_idx][slot] = StringEntry {
                    key_offset,
                    key_len,
                    value,
                };
                self.tier_slot_counts[tier] += 1;
                self.count += 1;
                return;
            }
        }
        // Overflow: try any tier
        for j in 1..=MAX_PROBES {
            for t in 0..self.num_tiers {
                let nb = self.tier_bucket_counts[t];
                if j - 1 >= nb {
                    continue;
                }
                let rel = Self::bucket_index(h, j - 1, nb);
                let abs_idx = self.tier_starts[t] + rel;
                let mask = match_empty_or_tombstone(&self.fingerprints[abs_idx]);
                if mask != 0 {
                    let slot = mask.trailing_zeros() as usize;
                    self.fingerprints[abs_idx][slot] = fp;
                    self.entries[abs_idx][slot] = StringEntry {
                        key_offset,
                        key_len,
                        value,
                    };
                    self.tier_slot_counts[t] += 1;
                    self.count += 1;
                    return;
                }
            }
        }
    }

    #[inline(never)]
    fn get_overflow(&self, h: u64, key: &[u8], fp: u8, key_buf: &[u8]) -> Option<u64> {
        if self.num_tiers <= 1 {
            return None;
        }
        let nb = self.tier_bucket_counts[1];
        let ts = self.tier_starts[1];
        let max_p = MAX_PROBES.min(nb);
        for probe in 0..max_p {
            let abs_idx = ts + Self::bucket_index(h, probe, nb);
            let mut mask = match_fingerprint(&self.fingerprints[abs_idx], fp);
            while mask != 0 {
                let slot = mask.trailing_zeros() as usize;
                let e = &self.entries[abs_idx][slot];
                let stored = &key_buf[e.key_offset..e.key_offset + e.key_len];
                if stored == key {
                    return Some(e.value);
                }
                mask &= mask - 1;
            }
            if match_empty(&self.fingerprints[abs_idx]) != 0 {
                return None;
            }
        }
        None
    }

    #[inline(always)]
    fn get(&self, key: &[u8], key_buf: &[u8]) -> Option<u64> {
        let h = Self::hash(key);
        let fp = Self::fingerprint(h);
        let mask = self.tier0_bucket_mask;
        let bucket_base = (h >> self.tier0_bucket_shift) as usize;

        for probe in 0..MAX_PROBES {
            let bucket_idx = (bucket_base + probe) & mask;
            // Check fingerprint matches
            let mut fpmask = match_fingerprint(&self.fingerprints[bucket_idx], fp);
            while fpmask != 0 {
                let slot = fpmask.trailing_zeros() as usize;
                let e = &self.entries[bucket_idx][slot];
                let stored = &key_buf[e.key_offset..e.key_offset + e.key_len];
                if stored == key {
                    return Some(e.value);
                }
                fpmask &= fpmask - 1;
            }
            // Early termination (cold path)
            if match_empty(&self.fingerprints[bucket_idx]) != 0 {
                return None;
            }
        }

        self.get_overflow(h, key, fp, key_buf)
    }

    fn remove(&mut self, key: &[u8], key_buf: &[u8]) -> bool {
        let h = Self::hash(key);
        let fp = Self::fingerprint(h);
        let mask = self.tier0_bucket_mask;
        let bucket_base = (h >> self.tier0_bucket_shift) as usize;

        for probe in 0..MAX_PROBES {
            let bucket_idx = (bucket_base + probe) & mask;
            let mut fpmask = match_fingerprint(&self.fingerprints[bucket_idx], fp);
            while fpmask != 0 {
                let slot = fpmask.trailing_zeros() as usize;
                let e = &self.entries[bucket_idx][slot];
                let stored = &key_buf[e.key_offset..e.key_offset + e.key_len];
                if stored == key {
                    self.fingerprints[bucket_idx][slot] = TOMBSTONE;
                    self.count -= 1;
                    return true;
                }
                fpmask &= fpmask - 1;
            }
        }
        false
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
    // Generate all keys in a flat buffer
    let mut key_buf = vec![0u8; fill * KEY_LEN];
    let mut miss_buf = vec![0u8; fill * KEY_LEN];
    let mut ks = KEY_SEED;
    let mut ms = MISS_SEED;
    for i in 0..fill {
        let mut tmp = [0u8; 16];
        u64_to_hex(splitmix64(&mut ks), &mut tmp);
        key_buf[i * KEY_LEN..(i + 1) * KEY_LEN].copy_from_slice(&tmp);
        u64_to_hex(splitmix64(&mut ms), &mut tmp);
        miss_buf[i * KEY_LEN..(i + 1) * KEY_LEN].copy_from_slice(&tmp);
    }

    // Shuffle order
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
            let key = &key_buf[i * KEY_LEN..(i + 1) * KEY_LEN];
            map.insert(i * KEY_LEN, key, i as u64);
        }
        let insert_us = start.elapsed().as_micros() as u64;

        // Shuffled hit lookup
        let start = Instant::now();
        for i in 0..fill {
            let ki = order[i];
            let key = &key_buf[ki * KEY_LEN..(ki + 1) * KEY_LEN];
            black_box(map.get(key, &key_buf));
        }
        let lookup_us = start.elapsed().as_micros() as u64;

        // Shuffled miss lookup
        let start = Instant::now();
        for i in 0..fill {
            let ki = order[i];
            let key = &miss_buf[ki * KEY_LEN..(ki + 1) * KEY_LEN];
            black_box(map.get(key, &miss_buf));
        }
        let miss_us = start.elapsed().as_micros() as u64;

        // Delete half
        let start = Instant::now();
        for i in 0..fill / 2 {
            let key = &key_buf[i * KEY_LEN..(i + 1) * KEY_LEN];
            black_box(map.remove(key, &key_buf));
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
        n,
        load_pct,
        median(&mut ins),
        median(&mut lkp),
        median(&mut del),
        median(&mut mis)
    );
}

fn main() {
    eprintln!("=== Elastic Hash Rust port ===");

    for pct in [10, 25, 50, 75, 90, 99] {
        let n = 1_048_576;
        let fill = n * pct / 100;
        bench(n, fill, pct);
    }

    eprintln!("DONE");
}
