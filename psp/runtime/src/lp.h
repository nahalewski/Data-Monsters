/*
 * lovepsp -- a small LÖVE 11.x compatible runtime for the Sony PSP.
 *
 * Shared declarations.  The runtime is split into a platform layer
 * (plat_psp.c for the console, plat_host.c for a desktop test build) and the
 * love.* modules, which only talk to the platform through plat.h.
 */
#ifndef LP_H
#define LP_H

#include <stdint.h>
#include <stddef.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#define LP_VERSION "0.1.0"

/* ------------------------------------------------------------ objects */

/* Every love object is a full userdata whose metatable carries
 * __name = "love.<Type>" and a "__types" set for typeOf(). */
typedef struct LPType {
  const char *name;         /* "Image" */
  const char *const *chain; /* supertypes, NULL-terminated: Texture, Drawable, Object */
  const luaL_Reg *methods;
  lua_CFunction gc;
} LPType;

void lp_register_type(lua_State *L, const LPType *t);
void *lp_newobj(lua_State *L, const LPType *t, size_t size);
void *lp_checkobj(lua_State *L, int idx, const LPType *t);
void *lp_testobj(lua_State *L, int idx, const LPType *t);
int lp_is_type(lua_State *L, int idx, const char *name);
int16_t *lp_sounddata_samples(lua_State *L, int idx, int *frames, int *channels);
int lp_apu_render(lua_State *L);
int lp_apu_copy(lua_State *L);
/* userdata user-value slot helpers: keep referenced objects alive */
void lp_setref(lua_State *L, int obj, int slot, int val);

/* float helpers */
static inline int lp_clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline uint8_t lp_f2b(double f) {
  if (f <= 0) return 0;
  if (f >= 1) return 255;
  return (uint8_t)(f * 255.0 + 0.5);
}

/* ------------------------------------------------------------ pixels */

/* Pixels are stored R,G,B,A bytes in memory (== PSP GU_PSM_8888, stb's
 * order, SDL_PIXELFORMAT_RGBA32).  The uint32 view of that depends on the
 * host's byte order, so the accessors do too (the PS3's PPU is big-endian). */
typedef uint32_t px_t;
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#define PX_R(p) ((p) >> 24)
#define PX_G(p) (((p) >> 16) & 0xff)
#define PX_B(p) (((p) >> 8) & 0xff)
#define PX_A(p) ((p) & 0xff)
#define PX(r, g, b, a) (((px_t)(r) << 24) | ((px_t)(g) << 16) | ((px_t)(b) << 8) | (px_t)(a))
#define PX_AMASK 0x000000ffu
#else
#define PX_R(p) ((p) & 0xff)
#define PX_G(p) (((p) >> 8) & 0xff)
#define PX_B(p) (((p) >> 16) & 0xff)
#define PX_A(p) ((p) >> 24)
#define PX(r, g, b, a) ((px_t)(r) | ((px_t)(g) << 8) | ((px_t)(b) << 16) | ((px_t)(a) << 24))
#define PX_AMASK 0xff000000u
#endif
#define PX_RGBMASK (~PX_AMASK)

/* A texture: backing store for Image and Canvas. */
typedef struct Tex {
  int w, h;
  px_t *px;
  int refs;
  int linear;       /* filter: 0 nearest, 1 linear (only honoured at present) */
  int wrap_repeat_x, wrap_repeat_y;
  int is_canvas;
  int opaque_hint;  /* all alpha == 255 */
} Tex;

Tex *tex_new(int w, int h);
void tex_retain(Tex *t);
void tex_release(Tex *t);

/* ImageData (CPU pixels) */
typedef struct ImageData {
  int w, h;
  px_t *px;
} ImageData;
extern const LPType lp_ImageData_type;
ImageData *imagedata_push(lua_State *L, int w, int h);
ImageData *imagedata_check(lua_State *L, int idx);
/* decode an encoded image (PNG/JPG/BMP/TGA) into a new pixel buffer */
px_t *image_decode(const void *data, size_t len, int *w, int *h);

/* FileData / ByteData */
typedef struct Blob {
  size_t len;
  char *data;
  char name[256];
} Blob;
extern const LPType lp_FileData_type;
extern const LPType lp_ByteData_type;
Blob *blob_push(lua_State *L, const LPType *t, const void *data, size_t len, const char *name);
/* read "string, FileData, ByteData or path" at idx into a malloc'd buffer */
char *lp_read_source(lua_State *L, int idx, size_t *len, const char **name);

/* ------------------------------------------------------------ filesystem */
int fs_init(const char *argv0, const char *base_dir, const char *save_dir);
/* read a whole file from the virtual filesystem; malloc'd, NULL if missing */
char *fs_read(const char *path, size_t *len);
int fs_exists(const char *path);

/* ------------------------------------------------------------ modules */
int luaopen_love(lua_State *L);
int lp_open_graphics(lua_State *L);
int lp_open_image(lua_State *L);
int lp_open_filesystem(lua_State *L);
int lp_open_audio(lua_State *L);
int lp_open_sound(lua_State *L);
int lp_open_timer(lua_State *L);
int lp_open_event(lua_State *L);
int lp_open_input(lua_State *L); /* keyboard, mouse, joystick, touch */
int lp_open_math(lua_State *L);
int lp_open_data(lua_State *L);
int lp_open_system(lua_State *L);
int lp_open_window(lua_State *L);
int luaopen_bit(lua_State *L);

/* graphics <-> window glue */
void gfx_resize_backbuffer(int w, int h);
Tex *gfx_backbuffer(void);
void gfx_present(void);

/* event queue (event.c) */
void ev_push(lua_State *L, const char *name, int nargs); /* pops nargs values */
void input_poll(lua_State *L);                           /* platform -> events */

/* audio (audio.c) */
void audio_start(void);

/* utility */
double lp_time(void);

#endif
