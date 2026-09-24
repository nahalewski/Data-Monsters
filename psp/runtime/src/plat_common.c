/* Scaling blitter shared by both platform backends. */
#include <string.h>
#include "plat_common.h"

static void compute_rect(int sw, int sh, int dw, int dh, int mode,
                         int *ox, int *oy, int *ow, int *oh) {
  int w = sw, h = sh;
  if (mode == 1) { /* aspect fit */
    if ((long)dw * sh <= (long)dh * sw) { w = dw; h = (int)((long)sh * dw / sw); }
    else { h = dh; w = (int)((long)sw * dh / sh); }
  } else if (mode == 2) { /* stretch */
    w = dw; h = dh;
  } else if (mode == 3) { /* integer fit */
    int s = dw / sw < dh / sh ? dw / sw : dh / sh;
    if (s < 1) s = 1;
    w = sw * s; h = sh * s;
  }
  if (w > dw) w = dw;
  if (h > dh) h = dh;
  *ox = (dw - w) / 2; *oy = (dh - h) / 2; *ow = w; *oh = h;
}

void plat_blit_scaled(const uint32_t *src, int sw, int sh,
                      uint32_t *dst, int dstride, int dw, int dh,
                      int mode, int smooth) {
  int ox, oy, ow, oh, x, y;
  if (sw <= 0 || sh <= 0) return;
  compute_rect(sw, sh, dw, dh, mode, &ox, &oy, &ow, &oh);
  /* clear borders (black, opaque) */
  for (y = 0; y < dh; y++) {
    uint32_t *row = dst + (long)y * dstride;
    if (y < oy || y >= oy + oh) { for (x = 0; x < dw; x++) row[x] = 0xff000000u; continue; }
    for (x = 0; x < ox; x++) row[x] = 0xff000000u;
    for (x = ox + ow; x < dw; x++) row[x] = 0xff000000u;
  }
  if (ow == sw && oh == sh) {
    for (y = 0; y < sh; y++) {
      const uint32_t *s = src + (long)y * sw;
      uint32_t *d = dst + (long)(oy + y) * dstride + ox;
      for (x = 0; x < sw; x++) d[x] = s[x] | 0xff000000u;
    }
    return;
  }
  if (!smooth || (ow % sw == 0 && oh % sh == 0)) {
    static int xmap[1024];
    int n = ow > 1024 ? 1024 : ow;
    for (x = 0; x < n; x++) xmap[x] = (int)(((long)x * sw) / ow);
    for (y = 0; y < oh; y++) {
      const uint32_t *s = src + (long)((long)y * sh / oh) * sw;
      uint32_t *d = dst + (long)(oy + y) * dstride + ox;
      for (x = 0; x < n; x++) d[x] = s[xmap[x]] | 0xff000000u;
    }
    return;
  }
  /* "sharp bilinear": nearest inside a source pixel, blend only across the
   * one destination pixel that straddles a source edge.  Keeps pixel art
   * crisp at non-integer scales without the uneven-row look of nearest. */
  {
    static int x0m[1024], x1m[1024], xw[1024];
    int n = ow > 1024 ? 1024 : ow;
    for (x = 0; x < n; x++) {
      /* source span covered by destination pixel x, 16.16 fixed */
      long a = ((long)x * sw << 16) / ow, b = ((long)(x + 1) * sw << 16) / ow;
      int ia = (int)(a >> 16);
      long edge = (long)(ia + 1) << 16;
      x0m[x] = ia;
      if (b > edge && ia + 1 < sw) {
        x1m[x] = ia + 1;
        xw[x] = (int)(((b - edge) * 256) / (b - a)); /* weight of right px */
      } else { x1m[x] = ia; xw[x] = 0; }
    }
    for (y = 0; y < oh; y++) {
      long a = ((long)y * sh << 16) / oh, b = ((long)(y + 1) * sh << 16) / oh;
      int ia = (int)(a >> 16), ib = ia, yw = 0;
      long edge = (long)(ia + 1) << 16;
      const uint32_t *r0, *r1;
      uint32_t *d = dst + (long)(oy + y) * dstride + ox;
      if (b > edge && ia + 1 < sh) { ib = ia + 1; yw = (int)(((b - edge) * 256) / (b - a)); }
      r0 = src + (long)ia * sw; r1 = src + (long)ib * sw;
      for (x = 0; x < n; x++) {
        uint32_t p00 = r0[x0m[x]], p01 = r0[x1m[x]], p10 = r1[x0m[x]], p11 = r1[x1m[x]];
        int wx = xw[x];
        if (!wx && !yw) { d[x] = p00 | 0xff000000u; continue; }
        {
          uint32_t out = 0xff000000u; int c;
          for (c = 0; c < 24; c += 8) {
            int top = (int)((p00 >> c) & 255) * (256 - wx) + (int)((p01 >> c) & 255) * wx;
            int bot = (int)((p10 >> c) & 255) * (256 - wx) + (int)((p11 >> c) & 255) * wx;
            int v = (top * (256 - yw) + bot * yw) >> 16;
            out |= (uint32_t)v << c;
          }
          d[x] = out;
        }
      }
    }
  }
}
