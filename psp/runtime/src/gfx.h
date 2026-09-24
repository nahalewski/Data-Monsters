/* Internal interfaces of the software renderer (gfx.c, font.c). */
#ifndef GFX_H
#define GFX_H
#include "lp.h"

typedef struct Mat { float a, b, c, d, e, f; } Mat; /* x'=a*x+c*y+e, y'=b*x+d*y+f */

static inline Mat mat_identity(void) { Mat m = {1, 0, 0, 1, 0, 0}; return m; }
static inline Mat mat_mul(Mat m1, Mat m2) {
  Mat r;
  r.a = m1.a * m2.a + m1.c * m2.b;
  r.b = m1.b * m2.a + m1.d * m2.b;
  r.c = m1.a * m2.c + m1.c * m2.d;
  r.d = m1.b * m2.c + m1.d * m2.d;
  r.e = m1.a * m2.e + m1.c * m2.f + m1.e;
  r.f = m1.b * m2.e + m1.d * m2.f + m1.f;
  return r;
}
Mat mat_transformation(float x, float y, float r, float sx, float sy, float ox, float oy, float kx, float ky);
int mat_invert(Mat m, Mat *out);

/* texture drawing entry used by fonts, sprite batches and draw() */
void gfx_draw_texture(Tex *t, float qx, float qy, float qw, float qh, float refw, float refh,
                      Mat m, const float *color /* NULL = current */);

/* fonts (font.c) */
typedef struct Font Font;
extern const LPType lp_Font_type;
Font *font_default(lua_State *L); /* pushes nothing; returns the built-in font */
int font_push_default(lua_State *L, float size);
Font *font_check(lua_State *L, int idx);
float font_line_advance(Font *f);
float font_height(Font *f);
/* draw a UTF-8 string at the current state; m maps text space to target */
void font_draw_line(Font *f, const char *s, size_t len, Mat m, float x, float y, const float *color);
float font_text_width(Font *f, const char *s, size_t len);
/* word wrap: calls cb for every produced line */
typedef void (*wrap_cb)(void *ud, const char *s, size_t len, float width, int last_in_para);
void font_wrap(Font *f, const char *s, size_t len, float limit, wrap_cb cb, void *ud);
int lp_font_newFont(lua_State *L);
int lp_font_newImageFont(lua_State *L);
void lp_font_register(lua_State *L);

extern const float *gfx_current_color(void);
#endif
