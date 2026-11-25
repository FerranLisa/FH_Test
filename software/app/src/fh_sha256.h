#ifndef FH_SHA256_H
#define FH_SHA256_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t state[8];
    uint64_t bytes;
} FhSha256;

/* The eMMC reader supplies whole 512-byte sectors. */
void fh_sha256_init(FhSha256 *ctx);
void fh_sha256_blocks(FhSha256 *ctx, const uint8_t *data, size_t bytes);
void fh_sha256_finish(FhSha256 *ctx, uint8_t digest[32]);

#endif
