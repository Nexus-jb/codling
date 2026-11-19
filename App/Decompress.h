// SPDX-License-Identifier: Apache-2.0
//
// Decompresses the package indexes repositories publish.

#ifndef CODLING_DECOMPRESS_H
#define CODLING_DECOMPRESS_H

#include <stddef.h>
#include <stdint.h>

enum codling_compression {
    codling_compression_none = 0,
    codling_compression_gzip = 1,
    codling_compression_bzip2 = 2,
    codling_compression_xz = 3,
};

enum codling_decompress_status {
    codling_decompress_ok = 0,
    codling_decompress_corrupt = 1,
    codling_decompress_too_large = 2,
    codling_decompress_no_memory = 3,
    codling_decompress_unsupported = 4,
};

// Decompresses input into a new buffer (free it with free), up to limit bytes
// of output. Concatenated gzip and bzip2 streams are read whole.
int codling_decompress(int compression, const uint8_t *input, size_t input_length, size_t limit,
                       uint8_t **output, size_t *output_length);

#endif
