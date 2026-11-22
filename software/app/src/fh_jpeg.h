#ifndef FH_JPEG_H
#define FH_JPEG_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    uint8_t *dst;
    size_t capacity,used;
    unsigned bits,count;
    int dc,failed;
} FhJpeg;
void fh_jpeg_begin(FhJpeg *j,uint8_t *out,size_t capacity);
int fh_jpeg_strip(FhJpeg *j,const uint8_t *src);
size_t fh_jpeg_end(FhJpeg *j);
#endif
