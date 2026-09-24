#ifndef PLAT_COMMON_H
#define PLAT_COMMON_H
#include <stdint.h>
void plat_blit_scaled(const uint32_t *src, int sw, int sh,
                      uint32_t *dst, int dstride, int dw, int dh,
                      int mode, int smooth);
#endif
