#pragma once
#include "common.h"

static constexpr size_t VERIFY_COUNT = 10000;
static constexpr uint64_t VERIFY_SEED = 0xABCDEF0123456789;
static constexpr uint64_t VERIFY_MISS_SEED = 0x1234567890ABCDEF;

template <typename HT>
static bool verify(const char* impl_name) {
    // Generate keys
    std::vector<char> key_buf(VERIFY_COUNT * KEY_LEN);
    std::vector<char> miss_buf(VERIFY_COUNT * KEY_LEN);
    uint64_t ks = VERIFY_SEED, ms = VERIFY_MISS_SEED;
    for (size_t i = 0; i < VERIFY_COUNT; i++) {
        u64_to_hex(splitmix64(ks), &key_buf[i * KEY_LEN]);
        u64_to_hex(splitmix64(ms), &miss_buf[i * KEY_LEN]);
    }

    HT map;
    map.init(VERIFY_COUNT * 2); // plenty of room
    bool ok = true;

    // Insert all keys
    for (size_t i = 0; i < VERIFY_COUNT; i++) {
        map.insert(&key_buf[i * KEY_LEN], KEY_LEN, i + 1);
    }

    // Verify all keys found with correct value
    for (size_t i = 0; i < VERIFY_COUNT; i++) {
        uint64_t* val = map.get(&key_buf[i * KEY_LEN], KEY_LEN);
        if (!val) {
            printf("FAIL [%s]: key %zu not found after insert\n", impl_name, i);
            ok = false;
            break;
        }
        if (*val != i + 1) {
            printf("FAIL [%s]: key %zu has value %llu, expected %llu\n",
                   impl_name, i, (unsigned long long)*val, (unsigned long long)(i + 1));
            ok = false;
            break;
        }
    }

    // Verify miss keys return null
    if (ok) {
        for (size_t i = 0; i < VERIFY_COUNT; i++) {
            uint64_t* val = map.get(&miss_buf[i * KEY_LEN], KEY_LEN);
            if (val) {
                printf("FAIL [%s]: miss key %zu returned non-null\n", impl_name, i);
                ok = false;
                break;
            }
        }
    }

    // Delete first half
    if (ok) {
        for (size_t i = 0; i < VERIFY_COUNT / 2; i++) {
            bool removed = map.remove(&key_buf[i * KEY_LEN], KEY_LEN);
            if (!removed) {
                printf("FAIL [%s]: remove key %zu returned false\n", impl_name, i);
                ok = false;
                break;
            }
        }
    }

    // Verify deleted keys return null
    if (ok) {
        for (size_t i = 0; i < VERIFY_COUNT / 2; i++) {
            uint64_t* val = map.get(&key_buf[i * KEY_LEN], KEY_LEN);
            if (val) {
                printf("FAIL [%s]: deleted key %zu still found\n", impl_name, i);
                ok = false;
                break;
            }
        }
    }

    // Verify remaining keys still found
    if (ok) {
        for (size_t i = VERIFY_COUNT / 2; i < VERIFY_COUNT; i++) {
            uint64_t* val = map.get(&key_buf[i * KEY_LEN], KEY_LEN);
            if (!val) {
                printf("FAIL [%s]: surviving key %zu not found after partial delete\n", impl_name, i);
                ok = false;
                break;
            }
            if (*val != i + 1) {
                printf("FAIL [%s]: surviving key %zu has wrong value\n", impl_name, i);
                ok = false;
                break;
            }
        }
    }

    map.destroy();

    if (ok) {
        printf("PASS [%s]\n", impl_name);
    }
    return ok;
}
