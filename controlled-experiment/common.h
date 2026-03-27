#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <vector>

#ifdef __ARM_NEON
#include <arm_neon.h>
#else
#include <immintrin.h>
#endif

// ---- wyhash (matching Zig's std.hash.Wyhash) ----
static inline uint64_t wymix(uint64_t a, uint64_t b) {
    __uint128_t r = (__uint128_t)a * b;
    return (uint64_t)(r >> 64) ^ (uint64_t)r;
}

static inline uint64_t wyr8(const uint8_t* p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}

static uint64_t wyhash(const void* key, size_t len) {
    const uint8_t* p = (const uint8_t*)key;
    uint64_t seed = 0;
    uint64_t a, b;
    const uint64_t s0 = 0xa0761d6478bd642f;
    const uint64_t s1 = 0xe7037ed1a0b428db;
    const uint64_t s2 = 0x8ebc6af09c88c6e3;
    const uint64_t s3 = 0x589965cc75374cc3;

    seed ^= s0;
    if (len <= 16) {
        if (len >= 4) {
            a = (wyr8(p) << 32) | (wyr8(p + ((len >> 3) << 2)) >> 32);
            b = (wyr8(p + len - 8) << 32) | (wyr8(p + len - 4 - ((len >> 3) << 2)) >> 32);
        } else if (len > 0) {
            a = ((uint64_t)p[0] << 16) | ((uint64_t)p[len >> 1] << 8) | p[len - 1];
            b = 0;
        } else {
            a = b = 0;
        }
    } else {
        size_t i = len;
        if (i > 48) {
            uint64_t see1 = seed, see2 = seed;
            while (i > 48) {
                seed = wymix(wyr8(p) ^ s1, wyr8(p + 8) ^ seed);
                see1 = wymix(wyr8(p + 16) ^ s2, wyr8(p + 24) ^ see1);
                see2 = wymix(wyr8(p + 32) ^ s3, wyr8(p + 40) ^ see2);
                p += 48;
                i -= 48;
            }
            seed ^= see1 ^ see2;
        }
        while (i > 16) {
            seed = wymix(wyr8(p) ^ s1, wyr8(p + 8) ^ seed);
            i -= 16;
            p += 16;
        }
        a = wyr8(p + i - 16);
        b = wyr8(p + i - 8);
    }
    return wymix(s1 ^ len, wymix(a ^ s1, b ^ seed));
}

// ---- Constants ----
static constexpr size_t BUCKET_SIZE = 16;
static constexpr size_t MAX_PROBES = 7;
static constexpr uint8_t TOMBSTONE = 0xFF;
static constexpr size_t KEY_LEN = 16;

// ---- SIMD fingerprint matching ----
#ifdef __ARM_NEON
static inline uint16_t match_fingerprint(const uint8_t* fps, uint8_t fp) {
    uint8x16_t v = vld1q_u8(fps);
    uint8x16_t needle = vdupq_n_u8(fp);
    uint8x16_t cmp = vceqq_u8(v, needle);
    static const uint8_t shift_table[16] = {1,2,4,8,16,32,64,128,1,2,4,8,16,32,64,128};
    uint8x16_t shift = vld1q_u8(shift_table);
    uint8x16_t bits = vandq_u8(cmp, shift);
    uint8x8_t lo = vget_low_u8(bits);
    uint8x8_t hi = vget_high_u8(bits);
    lo = vpadd_u8(lo, lo); lo = vpadd_u8(lo, lo); lo = vpadd_u8(lo, lo);
    hi = vpadd_u8(hi, hi); hi = vpadd_u8(hi, hi); hi = vpadd_u8(hi, hi);
    uint64_t lo_sum = vget_lane_u8(lo, 0);
    uint64_t hi_sum = vget_lane_u8(hi, 0);
    return (uint16_t)((hi_sum << 8) | lo_sum);
}

static inline uint16_t match_empty(const uint8_t* fps) {
    return match_fingerprint(fps, 0);
}
#else
static inline uint16_t match_fingerprint(const uint8_t* fps, uint8_t fp) {
    __m128i v = _mm_loadu_si128((const __m128i*)fps);
    __m128i needle = _mm_set1_epi8((char)fp);
    __m128i cmp = _mm_cmpeq_epi8(v, needle);
    return (uint16_t)_mm_movemask_epi8(cmp);
}

static inline uint16_t match_empty(const uint8_t* fps) {
    return match_fingerprint(fps, 0);
}
#endif

static inline uint16_t match_empty_or_tombstone(const uint8_t* fps) {
    return match_empty(fps) | match_fingerprint(fps, TOMBSTONE);
}

// ---- Data structures ----
struct StringEntry {
    const char* key_ptr;
    size_t key_len;
    uint64_t value;
};

// ---- Shared hash/fingerprint functions ----
static inline uint64_t hash_key(const char* key, size_t len) {
    return wyhash(key, len);
}

static inline uint8_t fingerprint(uint64_t h) {
    uint8_t fp = (uint8_t)(h >> 32);
    if (fp == 0) return 1;
    if (fp == TOMBSTONE) return 0xFE;
    return fp;
}

// ---- Utilities ----
template <typename T>
inline void do_not_optimize(T const& val) {
    asm volatile("" : : "r,m"(val) : "memory");
}

static uint64_t splitmix64(uint64_t& state) {
    state += 0x9e3779b97f4a7c15;
    uint64_t z = state;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) * 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

static const char hex_chars[] = "0123456789abcdef";

static void u64_to_hex(uint64_t val, char* buf) {
    for (int i = KEY_LEN - 1; i >= 0; i--) {
        buf[i] = hex_chars[val & 0xF];
        val >>= 4;
    }
}

static uint64_t median_val(uint64_t* arr, int n) {
    std::sort(arr, arr + n);
    return arr[n / 2];
}

// ---- HashTable interface ----
// All implementations must provide a struct HashTable with:
//   void init(size_t n);
//   void destroy();
//   void insert(const char* key, size_t key_len, uint64_t value);
//   uint64_t* get(const char* key, size_t key_len) const;
//   bool remove(const char* key, size_t key_len);
