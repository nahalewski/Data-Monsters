/* Scaling blitter shared by both platform backends. */
#include <stdint.h>
#include <string.h>
#include "plat_common.h"
#include "lp.h"
#ifdef __PSP__
#define touch_pad() 0 /* no touch module on the PSP build */
#endif

static int g_bar_l = -1, g_bar_r = -1;
static int g_gx, g_gy, g_gw, g_gh; /* forced game rect */
void plat_layout_set_game_rect(int x, int y, int w, int h) { g_gx = x; g_gy = y; g_gw = w; g_gh = h; }
void plat_layout_set_bars(int left, int right) { g_bar_l = left; g_bar_r = right; }
int plat_layout_custom_bars(void) { return g_bar_l >= 0 || g_bar_r >= 0; }

static void compute_rect(int sw, int sh, int dw, int dh, int mode,
                         int *ox, int *oy, int *ow, int *oh) {
  int w = sw, h = sh;
  if (g_gw > 0 && g_gh > 0) { *ox = g_gx; *oy = g_gy; *ow = g_gw; *oh = g_gh; return; }
  if (mode == 1) { /* aspect fit */
    if ((long)dw * sh <= (long)dh * sw) { w = dw; h = (int)((long)sh * dw / sw); }
    else { h = dh; w = (int)((long)sw * dh / sh); }
  } else if (mode == 2) { /* stretch */
    w = dw; h = dh;
  } else if (mode == 3) { /* integer fit */
    int s = dw / sw < dh / sh ? dw / sw : dh / sh;
    if (s < 1) s = 1;
    w = sw * s; h = sh * s;
  } else if (mode == 4) { /* touch layout: fit between the side bars */
    int def = touch_pad() ? TOUCH_BAR : 0;
    int bl = g_bar_l >= 0 ? g_bar_l : def, br = g_bar_r >= 0 ? g_bar_r : def;
    int iw = dw - bl - br;
    if (sw * 2 > dw || iw < sw) { w = sw < dw ? sw : dw; h = sh < dh ? sh : dh; }
    else if ((long)iw * sh <= (long)dh * sw) { w = iw; h = (int)((long)sh * iw / sw); }
    else { h = dh; w = (int)((long)sw * dh / sh); }
    if (w > dw) w = dw;
    if (h > dh) h = dh;
    *ox = bl + (iw - w) / 2; *oy = (dh - h) / 2; *ow = w; *oh = h;
    if (*ox < 0) *ox = 0;
    return;
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
    if (y < oy || y >= oy + oh) { for (x = 0; x < dw; x++) row[x] = PX_AMASK; continue; }
    for (x = 0; x < ox; x++) row[x] = PX_AMASK;
    for (x = ox + ow; x < dw; x++) row[x] = PX_AMASK;
  }
  if (ow == sw && oh == sh) {
    for (y = 0; y < sh; y++) {
      const uint32_t *s = src + (long)y * sw;
      uint32_t *d = dst + (long)(oy + y) * dstride + ox;
      for (x = 0; x < sw; x++) d[x] = s[x] | PX_AMASK;
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
      for (x = 0; x < n; x++) d[x] = s[xmap[x]] | PX_AMASK;
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
      /* 64-bit: x*sw<<16 overflows the PSP's 32-bit long */
      int64_t a = ((int64_t)x * sw << 16) / ow, b = ((int64_t)(x + 1) * sw << 16) / ow;
      int ia = (int)(a >> 16);
      int64_t edge = (int64_t)(ia + 1) << 16;
      x0m[x] = ia;
      if (b > edge && ia + 1 < sw) {
        x1m[x] = ia + 1;
        xw[x] = (int)(((b - edge) * 256) / (b - a)); /* weight of right px */
      } else { x1m[x] = ia; xw[x] = 0; }
    }
    for (y = 0; y < oh; y++) {
      int64_t a = ((int64_t)y * sh << 16) / oh, b = ((int64_t)(y + 1) * sh << 16) / oh;
      int ia = (int)(a >> 16), ib = ia, yw = 0;
      int64_t edge = (int64_t)(ia + 1) << 16;
      const uint32_t *r0, *r1;
      uint32_t *d = dst + (long)(oy + y) * dstride + ox;
      if (b > edge && ia + 1 < sh) { ib = ia + 1; yw = (int)(((b - edge) * 256) / (b - a)); }
      r0 = src + (long)ia * sw; r1 = src + (long)ib * sw;
      for (x = 0; x < n; x++) {
        uint32_t p00 = r0[x0m[x]], p01 = r0[x1m[x]], p10 = r1[x0m[x]], p11 = r1[x1m[x]];
        int wx = xw[x];
        if (!wx && !yw) { d[x] = p00 | PX_AMASK; continue; }
        {
          uint32_t out = PX_AMASK; int c;
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
