// SPDX-License-Identifier: Apache-2.0
//
// SHA-256, written from FIPS 180-4, section 6.2.

#include "sha256.h"

#include <string.h>

// The first 32 bits of the fractional parts of the cube roots of the first
// 64 primes (section 4.2.2).
static const uint32_t round_constants[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static uint32_t rotate_right(uint32_t value, unsigned count) {
    return (value >> count) | (value << (32 - count));
}

static void compress(uint32_t state[8], const uint8_t block[64]) {
    uint32_t schedule[64];
    for (int t = 0; t < 16; t++) {
        schedule[t] = (uint32_t)block[4 * t] << 24 | (uint32_t)block[4 * t + 1] << 16
                    | (uint32_t)block[4 * t + 2] << 8 | (uint32_t)block[4 * t + 3];
    }
    for (int t = 16; t < 64; t++) {
        uint32_t w15 = schedule[t - 15];
        uint32_t w2 = schedule[t - 2];
        uint32_t sigma0 = rotate_right(w15, 7) ^ rotate_right(w15, 18) ^ (w15 >> 3);
        uint32_t sigma1 = rotate_right(w2, 17) ^ rotate_right(w2, 19) ^ (w2 >> 10);
        schedule[t] = sigma1 + schedule[t - 7] + sigma0 + schedule[t - 16];
    }

    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
    for (int t = 0; t < 64; t++) {
        uint32_t big_sigma1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
        uint32_t choose = (e & f) ^ (~e & g);
        uint32_t first = h + big_sigma1 + choose + round_constants[t] + schedule[t];
        uint32_t big_sigma0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t second = big_sigma0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + first;
        d = c;
        c = b;
        b = a;
        a = first + second;
    }
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

void codling_sha256_init(codling_sha256 *hash) {
    // The first 32 bits of the fractional parts of the square roots of the
    // first 8 primes (section 5.3.3).
    static const uint32_t initial[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    memcpy(hash->state, initial, sizeof initial);
    hash->length = 0;
    hash->used = 0;
}

void codling_sha256_update(codling_sha256 *hash, const void *data, size_t size) {
    const uint8_t *bytes = data;
    hash->length += (uint64_t)size;
    while (size > 0) {
        size_t take = sizeof hash->block - hash->used;
        if (take > size) {
            take = size;
        }
        memcpy(hash->block + hash->used, bytes, take);
        hash->used += take;
        bytes += take;
        size -= take;
        if (hash->used == sizeof hash->block) {
            compress(hash->state, hash->block);
            hash->used = 0;
        }
    }
}

void codling_sha256_hex(codling_sha256 *hash, char hex[65]) {
    // Padding (section 5.1.1): a 1 bit, zeros, then the length in bits.
    uint64_t bits = hash->length * 8;
    hash->block[hash->used++] = 0x80;
    if (hash->used > 56) {
        memset(hash->block + hash->used, 0, sizeof hash->block - hash->used);
        compress(hash->state, hash->block);
        hash->used = 0;
    }
    memset(hash->block + hash->used, 0, 56 - hash->used);
    for (int i = 0; i < 8; i++) {
        hash->block[56 + i] = (uint8_t)(bits >> (56 - 8 * i));
    }
    compress(hash->state, hash->block);

    static const char digits[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 4; j++) {
            uint8_t byte = (uint8_t)(hash->state[i] >> (24 - 8 * j));
            hex[8 * i + 2 * j] = digits[byte >> 4];
            hex[8 * i + 2 * j + 1] = digits[byte & 0x0f];
        }
    }
    hex[64] = '\0';
}
