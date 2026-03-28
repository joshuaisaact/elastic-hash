/// Full benchmark: multiple sizes, load factors, and operations.
/// Tests the modified hashbrown across the full parameter space.
use hashbrown::HashMap;
use std::hash::BuildHasherDefault;
use std::hint::black_box;
use std::time::Instant;
use ahash::AHasher;

type AHashBuilder = BuildHasherDefault<AHasher>;

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
    let mut ks = 0xDEADBEEF12345678u64;
    let mut ms = 0xCAFEBABE87654321u64;
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

const WARMUP: usize = 2;
const MEASURED: usize = 5;
const TOTAL: usize = WARMUP + MEASURED;

fn bench(n: usize, fill: usize, pct: usize, kd: &KeyData) {
    let mut ins = [0u64; MEASURED];
    let mut hit = [0u64; MEASURED];
    let mut mis = [0u64; MEASURED];
    let mut del = [0u64; MEASURED];

    for r in 0..TOTAL {
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
        let del_us = start.elapsed().as_micros() as u64;

        if r >= WARMUP {
            let idx = r - WARMUP;
            ins[idx] = insert_us;
            hit[idx] = hit_us;
            mis[idx] = miss_us;
            del[idx] = del_us;
        }
    }

    println!("n={}\tload={}\thit={}\tmiss={}\tinsert={}\tdelete={}",
        n, pct, median(&mut hit), median(&mut mis), median(&mut ins), median(&mut del));
}

fn main() {
    println!("=== Modified hashbrown: full parameter sweep ===");
    println!("=== 16-byte string keys, shuffled, ahash, median of {} ===\n", MEASURED);

    // Size sweep at 50% load
    println!("--- Size sweep (50% load) ---");
    for n in [16_384, 65_536, 262_144, 1_048_576, 4_194_304] {
        let fill = n / 2;
        let kd = gen_keys(fill);
        flush_cache();
        bench(n, fill, 50, &kd);
    }

    // Load factor sweep at 1M
    println!("\n--- Load factor sweep (1M) ---");
    for pct in [10, 25, 50, 75, 90, 99] {
        let n = 1_048_576;
        let fill = n * pct / 100;
        let kd = gen_keys(fill);
        flush_cache();
        bench(n, fill, pct, &kd);
    }

    // u64 keys
    println!("\n--- u64 keys (1M, 50% load) ---");
    {
        let n = 1_048_576usize;
        let fill = n / 2;
        let mut keys = vec![0u64; fill];
        let mut miss_keys = vec![0u64; fill];
        let mut ks = 0xDEADBEEF12345678u64;
        let mut ms = 0xCAFEBABE87654321u64;
        for i in 0..fill { keys[i] = splitmix64(&mut ks); miss_keys[i] = splitmix64(&mut ms); }
        let mut order: Vec<usize> = (0..fill).collect();
        let mut rng = 42u64;
        for i in (1..fill).rev() { let j = (splitmix64(&mut rng) as usize) % (i + 1); order.swap(i, j); }

        let mut hit_arr = [0u64; MEASURED];
        let mut mis_arr = [0u64; MEASURED];
        let mut ins_arr = [0u64; MEASURED];
        for r in 0..TOTAL {
            let mut map: HashMap<u64, u64, AHashBuilder> =
                HashMap::with_capacity_and_hasher(n, Default::default());
            let start = Instant::now();
            for i in 0..fill { map.insert(keys[i], i as u64); }
            let ins_us = start.elapsed().as_micros() as u64;
            let start = Instant::now();
            for i in 0..fill { black_box(map.get(&keys[order[i]])); }
            let hit_us = start.elapsed().as_micros() as u64;
            let start = Instant::now();
            for i in 0..fill { black_box(map.get(&miss_keys[order[i]])); }
            let miss_us = start.elapsed().as_micros() as u64;
            if r >= WARMUP {
                let idx = r - WARMUP;
                hit_arr[idx] = hit_us;
                mis_arr[idx] = miss_us;
                ins_arr[idx] = ins_us;
            }
        }
        println!("n={}\tload=50\thit={}\tmiss={}\tinsert={}\t(u64 keys)",
            n, median(&mut hit_arr), median(&mut mis_arr), median(&mut ins_arr));
    }

    println!("\nDONE");
}
