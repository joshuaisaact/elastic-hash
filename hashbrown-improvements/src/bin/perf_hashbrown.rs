/// Minimal hashbrown lookup benchmark for perf profiling.
/// Does ONLY hit lookups in the measured section.
use hashbrown::HashMap;
use std::hash::BuildHasherDefault;
use std::hint::black_box;
use ahash::AHasher;

type M<'a> = HashMap<&'a [u8], u64, BuildHasherDefault<AHasher>>;

fn splitmix64(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9e3779b97f4a7c15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}

fn main() {
    let n = 1_048_576usize;
    let fill = n / 2;
    let mut keys = vec![[0u8; 16]; fill];
    let mut ks = 0xDEADBEEF12345678u64;
    let hex = b"0123456789abcdef";
    for i in 0..fill {
        let mut v = splitmix64(&mut ks);
        for j in (0..16).rev() { keys[i][j] = hex[(v & 0xF) as usize]; v >>= 4; }
    }
    let mut order: Vec<usize> = (0..fill).collect();
    let mut rng = 42u64;
    for i in (1..fill).rev() { let j = (splitmix64(&mut rng) as usize) % (i + 1); order.swap(i, j); }

    let mut map: M = HashMap::with_capacity_and_hasher(n, Default::default());
    for i in 0..fill { map.insert(&keys[i], i as u64); }

    // Warmup
    for i in 0..fill { black_box(map.get(&keys[order[i]] as &[u8])); }

    // MEASURED: 10 rounds of hit lookups only
    // Process 4 lookups at a time to maximize memory-level parallelism.
    for _ in 0..10 {
        let chunks = fill / 4;
        for c in 0..chunks {
            let base = c * 4;
            let results = map.get_batch_4([
                &keys[order[base]] as &[u8],
                &keys[order[base + 1]] as &[u8],
                &keys[order[base + 2]] as &[u8],
                &keys[order[base + 3]] as &[u8],
            ]);
            black_box(results);
        }
        // Handle remainder
        for i in (chunks * 4)..fill {
            black_box(map.get(&keys[order[i]] as &[u8]));
        }
    }
}
