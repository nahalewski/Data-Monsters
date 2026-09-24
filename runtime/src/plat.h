/*
 * Platform layer.  plat_psp.c implements this on the console; plat_host.c
 * implements it on a desktop (SDL2) so the runtime can be exercised off
 * hardware.
 */
#ifndef PLAT_H
#define PLAT_H

#include <stdint.h>

#define PLAT_SCREEN_W 480
#define PLAT_SCREEN_H 272

/* virtual PSP buttons (bitmask) */
enum {
  PB_UP = 1 << 0, PB_DOWN = 1 << 1, PB_LEFT = 1 << 2, PB_RIGHT = 1 << 3,
  PB_CROSS = 1 << 4, PB_CIRCLE = 1 << 5, PB_SQUARE = 1 << 6, PB_TRIANGLE = 1 << 7,
  PB_LTRIGGER = 1 << 8, PB_RTRIGGER = 1 << 9, PB_START = 1 << 10, PB_SELECT = 1 << 11,
  PB_HOME = 1 << 12,
  PB_COUNT = 13
};

typedef struct PlatInput {
  uint32_t buttons;
  float ax, ay; /* analog nub, -1..1 */
  float rx, ry; /* right stick (Vita, controllers), -1..1 */
  float lt, rt; /* L2 / R2 triggers, 0..1 */
  int quit;     /* HOME -> exit requested / window closed */
} PlatInput;

int plat_init(int argc, char **argv);
void plat_shutdown(void);

/* present an RGBA (R,G,B,A byte order) w*h image to the screen.
 * mode: 0 = 1:1 centred, 1 = aspect fit, 2 = stretch, 3 = integer fit
 * smooth: bilinear when scaling */
void plat_present(const uint32_t *px, int w, int h, int mode, int smooth);
void plat_vsync(void);

void plat_poll(PlatInput *in);

double plat_time(void); /* seconds, monotonic */
void plat_sleep(double seconds);

/* directories, with trailing '/' */
const char *plat_base_dir(void);   /* where EBOOT.PBP lives */
const char *plat_save_dir(void);   /* writable save root */
const char *plat_self_path(void);  /* path of the running EBOOT.PBP (archive) */
const char *plat_os_name(void);

/* on-screen touch controls (Vita); -1 = query */
int plat_touch(int on);
int plat_touch_pad(int on); /* the drawn D-pad/A/B overlay; -1 = query */
void plat_inject(uint32_t buttons); /* buttons a skin drawn by the shell holds this frame */
void plat_set_game_rect(int x, int y, int w, int h);
int plat_touch_get(int i, float *x, float *y); /* i-th finger in screen pixels */
/* HUD layer composited over the presented frame (screen-sized RGBA, or NULL) */
void plat_set_overlay(const uint32_t *px, int w, int h);
/* side bars the game is fitted between in the touch layout (-1 = default) */
void plat_set_bars(int left, int right);
/* screen layout: 0 = one screen, 1 = "DS": the game in the top half of a
 * double-height logical screen, the controls and panels in the bottom half */
void plat_set_layout(int mode); /* 0 single, 1 ds, 2 dual (bottom half on a second display) */
/* heights of the two halves in the ds/dual layouts (default 272 + 272; a
 * skin uses its frames' heights, e.g. 320 + 360) */
void plat_set_split(int top, int bottom);
void plat_get_split(int *top, int *bottom);
#define PLAT_MAX_LH 720
/* foldable hinge angle in degrees from the host app, -1 = no hinge sensor */
void plat_set_hinge(float degrees);
/* open a web page in the host's browser (Android); 0 when unsupported */
int plat_open_url(const char *url);
float plat_hinge(void);
int plat_get_layout(void);
void plat_screen_size(int *w, int *h);
int plat_bottom_half(uint32_t *out, int w, int h); /* dual mode: 0xAARRGGBB rows of the bottom half */
/* network (net.c) */
int plat_has_network(void);
int plat_http_get(const char *url, const char *auth, const char *out_path, char *err, size_t errn);

/* audio: the platform pulls stereo int16 frames at PLAT_AUDIO_RATE from cb */
#define PLAT_AUDIO_RATE 44100
typedef void (*plat_audio_cb)(int16_t *out, int frames);
int plat_audio_start(plat_audio_cb cb);
void plat_audio_lock(void);
void plat_audio_unlock(void);

/* battery: percent (-1 unknown), charging */
void plat_power(int *percent, int *charging, int *seconds);

/* free heap estimate in bytes (-1 unknown) */
long plat_free_memory(void);

void plat_debug(const char *fmt, ...);

#endif
