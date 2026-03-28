/// Benchmark: hashbrown with vs without entry prefetch.
/// Run with vendored hashbrown (has prefetch) and without (crates.io original).
use std::collections::HashMap;
use std::hash::BuildHasherDefault;
use std::hint::black_box;
use std::time::Instant;
use ahash::AHasher;

type AHashBuilder = BuildHasherDefault<AHasher>;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const WARMUP: usize = 2;
const MEASURED: usize = 10;
const TOTAL_RUNS: usize = WARMUP + MEASURED;

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
    for i in (0..16).rev() { buf[i] = HEX[(v & 0xF) as usize]; v >>= 4; }
}

fn median(arr: &mut [u64]) -> u64 { arr.sort(); arr[arr.len() / 2] }

fn flush_cache() {
    let size = 64 * 1024 * 1024;
    let mut buf = vec![0u8; size];
    for i in (0..size).step_by(64) { buf[i] = (i & 0xFF) as u8; }
    black_box(&buf);
}

struct KeyData {
    keys: Vec<[u8; 16]>,
    miss_keys: Vec<[u8; 16]>,
    order: Vec<usize>,
}

fn gen_keys(fill: usize) -> KeyData {
    let mut keys = vec![[0u8; 16]; fill];
    let mut miss_keys = vec![[0u8; 16]; fill];
    let mut ks = KEY_SEED;
    let mut ms = MISS_SEED;
    for i in 0..fill {
        u64_to_hex(splitmix64(&mut ks), &mut keys[i]);
        u64_to_hex(splitmix64(&mut ms), &mut miss_keys[i]);
    }
    let mut order: Vec<usize> = (0..fill).collect();
    let mut rng = 42u64;
    for i in (1..fill).rev() {
        let j = (splitmix64(&mut rng) as usize) % (i + 1);
        order.swap(i, j);
    }
    KeyData { keys, miss_keys, order }
}

fn bench(n: usize, fill: usize, pct: usize, kd: &KeyData) {
    let mut ins = [0u64; MEASURED];
    let mut lkp = [0u64; MEASURED];
    let mut mis = [0u64; MEASURED];
    let mut del = [0u64; MEASURED];

    for r in 0..TOTAL_RUNS {
        let mut map: HashMap<&[u8], u64, AHashBuilder> =
            HashMap::with_capacity_and_hasher(n, Default::default());

        let start = Instant::now();
        for i in 0..fill { map.insert(&kd.keys[i], i as u64); }
        let insert_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill { black_box(map.get(&kd.keys[kd.order[i]] as &[u8])); }
        let hit_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill { black_box(map.get(&kd.miss_keys[kd.order[i]] as &[u8])); }
        let miss_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill / 2 { black_box(map.remove(&kd.keys[i] as &[u8])); }
        let delete_us = start.elapsed().as_micros() as u64;

        if r >= WARMUP {
            let idx = r - WARMUP;
            ins[idx] = insert_us;
            lkp[idx] = hit_us;
            mis[idx] = miss_us;
            del[idx] = delete_us;
        }
    }

    println!("n={}\tload={}\thit={}\tmiss={}\tinsert={}\tdelete={}",
        n, pct, median(&mut lkp), median(&mut mis), median(&mut ins), median(&mut del));
}

fn main() {
    #[cfg(feature = "prefetch")]
    eprintln!("=== hashbrown WITH prefetch patch ===\n");
    #[cfg(not(feature = "prefetch"))]
    eprintln!("=== hashbrown (stock from vendor) ===\n");

    let configs: Vec<(usize, usize)> = vec![
        (65_536, 50), (262_144, 50),
        (1_048_576, 10), (1_048_576, 25), (1_048_576, 50), (1_048_576, 75), (1_048_576, 90),
        (4_194_304, 50),
    ];

    for run in 0..3 {
        eprintln!("--- Run {} ---", run);
        for (n, pct) in &configs {
            let fill = n * pct / 100;
            let kd = gen_keys(fill);
            flush_cache();
            bench(*n, fill, *pct, &kd);
        }
        println!();
    }
}
