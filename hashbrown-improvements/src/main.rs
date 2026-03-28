mod flat_hash;

use std::collections::HashMap;
use std::hash::BuildHasherDefault;
use std::hint::black_box;
use std::time::Instant;
use ahash::AHasher;
use flat_hash::{FlatHash, Probing};

type AHashBuilder = BuildHasherDefault<AHasher>;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const RUNS_PER_CONFIG: usize = 3;
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
    for i in (0..16).rev() {
        buf[i] = HEX[(v & 0xF) as usize];
        v >>= 4;
    }
}

fn median(arr: &mut [u64]) -> u64 {
    arr.sort();
    arr[arr.len() / 2]
}

/// Flush cache by allocating and touching a large buffer
fn flush_cache() {
    let size = 64 * 1024 * 1024; // 64MB > L3
    let mut buf = vec![0u8; size];
    for i in (0..size).step_by(64) {
        buf[i] = (i & 0xFF) as u8;
    }
    black_box(&buf);
    drop(buf);
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

/// Validate that a flat hash variant is correct
fn validate_flat(probing: Probing, prefetch: bool) -> bool {
    let hasher: AHashBuilder = Default::default();
    let mut map = FlatHash::new(1024, hasher, probing, prefetch);

    // Insert 500 keys
    let kd = gen_keys(500);
    for i in 0..500 {
        map.insert(&kd.keys[i], i as u64);
    }

    // Verify all present
    for i in 0..500 {
        if map.get(&kd.keys[i]) != Some(i as u64) {
            eprintln!("FAIL: key {} not found or wrong value", i);
            return false;
        }
    }

    // Verify misses
    for i in 0..500 {
        if map.get(&kd.miss_keys[i]).is_some() {
            eprintln!("FAIL: miss key {} found", i);
            return false;
        }
    }

    // Delete 250, verify
    for i in 0..250 {
        if !map.remove(&kd.keys[i]) {
            eprintln!("FAIL: delete key {} failed", i);
            return false;
        }
    }
    for i in 0..250 {
        if map.get(&kd.keys[i]).is_some() {
            eprintln!("FAIL: deleted key {} still found", i);
            return false;
        }
    }
    for i in 250..500 {
        if map.get(&kd.keys[i]) != Some(i as u64) {
            eprintln!("FAIL: surviving key {} wrong", i);
            return false;
        }
    }

    if map.len() != 250 {
        eprintln!("FAIL: wrong count {}", map.len());
        return false;
    }

    true
}

struct BenchResult {
    hit: u64,
    miss: u64,
    insert: u64,
    delete: u64,
}

fn bench_hashbrown(n: usize, fill: usize, kd: &KeyData) -> BenchResult {
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

    BenchResult {
        hit: median(&mut lkp), miss: median(&mut mis),
        insert: median(&mut ins), delete: median(&mut del),
    }
}

fn bench_flat(n: usize, fill: usize, kd: &KeyData, probing: Probing, prefetch: bool) -> BenchResult {
    let mut ins = [0u64; MEASURED];
    let mut lkp = [0u64; MEASURED];
    let mut mis = [0u64; MEASURED];
    let mut del = [0u64; MEASURED];

    for r in 0..TOTAL_RUNS {
        let hasher: AHashBuilder = Default::default();
        let mut map = FlatHash::new(n, hasher, probing, prefetch);

        let start = Instant::now();
        for i in 0..fill { map.insert(&kd.keys[i], i as u64); }
        let insert_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill { black_box(map.get(&kd.keys[kd.order[i]])); }
        let hit_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill { black_box(map.get(&kd.miss_keys[kd.order[i]])); }
        let miss_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill / 2 { black_box(map.remove(&kd.keys[i])); }
        let delete_us = start.elapsed().as_micros() as u64;

        if r >= WARMUP {
            let idx = r - WARMUP;
            ins[idx] = insert_us;
            lkp[idx] = hit_us;
            mis[idx] = miss_us;
            del[idx] = delete_us;
        }
    }

    BenchResult {
        hit: median(&mut lkp), miss: median(&mut mis),
        insert: median(&mut ins), delete: median(&mut del),
    }
}

fn label(probing: Probing, prefetch: bool) -> &'static str {
    match (probing, prefetch) {
        (Probing::Linear, true) => "linear+prefetch",
        (Probing::Linear, false) => "linear",
        (Probing::Triangular, true) => "triangular+prefetch",
        (Probing::Triangular, false) => "triangular",
    }
}

fn print_result(name: &str, n: usize, load: usize, run: usize, r: &BenchResult) {
    println!(
        "{}\tn={}\tload={}\trun={}\thit={}\tmiss={}\tinsert={}\tdelete={}",
        name, n, load, run, r.hit, r.miss, r.insert, r.delete
    );
}

fn main() {
    // Validate all 4 flat variants first
    eprintln!("Validating correctness...");
    for probing in [Probing::Linear, Probing::Triangular] {
        for prefetch in [true, false] {
            if !validate_flat(probing, prefetch) {
                eprintln!("VALIDATION FAILED: {:?} prefetch={}",
                    match probing { Probing::Linear => "linear", Probing::Triangular => "triangular" },
                    prefetch);
                std::process::exit(1);
            }
        }
    }
    eprintln!("All variants validated.\n");

    let configs: Vec<(usize, usize)> = vec![
        // (table_size, load_percent)
        (65_536, 50),
        (262_144, 50),
        (1_048_576, 25),
        (1_048_576, 50),
        (1_048_576, 75),
        (1_048_576, 90),
        (4_194_304, 50),
    ];

    let variants: Vec<(Probing, bool)> = vec![
        (Probing::Linear, true),
        (Probing::Linear, false),
        (Probing::Triangular, true),
        (Probing::Triangular, false),
    ];

    println!("=== HASHBROWN IMPROVEMENT ISOLATION ===");
    println!("=== 3 runs per config, cache flush between, ahash everywhere ===\n");

    for (n, pct) in &configs {
        let fill = n * pct / 100;
        let kd = gen_keys(fill);

        for run in 0..RUNS_PER_CONFIG {
            // Flush cache before each run
            flush_cache();
            let r = bench_hashbrown(*n, fill, &kd);
            print_result("hashbrown", *n, *pct, run, &r);

            for (probing, prefetch) in &variants {
                flush_cache();
                let r = bench_flat(*n, fill, &kd, *probing, *prefetch);
                print_result(label(*probing, *prefetch), *n, *pct, run, &r);
            }
            println!();
        }
        println!("---");
    }
}
