// SPDX-License-Identifier: Apache-2.0

#include "Decompress.h"

#include <bzlib.h>
#include <compression.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

struct output {
    uint8_t *data;
    size_t length;
    size_t capacity;
    size_t limit;
};

// Makes room for at least one more byte; returns a status on failure.
static int grow(struct output *out) {
    if (out->length < out->capacity) {
        return codling_decompress_ok;
    }
    if (out->capacity >= out->limit) {
        return codling_decompress_too_large;
    }
    size_t capacity = out->capacity ? out->capacity * 2 : 1 << 20;
    if (capacity > out->limit) {
        capacity = out->limit;
    }
    uint8_t *data = realloc(out->data, capacity);
    if (!data) {
        return codling_decompress_no_memory;
    }
    out->data = data;
    out->capacity = capacity;
    return codling_decompress_ok;
}

static int gunzip(const uint8_t *input, size_t length, struct output *out) {
    z_stream stream;
    memset(&stream, 0, sizeof stream);
    // 16 + MAX_WBITS: a gzip header and trailer around the deflate data.
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) {
        return codling_decompress_no_memory;
    }
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)length;
    int status = codling_decompress_ok;
    for (;;) {
        if ((status = grow(out)) != codling_decompress_ok) {
            break;
        }
        stream.next_out = out->data + out->length;
        stream.avail_out = (uInt)(out->capacity - out->length);
        int result = inflate(&stream, Z_NO_FLUSH);
        out->length = out->capacity - stream.avail_out;
        if (result == Z_STREAM_END) {
            if (stream.avail_in == 0) {
                break;
            }
            // Another gzip member follows.
            inflateReset(&stream);
            continue;
        }
        if (result != Z_OK && result != Z_BUF_ERROR) {
            status = codling_decompress_corrupt;
            break;
        }
        if (result == Z_BUF_ERROR && stream.avail_in == 0) {
            status = codling_decompress_corrupt;
            break;
        }
    }
    inflateEnd(&stream);
    return status;
}

static int bunzip2(const uint8_t *input, size_t length, struct output *out) {
    bz_stream stream;
    memset(&stream, 0, sizeof stream);
    if (BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK) {
        return codling_decompress_no_memory;
    }
    stream.next_in = (char *)input;
    stream.avail_in = (unsigned int)length;
    int status = codling_decompress_ok;
    for (;;) {
        if ((status = grow(out)) != codling_decompress_ok) {
            break;
        }
        stream.next_out = (char *)(out->data + out->length);
        stream.avail_out = (unsigned int)(out->capacity - out->length);
        int result = BZ2_bzDecompress(&stream);
        out->length = out->capacity - stream.avail_out;
        if (result == BZ_STREAM_END) {
            if (stream.avail_in == 0) {
                break;
            }
            // Another bzip2 stream follows.
            char *next = stream.next_in;
            unsigned int left = stream.avail_in;
            BZ2_bzDecompressEnd(&stream);
            memset(&stream, 0, sizeof stream);
            if (BZ2_bzDecompressInit(&stream, 0, 0) != BZ_OK) {
                return codling_decompress_no_memory;
            }
            stream.next_in = next;
            stream.avail_in = left;
            continue;
        }
        if (result != BZ_OK) {
            status = codling_decompress_corrupt;
            break;
        }
        if (stream.avail_in == 0 && stream.avail_out != 0) {
            // The input ended inside a stream.
            status = codling_decompress_corrupt;
            break;
        }
    }
    BZ2_bzDecompressEnd(&stream);
    return status;
}

static int unxz(const uint8_t *input, size_t length, struct output *out) {
    compression_stream stream;
    // COMPRESSION_LZMA reads the xz container.
    if (compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) != COMPRESSION_STATUS_OK) {
        return codling_decompress_no_memory;
    }
    stream.src_ptr = input;
    stream.src_size = length;
    int status = codling_decompress_ok;
    for (;;) {
        if ((status = grow(out)) != codling_decompress_ok) {
            break;
        }
        stream.dst_ptr = out->data + out->length;
        stream.dst_size = out->capacity - out->length;
        compression_status result = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE);
        out->length = out->capacity - stream.dst_size;
        if (result == COMPRESSION_STATUS_END) {
            break;
        }
        if (result != COMPRESSION_STATUS_OK) {
            status = codling_decompress_corrupt;
            break;
        }
        if (stream.src_size == 0 && stream.dst_size != 0) {
            status = codling_decompress_corrupt;
            break;
        }
    }
    compression_stream_destroy(&stream);
    return status;
}

int codling_decompress(int compression, const uint8_t *input, size_t input_length, size_t limit,
                       uint8_t **output, size_t *output_length) {
    struct output out = { .limit = limit };
    int status;
    switch (compression) {
    case codling_compression_none:
        if (input_length > limit) {
            return codling_decompress_too_large;
        }
        out.data = malloc(input_length ? input_length : 1);
        if (!out.data) {
            return codling_decompress_no_memory;
        }
        memcpy(out.data, input, input_length);
        out.length = input_length;
        status = codling_decompress_ok;
        break;
    case codling_compression_gzip:
        status = gunzip(input, input_length, &out);
        break;
    case codling_compression_bzip2:
        status = bunzip2(input, input_length, &out);
        break;
    case codling_compression_xz:
        status = unxz(input, input_length, &out);
        break;
    default:
        status = codling_decompress_unsupported;
    }
    if (status != codling_decompress_ok) {
        free(out.data);
        return status;
    }
    *output = out.data;
    *output_length = out.length;
    return codling_decompress_ok;
}
