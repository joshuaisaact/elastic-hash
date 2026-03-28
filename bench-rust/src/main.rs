mod flat_hash;

use std::collections::HashMap;
use std::hash::BuildHasherDefault;
use std::hint::black_box;
use std::time::Instant;
use ahash::AHasher;
use flat_hash::FlatHash;

type FastMap<'a> = HashMap<&'a [u8], u64, BuildHasherDefault<AHasher>>;

const KEY_SEED: u64 = 0xDEADBEEF12345678;
const MISS_SEED: u64 = 0xCAFEBABE87654321;
const TOTAL_RUNS: usize = 12;
const WARMUP: usize = 2;
const MEASURED: usize = TOTAL_RUNS - WARMUP;

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

fn gen_keys(fill: usize) -> (Vec<[u8; 16]>, Vec<[u8; 16]>, Vec<usize>) {
    let mut keys: Vec<[u8; 16]> = vec![[0u8; 16]; fill];
    let mut miss_keys: Vec<[u8; 16]> = vec![[0u8; 16]; fill];
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
    (keys, miss_keys, order)
}

fn bench_hashbrown(n: usize, fill: usize, load_pct: usize,
                   keys: &[[u8; 16]], miss_keys: &[[u8; 16]], order: &[usize]) {
    let mut ins = [0u64; MEASURED];
    let mut lkp = [0u64; MEASURED];
    let mut del = [0u64; MEASURED];
    let mut mis = [0u64; MEASURED];

    for r in 0..TOTAL_RUNS {
        let mut map: FastMap = HashMap::with_capacity_and_hasher(n, Default::default());

        let start = Instant::now();
        for i in 0..fill {
            map.insert(&keys[i], i as u64);
        }
        let insert_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill {
            black_box(map.get(&keys[order[i]] as &[u8]));
        }
        let lookup_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill {
            black_box(map.get(&miss_keys[order[i]] as &[u8]));
        }
        let miss_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill / 2 {
            black_box(map.remove(&keys[i] as &[u8]));
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
        "HASHBROWN\tn={}\tload={}\tinsert={}\thit={}\tmiss={}\tdelete={}",
        n, load_pct,
        median(&mut ins), median(&mut lkp), median(&mut mis), median(&mut del)
    );
}

fn bench_flat(n: usize, fill: usize, load_pct: usize,
              keys: &[[u8; 16]], miss_keys: &[[u8; 16]], order: &[usize]) {
    let mut ins = [0u64; MEASURED];
    let mut lkp = [0u64; MEASURED];
    let mut del = [0u64; MEASURED];
    let mut mis = [0u64; MEASURED];

    for r in 0..TOTAL_RUNS {
        let hasher: BuildHasherDefault<AHasher> = Default::default();
        let mut map = FlatHash::with_capacity_and_hasher(n, hasher);

        let start = Instant::now();
        for i in 0..fill {
            map.insert(&keys[i], i as u64);
        }
        let insert_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill {
            black_box(map.get(&keys[order[i]]));
        }
        let lookup_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill {
            black_box(map.get(&miss_keys[order[i]]));
        }
        let miss_us = start.elapsed().as_micros() as u64;

        let start = Instant::now();
        for i in 0..fill / 2 {
            black_box(map.remove(&keys[i]));
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
        "FLAT-RUST\tn={}\tload={}\tinsert={}\thit={}\tmiss={}\tdelete={}",
        n, load_pct,
        median(&mut ins), median(&mut lkp), median(&mut mis), median(&mut del)
    );
}

fn main() {
    eprintln!("=== Rust vs Rust: hashbrown (ahash) vs flat hash (ahash) ===");
    eprintln!("=== Same hash function, same keys, same methodology ===\n");

    // Size sweep at 50% load
    println!("--- Size sweep (50% load, shuffled, string keys) ---");
    for n in [16_384, 65_536, 262_144, 1_048_576, 4_194_304] {
        let fill = n / 2;
        let (keys, miss_keys, order) = gen_keys(fill);
        bench_flat(n, fill, 50, &keys, &miss_keys, &order);
        bench_hashbrown(n, fill, 50, &keys, &miss_keys, &order);
        println!();
    }

    // Load factor sweep at 1M
    println!("--- Load factor sweep (1M, shuffled, string keys) ---");
    for pct in [10, 25, 50, 75, 90, 99] {
        let n = 1_048_576;
        let fill = n * pct / 100;
        let (keys, miss_keys, order) = gen_keys(fill);
        bench_flat(n, fill, pct, &keys, &miss_keys, &order);
        bench_hashbrown(n, fill, pct, &keys, &miss_keys, &order);
        println!();
    }

    eprintln!("DONE");
}
