/// Correctness tests for modified hashbrown.
/// Tests insert, get, remove, overwrite, growth, and edge cases.
use hashbrown::HashMap;
use std::hash::BuildHasherDefault;
use ahash::AHasher;

type M = HashMap<String, u64, BuildHasherDefault<AHasher>>;

fn main() {
    let mut failures = 0;
    let mut tests = 0;

    macro_rules! check {
        ($cond:expr, $msg:expr) => {
            tests += 1;
            if !$cond {
                eprintln!("FAIL: {}", $msg);
                failures += 1;
            }
        };
    }

    // Basic insert/get
    {
        let mut m: M = HashMap::with_hasher(Default::default());
        m.insert("hello".to_string(), 1);
        m.insert("world".to_string(), 2);
        check!(m.get("hello") == Some(&1), "basic get hello");
        check!(m.get("world") == Some(&2), "basic get world");
        check!(m.get("missing") == None, "basic get missing");
        check!(m.len() == 2, "basic len");
    }

    // Overwrite
    {
        let mut m: M = HashMap::with_hasher(Default::default());
        m.insert("key".to_string(), 1);
        m.insert("key".to_string(), 2);
        check!(m.get("key") == Some(&2), "overwrite");
        check!(m.len() == 1, "overwrite len");
    }

    // Remove
    {
        let mut m: M = HashMap::with_hasher(Default::default());
        m.insert("a".to_string(), 1);
        m.insert("b".to_string(), 2);
        m.insert("c".to_string(), 3);
        check!(m.remove("b") == Some(2), "remove b");
        check!(m.get("b") == None, "get after remove");
        check!(m.get("a") == Some(&1), "a survives remove");
        check!(m.get("c") == Some(&3), "c survives remove");
        check!(m.len() == 2, "len after remove");
    }

    // Growth (insert enough to trigger resize)
    {
        let mut m: M = HashMap::with_hasher(Default::default());
        for i in 0..10_000 {
            m.insert(format!("key_{}", i), i as u64);
        }
        check!(m.len() == 10_000, "growth len");
        for i in 0..10_000 {
            check!(m.get(&format!("key_{}", i)) == Some(&(i as u64)),
                   &format!("growth get key_{}", i));
        }
    }

    // Large table with string keys (matches benchmark pattern)
    {
        let hex = b"0123456789abcdef";
        let mut keys: Vec<[u8; 16]> = Vec::new();
        let mut state = 0xDEADBEEF12345678u64;
        for _ in 0..100_000 {
            state = state.wrapping_add(0x9e3779b97f4a7c15);
            let mut z = state;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
            z ^= z >> 31;
            let mut buf = [0u8; 16];
            let mut v = z;
            for j in (0..16).rev() { buf[j] = hex[(v & 0xF) as usize]; v >>= 4; }
            keys.push(buf);
        }

        let mut m: HashMap<&[u8], u64, BuildHasherDefault<AHasher>> =
            HashMap::with_capacity_and_hasher(200_000, Default::default());
        for (i, k) in keys.iter().enumerate() {
            m.insert(k.as_slice(), i as u64);
        }
        check!(m.len() == 100_000, "large table len");

        // Verify all present
        let mut found = 0;
        for (i, k) in keys.iter().enumerate() {
            if m.get(k.as_slice()) == Some(&(i as u64)) { found += 1; }
        }
        check!(found == 100_000, &format!("large table: found {}/100000", found));

        // Verify misses
        let mut false_positives = 0;
        let mut miss_state = 0xCAFEBABE87654321u64;
        for _ in 0..10_000 {
            miss_state = miss_state.wrapping_add(0x9e3779b97f4a7c15);
            let mut z = miss_state;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
            z ^= z >> 31;
            let mut buf = [0u8; 16];
            let mut v = z;
            for j in (0..16).rev() { buf[j] = hex[(v & 0xF) as usize]; v >>= 4; }
            if m.get(buf.as_slice()).is_some() { false_positives += 1; }
        }
        check!(false_positives == 0, &format!("miss false positives: {}", false_positives));

        // Remove half, verify
        for (i, k) in keys.iter().enumerate().take(50_000) {
            let removed = m.remove(k.as_slice());
            check!(removed == Some(i as u64), &format!("remove key {}", i));
        }
        check!(m.len() == 50_000, "len after half removal");
        for (i, k) in keys.iter().enumerate().skip(50_000) {
            check!(m.get(k.as_slice()) == Some(&(i as u64)),
                   &format!("surviving key {}", i));
        }
    }

    // Empty table edge cases
    {
        let m: HashMap<&str, u64, BuildHasherDefault<AHasher>> =
            HashMap::with_hasher(Default::default());
        check!(m.get("anything") == None, "empty table get");
        check!(m.len() == 0, "empty table len");
    }

    if failures == 0 {
        println!("ALL {} TESTS PASSED", tests);
    } else {
        println!("FAILED: {}/{} tests failed", failures, tests);
        std::process::exit(1);
    }
}
