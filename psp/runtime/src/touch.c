/* On-screen touch controls for the Vita (and desktop testing with the
 * mouse).  The engine is drawn at 160x144 and scaled by the runtime, so
 * the overlay lives here, in the presented frame, rather than inside the
 * game's canvas: it works in the launcher and in every game the same way.
 *
 * Layout (in the 480x272 logical screen, 2x on the Vita's panel): the game
 * is presented at 240x216 (a clean 3x on the panel) between two 120 px
 * bars.  D-pad on the left bar, A/B on the right, START/SELECT along the
 * bottom.  Fingers press PB_* buttons through touch_buttons(); the overlay
 * dims when the last input came from the pad and returns at the next touch.
 */
#include <math.h>
#include <string.h>
#include "plat.h"
#include "plat_common.h"
#include "lp.h"

const char *lp_font8x8(int cp);

#define MAX_FINGERS 12
typedef struct { int active; long id; float x, y; } Finger;
static Finger g_fingers[MAX_FINGERS];
static int g_enabled;
static int g_offy; /* y offset of the control area (DS layout) */
static int g_visible; /* overlay shown (game presented between the bars) */
static int g_pad = 1;  /* the drawn pad is wanted at all */
static uint32_t g_last_buttons;

/* geometry, logical pixels */
#define DPAD_X 62
#define DPAD_Y 150
#define DPAD_ARM 50
#define DPAD_W 32
#define DPAD_DEAD 11
#define A_X 444
#define A_Y 126
#define B_X 386
#define B_Y 170
#define AB_R 23
#define START_X 404
#define START_Y 240
#define SELECT_X 340
#define SELECT_Y 240
#define SS_W 60
#define SS_H 20

void touch_set_enabled(int on) { g_enabled = on; if (!on) memset(g_fingers, 0, sizeof g_fingers); }
void touch_set_offset(int y) { g_offy = y; }
int touch_enabled(void) { return g_enabled; }

void touch_finger(long id, int down, float lx, float ly) {
  int i, slot = -1;
  if (!g_enabled) return;
  for (i = 0; i < MAX_FINGERS; i++) if (g_fingers[i].active && g_fingers[i].id == id) { slot = i; break; }
  if (!down) { if (slot >= 0) g_fingers[slot].active = 0; return; }
  if (slot < 0) for (i = 0; i < MAX_FINGERS; i++) if (!g_fingers[i].active) { slot = i; break; }
  if (slot < 0) return;
  g_fingers[slot].active = 1; g_fingers[slot].id = id;
  g_fingers[slot].x = lx; g_fingers[slot].y = ly;
}

static uint32_t hit(float x, float y) {
  uint32_t b = 0;
  float dx, dy;
  y -= g_offy;
  dx = x - DPAD_X; dy = y - DPAD_Y;
  float ax = fabsf(dx), ay = fabsf(dy);
  if (ax <= DPAD_ARM + 14 && ay <= DPAD_ARM + 14 && (ax > DPAD_DEAD || ay > DPAD_DEAD)) {
    if (ax >= ay * 0.45f) b |= dx < 0 ? PB_LEFT : PB_RIGHT;
    if (ay >= ax * 0.45f) b |= dy < 0 ? PB_UP : PB_DOWN;
  }
  dx = x - A_X; dy = y - A_Y;
  if (dx * dx + dy * dy <= (AB_R + 10) * (AB_R + 10)) b |= PB_CROSS;
  dx = x - B_X; dy = y - B_Y;
  if (dx * dx + dy * dy <= (AB_R + 10) * (AB_R + 10)) b |= PB_CIRCLE;
  if (x >= START_X - 6 && x <= START_X + SS_W + 6 && y >= START_Y - 8 && y <= START_Y + SS_H + 8) b |= PB_START;
  if (x >= SELECT_X - 6 && x <= SELECT_X + SS_W + 6 && y >= SELECT_Y - 8 && y <= SELECT_Y + SS_H + 8) b |= PB_SELECT;
  return b;
}

void touch_set_visible(int on) { g_visible = on; }
void touch_set_pad(int on) { g_pad = on; }
int touch_pad(void) { return g_pad; }
int touch_visible(void) { return g_enabled && g_pad && g_visible; }

/* the i-th active finger in logical screen pixels; 0 when there is none */
int touch_get(int i, float *x, float *y) {
  int k, n = 0;
  if (!g_enabled) return 0;
  for (k = 0; k < MAX_FINGERS; k++) {
    if (!g_fingers[k].active) continue;
    if (n == i) { *x = g_fingers[k].x; *y = g_fingers[k].y; return 1; }
    n++;
  }
  return 0;
}

uint32_t touch_buttons(void) {
  uint32_t b = 0;
  int i;
  if (!g_enabled || !g_visible) { g_last_buttons = 0; return 0; }
  for (i = 0; i < MAX_FINGERS; i++) if (g_fingers[i].active) b |= hit(g_fingers[i].x, g_fingers[i].y);
  g_last_buttons = b;
  return b;
}

/* ---------------------------------------------------------------- drawing */

static void blend(uint32_t *p, int r, int g, int bl, int a) {
  uint32_t d = *p;
  int dr = PX_R(d), dg = PX_G(d), db = PX_B(d);
  dr += ((r - dr) * a) >> 8; dg += ((g - dg) * a) >> 8; db += ((bl - db) * a) >> 8;
  *p = PX(dr, dg, db, 255);
}

static void fill_rect(uint32_t *s, int w, int h, int x0, int y0, int rw, int rh, int r, int g, int b, int a) {
  int x, y;
  y0 += g_offy;
  for (y = y0; y < y0 + rh; y++) {
    if (y < 0 || y >= h) continue;
    for (x = x0; x < x0 + rw; x++) if (x >= 0 && x < w) blend(s + (long)y * w + x, r, g, b, a);
  }
}

static void fill_disc(uint32_t *s, int w, int h, int cx, int cy, int rad, int r, int g, int b, int a) {
  int x, y;
  cy += g_offy;
  for (y = cy - rad; y <= cy + rad; y++) {
    if (y < 0 || y >= h) continue;
    for (x = cx - rad; x <= cx + rad; x++) {
      int dx = x - cx, dy = y - cy;
      if (x >= 0 && x < w && dx * dx + dy * dy <= rad * rad) blend(s + (long)y * w + x, r, g, b, a);
    }
  }
}

static void text(uint32_t *s, int w, int h, int x0, int y0, const char *t, int scale, int r, int g, int b, int a) {
  int i;
  for (i = 0; t[i]; i++) {
    const char *bits = lp_font8x8((unsigned char)t[i]);
    int ry, rx;
    for (ry = 0; ry < 8; ry++)
      for (rx = 0; rx < 8; rx++)
        if (bits[ry] & (1 << rx))
          fill_rect(s, w, h, x0 + (i * 8 + rx) * scale, y0 + ry * scale, scale, scale, r, g, b, a);
  }
}

static void dpad_arm(uint32_t *s, int w, int h, int dir, int pressed, int a) {
  int x, y, rw, rh;
  int lit = pressed ? 235 : 200;
  int alpha = pressed ? a + 90 : a;
  if (alpha > 255) alpha = 255;
  if (dir == 0) { x = DPAD_X - DPAD_W / 2; y = DPAD_Y - DPAD_ARM; rw = DPAD_W; rh = DPAD_ARM - DPAD_DEAD; }
  else if (dir == 1) { x = DPAD_X - DPAD_W / 2; y = DPAD_Y + DPAD_DEAD; rw = DPAD_W; rh = DPAD_ARM - DPAD_DEAD; }
  else if (dir == 2) { x = DPAD_X - DPAD_ARM; y = DPAD_Y - DPAD_W / 2; rw = DPAD_ARM - DPAD_DEAD; rh = DPAD_W; }
  else { x = DPAD_X + DPAD_DEAD; y = DPAD_Y - DPAD_W / 2; rw = DPAD_ARM - DPAD_DEAD; rh = DPAD_W; }
  fill_rect(s, w, h, x, y, rw, rh, lit, lit, lit, alpha);
  /* arrow tip */
  {
    int i, len = 6;
    for (i = 0; i < len; i++) {
      int span = (len - i) * 2 + 1;
      if (dir == 0) fill_rect(s, w, h, DPAD_X - span / 2, y + 4 + i, span, 1, 40, 40, 50, alpha);
      else if (dir == 1) fill_rect(s, w, h, DPAD_X - span / 2, y + rh - 5 - i, span, 1, 40, 40, 50, alpha);
      else if (dir == 2) fill_rect(s, w, h, x + 4 + i, DPAD_Y - span / 2, 1, span, 40, 40, 50, alpha);
      else fill_rect(s, w, h, x + rw - 5 - i, DPAD_Y - span / 2, 1, span, 40, 40, 50, alpha);
    }
  }
}

static void button(uint32_t *s, int w, int h, int cx, int cy, const char *label, int pressed, int a,
                   int r, int g, int b) {
  int alpha = pressed ? a + 90 : a;
  if (alpha > 255) alpha = 255;
  fill_disc(s, w, h, cx, cy, AB_R + 2, 20, 20, 30, alpha / 2);
  fill_disc(s, w, h, cx, cy, AB_R, r, g, b, alpha);
  text(s, w, h, cx - 8, cy - 8, label, 2, 250, 250, 250, alpha);
}

static void pill(uint32_t *s, int w, int h, int x, int y, const char *label, int pressed, int a) {
  int alpha = pressed ? a + 90 : a;
  int tw = (int)strlen(label) * 8;
  if (alpha > 255) alpha = 255;
  fill_rect(s, w, h, x, y, SS_W, SS_H, 20, 20, 30, alpha / 2);
  fill_rect(s, w, h, x + 2, y + 2, SS_W - 4, SS_H - 4, 190, 190, 200, alpha);
  text(s, w, h, x + (SS_W - tw) / 2, y + (SS_H - 8) / 2, label, 1, 30, 30, 40, alpha);
}

void touch_draw(uint32_t *s, int w, int h, int dim) {
  int a = dim ? 70 : 150;
  uint32_t b = g_last_buttons;
  if (!g_enabled || !g_visible) return;
  fill_disc(s, w, h, DPAD_X, DPAD_Y, DPAD_ARM + 8, 20, 20, 30, a / 2);
  dpad_arm(s, w, h, 0, (b & PB_UP) != 0, a);
  dpad_arm(s, w, h, 1, (b & PB_DOWN) != 0, a);
  dpad_arm(s, w, h, 2, (b & PB_LEFT) != 0, a);
  dpad_arm(s, w, h, 3, (b & PB_RIGHT) != 0, a);
  fill_disc(s, w, h, DPAD_X, DPAD_Y, DPAD_DEAD - 1, 120, 120, 130, a);
  button(s, w, h, A_X, A_Y, "A", (b & PB_CROSS) != 0, a, 200, 60, 70);
  button(s, w, h, B_X, B_Y, "B", (b & PB_CIRCLE) != 0, a, 60, 90, 200);
  pill(s, w, h, START_X, START_Y, "START", (b & PB_START) != 0, a);
  pill(s, w, h, SELECT_X, SELECT_Y, "SELECT", (b & PB_SELECT) != 0, a);
}
