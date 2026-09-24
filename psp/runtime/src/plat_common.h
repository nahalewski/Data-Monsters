#ifndef PLAT_COMMON_H
#define PLAT_COMMON_H
#include <stdint.h>
/* mode 4 = touch layout: a small source sits in a 240x216 box between two
 * 120 px bars for the on-screen controls (touch.c) */
#define TOUCH_BAR 120
/* side bars for mode 4: -1 = the touch default */
void plat_layout_set_bars(int left, int right);
/* explicit game rectangle (skins): w <= 0 clears it */
void plat_layout_set_game_rect(int x, int y, int w, int h);
int plat_layout_custom_bars(void);
void plat_blit_scaled(const uint32_t *src, int sw, int sh,
                      uint32_t *dst, int dstride, int dw, int dh,
                      int mode, int smooth);

/* touch overlay (touch.c; SDL backends only) */
void touch_set_enabled(int on);
int touch_enabled(void);
void touch_finger(long id, int down, float lx, float ly); /* logical screen pixels */
void touch_set_offset(int y); /* DS layout: the controls live in the bottom half */
uint32_t touch_buttons(void);
void touch_draw(uint32_t *screen, int w, int h, int dim);
void touch_set_visible(int on); /* the overlay only shows while a game is between the bars */
void touch_set_pad(int on); /* draw the D-pad/A/B overlay at all (off on the Vita: real buttons) */
int touch_pad(void);
int touch_visible(void);
int touch_get(int i, float *x, float *y);
#endif
