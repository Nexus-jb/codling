// SPDX-License-Identifier: Apache-2.0
//
// SHA-256 as FIPS 180-4 describes it, for checking a downloaded package
// against the hash apt lists for it.

#ifndef CODLING_SHA256_H
#define CODLING_SHA256_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t state[8];
    uint64_t length;
    uint8_t block[64];
    size_t used;
} codling_sha256;

void codling_sha256_init(codling_sha256 *hash);
void codling_sha256_update(codling_sha256 *hash, const void *data, size_t size);

// Finishes the hash and writes it as 64 lower-case hex digits and a NUL.
void codling_sha256_hex(codling_sha256 *hash, char hex[65]);

#endif
