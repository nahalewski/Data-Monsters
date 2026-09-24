/*
 * love.graphics as a software rasterizer.
 *
 * The PSP's GE cannot run GLSL, and gen1recomp's look depends on a handful
 * of palette shaders, so drawing happens on the CPU into RGBA8888 surfaces:
 * the game renders a 160x144 Game Boy frame, which is small enough for the
 * 333 MHz Allegrex to fill every frame.  Known shaders are recognised by
 * their source and run as native kernels (see shader_classify).
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "gfx.h"
#include "plat.h"

#define DIV255(x) (((x) + 1 + ((x) >> 8)) >> 8)

/* ------------------------------------------------------------ textures */

Tex *tex_new(int w, int h) {
  Tex *t;
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  t = (Tex *)calloc(1, sizeof(Tex));
  if (!t) return NULL;
  t->px = (px_t *)calloc((size_t)w * h, sizeof(px_t));
  if (!t->px) { free(t); return NULL; }
  t->w = w; t->h = h; t->refs = 1;
  return t;
}
void tex_retain(Tex *t) { if (t) t->refs++; }
void tex_release(Tex *t) {
  if (t && --t->refs <= 0) { free(t->px); free(t); }
}

/* ------------------------------------------------------------ matrices */

Mat mat_transformation(float x, float y, float r, float sx, float sy, float ox, float oy, float kx, float ky) {
  Mat m;
  float c = 1, s = 0;
  if (r != 0) { c = cosf(r); s = sinf(r); }
  m.a = c * sx - ky * s * sy;
  m.b = s * sx + ky * c * sy;
  m.c = kx * c * sx - s * sy;
  m.d = kx * s * sx + c * sy;
  m.e = x - ox * m.a - oy * m.c;
  m.f = y - ox * m.b - oy * m.d;
  return m;
}

int mat_invert(Mat m, Mat *o) {
  float det = m.a * m.d - m.b * m.c, id;
  if (det == 0) return 0;
  id = 1.0f / det;
  o->a = m.d * id; o->b = -m.b * id; o->c = -m.c * id; o->d = m.a * id;
  o->e = (m.c * m.f - m.d * m.e) * id;
  o->f = (m.b * m.e - m.a * m.f) * id;
  return 1;
}

/* ------------------------------------------------------------ shaders */

enum { K_PAL4 = 1, K_PAL4_KEYED, K_KEY0, K_GBC, K_GBC_KEYED, K_REMAP, K_PASS };

typedef struct Uniform { char name[24]; int n; float v[64 * 3]; } Uniform;

typedef struct Shader {
  int kind;
  int nuni;
  Uniform u[6];
  int dirty;
  px_t lut[256];       /* PAL4/GBC: red channel -> rgb */
  uint8_t lut_key[256]; /* GBC keyed: 1 when shade 0 */
  /* remap cache */
  uint32_t rc_key[256];
  px_t rc_val[256];
} Shader;

static Uniform *shader_uniform(Shader *s, const char *name, int create) {
  int i;
  for (i = 0; i < s->nuni; i++) if (!strcmp(s->u[i].name, name)) return &s->u[i];
  if (!create || s->nuni >= 6) return NULL;
  memset(&s->u[s->nuni], 0, sizeof(Uniform));
  strncpy(s->u[s->nuni].name, name, sizeof s->u[0].name - 1);
  return &s->u[s->nuni++];
}

static int shader_classify(const char *src) {
  if (strstr(src, "remapSrc") && strstr(src, "remapDst")) return K_REMAP;
  if (strstr(src, "pal0") && strstr(src, "(1.0 - px.r)"))
    return strstr(src, "shade < 0.5 ? 0.0") ? K_GBC_KEYED : K_GBC;
  if (strstr(src, "extern vec3 c0") && strstr(src, "p.r > 0.83"))
    return strstr(src, "p.g > 0.83") ? K_PAL4_KEYED : K_PAL4;
  if (strstr(src, "p.r > 0.83 && p.g > 0.83 && p.b > 0.83") && strstr(src, "p.a = 0.0"))
    return K_KEY0;
  return 0;
}

static void shader_build(Shader *s) {
  int i;
  s->dirty = 0;
  if (s->kind == K_PAL4 || s->kind == K_PAL4_KEYED) {
    const char *names[4] = {"c0", "c1", "c2", "c3"};
    px_t pal[4];
    for (i = 0; i < 4; i++) {
      Uniform *u = shader_uniform(s, names[i], 0);
      pal[i] = u ? PX(lp_f2b(u->v[0]), lp_f2b(u->v[1]), lp_f2b(u->v[2]), 0) : 0;
    }
    for (i = 0; i < 256; i++) {
      float r = i / 255.0f;
      s->lut[i] = r > 0.83f ? pal[0] : r > 0.5f ? pal[1] : r > 0.17f ? pal[2] : pal[3];
    }
  } else if (s->kind == K_GBC || s->kind == K_GBC_KEYED) {
    const char *names[4] = {"pal0", "pal1", "pal2", "pal3"};
    px_t pal[4];
    for (i = 0; i < 4; i++) {
      Uniform *u = shader_uniform(s, names[i], 0);
      pal[i] = u ? PX(lp_f2b(u->v[0]), lp_f2b(u->v[1]), lp_f2b(u->v[2]), 0) : 0;
    }
    for (i = 0; i < 256; i++) {
      float shade = floorf((1.0f - i / 255.0f) * 3.0f + 0.5f);
      int k = shade > 2.5f ? 3 : shade > 1.5f ? 2 : shade > 0.5f ? 1 : 0;
      s->lut[i] = pal[k];
      s->lut_key[i] = k == 0;
    }
  } else if (s->kind == K_REMAP) {
    memset(s->rc_key, 0xff, sizeof s->rc_key);
  }
}

static inline px_t modulate(px_t t, const int *c) {
  return PX(DIV255(PX_R(t) * c[0]), DIV255(PX_G(t) * c[1]), DIV255(PX_B(t) * c[2]), DIV255(PX_A(t) * c[3]));
}

static px_t shader_apply(Shader *s, px_t t, const int *c, int white) {
  px_t o;
  switch (s->kind) {
  case K_PAL4:
    return s->lut[PX_R(t)] | (t & PX_AMASK);
  case K_PAL4_KEYED:
    if (PX_R(t) >= 212 && PX_G(t) >= 212 && PX_B(t) >= 212) return s->lut[PX_R(t)];
    return s->lut[PX_R(t)] | (t & PX_AMASK);
  case K_KEY0:
    o = white ? t : modulate(t, c);
    if (PX_R(o) >= 212 && PX_G(o) >= 212 && PX_B(o) >= 212) o &= PX_RGBMASK;
    return o;
  case K_GBC:
    o = s->lut[PX_R(t)] | (t & PX_AMASK);
    return white ? o : modulate(o, c);
  case K_GBC_KEYED:
    o = s->lut_key[PX_R(t)] ? s->lut[PX_R(t)] : (s->lut[PX_R(t)] | (t & PX_AMASK));
    return white ? o : modulate(o, c);
  case K_REMAP: {
    uint32_t key = t & PX_RGBMASK;
    unsigned h = (key * 2654435761u) >> 24;
    if (s->rc_key[h] != key) {
      Uniform *cnt = shader_uniform(s, "remapCount", 0), *tol = shader_uniform(s, "remapTol", 0);
      Uniform *src = shader_uniform(s, "remapSrc", 0), *dst = shader_uniform(s, "remapDst", 0);
      float best = tol ? tol->v[0] : 0, r = PX_R(t) / 255.0f, g = PX_G(t) / 255.0f, b = PX_B(t) / 255.0f;
      int n = cnt ? (int)cnt->v[0] : 0, i;
      px_t m = key;
      if (n > 64) n = 64;
      for (i = 0; src && dst && i < n && i * 3 + 2 < src->n && i * 3 + 2 < dst->n; i++) {
        float dr = r - src->v[i * 3], dg = g - src->v[i * 3 + 1], db = b - src->v[i * 3 + 2];
        float dist = dr * dr + dg * dg + db * db;
        if (dist < best) {
          best = dist;
          m = PX(lp_f2b(dst->v[i * 3]), lp_f2b(dst->v[i * 3 + 1]), lp_f2b(dst->v[i * 3 + 2]), 0);
        }
      }
      s->rc_key[h] = key;
      s->rc_val[h] = m;
    }
    o = s->rc_val[h] | (t & PX_AMASK);
    return white ? o : modulate(o, c);
  }
  default:
    return white ? t : modulate(t, c);
  }
}

/* ------------------------------------------------------------ state */

enum { B_ALPHA, B_REPLACE, B_ADD, B_SUBTRACT, B_MULTIPLY, B_LIGHTEN, B_DARKEN, B_SCREEN, B_NONE };
static const char *const blend_names[] = {"alpha", "replace", "add", "subtract", "multiply", "lighten", "darken", "screen", "none", NULL};

typedef struct GState {
  float color[4];
  float bg[4];
  int blend, premul;
  Mat tf;
  int sc_on, sx, sy, sw, sh;
  Shader *shader;
  Font *font;
  float line_width;
  float point_size;
  int line_join;
} GState;

#define STACK_MAX 64
static GState g_st;
static GState g_stack[STACK_MAX];
static int g_stack_all[STACK_MAX];
static int g_depth;
static Tex *g_back;       /* window backbuffer */
static Tex *g_target;     /* current render target */
static int g_default_linear;
static int g_present_mode = 1, g_present_smooth = 1;
static Tex *g_overlay;    /* HUD canvas composited by the platform after scaling */
static lua_State *g_L;
static int g_draw_calls;

/* registry keys holding Lua references for the current state/stack */
static const char *const REF_KEY = "lovepsp.gfx.refs";

Tex *gfx_backbuffer(void) { return g_back; }
const float *gfx_current_color(void) { return g_st.color; }

void gfx_resize_backbuffer(int w, int h) {
  Tex *t;
  if (g_back && g_back->w == w && g_back->h == h) return;
  t = tex_new(w, h);
  if (!t) return;
  if (g_target == g_back) g_target = t;
  tex_release(g_back);
  g_back = t;
  if (!g_target) g_target = t;
}

/* painter for the current draw: color as ints, blend, shader */
typedef struct Paint {
  int c[4];
  int white;
  int blend, premul;
  Shader *sh;
  px_t *dst;
  int dw;
  int cx0, cy0, cx1, cy1; /* clip, exclusive max */
} Paint;

static void paint_setup(Paint *p, const float *color) {
  const float *col = color ? color : g_st.color;
  int i;
  for (i = 0; i < 4; i++) p->c[i] = lp_f2b(col[i]);
  p->white = p->c[0] == 255 && p->c[1] == 255 && p->c[2] == 255 && p->c[3] == 255;
  p->blend = g_st.blend;
  p->premul = g_st.premul;
  p->sh = g_st.shader;
  if (p->sh && p->sh->dirty) shader_build(p->sh);
  p->dst = g_target->px;
  p->dw = g_target->w;
  p->cx0 = 0; p->cy0 = 0; p->cx1 = g_target->w; p->cy1 = g_target->h;
  if (g_st.sc_on) {
    if (g_st.sx > p->cx0) p->cx0 = g_st.sx;
    if (g_st.sy > p->cy0) p->cy0 = g_st.sy;
    if (g_st.sx + g_st.sw < p->cx1) p->cx1 = g_st.sx + g_st.sw;
    if (g_st.sy + g_st.sh < p->cy1) p->cy1 = g_st.sy + g_st.sh;
  }
  g_draw_calls++;
}

static inline void blend_px(px_t *d, px_t s, int blend, int premul) {
  int sr = PX_R(s), sg = PX_G(s), sb = PX_B(s), sa = PX_A(s);
  px_t D = *d;
  int dr = PX_R(D), dg = PX_G(D), db = PX_B(D), da = PX_A(D), ia;
  if (!premul && blend != B_MULTIPLY) { /* alphamultiply: premultiply src */
    if (sa != 255) { sr = DIV255(sr * sa); sg = DIV255(sg * sa); sb = DIV255(sb * sa); }
  }
  switch (blend) {
  case B_ALPHA:
    if (sa == 0 && !premul) return;
    if (sa == 255) { *d = PX(sr, sg, sb, 255); return; }
    ia = 255 - sa;
    dr = sr + DIV255(dr * ia); dg = sg + DIV255(dg * ia); db = sb + DIV255(db * ia);
    da = sa + DIV255(da * ia);
    break;
  case B_REPLACE: dr = sr; dg = sg; db = sb; da = sa; break;
  case B_NONE: dr = sr; dg = sg; db = sb; da = sa; break;
  case B_ADD: dr += sr; dg += sg; db += sb; break;
  case B_SUBTRACT: dr -= sr; dg -= sg; db -= sb; break;
  case B_MULTIPLY:
    dr = DIV255(sr * dr); dg = DIV255(sg * dg); db = DIV255(sb * db); da = DIV255(sa * da);
    break;
  case B_LIGHTEN:
    if (sr > dr) dr = sr;
    if (sg > dg) dg = sg;
    if (sb > db) db = sb;
    if (sa > da) da = sa;
    break;
  case B_DARKEN:
    if (sr < dr) dr = sr;
    if (sg < dg) dg = sg;
    if (sb < db) db = sb;
    if (sa < da) da = sa;
    break;
  case B_SCREEN:
    dr = sr + DIV255(dr * (255 - sr)); dg = sg + DIV255(dg * (255 - sg));
    db = sb + DIV255(db * (255 - sb)); da = sa + DIV255(da * (255 - sa));
    break;
  }
  if (dr < 0) dr = 0; else if (dr > 255) dr = 255;
  if (dg < 0) dg = 0; else if (dg > 255) dg = 255;
  if (db < 0) db = 0; else if (db > 255) db = 255;
  if (da < 0) da = 0; else if (da > 255) da = 255;
  *d = PX(dr, dg, db, da);
}

/* fragment for texel t under the paint, then blend into d */
static inline void frag(Paint *p, px_t *d, px_t t) {
  px_t s;
  if (p->sh) s = shader_apply(p->sh, t, p->c, p->white);
  else if (p->white) s = t;
  else s = modulate(t, p->c);
  if (p->blend == B_ALPHA && !p->premul) {
    unsigned a = PX_A(s);
    if (a == 255) { *d = s; return; }
    if (a == 0) return;
  }
  blend_px(d, s, p->blend, p->premul);
}

/* ------------------------------------------------------------ textured quads */

static inline int wrapi(int v, int n, int repeat) {
  if (repeat) { v %= n; if (v < 0) v += n; return v; }
  return v < 0 ? 0 : (v >= n ? n - 1 : v);
}

void gfx_draw_texture(Tex *t, float qx, float qy, float qw, float qh, float refw, float refh,
                      Mat m, const float *color) {
  Paint p;
  float xs[4], ys[4], minx, maxx, miny, maxy;
  float kx = refw > 0 ? t->w / refw : 1, ky = refh > 0 ? t->h / refh : 1;
  int x0, x1, y0, y1, x, y, i;
  if (!t || !g_target || qw <= 0 || qh <= 0) return;
  paint_setup(&p, color);
  if (p.c[3] == 0 && p.blend == B_ALPHA && !p.sh) return;
  xs[0] = m.e; ys[0] = m.f;
  xs[1] = m.a * qw + m.e; ys[1] = m.b * qw + m.f;
  xs[2] = m.c * qh + m.e; ys[2] = m.d * qh + m.f;
  xs[3] = m.a * qw + m.c * qh + m.e; ys[3] = m.b * qw + m.d * qh + m.f;
  minx = maxx = xs[0]; miny = maxy = ys[0];
  for (i = 1; i < 4; i++) {
    if (xs[i] < minx) minx = xs[i];
    if (xs[i] > maxx) maxx = xs[i];
    if (ys[i] < miny) miny = ys[i];
    if (ys[i] > maxy) maxy = ys[i];
  }
  if (maxx < -1e6f || minx > 1e6f || maxy < -1e6f || miny > 1e6f) return;
  x0 = (int)ceilf(minx - 0.5f); x1 = (int)ceilf(maxx - 0.5f);
  y0 = (int)ceilf(miny - 0.5f); y1 = (int)ceilf(maxy - 0.5f);
  if (x0 < p.cx0) x0 = p.cx0;
  if (y0 < p.cy0) y0 = p.cy0;
  if (x1 > p.cx1) x1 = p.cx1;
  if (y1 > p.cy1) y1 = p.cy1;
  if (x0 >= x1 || y0 >= y1) return;

  if (fabsf(m.b) < 1e-6f && fabsf(m.c) < 1e-6f && m.a != 0 && m.d != 0) {
    /* axis aligned: per-column texel map, one texel row per destination row */
    static int colmap[2048];
    int n = x1 - x0;
    float ia = 1.0f / m.a, id = 1.0f / m.d;
    if (n > 2048) n = 2048, x1 = x0 + 2048;
    for (i = 0; i < n; i++) {
      float u = ((x0 + i) + 0.5f - m.e) * ia; /* 0..qw */
      if (u < 0) u = 0;
      if (u >= qw) u = qw - 1e-3f;
      colmap[i] = wrapi((int)floorf((qx + u) * kx), t->w, t->wrap_repeat_x);
    }
    for (y = y0; y < y1; y++) {
      float v = (y + 0.5f - m.f) * id;
      const px_t *srow;
      px_t *drow = p.dst + (long)y * p.dw + x0;
      if (v < 0) v = 0;
      if (v >= qh) v = qh - 1e-3f;
      srow = t->px + (long)wrapi((int)floorf((qy + v) * ky), t->h, t->wrap_repeat_y) * t->w;
      if (!p.sh && p.white && p.blend == B_ALPHA && !p.premul) {
        for (i = 0; i < n; i++) {
          px_t s = srow[colmap[i]];
          unsigned a = PX_A(s);
          if (a == 255) drow[i] = s;
          else if (a) blend_px(&drow[i], s, B_ALPHA, 0);
        }
      } else {
        for (i = 0; i < n; i++) frag(&p, &drow[i], srow[colmap[i]]);
      }
    }
    return;
  }
  {
    Mat inv;
    if (!mat_invert(m, &inv)) return;
    for (y = y0; y < y1; y++) {
      float fy = y + 0.5f, fx = x0 + 0.5f;
      float u = inv.a * fx + inv.c * fy + inv.e;
      float v = inv.b * fx + inv.d * fy + inv.f;
      px_t *drow = p.dst + (long)y * p.dw;
      for (x = x0; x < x1; x++, u += inv.a, v += inv.b) {
        int tx, ty;
        if (u < 0 || v < 0 || u >= qw || v >= qh) continue;
        tx = wrapi((int)floorf((qx + u) * kx), t->w, t->wrap_repeat_x);
        ty = wrapi((int)floorf((qy + v) * ky), t->h, t->wrap_repeat_y);
        frag(&p, &drow[x], t->px[(long)ty * t->w + tx]);
      }
    }
  }
}

/* ------------------------------------------------------------ polygons */

/* even-odd scanline fill of a closed polygon given in target pixels */
static void fill_poly(const float *pts, int n, Paint *p) {
  float miny, maxy;
  int y0, y1, y, i;
  static float xs[512];
  /* opaque untextured fill with no shader: plain stores */
  int solid = !p->sh && p->blend == B_ALPHA && !p->premul && p->c[3] == 255;
  px_t solidpx = PX(p->c[0], p->c[1], p->c[2], 255);
  if (n < 3) return;
  miny = maxy = pts[1];
  for (i = 1; i < n; i++) {
    if (pts[i * 2 + 1] < miny) miny = pts[i * 2 + 1];
    if (pts[i * 2 + 1] > maxy) maxy = pts[i * 2 + 1];
  }
  y0 = (int)ceilf(miny - 0.5f); y1 = (int)ceilf(maxy - 0.5f);
  if (y0 < p->cy0) y0 = p->cy0;
  if (y1 > p->cy1) y1 = p->cy1;
  for (y = y0; y < y1; y++) {
    float yc = y + 0.5f;
    int k = 0, a, b;
    for (i = 0; i < n && k < 512; i++) {
      float ax = pts[i * 2], ay = pts[i * 2 + 1];
      float bx = pts[((i + 1) % n) * 2], by = pts[((i + 1) % n) * 2 + 1];
      if ((ay <= yc && by > yc) || (by <= yc && ay > yc))
        xs[k++] = ax + (yc - ay) * (bx - ax) / (by - ay);
    }
    /* insertion sort, k is tiny */
    for (a = 1; a < k; a++) {
      float v = xs[a];
      b = a - 1;
      while (b >= 0 && xs[b] > v) { xs[b + 1] = xs[b]; b--; }
      xs[b + 1] = v;
    }
    for (a = 0; a + 1 < k; a += 2) {
      int xa = (int)ceilf(xs[a] - 0.5f), xb = (int)ceilf(xs[a + 1] - 0.5f), x;
      px_t *row = p->dst + (long)y * p->dw;
      if (xa < p->cx0) xa = p->cx0;
      if (xb > p->cx1) xb = p->cx1;
      if (solid) { for (x = xa; x < xb; x++) row[x] = solidpx; }
      else for (x = xa; x < xb; x++) frag(p, &row[x], 0xffffffffu);
    }
  }
}

/* transform local points by the current transform, then fill */
static void fill_local(const float *pts, int n, const float *color) {
  Paint p;
  float *tp;
  int i;
  Mat m = g_st.tf;
  if (n < 3 || !g_target) return;
  paint_setup(&p, color);
  tp = (float *)malloc(sizeof(float) * 2 * n);
  if (!tp) return;
  for (i = 0; i < n; i++) {
    float x = pts[i * 2], y = pts[i * 2 + 1];
    tp[i * 2] = m.a * x + m.c * y + m.e;
    tp[i * 2 + 1] = m.b * x + m.d * y + m.f;
  }
  fill_poly(tp, n, &p);
  free(tp);
}

static void fill_rect_local(float x, float y, float w, float h) {
  Mat m = g_st.tf;
  if (w < 0) { x += w; w = -w; }
  if (h < 0) { y += h; h = -h; }
  if (fabsf(m.b) < 1e-6f && fabsf(m.c) < 1e-6f) {
    Paint p;
    float ax = m.a * x + m.e, bx = m.a * (x + w) + m.e;
    float ay = m.d * y + m.f, by = m.d * (y + h) + m.f;
    int x0, x1, y0, y1, yy, xx;
    if (!g_target) return;
    paint_setup(&p, NULL);
    if (ax > bx) { float t = ax; ax = bx; bx = t; }
    if (ay > by) { float t = ay; ay = by; by = t; }
    x0 = (int)ceilf(ax - 0.5f); x1 = (int)ceilf(bx - 0.5f);
    y0 = (int)ceilf(ay - 0.5f); y1 = (int)ceilf(by - 0.5f);
    if (x0 < p.cx0) x0 = p.cx0;
    if (y0 < p.cy0) y0 = p.cy0;
    if (x1 > p.cx1) x1 = p.cx1;
    if (y1 > p.cy1) y1 = p.cy1;
    if (x0 >= x1) return;
    if (!p.sh && p.blend == B_ALPHA && !p.premul && p.c[3] == 255) {
      px_t s = PX(p.c[0], p.c[1], p.c[2], 255);
      for (yy = y0; yy < y1; yy++) {
        px_t *row = p.dst + (long)yy * p.dw;
        for (xx = x0; xx < x1; xx++) row[xx] = s;
      }
      return;
    }
    for (yy = y0; yy < y1; yy++) {
      px_t *row = p.dst + (long)yy * p.dw;
      for (xx = x0; xx < x1; xx++) frag(&p, &row[xx], 0xffffffffu);
    }
    return;
  }
  {
    float pts[8] = {x, y, x + w, y, x + w, y + h, x, y + h};
    fill_local(pts, 4, NULL);
  }
}

/* a thick polyline as one quad per segment (miter joins are not drawn) */
static void stroke_local(const float *pts, int n, int closed) {
  float hw = g_st.line_width * 0.5f;
  int i, segs = closed ? n : n - 1;
  if (hw <= 0) hw = 0.5f;
  for (i = 0; i < segs; i++) {
    float ax = pts[i * 2], ay = pts[i * 2 + 1];
    float bx = pts[((i + 1) % n) * 2], by = pts[((i + 1) % n) * 2 + 1];
    float dx = bx - ax, dy = by - ay, len = sqrtf(dx * dx + dy * dy), nx, ny;
    float q[8];
    if (len < 1e-6f) continue;
    nx = -dy / len * hw; ny = dx / len * hw;
    /* extend along the segment by hw so corners close */
    dx = dx / len * (closed || (i > 0) ? hw : 0);
    dy = dy / len * (closed || (i > 0) ? hw : 0);
    q[0] = ax + nx - dx; q[1] = ay + ny - dy;
    q[2] = bx + nx; q[3] = by + ny;
    q[4] = bx - nx; q[5] = by - ny;
    q[6] = ax - nx - dx; q[7] = ay - ny - dy;
    fill_local(q, 4, NULL);
  }
}

static int ellipse_points(float rx, float ry, int segs, float *out, float cx, float cy, float a0, float a1, int extra_center) {
  int i, k = 0;
  if (extra_center) { out[k++] = cx; out[k++] = cy; }
  for (i = 0; i <= segs; i++) {
    float a = a0 + (a1 - a0) * i / segs;
    out[k++] = cx + cosf(a) * rx;
    out[k++] = cy + sinf(a) * ry;
  }
  return k / 2;
}

static int auto_segments(float rx, float ry) {
  float r = (fabsf(rx) + fabsf(ry)) * 0.5f;
  float s = sqrtf(fabsf(g_st.tf.a * g_st.tf.d - g_st.tf.b * g_st.tf.c));
  int n = (int)(r * s * 0.75f) + 8;
  if (n > 96) n = 96;
  return n;
}

/* ------------------------------------------------------------ objects */

typedef struct TexObj { Tex *t; float dpi; } TexObj;
typedef struct Quad { float x, y, w, h, sw, sh; } Quad;

static int tex_gc(lua_State *L) {
  TexObj *o = (TexObj *)lua_touserdata(L, 1);
  if (o->t) { tex_release(o->t); o->t = NULL; }
  return 0;
}

static const char *const tex_chain[] = {"Texture", "Drawable", NULL};
static LPType Image_type = {"Image", tex_chain, NULL, tex_gc};
static LPType Canvas_type = {"Canvas", tex_chain, NULL, tex_gc};

static Tex *totex(lua_State *L, int idx) {
  TexObj *o = (TexObj *)lp_testobj(L, idx, &Image_type);
  if (!o) o = (TexObj *)lp_testobj(L, idx, &Canvas_type);
  if (!o) return NULL;
  if (!o->t) luaL_error(L, "Cannot use object after it has been released.");
  return o->t;
}
static Tex *checktex(lua_State *L, int idx) {
  Tex *t = totex(L, idx);
  if (!t) luaL_argerror(L, idx, "Texture expected");
  return t;
}

static int tex_getWidth(lua_State *L) { lua_pushinteger(L, checktex(L, 1)->w); return 1; }
static int tex_getHeight(lua_State *L) { lua_pushinteger(L, checktex(L, 1)->h); return 1; }
static int tex_getDimensions(lua_State *L) { Tex *t = checktex(L, 1); lua_pushinteger(L, t->w); lua_pushinteger(L, t->h); return 2; }
static int tex_getDPIScale(lua_State *L) { (void)L; lua_pushnumber(L, 1); return 1; }
static int tex_getFilter(lua_State *L) {
  Tex *t = checktex(L, 1);
  lua_pushstring(L, t->linear ? "linear" : "nearest");
  lua_pushstring(L, t->linear ? "linear" : "nearest");
  lua_pushnumber(L, 1);
  return 3;
}
static int tex_setFilter(lua_State *L) {
  Tex *t = checktex(L, 1);
  t->linear = !strcmp(luaL_optstring(L, 2, "nearest"), "linear");
  return 0;
}
static int tex_getWrap(lua_State *L) {
  Tex *t = checktex(L, 1);
  lua_pushstring(L, t->wrap_repeat_x ? "repeat" : "clamp");
  lua_pushstring(L, t->wrap_repeat_y ? "repeat" : "clamp");
  return 2;
}
static int tex_setWrap(lua_State *L) {
  Tex *t = checktex(L, 1);
  const char *h = luaL_optstring(L, 2, "clamp"), *v = luaL_optstring(L, 3, h);
  t->wrap_repeat_x = !strcmp(h, "repeat") || !strcmp(h, "mirroredrepeat");
  t->wrap_repeat_y = !strcmp(v, "repeat") || !strcmp(v, "mirroredrepeat");
  return 0;
}
static int tex_getFormat(lua_State *L) { lua_pushliteral(L, "rgba8"); return 1; }
static int tex_one(lua_State *L) { lua_pushinteger(L, 1); return 1; }
static int tex_false(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int tex_noop(lua_State *L) { (void)L; return 0; }
static int tex_getTextureType(lua_State *L) { lua_pushliteral(L, "2d"); return 1; }

static int image_replacePixels(lua_State *L) {
  Tex *t = checktex(L, 1);
  ImageData *d = imagedata_check(L, 2);
  int x = (int)luaL_optinteger(L, 5, 0), y = (int)luaL_optinteger(L, 6, 0), row;
  for (row = 0; row < d->h; row++) {
    int ty = y + row, w = d->w;
    if (ty < 0 || ty >= t->h) continue;
    if (x + w > t->w) w = t->w - x;
    if (w > 0 && x >= 0) memcpy(&t->px[(long)ty * t->w + x], &d->px[(long)row * d->w], (size_t)w * 4);
  }
  return 0;
}

static int canvas_newImageData(lua_State *L) {
  Tex *t = checktex(L, 1);
  int argb = lua_isnumber(L, 2) && lua_gettop(L) >= 6 ? 4 : (lua_gettop(L) >= 5 ? 2 : 0);
  int x = 0, y = 0, w = t->w, h = t->h, row;
  ImageData *d;
  if (argb) {
    x = (int)luaL_checkinteger(L, argb); y = (int)luaL_checkinteger(L, argb + 1);
    w = (int)luaL_checkinteger(L, argb + 2); h = (int)luaL_checkinteger(L, argb + 3);
  }
  if (x < 0 || y < 0 || x + w > t->w || y + h > t->h) return luaL_error(L, "Invalid rectangle dimensions.");
  d = imagedata_push(L, w, h);
  for (row = 0; row < h; row++) memcpy(&d->px[(long)row * w], &t->px[(long)(y + row) * t->w + x], (size_t)w * 4);
  return 1;
}

static int canvas_renderTo(lua_State *L);

static const luaL_Reg image_methods[] = {
  {"getWidth", tex_getWidth}, {"getHeight", tex_getHeight}, {"getDimensions", tex_getDimensions},
  {"getPixelWidth", tex_getWidth}, {"getPixelHeight", tex_getHeight},
  {"getPixelDimensions", tex_getDimensions}, {"getDPIScale", tex_getDPIScale},
  {"getFilter", tex_getFilter}, {"setFilter", tex_setFilter}, {"getWrap", tex_getWrap},
  {"setWrap", tex_setWrap}, {"getFormat", tex_getFormat}, {"getMipmapCount", tex_one},
  {"getLayerCount", tex_one}, {"getDepth", tex_one}, {"isReadable", tex_false},
  {"setMipmapFilter", tex_noop}, {"getMipmapFilter", tex_noop}, {"getTextureType", tex_getTextureType},
  {"isCompressed", tex_false}, {"isFormatLinear", tex_false},
  {"replacePixels", image_replacePixels}, {NULL, NULL}};

static const luaL_Reg canvas_methods[] = {
  {"getWidth", tex_getWidth}, {"getHeight", tex_getHeight}, {"getDimensions", tex_getDimensions},
  {"getPixelWidth", tex_getWidth}, {"getPixelHeight", tex_getHeight},
  {"getPixelDimensions", tex_getDimensions}, {"getDPIScale", tex_getDPIScale},
  {"getFilter", tex_getFilter}, {"setFilter", tex_setFilter}, {"getWrap", tex_getWrap},
  {"setWrap", tex_setWrap}, {"getFormat", tex_getFormat}, {"getMipmapCount", tex_one},
  {"getLayerCount", tex_one}, {"getDepth", tex_one}, {"getMSAA", tex_one},
  {"setMipmapFilter", tex_noop}, {"getMipmapFilter", tex_noop}, {"generateMipmaps", tex_noop},
  {"getTextureType", tex_getTextureType}, {"isReadable", tex_false},
  {"newImageData", canvas_newImageData}, {"renderTo", canvas_renderTo}, {NULL, NULL}};

static TexObj *push_texobj(lua_State *L, LPType *ty, Tex *t) {
  TexObj *o = (TexObj *)lp_newobj(L, ty, sizeof(TexObj));
  o->t = t;
  o->dpi = 1;
  t->linear = g_default_linear;
  return o;
}

static int g_newImage(lua_State *L) {
  Tex *t;
  ImageData *d = (ImageData *)lp_testobj(L, 1, &lp_ImageData_type);
  if (d) {
    t = tex_new(d->w, d->h);
    if (!t) return luaL_error(L, "out of memory creating %dx%d image", d->w, d->h);
    memcpy(t->px, d->px, (size_t)d->w * d->h * 4);
  } else {
    size_t len;
    const char *name = NULL;
    int w, h;
    char *buf = lp_read_source(L, 1, &len, &name);
    px_t *px;
    if (!buf) return luaL_error(L, "could not read image");
    px = image_decode(buf, len, &w, &h);
    free(buf);
    if (!px) return luaL_error(L, "Could not decode image '%s'", name ? name : "?");
    t = (Tex *)calloc(1, sizeof(Tex));
    if (!t) { free(px); return luaL_error(L, "out of memory"); }
    t->w = w; t->h = h; t->px = px; t->refs = 1;
  }
  push_texobj(L, &Image_type, t);
  return 1;
}

static int g_newCanvas(lua_State *L) {
  int w = (int)luaL_optnumber(L, 1, g_back ? g_back->w : PLAT_SCREEN_W);
  int h = (int)luaL_optnumber(L, 2, g_back ? g_back->h : PLAT_SCREEN_H);
  Tex *t;
  if (w > 4096 || h > 4096) return luaL_error(L, "Cannot create canvas: size %dx%d exceeds the 4096 limit", w, h);
  t = tex_new(w, h);
  if (!t) return luaL_error(L, "Cannot create canvas: out of memory (%dx%d)", w, h);
  t->is_canvas = 1;
  push_texobj(L, &Canvas_type, t);
  return 1;
}

/* Quad */
static const char *const quad_chain[] = {NULL};
static int quad_getViewport(lua_State *L);
static int quad_setViewport(lua_State *L);
static int quad_getTextureDimensions(lua_State *L);
static const luaL_Reg quad_methods[] = {
  {"getViewport", quad_getViewport}, {"setViewport", quad_setViewport},
  {"getTextureDimensions", quad_getTextureDimensions}, {NULL, NULL}};
static LPType Quad_type = {"Quad", quad_chain, quad_methods, NULL};

static int quad_getViewport(lua_State *L) {
  Quad *q = (Quad *)lp_checkobj(L, 1, &Quad_type);
  lua_pushnumber(L, q->x); lua_pushnumber(L, q->y); lua_pushnumber(L, q->w); lua_pushnumber(L, q->h);
  return 4;
}
static int quad_setViewport(lua_State *L) {
  Quad *q = (Quad *)lp_checkobj(L, 1, &Quad_type);
  q->x = (float)luaL_checknumber(L, 2); q->y = (float)luaL_checknumber(L, 3);
  q->w = (float)luaL_checknumber(L, 4); q->h = (float)luaL_checknumber(L, 5);
  if (lua_isnumber(L, 6)) { q->sw = (float)lua_tonumber(L, 6); q->sh = (float)luaL_checknumber(L, 7); }
  return 0;
}
static int quad_getTextureDimensions(lua_State *L) {
  Quad *q = (Quad *)lp_checkobj(L, 1, &Quad_type);
  lua_pushnumber(L, q->sw); lua_pushnumber(L, q->sh);
  return 2;
}
static int g_newQuad(lua_State *L) {
  Quad *q = (Quad *)lp_newobj(L, &Quad_type, sizeof(Quad));
  q->x = (float)luaL_checknumber(L, 1); q->y = (float)luaL_checknumber(L, 2);
  q->w = (float)luaL_checknumber(L, 3); q->h = (float)luaL_checknumber(L, 4);
  if (lua_isnumber(L, 5)) { q->sw = (float)lua_tonumber(L, 5); q->sh = (float)luaL_checknumber(L, 6); }
  else {
    Tex *t = totex(L, 5);
    if (!t) return luaL_error(L, "newQuad: reference dimensions or texture expected");
    q->sw = (float)t->w; q->sh = (float)t->h;
  }
  return 1;
}

/* ------------------------------------------------------------ Transform */

typedef struct TransformObj { Mat m; } TransformObj;
static const char *const tf_chain[] = {NULL};
static LPType Transform_type;

static Mat *checktf(lua_State *L, int i) { return &((TransformObj *)lp_checkobj(L, i, &Transform_type))->m; }

static Mat read_transformation(lua_State *L, int i) {
  return mat_transformation((float)luaL_optnumber(L, i, 0), (float)luaL_optnumber(L, i + 1, 0),
                            (float)luaL_optnumber(L, i + 2, 0), (float)luaL_optnumber(L, i + 3, 1),
                            (float)luaL_optnumber(L, i + 4, lua_isnumber(L, i + 3) ? lua_tonumber(L, i + 3) : 1),
                            (float)luaL_optnumber(L, i + 5, 0), (float)luaL_optnumber(L, i + 6, 0),
                            (float)luaL_optnumber(L, i + 7, 0), (float)luaL_optnumber(L, i + 8, 0));
}

static int tf_push(lua_State *L, Mat m) {
  TransformObj *t = (TransformObj *)lp_newobj(L, &Transform_type, sizeof(TransformObj));
  t->m = m;
  return 1;
}
static int tf_translate(lua_State *L) { Mat *m = checktf(L, 1); Mat t = {1, 0, 0, 1, (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3)}; *m = mat_mul(*m, t); lua_settop(L, 1); return 1; }
static int tf_scale(lua_State *L) { Mat *m = checktf(L, 1); float sx = (float)luaL_checknumber(L, 2); Mat t = {sx, 0, 0, (float)luaL_optnumber(L, 3, sx), 0, 0}; *m = mat_mul(*m, t); lua_settop(L, 1); return 1; }
static int tf_rotate(lua_State *L) { Mat *m = checktf(L, 1); float a = (float)luaL_checknumber(L, 2); Mat t = {cosf(a), sinf(a), -sinf(a), cosf(a), 0, 0}; *m = mat_mul(*m, t); lua_settop(L, 1); return 1; }
static int tf_shear(lua_State *L) { Mat *m = checktf(L, 1); Mat t = {1, (float)luaL_checknumber(L, 3), (float)luaL_checknumber(L, 2), 1, 0, 0}; *m = mat_mul(*m, t); lua_settop(L, 1); return 1; }
static int tf_reset(lua_State *L) { *checktf(L, 1) = mat_identity(); lua_settop(L, 1); return 1; }
static int tf_clone(lua_State *L) { return tf_push(L, *checktf(L, 1)); }
static int tf_inverse(lua_State *L) { Mat o; if (!mat_invert(*checktf(L, 1), &o)) o = mat_identity(); return tf_push(L, o); }
static int tf_apply(lua_State *L) { Mat *m = checktf(L, 1); *m = mat_mul(*m, *checktf(L, 2)); lua_settop(L, 1); return 1; }
static int tf_setTransformation(lua_State *L) { *checktf(L, 1) = read_transformation(L, 2); lua_settop(L, 1); return 1; }
static int tf_transformPoint(lua_State *L) {
  Mat *m = checktf(L, 1);
  float x = (float)luaL_checknumber(L, 2), y = (float)luaL_checknumber(L, 3);
  lua_pushnumber(L, m->a * x + m->c * y + m->e); lua_pushnumber(L, m->b * x + m->d * y + m->f);
  return 2;
}
static int tf_inverseTransformPoint(lua_State *L) {
  Mat o, *m = checktf(L, 1);
  float x = (float)luaL_checknumber(L, 2), y = (float)luaL_checknumber(L, 3);
  if (!mat_invert(*m, &o)) o = mat_identity();
  lua_pushnumber(L, o.a * x + o.c * y + o.e); lua_pushnumber(L, o.b * x + o.d * y + o.f);
  return 2;
}
static int tf_getMatrix(lua_State *L) {
  Mat *m = checktf(L, 1);
  double v[16] = {m->a, m->c, 0, m->e, m->b, m->d, 0, m->f, 0, 0, 1, 0, 0, 0, 0, 1};
  int i;
  for (i = 0; i < 16; i++) lua_pushnumber(L, v[i]);
  return 16;
}
static int tf_setMatrix(lua_State *L) {
  Mat *m = checktf(L, 1);
  int i = 2;
  if (lua_type(L, 2) == LUA_TSTRING) i = 3;
  m->a = (float)luaL_checknumber(L, i); m->c = (float)luaL_checknumber(L, i + 1); m->e = (float)luaL_checknumber(L, i + 3);
  m->b = (float)luaL_checknumber(L, i + 4); m->d = (float)luaL_checknumber(L, i + 5); m->f = (float)luaL_checknumber(L, i + 7);
  lua_settop(L, 1);
  return 1;
}
static int tf_isAffine(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static const luaL_Reg tf_methods[] = {
  {"translate", tf_translate}, {"scale", tf_scale}, {"rotate", tf_rotate}, {"shear", tf_shear},
  {"reset", tf_reset}, {"clone", tf_clone}, {"inverse", tf_inverse}, {"apply", tf_apply},
  {"setTransformation", tf_setTransformation}, {"transformPoint", tf_transformPoint},
  {"inverseTransformPoint", tf_inverseTransformPoint}, {"getMatrix", tf_getMatrix},
  {"setMatrix", tf_setMatrix}, {"isAffine2DTransform", tf_isAffine}, {NULL, NULL}};
static LPType Transform_type = {"Transform", tf_chain, tf_methods, NULL};

int lp_newTransform(lua_State *L) {
  if (lua_gettop(L) == 0) return tf_push(L, mat_identity());
  return tf_push(L, read_transformation(L, 1));
}

/* draw arguments after the drawable (and quad): x,y,r,sx,sy,ox,oy,kx,ky or Transform */
static Mat draw_matrix(lua_State *L, int i) {
  TransformObj *t = (TransformObj *)lp_testobj(L, i, &Transform_type);
  if (t) return mat_mul(g_st.tf, t->m);
  return mat_mul(g_st.tf, read_transformation(L, i));
}

/* ------------------------------------------------------------ SpriteBatch */

typedef struct SBItem { float qx, qy, qw, qh, rw, rh; Mat m; float color[4]; int has_color; } SBItem;
typedef struct SpriteBatch {
  Tex *t;
  SBItem *items;
  int count, cap, limit;
  float color[4];
  int has_color;
  int range_start, range_count;
} SpriteBatch;

static int sb_gc(lua_State *L) {
  SpriteBatch *b = (SpriteBatch *)lua_touserdata(L, 1);
  if (b->t) { tex_release(b->t); b->t = NULL; }
  free(b->items); b->items = NULL;
  return 0;
}
static const char *const sb_chain[] = {"Drawable", NULL};
static LPType SpriteBatch_type;
static SpriteBatch *checksb(lua_State *L) { return (SpriteBatch *)lp_checkobj(L, 1, &SpriteBatch_type); }

static int sb_fill(lua_State *L, SpriteBatch *b, SBItem *it) {
  Quad *q = (Quad *)lp_testobj(L, 2, &Quad_type);
  int ai = q ? 3 : 2;
  TransformObj *t;
  if (q) { it->qx = q->x; it->qy = q->y; it->qw = q->w; it->qh = q->h; it->rw = q->sw; it->rh = q->sh; }
  else {
    it->qx = 0; it->qy = 0;
    it->qw = it->rw = (float)b->t->w; it->qh = it->rh = (float)b->t->h;
  }
  t = (TransformObj *)lp_testobj(L, ai, &Transform_type);
  it->m = t ? t->m : read_transformation(L, ai);
  it->has_color = b->has_color;
  memcpy(it->color, b->color, sizeof it->color);
  return 0;
}

static int sb_add(lua_State *L) {
  SpriteBatch *b = checksb(L);
  if (b->limit > 0 && b->count >= b->limit) { lua_pushinteger(L, 0); return 1; }
  if (b->count >= b->cap) {
    int nc = b->cap ? b->cap * 2 : 64;
    SBItem *n = (SBItem *)realloc(b->items, sizeof(SBItem) * nc);
    if (!n) return luaL_error(L, "out of memory in SpriteBatch:add");
    b->items = n; b->cap = nc;
  }
  sb_fill(L, b, &b->items[b->count]);
  lua_pushinteger(L, ++b->count);
  return 1;
}
static int sb_set(lua_State *L) {
  SpriteBatch *b = checksb(L);
  int id = (int)luaL_checkinteger(L, 2);
  if (id < 1 || id > b->count) return luaL_error(L, "Invalid sprite index: %d", id);
  lua_remove(L, 2);
  sb_fill(L, b, &b->items[id - 1]);
  return 0;
}
static int sb_clear(lua_State *L) { checksb(L)->count = 0; return 0; }
static int sb_flush(lua_State *L) { (void)L; return 0; }
static int sb_getCount(lua_State *L) { lua_pushinteger(L, checksb(L)->count); return 1; }
static int sb_getBufferSize(lua_State *L) { SpriteBatch *b = checksb(L); lua_pushinteger(L, b->limit > 0 ? b->limit : b->cap); return 1; }
static int sb_setColor(lua_State *L) {
  SpriteBatch *b = checksb(L);
  if (lua_gettop(L) <= 1) { b->has_color = 0; return 0; }
  if (lua_istable(L, 2)) {
    int i;
    for (i = 0; i < 4; i++) { lua_rawgeti(L, 2, i + 1); b->color[i] = (float)luaL_optnumber(L, -1, 1); lua_pop(L, 1); }
  } else {
    b->color[0] = (float)luaL_checknumber(L, 2); b->color[1] = (float)luaL_checknumber(L, 3);
    b->color[2] = (float)luaL_checknumber(L, 4); b->color[3] = (float)luaL_optnumber(L, 5, 1);
  }
  b->has_color = 1;
  return 0;
}
static int sb_getColor(lua_State *L) {
  SpriteBatch *b = checksb(L);
  int i;
  if (!b->has_color) return 0;
  for (i = 0; i < 4; i++) lua_pushnumber(L, b->color[i]);
  return 4;
}
static int sb_setTexture(lua_State *L) {
  SpriteBatch *b = checksb(L);
  Tex *t = checktex(L, 2);
  tex_retain(t);
  tex_release(b->t);
  b->t = t;
  lua_settop(L, 2);
  lua_setiuservalue(L, 1, 1);
  return 0;
}
static int sb_getTexture(lua_State *L) { checksb(L); lua_getiuservalue(L, 1, 1); return 1; }
static int sb_setDrawRange(lua_State *L) {
  SpriteBatch *b = checksb(L);
  if (lua_isnoneornil(L, 2)) { b->range_start = 0; b->range_count = 0; return 0; }
  b->range_start = (int)luaL_checkinteger(L, 2);
  b->range_count = (int)luaL_checkinteger(L, 3);
  return 0;
}
static int sb_getDrawRange(lua_State *L) {
  SpriteBatch *b = checksb(L);
  if (!b->range_count) return 0;
  lua_pushinteger(L, b->range_start); lua_pushinteger(L, b->range_count);
  return 2;
}
static int sb_attach(lua_State *L) { (void)L; return 0; }
static const luaL_Reg sb_methods[] = {
  {"add", sb_add}, {"set", sb_set}, {"clear", sb_clear}, {"flush", sb_flush},
  {"getCount", sb_getCount}, {"getBufferSize", sb_getBufferSize}, {"setColor", sb_setColor},
  {"getColor", sb_getColor}, {"setTexture", sb_setTexture}, {"getTexture", sb_getTexture},
  {"setDrawRange", sb_setDrawRange}, {"getDrawRange", sb_getDrawRange},
  {"attachAttribute", sb_attach}, {"setBufferSize", sb_attach}, {NULL, NULL}};
static LPType SpriteBatch_type = {"SpriteBatch", sb_chain, sb_methods, sb_gc};

static int g_newSpriteBatch(lua_State *L) {
  Tex *t = checktex(L, 1);
  SpriteBatch *b;
  lua_settop(L, 1); /* size and usage hints are irrelevant: batches grow */
  b = (SpriteBatch *)lp_newobj(L, &SpriteBatch_type, sizeof(SpriteBatch));
  b->t = t;
  tex_retain(t);
  lp_setref(L, -1, 1, 1);
  return 1;
}

static void sb_draw(SpriteBatch *b, Mat m) {
  int i, start = 0, end = b->count;
  const float *gc = g_st.color;
  if (b->range_count > 0) {
    start = b->range_start - 1;
    end = start + b->range_count;
    if (start < 0) start = 0;
    if (end > b->count) end = b->count;
  }
  for (i = start; i < end; i++) {
    SBItem *it = &b->items[i];
    float c[4];
    if (it->has_color) {
      c[0] = it->color[0] * gc[0]; c[1] = it->color[1] * gc[1];
      c[2] = it->color[2] * gc[2]; c[3] = it->color[3] * gc[3];
      gfx_draw_texture(b->t, it->qx, it->qy, it->qw, it->qh, it->rw, it->rh, mat_mul(m, it->m), c);
    } else {
      gfx_draw_texture(b->t, it->qx, it->qy, it->qw, it->qh, it->rw, it->rh, mat_mul(m, it->m), NULL);
    }
  }
}

/* ------------------------------------------------------------ Mesh */

typedef struct MVert { float x, y, u, v, r, g, b, a; } MVert;
typedef struct Mesh {
  MVert *v;
  int n;
  int mode; /* 0 fan, 1 strip, 2 triangles, 3 points */
  int *map; int nmap;
  Tex *tex;
  int range_start, range_count;
  int attr_pos, attr_uv, attr_col; /* component offsets in the user format */
  int ncomp;
} Mesh;

static int mesh_gc(lua_State *L) {
  Mesh *m = (Mesh *)lua_touserdata(L, 1);
  free(m->v); m->v = NULL;
  free(m->map); m->map = NULL;
  if (m->tex) { tex_release(m->tex); m->tex = NULL; }
  return 0;
}
static const char *const mesh_chain[] = {"Drawable", NULL};
static LPType Mesh_type;
static Mesh *checkmesh(lua_State *L) { return (Mesh *)lp_checkobj(L, 1, &Mesh_type); }

static void mesh_read_vertex(lua_State *L, Mesh *m, int tidx, MVert *v) {
  float comp[16];
  int i;
  for (i = 0; i < m->ncomp && i < 16; i++) {
    lua_rawgeti(L, tidx, i + 1);
    comp[i] = (float)luaL_optnumber(L, -1, (i >= m->attr_col && m->attr_col >= 0) ? 1 : 0);
    lua_pop(L, 1);
  }
  v->x = m->attr_pos >= 0 ? comp[m->attr_pos] : 0;
  v->y = m->attr_pos >= 0 ? comp[m->attr_pos + 1] : 0;
  v->u = m->attr_uv >= 0 ? comp[m->attr_uv] : 0;
  v->v = m->attr_uv >= 0 ? comp[m->attr_uv + 1] : 0;
  if (m->attr_col >= 0) {
    v->r = comp[m->attr_col]; v->g = comp[m->attr_col + 1];
    v->b = comp[m->attr_col + 2]; v->a = m->attr_col + 3 < m->ncomp ? comp[m->attr_col + 3] : 1;
  } else { v->r = v->g = v->b = v->a = 1; }
}

static int mesh_mode(const char *s) {
  if (!strcmp(s, "strip")) return 1;
  if (!strcmp(s, "triangles")) return 2;
  if (!strcmp(s, "points")) return 3;
  return 0;
}

static int g_newMesh(lua_State *L) {
  Mesh *m;
  int vi = 1, i, mi;
  int has_format = 0;
  if (lua_istable(L, 1)) {
    lua_rawgeti(L, 1, 1);
    if (lua_istable(L, -1)) {
      lua_rawgeti(L, -1, 1);
      has_format = lua_type(L, -1) == LUA_TSTRING;
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  if (has_format) vi = 2;
  m = (Mesh *)lp_newobj(L, &Mesh_type, sizeof(Mesh));
  mi = lua_gettop(L);
  m->attr_pos = 0; m->attr_uv = 2; m->attr_col = 4; m->ncomp = 8;
  if (has_format) {
    int n = (int)lua_rawlen(L, 1), off = 0;
    m->attr_pos = m->attr_uv = m->attr_col = -1;
    for (i = 1; i <= n; i++) {
      const char *name;
      int comps;
      lua_rawgeti(L, 1, i);
      lua_rawgeti(L, -1, 1); name = lua_tostring(L, -1);
      lua_rawgeti(L, -2, 3); comps = (int)lua_tointeger(L, -1);
      if (name && !strcmp(name, "VertexPosition")) m->attr_pos = off;
      else if (name && !strcmp(name, "VertexTexCoord")) m->attr_uv = off;
      else if (name && !strcmp(name, "VertexColor")) m->attr_col = off;
      off += comps > 0 ? comps : 0;
      lua_pop(L, 3);
    }
    m->ncomp = off;
  }
  if (lua_istable(L, vi)) {
    m->n = (int)lua_rawlen(L, vi);
    m->v = (MVert *)calloc(m->n ? m->n : 1, sizeof(MVert));
    for (i = 0; i < m->n; i++) {
      lua_rawgeti(L, vi, i + 1);
      mesh_read_vertex(L, m, lua_gettop(L), &m->v[i]);
      lua_pop(L, 1);
    }
  } else {
    m->n = (int)luaL_checkinteger(L, vi);
    m->v = (MVert *)calloc(m->n ? m->n : 1, sizeof(MVert));
    for (i = 0; i < m->n; i++) m->v[i].r = m->v[i].g = m->v[i].b = m->v[i].a = 1;
  }
  m->mode = mesh_mode(luaL_optstring(L, vi + 1, "fan"));
  lua_pushvalue(L, mi);
  return 1;
}

static int mesh_setVertices(lua_State *L) {
  Mesh *m = checkmesh(L);
  int start = (int)luaL_optinteger(L, 3, 1) - 1, n, i;
  luaL_checktype(L, 2, LUA_TTABLE);
  n = (int)lua_rawlen(L, 2);
  if (start + n > m->n) {
    MVert *nv = (MVert *)realloc(m->v, sizeof(MVert) * (start + n));
    if (!nv) return luaL_error(L, "out of memory");
    m->v = nv; m->n = start + n;
  }
  for (i = 0; i < n; i++) {
    lua_rawgeti(L, 2, i + 1);
    mesh_read_vertex(L, m, lua_gettop(L), &m->v[start + i]);
    lua_pop(L, 1);
  }
  return 0;
}
static int mesh_setVertex(lua_State *L) {
  Mesh *m = checkmesh(L);
  int i = (int)luaL_checkinteger(L, 2) - 1;
  if (i < 0 || i >= m->n) return luaL_error(L, "Invalid vertex index");
  if (lua_istable(L, 3)) mesh_read_vertex(L, m, 3, &m->v[i]);
  else {
    int k, top = lua_gettop(L);
    lua_newtable(L);
    for (k = 3; k <= top; k++) { lua_pushvalue(L, k); lua_rawseti(L, -2, k - 2); }
    mesh_read_vertex(L, m, lua_gettop(L), &m->v[i]);
  }
  return 0;
}
static int mesh_getVertex(lua_State *L) {
  Mesh *m = checkmesh(L);
  int i = (int)luaL_checkinteger(L, 2) - 1;
  MVert *v;
  if (i < 0 || i >= m->n) return luaL_error(L, "Invalid vertex index");
  v = &m->v[i];
  lua_pushnumber(L, v->x); lua_pushnumber(L, v->y); lua_pushnumber(L, v->u); lua_pushnumber(L, v->v);
  lua_pushnumber(L, v->r); lua_pushnumber(L, v->g); lua_pushnumber(L, v->b); lua_pushnumber(L, v->a);
  return 8;
}
static int mesh_getVertexCount(lua_State *L) { lua_pushinteger(L, checkmesh(L)->n); return 1; }
static int mesh_setTexture(lua_State *L) {
  Mesh *m = checkmesh(L);
  Tex *t = lua_isnoneornil(L, 2) ? NULL : checktex(L, 2);
  if (t) tex_retain(t);
  if (m->tex) tex_release(m->tex);
  m->tex = t;
  lua_settop(L, 2);
  lua_setiuservalue(L, 1, 1);
  return 0;
}
static int mesh_getTexture(lua_State *L) { checkmesh(L); lua_getiuservalue(L, 1, 1); return 1; }
static int mesh_setDrawMode(lua_State *L) { checkmesh(L)->mode = mesh_mode(luaL_checkstring(L, 2)); return 0; }
static int mesh_getDrawMode(lua_State *L) {
  static const char *const names[] = {"fan", "strip", "triangles", "points"};
  lua_pushstring(L, names[checkmesh(L)->mode]);
  return 1;
}
static int mesh_setVertexMap(lua_State *L) {
  Mesh *m = checkmesh(L);
  int i, n;
  free(m->map); m->map = NULL; m->nmap = 0;
  if (lua_isnoneornil(L, 2)) return 0;
  if (lua_istable(L, 2)) {
    n = (int)lua_rawlen(L, 2);
    m->map = (int *)malloc(sizeof(int) * (n ? n : 1));
    for (i = 0; i < n; i++) { lua_rawgeti(L, 2, i + 1); m->map[i] = (int)lua_tointeger(L, -1) - 1; lua_pop(L, 1); }
  } else {
    n = lua_gettop(L) - 1;
    m->map = (int *)malloc(sizeof(int) * (n ? n : 1));
    for (i = 0; i < n; i++) m->map[i] = (int)luaL_checkinteger(L, i + 2) - 1;
  }
  m->nmap = n;
  return 0;
}
static int mesh_getVertexMap(lua_State *L) {
  Mesh *m = checkmesh(L);
  int i;
  if (!m->map) { lua_pushnil(L); return 1; }
  lua_createtable(L, m->nmap, 0);
  for (i = 0; i < m->nmap; i++) { lua_pushinteger(L, m->map[i] + 1); lua_rawseti(L, -2, i + 1); }
  return 1;
}
static int mesh_setDrawRange(lua_State *L) {
  Mesh *m = checkmesh(L);
  if (lua_isnoneornil(L, 2)) { m->range_start = m->range_count = 0; return 0; }
  m->range_start = (int)luaL_checkinteger(L, 2); m->range_count = (int)luaL_checkinteger(L, 3);
  return 0;
}
static int mesh_noop(lua_State *L) { (void)L; return 0; }
static const luaL_Reg mesh_methods[] = {
  {"setVertices", mesh_setVertices}, {"setVertex", mesh_setVertex}, {"getVertex", mesh_getVertex},
  {"getVertexCount", mesh_getVertexCount}, {"setTexture", mesh_setTexture},
  {"getTexture", mesh_getTexture}, {"setDrawMode", mesh_setDrawMode},
  {"getDrawMode", mesh_getDrawMode}, {"setVertexMap", mesh_setVertexMap},
  {"getVertexMap", mesh_getVertexMap}, {"setDrawRange", mesh_setDrawRange},
  {"flush", mesh_noop}, {"attachAttribute", mesh_noop}, {"setAttributeEnabled", mesh_noop},
  {NULL, NULL}};
static LPType Mesh_type = {"Mesh", mesh_chain, mesh_methods, mesh_gc};

/* affine textured / gouraud triangle */
static void raster_tri(Paint *p, Tex *t, const MVert *a, const MVert *b, const MVert *c) {
  float minx, maxx, miny, maxy, area;
  int x0, x1, y0, y1, x, y;
  minx = fminf(a->x, fminf(b->x, c->x)); maxx = fmaxf(a->x, fmaxf(b->x, c->x));
  miny = fminf(a->y, fminf(b->y, c->y)); maxy = fmaxf(a->y, fmaxf(b->y, c->y));
  x0 = (int)ceilf(minx - 0.5f); x1 = (int)ceilf(maxx - 0.5f);
  y0 = (int)ceilf(miny - 0.5f); y1 = (int)ceilf(maxy - 0.5f);
  if (x0 < p->cx0) x0 = p->cx0;
  if (y0 < p->cy0) y0 = p->cy0;
  if (x1 > p->cx1) x1 = p->cx1;
  if (y1 > p->cy1) y1 = p->cy1;
  area = (b->x - a->x) * (c->y - a->y) - (b->y - a->y) * (c->x - a->x);
  if (fabsf(area) < 1e-8f) return;
  for (y = y0; y < y1; y++) {
    float py = y + 0.5f;
    px_t *row = p->dst + (long)y * p->dw;
    for (x = x0; x < x1; x++) {
      float px = x + 0.5f;
      float w0 = ((b->x - px) * (c->y - py) - (b->y - py) * (c->x - px)) / area;
      float w1 = ((c->x - px) * (a->y - py) - (c->y - py) * (a->x - px)) / area;
      float w2 = 1 - w0 - w1;
      px_t tx = 0xffffffffu;
      int save[4], k;
      if (w0 < 0 || w1 < 0 || w2 < 0) continue;
      if (t) {
        float u = (a->u * w0 + b->u * w1 + c->u * w2) * t->w;
        float v = (a->v * w0 + b->v * w1 + c->v * w2) * t->h;
        tx = t->px[(long)wrapi((int)floorf(v), t->h, t->wrap_repeat_y) * t->w + wrapi((int)floorf(u), t->w, t->wrap_repeat_x)];
      }
      for (k = 0; k < 4; k++) save[k] = p->c[k];
      p->c[0] = DIV255(save[0] * lp_f2b(a->r * w0 + b->r * w1 + c->r * w2));
      p->c[1] = DIV255(save[1] * lp_f2b(a->g * w0 + b->g * w1 + c->g * w2));
      p->c[2] = DIV255(save[2] * lp_f2b(a->b * w0 + b->b * w1 + c->b * w2));
      p->c[3] = DIV255(save[3] * lp_f2b(a->a * w0 + b->a * w1 + c->a * w2));
      p->white = 0;
      frag(p, &row[x], tx);
      for (k = 0; k < 4; k++) p->c[k] = save[k];
    }
  }
}

static void mesh_draw(Mesh *m, Mat mt) {
  Paint p;
  int count = m->map ? m->nmap : m->n, start = 0, i;
  MVert *tv;
  if (m->range_count > 0) {
    start = m->range_start - 1;
    if (start < 0) start = 0;
    if (start + m->range_count < count) count = start + m->range_count;
  }
  if (!g_target || count - start < 3) return;
  tv = (MVert *)malloc(sizeof(MVert) * (count - start));
  if (!tv) return;
  for (i = start; i < count; i++) {
    int idx = m->map ? m->map[i] : i;
    MVert v;
    if (idx < 0 || idx >= m->n) { memset(&v, 0, sizeof v); }
    else v = m->v[idx];
    tv[i - start] = v;
    tv[i - start].x = mt.a * v.x + mt.c * v.y + mt.e;
    tv[i - start].y = mt.b * v.x + mt.d * v.y + mt.f;
  }
  paint_setup(&p, NULL);
  count -= start;
  if (m->mode == 0) for (i = 1; i + 1 < count; i++) raster_tri(&p, m->tex, &tv[0], &tv[i], &tv[i + 1]);
  else if (m->mode == 1) for (i = 0; i + 2 < count; i++) raster_tri(&p, m->tex, &tv[i], &tv[i + 1], &tv[i + 2]);
  else if (m->mode == 2) for (i = 0; i + 2 < count; i += 3) raster_tri(&p, m->tex, &tv[i], &tv[i + 1], &tv[i + 2]);
  free(tv);
}

/* ------------------------------------------------------------ Shader object */

static const char *const shader_chain[] = {NULL};
static LPType Shader_type;

static int sh_send(lua_State *L) {
  Shader *s = (Shader *)lp_checkobj(L, 1, &Shader_type);
  const char *name = luaL_checkstring(L, 2);
  Uniform *u = shader_uniform(s, name, 1);
  int i, top = lua_gettop(L);
  if (!u) return 0;
  u->n = 0;
  for (i = 3; i <= top; i++) {
    if (lua_istable(L, i)) {
      int k, n = (int)lua_rawlen(L, i);
      for (k = 1; k <= n && u->n < 64 * 3; k++) {
        lua_rawgeti(L, i, k);
        if (lua_istable(L, -1)) {
          int j, m = (int)lua_rawlen(L, -1);
          for (j = 1; j <= m && u->n < 64 * 3; j++) { lua_rawgeti(L, -1, j); u->v[u->n++] = (float)lua_tonumber(L, -1); lua_pop(L, 1); }
        } else u->v[u->n++] = (float)lua_tonumber(L, -1);
        lua_pop(L, 1);
      }
    } else if (lua_isboolean(L, i)) {
      if (u->n < 64 * 3) u->v[u->n++] = lua_toboolean(L, i) ? 1.0f : 0.0f;
    } else if (lua_isnumber(L, i)) {
      if (u->n < 64 * 3) u->v[u->n++] = (float)lua_tonumber(L, i);
    }
  }
  s->dirty = 1;
  return 0;
}
static int sh_hasUniform(lua_State *L) {
  Shader *s = (Shader *)lp_checkobj(L, 1, &Shader_type);
  const char *n = luaL_checkstring(L, 2);
  int known = 0;
  switch (s->kind) {
  case K_PAL4: case K_PAL4_KEYED: known = n[0] == 'c' && n[1] >= '0' && n[1] <= '3' && !n[2]; break;
  case K_GBC: case K_GBC_KEYED: known = !strncmp(n, "pal", 3) && n[3] >= '0' && n[3] <= '3' && !n[4]; break;
  case K_REMAP: known = !strncmp(n, "remap", 5); break;
  }
  lua_pushboolean(L, known);
  return 1;
}
static int sh_getWarnings(lua_State *L) { lua_pushliteral(L, ""); return 1; }
static const luaL_Reg shader_methods[] = {
  {"send", sh_send}, {"sendColor", sh_send}, {"hasUniform", sh_hasUniform},
  {"getWarnings", sh_getWarnings}, {NULL, NULL}};
static LPType Shader_type = {"Shader", shader_chain, shader_methods, NULL};

static int g_newShader(lua_State *L) {
  const char *src = luaL_checkstring(L, 1);
  int kind;
  Shader *s;
  char *file = NULL;
  size_t len;
  if (!strstr(src, "effect") && !strstr(src, "position") && fs_exists(src)) {
    file = fs_read(src, &len);
    src = file;
  }
  kind = src ? shader_classify(src) : 0;
  free(file);
  if (!kind) return luaL_error(L, "Shaders are not supported on PSP (unrecognised shader)");
  s = (Shader *)lp_newobj(L, &Shader_type, sizeof(Shader));
  s->kind = kind;
  s->dirty = 1;
  return 1;
}
static int g_validateShader(lua_State *L) {
  int i = lua_isboolean(L, 1) ? 2 : 1;
  const char *src = luaL_checkstring(L, i);
  if (shader_classify(src)) { lua_pushboolean(L, 1); return 1; }
  lua_pushboolean(L, 0);
  lua_pushliteral(L, "Shaders are not supported on PSP");
  return 2;
}

/* ------------------------------------------------------------ state refs */

/* refs table: [1] shader [2] font [3] canvas; stack copies at 10+depth*3 */
static void set_ref(lua_State *L, int slot, int val) {
  lua_getfield(L, LUA_REGISTRYINDEX, REF_KEY);
  if (val) lua_pushvalue(L, val < 0 ? val - 1 : val); else lua_pushnil(L);
  lua_rawseti(L, -2, slot);
  lua_pop(L, 1);
}
static void copy_ref(lua_State *L, int from, int to) {
  lua_getfield(L, LUA_REGISTRYINDEX, REF_KEY);
  lua_rawgeti(L, -1, from);
  lua_rawseti(L, -2, to);
  lua_pop(L, 1);
}
static void get_ref(lua_State *L, int slot) {
  lua_getfield(L, LUA_REGISTRYINDEX, REF_KEY);
  lua_rawgeti(L, -1, slot);
  lua_remove(L, -2);
}

/* ------------------------------------------------------------ love.graphics */

static void read_color(lua_State *L, int i, float *c) {
  if (lua_istable(L, i)) {
    int k;
    for (k = 0; k < 4; k++) {
      lua_rawgeti(L, i, k + 1);
      c[k] = (float)luaL_optnumber(L, -1, k == 3 ? 1 : 0);
      lua_pop(L, 1);
    }
  } else {
    c[0] = (float)luaL_optnumber(L, i, 0); c[1] = (float)luaL_optnumber(L, i + 1, 0);
    c[2] = (float)luaL_optnumber(L, i + 2, 0); c[3] = (float)luaL_optnumber(L, i + 3, 1);
  }
}

static int g_setColor(lua_State *L) {
  read_color(L, 1, g_st.color);
  return 0;
}
static int g_getColor(lua_State *L) {
  int i;
  for (i = 0; i < 4; i++) lua_pushnumber(L, g_st.color[i]);
  return 4;
}
static int g_setBackgroundColor(lua_State *L) { read_color(L, 1, g_st.bg); return 0; }
static int g_getBackgroundColor(lua_State *L) {
  int i;
  for (i = 0; i < 4; i++) lua_pushnumber(L, g_st.bg[i]);
  return 4;
}

static int g_setBlendMode(lua_State *L) {
  g_st.blend = luaL_checkoption(L, 1, "alpha", blend_names);
  g_st.premul = !strcmp(luaL_optstring(L, 2, g_st.blend == B_MULTIPLY || g_st.blend == B_LIGHTEN || g_st.blend == B_DARKEN ? "premultiplied" : "alphamultiply"), "premultiplied");
  return 0;
}
static int g_getBlendMode(lua_State *L) {
  lua_pushstring(L, blend_names[g_st.blend]);
  lua_pushstring(L, g_st.premul ? "premultiplied" : "alphamultiply");
  return 2;
}

static int g_setScissor(lua_State *L) {
  if (lua_isnoneornil(L, 1)) { g_st.sc_on = 0; return 0; }
  g_st.sc_on = 1;
  g_st.sx = (int)luaL_checknumber(L, 1); g_st.sy = (int)luaL_checknumber(L, 2);
  g_st.sw = (int)luaL_checknumber(L, 3); g_st.sh = (int)luaL_checknumber(L, 4);
  if (g_st.sw < 0) g_st.sw = 0;
  if (g_st.sh < 0) g_st.sh = 0;
  return 0;
}
static int g_intersectScissor(lua_State *L) {
  int x = (int)luaL_checknumber(L, 1), y = (int)luaL_checknumber(L, 2);
  int w = (int)luaL_checknumber(L, 3), h = (int)luaL_checknumber(L, 4);
  if (g_st.sc_on) {
    int x2 = x + w < g_st.sx + g_st.sw ? x + w : g_st.sx + g_st.sw;
    int y2 = y + h < g_st.sy + g_st.sh ? y + h : g_st.sy + g_st.sh;
    if (x < g_st.sx) x = g_st.sx;
    if (y < g_st.sy) y = g_st.sy;
    w = x2 - x; h = y2 - y;
    if (w < 0) w = 0;
    if (h < 0) h = 0;
  }
  g_st.sc_on = 1; g_st.sx = x; g_st.sy = y; g_st.sw = w; g_st.sh = h;
  return 0;
}
static int g_getScissor(lua_State *L) {
  if (!g_st.sc_on) return 0;
  lua_pushinteger(L, g_st.sx); lua_pushinteger(L, g_st.sy);
  lua_pushinteger(L, g_st.sw); lua_pushinteger(L, g_st.sh);
  return 4;
}

static int g_setCanvas(lua_State *L) {
  Tex *t = NULL;
  int idx = 1;
  if (lua_istable(L, 1)) {
    lua_rawgeti(L, 1, 1);
    if (lua_istable(L, -1)) { lua_rawgeti(L, -1, 1); lua_remove(L, -2); }
    idx = lua_gettop(L);
  }
  if (!lua_isnoneornil(L, idx)) t = checktex(L, idx);
  if (t) { g_target = t; set_ref(L, 3, idx); }
  else { g_target = g_back; set_ref(L, 3, 0); }
  return 0;
}
static int g_getCanvas(lua_State *L) {
  if (g_target == g_back) return 0;
  get_ref(L, 3);
  return 1;
}

static int canvas_renderTo(lua_State *L) {
  Tex *prev = g_target;
  int status;
  checktex(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  get_ref(L, 3);
  lua_insert(L, 1); /* keep the previous canvas ref at index 1 */
  g_target = checktex(L, 2);
  set_ref(L, 3, 2);
  lua_pushvalue(L, 3);
  status = lua_pcall(L, 0, 0, 0);
  g_target = prev;
  set_ref(L, 3, lua_isnil(L, 1) ? 0 : 1);
  if (status != LUA_OK) return lua_error(L);
  return 0;
}

static int g_clear(lua_State *L) {
  float c[4] = {0, 0, 0, 0};
  int x0 = 0, y0 = 0, x1, y1, x, y;
  px_t v;
  if (!g_target) return 0;
  if (lua_gettop(L) >= 1 && (lua_isnumber(L, 1) || lua_istable(L, 1))) read_color(L, 1, c);
  v = PX(lp_f2b(c[0]), lp_f2b(c[1]), lp_f2b(c[2]), lp_f2b(c[3]));
  x1 = g_target->w; y1 = g_target->h;
  if (g_st.sc_on) {
    if (g_st.sx > x0) x0 = g_st.sx;
    if (g_st.sy > y0) y0 = g_st.sy;
    if (g_st.sx + g_st.sw < x1) x1 = g_st.sx + g_st.sw;
    if (g_st.sy + g_st.sh < y1) y1 = g_st.sy + g_st.sh;
  }
  for (y = y0; y < y1; y++) {
    px_t *row = g_target->px + (long)y * g_target->w;
    for (x = x0; x < x1; x++) row[x] = v;
  }
  return 0;
}

static int g_push(lua_State *L) {
  const char *mode = luaL_optstring(L, 1, "transform");
  if (g_depth >= STACK_MAX) return luaL_error(L, "Maximum stack depth reached (more pushes than pops?)");
  g_stack[g_depth] = g_st;
  g_stack_all[g_depth] = !strcmp(mode, "all");
  copy_ref(L, 1, 10 + g_depth * 3);
  copy_ref(L, 2, 11 + g_depth * 3);
  g_depth++;
  return 0;
}
static int g_pop(lua_State *L) {
  if (g_depth <= 0) return luaL_error(L, "Minimum stack depth reached (more pops than pushes?)");
  g_depth--;
  if (g_stack_all[g_depth]) {
    g_st = g_stack[g_depth];
    copy_ref(L, 10 + g_depth * 3, 1);
    copy_ref(L, 11 + g_depth * 3, 2);
  } else {
    g_st.tf = g_stack[g_depth].tf;
  }
  return 0;
}
static int g_origin(lua_State *L) { (void)L; g_st.tf = mat_identity(); return 0; }
static int g_translate(lua_State *L) {
  Mat t = {1, 0, 0, 1, (float)luaL_checknumber(L, 1), (float)luaL_checknumber(L, 2)};
  g_st.tf = mat_mul(g_st.tf, t);
  return 0;
}
static int g_scale(lua_State *L) {
  float sx = (float)luaL_checknumber(L, 1);
  Mat t = {sx, 0, 0, (float)luaL_optnumber(L, 2, sx), 0, 0};
  g_st.tf = mat_mul(g_st.tf, t);
  return 0;
}
static int g_rotate(lua_State *L) {
  float a = (float)luaL_checknumber(L, 1);
  Mat t = {cosf(a), sinf(a), -sinf(a), cosf(a), 0, 0};
  g_st.tf = mat_mul(g_st.tf, t);
  return 0;
}
static int g_shear(lua_State *L) {
  Mat t = {1, (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 1), 1, 0, 0};
  g_st.tf = mat_mul(g_st.tf, t);
  return 0;
}
static int g_applyTransform(lua_State *L) { g_st.tf = mat_mul(g_st.tf, *checktf(L, 1)); return 0; }
static int g_replaceTransform(lua_State *L) { g_st.tf = *checktf(L, 1); return 0; }
static int g_transformPoint(lua_State *L) {
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  Mat m = g_st.tf;
  lua_pushnumber(L, m.a * x + m.c * y + m.e); lua_pushnumber(L, m.b * x + m.d * y + m.f);
  return 2;
}
static int g_inverseTransformPoint(lua_State *L) {
  float x = (float)luaL_checknumber(L, 1), y = (float)luaL_checknumber(L, 2);
  Mat m;
  if (!mat_invert(g_st.tf, &m)) m = mat_identity();
  lua_pushnumber(L, m.a * x + m.c * y + m.e); lua_pushnumber(L, m.b * x + m.d * y + m.f);
  return 2;
}

static int g_setShader(lua_State *L) {
  if (lua_isnoneornil(L, 1)) { g_st.shader = NULL; set_ref(L, 1, 0); return 0; }
  g_st.shader = (Shader *)lp_checkobj(L, 1, &Shader_type);
  set_ref(L, 1, 1);
  return 0;
}
static int g_getShader(lua_State *L) {
  if (!g_st.shader) return 0;
  get_ref(L, 1);
  return 1;
}

static int g_setFont(lua_State *L) {
  g_st.font = font_check(L, 1);
  set_ref(L, 2, 1);
  return 0;
}
static Font *current_font(lua_State *L) {
  if (!g_st.font) {
    font_push_default(L, 12);
    g_st.font = font_check(L, -1);
    set_ref(L, 2, -1);
    lua_pop(L, 1);
  }
  return g_st.font;
}
static int g_getFont(lua_State *L) {
  current_font(L);
  get_ref(L, 2);
  return 1;
}
static int g_setNewFont(lua_State *L) {
  lp_font_newFont(L);
  g_st.font = font_check(L, -1);
  set_ref(L, 2, -1);
  return 1;
}

static int g_setLineWidth(lua_State *L) { g_st.line_width = (float)luaL_checknumber(L, 1); return 0; }
static int g_getLineWidth(lua_State *L) { lua_pushnumber(L, g_st.line_width); return 1; }
static int g_setPointSize(lua_State *L) { g_st.point_size = (float)luaL_checknumber(L, 1); return 0; }
static int g_getPointSize(lua_State *L) { lua_pushnumber(L, g_st.point_size); return 1; }
static int g_setLineJoin(lua_State *L) { (void)L; return 0; }
static int g_getLineJoin(lua_State *L) { lua_pushliteral(L, "miter"); return 1; }
static int g_setLineStyle(lua_State *L) { (void)L; return 0; }
static int g_getLineStyle(lua_State *L) { lua_pushliteral(L, "rough"); return 1; }

static int g_setDefaultFilter(lua_State *L) {
  g_default_linear = !strcmp(luaL_optstring(L, 1, "linear"), "linear");
  return 0;
}
static int g_getDefaultFilter(lua_State *L) {
  lua_pushstring(L, g_default_linear ? "linear" : "nearest");
  lua_pushstring(L, g_default_linear ? "linear" : "nearest");
  lua_pushnumber(L, 1);
  return 3;
}

/* points from varargs or a table (optionally a table of {x,y} pairs) */
static float *read_points(lua_State *L, int start, int *n) {
  int count, i;
  float *pts;
  if (lua_istable(L, start)) {
    int len = (int)lua_rawlen(L, start);
    count = len / 2;
    pts = (float *)malloc(sizeof(float) * (count * 2 + 2));
    for (i = 0; i < count * 2; i++) { lua_rawgeti(L, start, i + 1); pts[i] = (float)lua_tonumber(L, -1); lua_pop(L, 1); }
  } else {
    int top = lua_gettop(L);
    count = (top - start + 1) / 2;
    pts = (float *)malloc(sizeof(float) * (count * 2 + 2));
    for (i = 0; i < count * 2; i++) pts[i] = (float)luaL_checknumber(L, start + i);
  }
  *n = count;
  return pts;
}

static int is_fill(lua_State *L, int i) {
  const char *m = luaL_checkstring(L, i);
  return strcmp(m, "line") != 0;
}

static int g_rectangle(lua_State *L) {
  int fill = is_fill(L, 1);
  float x = (float)luaL_checknumber(L, 2), y = (float)luaL_checknumber(L, 3);
  float w = (float)luaL_checknumber(L, 4), h = (float)luaL_checknumber(L, 5);
  if (lua_isnumber(L, 6) && lua_tonumber(L, 6) > 0) {
    /* rounded rectangle */
    float rx = (float)lua_tonumber(L, 6), ry = (float)luaL_optnumber(L, 7, rx);
    int segs = (int)luaL_optinteger(L, 8, 4), k = 0, i;
    float *pts;
    if (rx > w / 2) rx = w / 2;
    if (ry > h / 2) ry = h / 2;
    pts = (float *)malloc(sizeof(float) * 2 * 4 * (segs + 1));
    for (i = 0; i <= segs; i++) { float a = (float)M_PI + (float)M_PI / 2 * i / segs; pts[k++] = x + rx + cosf(a) * rx; pts[k++] = y + ry + sinf(a) * ry; }
    for (i = 0; i <= segs; i++) { float a = -(float)M_PI / 2 + (float)M_PI / 2 * i / segs; pts[k++] = x + w - rx + cosf(a) * rx; pts[k++] = y + ry + sinf(a) * ry; }
    for (i = 0; i <= segs; i++) { float a = (float)M_PI / 2 * i / segs; pts[k++] = x + w - rx + cosf(a) * rx; pts[k++] = y + h - ry + sinf(a) * ry; }
    for (i = 0; i <= segs; i++) { float a = (float)M_PI / 2 + (float)M_PI / 2 * i / segs; pts[k++] = x + rx + cosf(a) * rx; pts[k++] = y + h - ry + sinf(a) * ry; }
    if (fill) fill_local(pts, k / 2, NULL); else stroke_local(pts, k / 2, 1);
    free(pts);
    return 0;
  }
  if (fill) fill_rect_local(x, y, w, h);
  else {
    float pts[8] = {x, y, x + w, y, x + w, y + h, x, y + h};
    stroke_local(pts, 4, 1);
  }
  return 0;
}

static void ellipse_common(int fill, float cx, float cy, float rx, float ry, int segs) {
  float *pts;
  int n;
  if (segs <= 0) segs = auto_segments(rx, ry);
  pts = (float *)malloc(sizeof(float) * 2 * (segs + 2));
  n = ellipse_points(rx, ry, segs, pts, cx, cy, 0, 2 * (float)M_PI, 0) - 1;
  if (fill) fill_local(pts, n, NULL); else stroke_local(pts, n, 1);
  free(pts);
}
static int g_circle(lua_State *L) {
  float r = (float)luaL_checknumber(L, 4);
  ellipse_common(is_fill(L, 1), (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3), r, r,
                 (int)luaL_optinteger(L, 5, 0));
  return 0;
}
static int g_ellipse(lua_State *L) {
  ellipse_common(is_fill(L, 1), (float)luaL_checknumber(L, 2), (float)luaL_checknumber(L, 3),
                 (float)luaL_checknumber(L, 4), (float)luaL_checknumber(L, 5), (int)luaL_optinteger(L, 6, 0));
  return 0;
}
static int g_arc(lua_State *L) {
  int fill = is_fill(L, 1), ai = 2, type = 0; /* 0 pie, 1 open, 2 closed */
  float cx, cy, r, a1, a2, *pts;
  int segs, n;
  if (lua_type(L, 2) == LUA_TSTRING) {
    const char *t = lua_tostring(L, 2);
    type = !strcmp(t, "open") ? 1 : !strcmp(t, "closed") ? 2 : 0;
    ai = 3;
  }
  cx = (float)luaL_checknumber(L, ai); cy = (float)luaL_checknumber(L, ai + 1);
  r = (float)luaL_checknumber(L, ai + 2);
  a1 = (float)luaL_checknumber(L, ai + 3); a2 = (float)luaL_checknumber(L, ai + 4);
  segs = (int)luaL_optinteger(L, ai + 5, 0);
  if (segs <= 0) segs = auto_segments(r, r);
  pts = (float *)malloc(sizeof(float) * 2 * (segs + 3));
  n = ellipse_points(r, r, segs, pts, cx, cy, a1, a2, type == 0);
  if (fill) fill_local(pts, n, NULL);
  else stroke_local(pts, n, type != 1);
  free(pts);
  return 0;
}
static int g_polygon(lua_State *L) {
  int fill = is_fill(L, 1), n;
  float *pts = read_points(L, 2, &n);
  if (fill) fill_local(pts, n, NULL); else stroke_local(pts, n, 1);
  free(pts);
  return 0;
}
static int g_line(lua_State *L) {
  int n;
  float *pts = read_points(L, 1, &n);
  stroke_local(pts, n, 0);
  free(pts);
  return 0;
}
static int g_points(lua_State *L) {
  int n, i;
  float *pts;
  float s = g_st.point_size > 0 ? g_st.point_size : 1;
  if (lua_istable(L, 1)) {
    /* either flat {x,y,...} or {{x,y,r,g,b,a}, ...} */
    lua_rawgeti(L, 1, 1);
    if (lua_istable(L, -1)) {
      int len = (int)lua_rawlen(L, 1);
      float save[4];
      lua_pop(L, 1);
      memcpy(save, g_st.color, sizeof save);
      for (i = 1; i <= len; i++) {
        float x, y;
        lua_rawgeti(L, 1, i);
        lua_rawgeti(L, -1, 1); x = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_rawgeti(L, -1, 2); y = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_rawgeti(L, -1, 3);
        if (!lua_isnil(L, -1)) {
          int k;
          for (k = 0; k < 4; k++) { lua_rawgeti(L, -2, 3 + k); g_st.color[k] = save[k] * (float)luaL_optnumber(L, -1, 1); lua_pop(L, 1); }
        }
        lua_pop(L, 2);
        fill_rect_local(x - s / 2, y - s / 2, s, s);
        memcpy(g_st.color, save, sizeof save);
      }
      return 0;
    }
    lua_pop(L, 1);
  }
  pts = read_points(L, 1, &n);
  for (i = 0; i < n; i++) fill_rect_local(pts[i * 2] - s / 2, pts[i * 2 + 1] - s / 2, s, s);
  free(pts);
  return 0;
}

/* Text object (love.graphics.newText) keeps its content in a Lua table */
typedef struct TextObj { int dummy; } TextObj;
static LPType Text_type;
static int print_impl(lua_State *L, Font *f, int textidx, Mat m, int wrap, float limit, int align);

static int text_set(lua_State *L) {
  lp_checkobj(L, 1, &Text_type);
  lua_getiuservalue(L, 1, 2);
  lua_newtable(L);
  lua_setiuservalue(L, 1, 2);
  lua_pop(L, 1);
  if (!lua_isnoneornil(L, 2)) {
    lua_getiuservalue(L, 1, 2);
    lua_newtable(L);
    lua_pushvalue(L, 2); lua_setfield(L, -2, "text");
    if (lua_gettop(L) >= 4 && lua_isnumber(L, 3)) {
      lua_pushvalue(L, 3); lua_setfield(L, -2, "limit");
      lua_pushvalue(L, 4); lua_setfield(L, -2, "align");
    }
    lua_rawseti(L, -2, 1);
  }
  return 0;
}
static int text_add(lua_State *L) {
  int n, k;
  lp_checkobj(L, 1, &Text_type);
  lua_getiuservalue(L, 1, 2);
  n = (int)lua_rawlen(L, -1);
  lua_newtable(L);
  lua_pushvalue(L, 2); lua_setfield(L, -2, "text");
  for (k = 3; k <= 12 && k <= lua_gettop(L) - 2; k++) { lua_pushvalue(L, k); lua_rawseti(L, -2, k - 2); }
  lua_rawseti(L, -2, n + 1);
  lua_pushinteger(L, n + 1);
  return 1;
}
static int text_addf(lua_State *L) {
  int n;
  lp_checkobj(L, 1, &Text_type);
  lua_getiuservalue(L, 1, 2);
  n = (int)lua_rawlen(L, -1);
  lua_newtable(L);
  lua_pushvalue(L, 2); lua_setfield(L, -2, "text");
  lua_pushvalue(L, 3); lua_setfield(L, -2, "limit");
  lua_pushvalue(L, 4); lua_setfield(L, -2, "align");
  lua_pushvalue(L, 5); lua_rawseti(L, -2, 1);
  lua_pushvalue(L, 6); lua_rawseti(L, -2, 2);
  lua_rawseti(L, -2, n + 1);
  lua_pushinteger(L, n + 1);
  return 1;
}
static int text_clear(lua_State *L) { lp_checkobj(L, 1, &Text_type); lua_newtable(L); lua_setiuservalue(L, 1, 2); return 0; }
static int text_getFont(lua_State *L) { lp_checkobj(L, 1, &Text_type); lua_getiuservalue(L, 1, 1); return 1; }
static int text_setFont(lua_State *L) { lp_checkobj(L, 1, &Text_type); font_check(L, 2); lua_pushvalue(L, 2); lua_setiuservalue(L, 1, 1); return 0; }

typedef struct Measure { float w; int lines; } Measure;
static void measure_cb(void *ud, const char *s, size_t len, float width, int last) {
  Measure *m = (Measure *)ud;
  (void)s; (void)len; (void)last;
  if (width > m->w) m->w = width;
  m->lines++;
}
static void text_measure(lua_State *L, float *w, float *h) {
  Font *f;
  int n, i;
  Measure m = {0, 0};
  lua_getiuservalue(L, 1, 1);
  f = font_check(L, -1);
  lua_getiuservalue(L, 1, 2);
  n = (int)lua_rawlen(L, -1);
  for (i = 1; i <= n; i++) {
    const char *s;
    size_t len;
    float limit;
    lua_rawgeti(L, -1, i);
    lua_getfield(L, -1, "text");
    s = lua_tolstring(L, -1, &len);
    lua_getfield(L, -2, "limit");
    limit = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : 1e9f;
    if (s) font_wrap(f, s, len, limit, measure_cb, &m);
    lua_pop(L, 3);
  }
  lua_pop(L, 2);
  *w = m.w;
  *h = m.lines * font_line_advance(f);
}
static int text_getWidth(lua_State *L) { float w, h; lp_checkobj(L, 1, &Text_type); text_measure(L, &w, &h); lua_pushnumber(L, w); return 1; }
static int text_getHeight(lua_State *L) { float w, h; lp_checkobj(L, 1, &Text_type); text_measure(L, &w, &h); lua_pushnumber(L, h); return 1; }
static int text_getDimensions(lua_State *L) { float w, h; lp_checkobj(L, 1, &Text_type); text_measure(L, &w, &h); lua_pushnumber(L, w); lua_pushnumber(L, h); return 2; }
static const luaL_Reg text_methods[] = {
  {"set", text_set}, {"setf", text_set}, {"add", text_add}, {"addf", text_addf}, {"clear", text_clear},
  {"getFont", text_getFont}, {"setFont", text_setFont}, {"getWidth", text_getWidth},
  {"getHeight", text_getHeight}, {"getDimensions", text_getDimensions}, {NULL, NULL}};
static const char *const text_chain[] = {"Drawable", NULL};
static LPType Text_type = {"Text", text_chain, text_methods, NULL};

static int g_newText(lua_State *L) {
  font_check(L, 1);
  lp_newobj(L, &Text_type, sizeof(TextObj));
  lua_pushvalue(L, 1); lua_setiuservalue(L, -2, 1);
  lua_newtable(L); lua_setiuservalue(L, -2, 2);
  if (!lua_isnoneornil(L, 2)) {
    int obj = lua_gettop(L);
    lua_pushcfunction(L, text_set);
    lua_pushvalue(L, obj);
    lua_pushvalue(L, 2);
    lua_call(L, 2, 0);
  }
  return 1;
}

static void text_draw(lua_State *L, int obj, Mat m) {
  Font *f;
  int n, i;
  lua_getiuservalue(L, obj, 1);
  f = font_check(L, -1);
  lua_getiuservalue(L, obj, 2);
  n = (int)lua_rawlen(L, -1);
  for (i = 1; i <= n; i++) {
    int e, wrap;
    float limit = 0;
    const char *al;
    int align = 0;
    Mat mm = m;
    lua_rawgeti(L, -1, i);
    e = lua_gettop(L);
    lua_getfield(L, e, "limit");
    wrap = lua_isnumber(L, -1);
    if (wrap) limit = (float)lua_tonumber(L, -1);
    lua_getfield(L, e, "align");
    al = lua_tostring(L, -1);
    if (al) align = !strcmp(al, "center") ? 1 : !strcmp(al, "right") ? 2 : !strcmp(al, "justify") ? 3 : 0;
    lua_rawgeti(L, e, 1);
    if (lua_isnumber(L, -1)) {
      lua_rawgeti(L, e, 2);
      mm = mat_mul(m, mat_transformation((float)lua_tonumber(L, -2), (float)lua_tonumber(L, -1), 0, 1, 1, 0, 0, 0, 0));
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    lua_getfield(L, e, "text");
    print_impl(L, f, lua_gettop(L), mm, wrap, limit, align);
    lua_settop(L, e - 1);
  }
  lua_pop(L, 2);
}

static int g_draw(lua_State *L) {
  Tex *t = totex(L, 1);
  if (t) {
    Quad *q = (Quad *)lp_testobj(L, 2, &Quad_type);
    if (q) {
      Mat m = draw_matrix(L, 3);
      gfx_draw_texture(t, q->x, q->y, q->w, q->h, q->sw, q->sh, m, NULL);
    } else {
      Mat m = draw_matrix(L, 2);
      gfx_draw_texture(t, 0, 0, (float)t->w, (float)t->h, (float)t->w, (float)t->h, m, NULL);
    }
    return 0;
  }
  {
    SpriteBatch *b = (SpriteBatch *)lp_testobj(L, 1, &SpriteBatch_type);
    if (b) { sb_draw(b, draw_matrix(L, 2)); return 0; }
  }
  {
    Mesh *m = (Mesh *)lp_testobj(L, 1, &Mesh_type);
    if (m) { mesh_draw(m, draw_matrix(L, 2)); return 0; }
  }
  if (lp_testobj(L, 1, &Text_type)) { text_draw(L, 1, draw_matrix(L, 2)); return 0; }
  return luaL_argerror(L, 1, "Drawable expected");
}

static int g_drawLayer(lua_State *L) {
  lua_remove(L, 2); /* ignore the layer index: array textures are not supported */
  return g_draw(L);
}

/* ---- text printing ---- */

typedef struct PrintCtx {
  Font *f;
  Mat m;
  float y, limit;
  int align;
  const float *color;
} PrintCtx;

static void print_line_cb(void *ud, const char *s, size_t len, float width, int last) {
  PrintCtx *c = (PrintCtx *)ud;
  float x = 0;
  (void)last;
  if (c->align == 1) x = floorf((c->limit - width) / 2);
  else if (c->align == 2) x = c->limit - width;
  font_draw_line(c->f, s, len, c->m, x, c->y, c->color);
  c->y += font_line_advance(c->f);
}

/* textidx: string or coloured-text table */
static int print_impl(lua_State *L, Font *f, int textidx, Mat m, int wrap, float limit, int align) {
  PrintCtx c;
  c.f = f; c.m = m; c.y = 0; c.limit = limit; c.align = align; c.color = NULL;
  if (lua_istable(L, textidx)) {
    /* coloured text: draw segments sequentially on one logical line */
    int n = (int)lua_rawlen(L, textidx), i;
    float pen = 0, col[4];
    luaL_Buffer b;
    if (wrap) {
      /* wrapping coloured text: concatenate and use the first colour */
      luaL_buffinit(L, &b);
      for (i = 1; i <= n; i++) {
        lua_rawgeti(L, textidx, i);
        if (lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER) luaL_addvalue(&b); else lua_pop(L, 1);
      }
      luaL_pushresult(&b);
      {
        size_t len;
        const char *s = lua_tolstring(L, -1, &len);
        font_wrap(f, s, len, limit, print_line_cb, &c);
      }
      lua_pop(L, 1);
      return 0;
    }
    memcpy(col, g_st.color, sizeof col);
    for (i = 1; i <= n; i++) {
      lua_rawgeti(L, textidx, i);
      if (lua_istable(L, -1)) {
        int k;
        for (k = 0; k < 4; k++) { lua_rawgeti(L, -1, k + 1); col[k] = g_st.color[k] * (float)luaL_optnumber(L, -1, 1); lua_pop(L, 1); }
      } else if (lua_isstring(L, -1)) {
        size_t len;
        const char *s = lua_tolstring(L, -1, &len);
        const char *nl;
        while ((nl = memchr(s, '\n', len)) != NULL) {
          font_draw_line(f, s, (size_t)(nl - s), m, pen, c.y, col);
          c.y += font_line_advance(f);
          pen = 0;
          len -= (size_t)(nl - s) + 1;
          s = nl + 1;
        }
        font_draw_line(f, s, len, m, pen, c.y, col);
        pen += font_text_width(f, s, len);
      }
      lua_pop(L, 1);
    }
    return 0;
  }
  {
    size_t len;
    const char *s;
    lua_pushvalue(L, textidx);
    s = luaL_tolstring(L, -1, &len);
    font_wrap(f, s, len, wrap ? limit : 1e9f, print_line_cb, &c);
    lua_pop(L, 2);
  }
  return 0;
}

static int g_print(lua_State *L) {
  Font *f = current_font(L);
  int ai = 2;
  Mat m;
  if (lp_testobj(L, 2, &lp_Font_type)) { f = font_check(L, 2); ai = 3; }
  m = draw_matrix(L, ai);
  return print_impl(L, f, 1, m, 0, 0, 0);
}
static int g_printf(lua_State *L) {
  Font *f = current_font(L);
  int ai = 2, align = 0;
  float limit;
  Mat m;
  const char *al;
  if (lp_testobj(L, 2, &lp_Font_type)) { f = font_check(L, 2); ai = 3; }
  if (lp_testobj(L, ai, &Transform_type)) {
    TransformObj *t = (TransformObj *)lua_touserdata(L, ai);
    m = mat_mul(g_st.tf, t->m);
    limit = (float)luaL_checknumber(L, ai + 1);
    al = luaL_optstring(L, ai + 2, "left");
  } else {
    float x = (float)luaL_optnumber(L, ai, 0), y = (float)luaL_optnumber(L, ai + 1, 0);
    float sx;
    limit = (float)luaL_checknumber(L, ai + 2);
    al = luaL_optstring(L, ai + 3, "left");
    sx = (float)luaL_optnumber(L, ai + 5, 1);
    m = mat_mul(g_st.tf, mat_transformation(x, y, (float)luaL_optnumber(L, ai + 4, 0), sx,
                                            (float)luaL_optnumber(L, ai + 6, sx),
                                            (float)luaL_optnumber(L, ai + 7, 0), (float)luaL_optnumber(L, ai + 8, 0),
                                            (float)luaL_optnumber(L, ai + 9, 0), (float)luaL_optnumber(L, ai + 10, 0)));
  }
  align = !strcmp(al, "center") ? 1 : !strcmp(al, "right") ? 2 : !strcmp(al, "justify") ? 3 : 0;
  return print_impl(L, f, 1, m, 1, limit, align);
}

/* ---- window glue ---- */

static int g_getDimensions(lua_State *L) { lua_pushinteger(L, g_back->w); lua_pushinteger(L, g_back->h); return 2; }
static int g_getWidth(lua_State *L) { lua_pushinteger(L, g_back->w); return 1; }
static int g_getHeight(lua_State *L) { lua_pushinteger(L, g_back->h); return 1; }
static int g_getDPIScale(lua_State *L) { lua_pushnumber(L, 1); return 1; }
static int g_isActive(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static int g_isCreated(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static int g_noop(lua_State *L) { (void)L; return 0; }
static int g_false(lua_State *L) { lua_pushboolean(L, 0); return 1; }

static int g_capture_pending;

void gfx_present(void) {
  lua_State *L = g_L;
  if (g_capture_pending && L) {
    int n, i;
    lua_getfield(L, LUA_REGISTRYINDEX, "lovepsp.capture");
    n = (int)lua_rawlen(L, -1);
    for (i = 1; i <= n; i++) {
      ImageData *d;
      lua_rawgeti(L, -1, i);
      d = imagedata_push(L, g_back->w, g_back->h);
      memcpy(d->px, g_back->px, (size_t)g_back->w * g_back->h * 4);
      if (lua_type(L, -2) == LUA_TSTRING) {
        lua_getfield(L, -1, "encode");
        lua_insert(L, -2);
        lua_pushliteral(L, "png");
        lua_pushvalue(L, -4);
        if (lua_pcall(L, 3, 0, 0) != LUA_OK) lua_pop(L, 1);
        lua_pop(L, 1);
      } else if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
        plat_debug("captureScreenshot callback: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
      }
    }
    lua_pop(L, 1);
    lua_newtable(L);
    lua_setfield(L, LUA_REGISTRYINDEX, "lovepsp.capture");
    g_capture_pending = 0;
  }
  plat_set_overlay(g_overlay ? g_overlay->px : NULL, g_overlay ? g_overlay->w : 0, g_overlay ? g_overlay->h : 0);
  plat_present(g_back->px, g_back->w, g_back->h, g_present_mode, g_present_smooth);
}

/* love.graphics._setOverlay(canvas|nil): a screen-sized canvas drawn over the
 * presented frame at 1:1 (the shell's Vita sidebars) */
static int g_setOverlay(lua_State *L) {
  Tex *t = NULL;
  if (!lua_isnoneornil(L, 1)) {
    TexObj *o = (TexObj *)lp_checkobj(L, 1, &Canvas_type);
    t = o->t;
  }
  if (t) t->refs++;
  if (g_overlay) tex_release(g_overlay);
  g_overlay = t;
  return 0;
}
/* love.graphics._setBars(left, right): side bars for the touch layout */
static int g_setBars(lua_State *L) {
  plat_set_bars((int)luaL_optinteger(L, 1, -1), (int)luaL_optinteger(L, 2, -1));
  return 0;
}

/* between Lua states (restart): drop everything that pointed into the old one */
void lp_gfx_reset(void) {
  if (g_overlay) { tex_release(g_overlay); g_overlay = NULL; }
  plat_set_overlay(NULL, 0, 0);
  plat_set_bars(-1, -1);
  if (g_target && g_target != g_back) g_target = g_back;
  g_depth = 0;
  g_L = NULL;
}

static int g_present(lua_State *L) { (void)L; gfx_present(); return 0; }

static int g_captureScreenshot(lua_State *L) {
  size_t n;
  lua_getfield(L, LUA_REGISTRYINDEX, "lovepsp.capture");
  n = lua_rawlen(L, -1);
  lua_pushvalue(L, 1);
  lua_rawseti(L, -2, (lua_Integer)n + 1);
  g_capture_pending = 1;
  return 0;
}

static int g_getSupported(lua_State *L) {
  lua_newtable(L);
  lua_pushboolean(L, 0); lua_setfield(L, -2, "glsl3");
  lua_pushboolean(L, 0); lua_setfield(L, -2, "shaderderivatives");
  lua_pushboolean(L, 1); lua_setfield(L, -2, "clampzero");
  lua_pushboolean(L, 0); lua_setfield(L, -2, "multicanvasformats");
  lua_pushboolean(L, 0); lua_setfield(L, -2, "instancing");
  lua_pushboolean(L, 1); lua_setfield(L, -2, "fullnpot");
  lua_pushboolean(L, 0); lua_setfield(L, -2, "pixelshaderhighp");
  lua_pushboolean(L, 0); lua_setfield(L, -2, "lighten");
  return 1;
}
static int g_getRendererInfo(lua_State *L) {
  lua_pushliteral(L, "lovepsp-software");
  lua_pushliteral(L, LP_VERSION);
  lua_pushliteral(L, "lovepsp");
  lua_pushliteral(L, "Allegrex CPU rasterizer");
  return 4;
}
static int g_getSystemLimits(lua_State *L) {
  lua_newtable(L);
  lua_pushinteger(L, 2048); lua_setfield(L, -2, "texturesize");
  lua_pushinteger(L, 1); lua_setfield(L, -2, "multicanvas");
  lua_pushinteger(L, 1); lua_setfield(L, -2, "canvasmsaa");
  lua_pushinteger(L, 1); lua_setfield(L, -2, "texturelayers");
  lua_pushinteger(L, 1); lua_setfield(L, -2, "volumetexturesize");
  lua_pushinteger(L, 1); lua_setfield(L, -2, "cubetexturesize");
  lua_pushinteger(L, 1); lua_setfield(L, -2, "anisotropy");
  lua_pushnumber(L, 64); lua_setfield(L, -2, "pointsize");
  return 1;
}
static int g_getFormats(lua_State *L) {
  lua_newtable(L);
  lua_pushboolean(L, 1); lua_setfield(L, -2, "rgba8");
  lua_pushboolean(L, 1); lua_setfield(L, -2, "normal");
  return 1;
}
static int g_getTextureTypes(lua_State *L) {
  lua_newtable(L);
  lua_pushboolean(L, 1); lua_setfield(L, -2, "2d");
  return 1;
}
static int g_getStats(lua_State *L) {
  lua_newtable(L);
  lua_pushinteger(L, g_draw_calls); lua_setfield(L, -2, "drawcalls");
  lua_pushinteger(L, 0); lua_setfield(L, -2, "canvasswitches");
  lua_pushinteger(L, 0); lua_setfield(L, -2, "texturememory");
  lua_pushinteger(L, 0); lua_setfield(L, -2, "images");
  lua_pushinteger(L, 0); lua_setfield(L, -2, "canvases");
  lua_pushinteger(L, 0); lua_setfield(L, -2, "fonts");
  lua_pushinteger(L, 0); lua_setfield(L, -2, "shaderswitches");
  lua_pushinteger(L, 0); lua_setfield(L, -2, "drawcallsbatched");
  return 1;
}
static int g_reset(lua_State *L) {
  g_st.color[0] = g_st.color[1] = g_st.color[2] = g_st.color[3] = 1;
  g_st.blend = B_ALPHA; g_st.premul = 0;
  g_st.tf = mat_identity();
  g_st.sc_on = 0;
  g_st.shader = NULL;
  g_st.line_width = 1; g_st.point_size = 1;
  g_target = g_back;
  set_ref(L, 1, 0); set_ref(L, 3, 0);
  return 0;
}
static int g_resetFrameStats(lua_State *L) { (void)L; g_draw_calls = 0; return 0; }
static int g_setPresentScaling(lua_State *L) {
  static const char *const modes[] = {"none", "fit", "stretch", "integer", NULL};
  g_present_mode = luaL_checkoption(L, 1, "fit", modes);
  g_present_smooth = lua_isnoneornil(L, 2) ? g_present_smooth : lua_toboolean(L, 2);
  return 0;
}
static int g_getPresentScaling(lua_State *L) {
  static const char *const modes[] = {"none", "fit", "stretch", "integer"};
  lua_pushstring(L, modes[g_present_mode]);
  lua_pushboolean(L, g_present_smooth);
  return 2;
}
static int g_stencil(lua_State *L) {
  /* no stencil buffer: run the function so side effects happen, draw nothing */
  (void)L;
  return 0;
}
static int g_getStackDepth(lua_State *L) { lua_pushinteger(L, g_depth); return 1; }

static const luaL_Reg g_funcs[] = {
  {"newImage", g_newImage}, {"newCanvas", g_newCanvas}, {"newQuad", g_newQuad},
  {"newSpriteBatch", g_newSpriteBatch}, {"newMesh", g_newMesh}, {"newShader", g_newShader},
  {"validateShader", g_validateShader}, {"newText", g_newText},
  {"newFont", lp_font_newFont}, {"newImageFont", lp_font_newImageFont}, {"setNewFont", g_setNewFont},
  {"setColor", g_setColor}, {"getColor", g_getColor},
  {"setBackgroundColor", g_setBackgroundColor}, {"getBackgroundColor", g_getBackgroundColor},
  {"setBlendMode", g_setBlendMode}, {"getBlendMode", g_getBlendMode},
  {"setScissor", g_setScissor}, {"intersectScissor", g_intersectScissor}, {"getScissor", g_getScissor},
  {"setCanvas", g_setCanvas}, {"getCanvas", g_getCanvas}, {"clear", g_clear},
  {"push", g_push}, {"pop", g_pop}, {"origin", g_origin}, {"translate", g_translate},
  {"scale", g_scale}, {"rotate", g_rotate}, {"shear", g_shear}, {"applyTransform", g_applyTransform},
  {"replaceTransform", g_replaceTransform}, {"transformPoint", g_transformPoint},
  {"inverseTransformPoint", g_inverseTransformPoint},
  {"setShader", g_setShader}, {"getShader", g_getShader}, {"setFont", g_setFont}, {"getFont", g_getFont},
  {"setLineWidth", g_setLineWidth}, {"getLineWidth", g_getLineWidth},
  {"setPointSize", g_setPointSize}, {"getPointSize", g_getPointSize},
  {"setLineJoin", g_setLineJoin}, {"getLineJoin", g_getLineJoin},
  {"setLineStyle", g_setLineStyle}, {"getLineStyle", g_getLineStyle},
  {"setDefaultFilter", g_setDefaultFilter}, {"getDefaultFilter", g_getDefaultFilter},
  {"rectangle", g_rectangle}, {"circle", g_circle}, {"ellipse", g_ellipse}, {"arc", g_arc},
  {"polygon", g_polygon}, {"line", g_line}, {"points", g_points},
  {"draw", g_draw}, {"drawLayer", g_drawLayer}, {"drawInstanced", g_draw}, {"print", g_print}, {"printf", g_printf},
  {"getDimensions", g_getDimensions}, {"getWidth", g_getWidth}, {"getHeight", g_getHeight},
  {"getPixelDimensions", g_getDimensions}, {"getPixelWidth", g_getWidth}, {"getPixelHeight", g_getHeight},
  {"getDPIScale", g_getDPIScale}, {"isActive", g_isActive}, {"isCreated", g_isCreated},
  {"present", g_present}, {"captureScreenshot", g_captureScreenshot},
  {"getSupported", g_getSupported}, {"getRendererInfo", g_getRendererInfo},
  {"getSystemLimits", g_getSystemLimits}, {"getCanvasFormats", g_getFormats},
  {"getImageFormats", g_getFormats}, {"getTextureTypes", g_getTextureTypes}, {"getStats", g_getStats},
  {"reset", g_reset}, {"flushBatch", g_noop}, {"setWireframe", g_noop}, {"isWireframe", g_false},
  {"setColorMask", g_noop}, {"setStencilTest", g_noop}, {"getStencilTest", g_false},
  {"stencil", g_stencil}, {"setDepthMode", g_noop}, {"setMeshCullMode", g_noop},
  {"setFrontFaceWinding", g_noop}, {"discard", g_noop}, {"isGammaCorrect", g_false},
  {"getStackDepth", g_getStackDepth},
  {"_resetFrameStats", g_resetFrameStats}, {"_setPresentScaling", g_setPresentScaling},
  {"_getPresentScaling", g_getPresentScaling}, {"_setOverlay", g_setOverlay}, {"_setBars", g_setBars}, {NULL, NULL}};

int lp_open_graphics(lua_State *L) {
  g_L = L;
  Image_type.methods = image_methods;
  Canvas_type.methods = canvas_methods;
  lp_register_type(L, &Image_type);
  lp_register_type(L, &Canvas_type);
  lp_register_type(L, &Quad_type);
  lp_register_type(L, &SpriteBatch_type);
  lp_register_type(L, &Mesh_type);
  lp_register_type(L, &Shader_type);
  lp_register_type(L, &Transform_type);
  lp_register_type(L, &Text_type);
  lp_font_register(L);
  lua_newtable(L); lua_setfield(L, LUA_REGISTRYINDEX, REF_KEY);
  lua_newtable(L); lua_setfield(L, LUA_REGISTRYINDEX, "lovepsp.capture");
  if (!g_back) gfx_resize_backbuffer(PLAT_SCREEN_W, PLAT_SCREEN_H);
  g_target = g_back;
  g_st.color[0] = g_st.color[1] = g_st.color[2] = g_st.color[3] = 1;
  g_st.bg[3] = 1;
  g_st.tf = mat_identity();
  g_st.line_width = 1;
  g_st.point_size = 1;
  luaL_newlib(L, g_funcs);
  return 1;
}
