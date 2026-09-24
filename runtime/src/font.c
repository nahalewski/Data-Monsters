/* Fonts: TrueType (stb_truetype), LÖVE image fonts and a built-in 8x8 font. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "gfx.h"

#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "stb_truetype.h"
#include "font8x8_basic.h"

const char *lp_font8x8(int cp) { return (cp >= 0 && cp < 128) ? font8x8_basic[cp] : font8x8_basic[(int)'?']; }

enum { F_BITMAP, F_TTF, F_IMAGE };

typedef struct Glyph {
  int cp;          /* -1 empty slot */
  int ax, ay, w, h; /* atlas rect */
  float xoff, yoff, adv;
} Glyph;

struct Font {
  int kind;
  float size;
  int scale;              /* bitmap font integer scale */
  int mono;
  unsigned char *ttf;
  stbtt_fontinfo info;
  float tt_scale;
  float ascent, descent, height;
  float line_height;      /* multiplier */
  float extra_spacing;    /* image fonts */
  Tex *atlas;
  int shelf_x, shelf_y, shelf_h;
  Glyph *glyphs;
  int cap, count;
  /* image font source */
  ImageData src;
};

typedef struct FontObj { Font *f; } FontObj;

static void font_free(Font *f) {
  if (!f) return;
  free(f->ttf);
  free(f->glyphs);
  free(f->src.px);
  tex_release(f->atlas);
  free(f);
}

static int fontobj_gc(lua_State *L) {
  FontObj *o = (FontObj *)lua_touserdata(L, 1);
  if (o->f) { font_free(o->f); o->f = NULL; }
  return 0;
}

static Glyph *glyph_slot(Font *f, int cp) {
  unsigned h;
  if (f->count * 2 >= f->cap) {
    int nc = f->cap ? f->cap * 2 : 256, i;
    Glyph *old = f->glyphs, *ng = (Glyph *)malloc(sizeof(Glyph) * nc);
    int oc = f->cap;
    if (!ng) return NULL;
    for (i = 0; i < nc; i++) ng[i].cp = -1;
    f->glyphs = ng; f->cap = nc; f->count = 0;
    for (i = 0; i < oc; i++) {
      if (old[i].cp >= 0) {
        Glyph *s = glyph_slot(f, old[i].cp);
        *s = old[i];
        f->count++;
      }
    }
    free(old);
  }
  h = ((unsigned)cp * 2654435761u) & (unsigned)(f->cap - 1);
  while (f->glyphs[h].cp >= 0 && f->glyphs[h].cp != cp) h = (h + 1) & (unsigned)(f->cap - 1);
  return &f->glyphs[h];
}

/* reserve w x h in the atlas; returns 0 on failure */
static int atlas_alloc(Font *f, int w, int h, int *x, int *y) {
  if (w > f->atlas->w) return 0;
  if (f->shelf_x + w > f->atlas->w) { f->shelf_x = 0; f->shelf_y += f->shelf_h + 1; f->shelf_h = 0; }
  while (f->shelf_y + h > f->atlas->h) {
    int nh = f->atlas->h * 2;
    px_t *np;
    if (nh > 2048) return 0;
    np = (px_t *)realloc(f->atlas->px, (size_t)f->atlas->w * nh * 4);
    if (!np) return 0;
    memset(np + (size_t)f->atlas->w * f->atlas->h, 0, (size_t)f->atlas->w * (nh - f->atlas->h) * 4);
    f->atlas->px = np;
    f->atlas->h = nh;
  }
  *x = f->shelf_x; *y = f->shelf_y;
  f->shelf_x += w + 1;
  if (h > f->shelf_h) f->shelf_h = h;
  return 1;
}

static Glyph *glyph_get(Font *f, int cp) {
  Glyph *g = glyph_slot(f, cp);
  int x, y, i, j;
  if (!g) return NULL;
  if (g->cp == cp) return g;
  memset(g, 0, sizeof *g);
  g->cp = cp;
  f->count++;
  if (f->kind == F_BITMAP) {
    int s = f->scale;
    const char *bits = (cp >= 0 && cp < 128) ? font8x8_basic[cp] : font8x8_basic['?'];
    g->adv = 8.0f * s;
    if (cp == ' ' || cp == '\t') { if (cp == '\t') g->adv *= 4; return g; }
    if (!atlas_alloc(f, 8 * s, 8 * s, &x, &y)) return g;
    for (j = 0; j < 8 * s; j++)
      for (i = 0; i < 8 * s; i++)
        if (bits[j / s] & (1 << (i / s))) f->atlas->px[(long)(y + j) * f->atlas->w + x + i] = 0xffffffffu;
    g->ax = x; g->ay = y; g->w = 8 * s; g->h = 8 * s;
    g->xoff = 0; g->yoff = (f->height - 8 * s) / 2;
  } else if (f->kind == F_TTF) {
    int adv, lsb, x0, y0, x1, y1, w, h, gi = stbtt_FindGlyphIndex(&f->info, cp);
    unsigned char *bmp;
    stbtt_GetGlyphHMetrics(&f->info, gi, &adv, &lsb);
    g->adv = floorf(adv * f->tt_scale + 0.5f);
    stbtt_GetGlyphBitmapBox(&f->info, gi, f->tt_scale, f->tt_scale, &x0, &y0, &x1, &y1);
    w = x1 - x0; h = y1 - y0;
    if (w <= 0 || h <= 0) return g;
    bmp = (unsigned char *)malloc((size_t)w * h);
    if (!bmp) return g;
    stbtt_MakeGlyphBitmap(&f->info, bmp, w, h, w, f->tt_scale, f->tt_scale, gi);
    if (atlas_alloc(f, w, h, &x, &y)) {
      for (j = 0; j < h; j++)
        for (i = 0; i < w; i++) {
          unsigned a = bmp[j * w + i];
          if (f->mono) a = a >= 128 ? 255 : 0;
          f->atlas->px[(long)(y + j) * f->atlas->w + x + i] = PX(255, 255, 255, a);
        }
      g->ax = x; g->ay = y; g->w = w; g->h = h;
      g->xoff = (float)x0;
      g->yoff = f->ascent + (float)y0;
    }
    free(bmp);
  }
  /* image font glyphs are all created up front; unknown ones stay empty */
  return g;
}

static Font *font_alloc(int kind, float size) {
  Font *f = (Font *)calloc(1, sizeof(Font));
  int aw;
  if (!f) return NULL;
  f->kind = kind;
  f->size = size;
  f->line_height = 1;
  aw = 128;
  while (aw < size * 4 && aw < 1024) aw *= 2;
  f->atlas = tex_new(aw, 64);
  if (!f->atlas) { free(f); return NULL; }
  return f;
}

static const char *const font_chain[] = {NULL};
static int fo_getHeight(lua_State *L);
static int fo_getLineHeight(lua_State *L);
static int fo_setLineHeight(lua_State *L);
static int fo_getWidth(lua_State *L);
static int fo_getWrap(lua_State *L);
static int fo_getAscent(lua_State *L);
static int fo_getDescent(lua_State *L);
static int fo_getBaseline(lua_State *L);
static int fo_hasGlyphs(lua_State *L);
static int fo_noop(lua_State *L);
static int fo_getFilter(lua_State *L);
static int fo_getDPIScale(lua_State *L);
static int fo_getKerning(lua_State *L);
static const luaL_Reg font_methods[] = {
  {"getHeight", fo_getHeight}, {"getLineHeight", fo_getLineHeight}, {"setLineHeight", fo_setLineHeight},
  {"getWidth", fo_getWidth}, {"getWrap", fo_getWrap}, {"getAscent", fo_getAscent},
  {"getDescent", fo_getDescent}, {"getBaseline", fo_getBaseline}, {"hasGlyphs", fo_hasGlyphs},
  {"setFallbacks", fo_noop}, {"setFilter", fo_noop}, {"getFilter", fo_getFilter},
  {"getDPIScale", fo_getDPIScale}, {"getKerning", fo_getKerning}, {NULL, NULL}};
const LPType lp_Font_type = {"Font", font_chain, font_methods, fontobj_gc};

Font *font_check(lua_State *L, int idx) {
  FontObj *o = (FontObj *)lp_checkobj(L, idx, &lp_Font_type);
  if (!o->f) luaL_error(L, "Font has been released");
  return o->f;
}

static void push_font(lua_State *L, Font *f) {
  FontObj *o = (FontObj *)lp_newobj(L, &lp_Font_type, sizeof(FontObj));
  o->f = f;
}

int font_push_default(lua_State *L, float size) {
  Font *f = font_alloc(F_BITMAP, size);
  if (!f) return luaL_error(L, "out of memory creating font");
  f->scale = size >= 30 ? 3 : size >= 18 ? 2 : 1;
  f->ascent = 8.0f * f->scale;
  f->descent = -2.0f * f->scale;
  f->height = 10.0f * f->scale;
  push_font(L, f);
  return 1;
}

float font_height(Font *f) { return f->height; }
float font_line_advance(Font *f) { return floorf(f->height * f->line_height + 0.5f); }

static int utf8_next(const char **ps, const char *end) {
  const unsigned char *s = (const unsigned char *)*ps;
  int c = *s, n, cp, i;
  if (c < 0x80) { *ps += 1; return c; }
  if ((c & 0xe0) == 0xc0) { n = 1; cp = c & 0x1f; }
  else if ((c & 0xf0) == 0xe0) { n = 2; cp = c & 0x0f; }
  else if ((c & 0xf8) == 0xf0) { n = 3; cp = c & 0x07; }
  else { *ps += 1; return 0xfffd; }
  if ((const char *)s + n >= end) { *ps = end; return 0xfffd; }
  for (i = 1; i <= n; i++) {
    if ((s[i] & 0xc0) != 0x80) { *ps += i; return 0xfffd; }
    cp = (cp << 6) | (s[i] & 0x3f);
  }
  *ps += n + 1;
  return cp;
}

float font_text_width(Font *f, const char *s, size_t len) {
  const char *end = s + len;
  float w = 0;
  while (s < end) {
    int cp = utf8_next(&s, end);
    Glyph *g = glyph_get(f, cp);
    if (g) w += g->adv + f->extra_spacing;
  }
  return w;
}

void font_draw_line(Font *f, const char *s, size_t len, Mat m, float x, float y, const float *color) {
  const char *end = s + len;
  float pen = floorf(x + 0.5f);
  y = floorf(y + 0.5f);
  while (s < end) {
    int cp = utf8_next(&s, end);
    Glyph *g = glyph_get(f, cp);
    if (!g) continue;
    if (g->w > 0 && g->h > 0) {
      Mat t = {1, 0, 0, 1, pen + g->xoff, y + g->yoff};
      gfx_draw_texture(f->atlas, (float)g->ax, (float)g->ay, (float)g->w, (float)g->h,
                       (float)f->atlas->w, (float)f->atlas->h, mat_mul(m, t), color);
    }
    pen += g->adv + f->extra_spacing;
  }
}

/* greedy word wrap, LÖVE style: breaks at spaces, splits over-long words */
static void wrap_para(Font *f, const char *para, const char *pe, float limit, wrap_cb cb, void *ud) {
  const char *line = para, *p = para;
  float lw = 0;
  if (pe == para) { cb(ud, para, 0, 0, 1); return; }
  while (p < pe) {
    const char *ws = p, *we;
    float segw;
    while (ws < pe && *ws == ' ') ws++;
    we = ws;
    while (we < pe && *we != ' ') we++;
    segw = font_text_width(f, p, (size_t)(we - p));
    if (p == line) {
      if (segw <= limit) { lw = segw; p = we; continue; }
      {
        /* a word wider than the limit: break inside it (at least one char) */
        const char *q = line;
        float cw = 0;
        while (q < we) {
          const char *nq = q;
          float gw;
          utf8_next(&nq, we);
          gw = font_text_width(f, q, (size_t)(nq - q));
          if (cw + gw > limit && q > line) break;
          cw += gw;
          q = nq;
        }
        if (q >= pe) { cb(ud, line, (size_t)(q - line), cw, 1); return; }
        cb(ud, line, (size_t)(q - line), cw, 0);
        line = p = q;
        lw = 0;
        continue;
      }
    }
    if (lw + segw <= limit) { lw += segw; p = we; }
    else {
      cb(ud, line, (size_t)(p - line), lw, 0);
      line = p = ws;
      lw = 0;
    }
  }
  cb(ud, line, (size_t)(p - line), font_text_width(f, line, (size_t)(p - line)), 1);
}

void font_wrap(Font *f, const char *s, size_t len, float limit, wrap_cb cb, void *ud) {
  const char *end = s + len, *para = s;
  for (;;) {
    const char *pe = memchr(para, '\n', (size_t)(end - para));
    if (!pe) pe = end;
    wrap_para(f, para, pe, limit, cb, ud);
    if (pe >= end) break;
    para = pe + 1;
  }
}

static int fo_getHeight(lua_State *L) { lua_pushnumber(L, font_check(L, 1)->height); return 1; }
static int fo_getLineHeight(lua_State *L) { lua_pushnumber(L, font_check(L, 1)->line_height); return 1; }
static int fo_setLineHeight(lua_State *L) { font_check(L, 1)->line_height = (float)luaL_checknumber(L, 2); return 0; }
static int fo_getAscent(lua_State *L) { lua_pushnumber(L, font_check(L, 1)->ascent); return 1; }
static int fo_getDescent(lua_State *L) { lua_pushnumber(L, font_check(L, 1)->descent); return 1; }
static int fo_getBaseline(lua_State *L) { lua_pushnumber(L, font_check(L, 1)->ascent); return 1; }
static int fo_noop(lua_State *L) { (void)L; return 0; }
static int fo_getFilter(lua_State *L) { lua_pushliteral(L, "nearest"); lua_pushliteral(L, "nearest"); lua_pushnumber(L, 1); return 3; }
static int fo_getDPIScale(lua_State *L) { lua_pushnumber(L, 1); return 1; }
static int fo_getKerning(lua_State *L) { lua_pushnumber(L, 0); return 1; }

static int fo_getWidth(lua_State *L) {
  Font *f = font_check(L, 1);
  size_t len;
  const char *s = luaL_tolstring(L, 2, &len), *end = s + len, *p = s;
  float best = 0;
  while (p <= end) {
    const char *nl = memchr(p, '\n', (size_t)(end - p));
    float w;
    if (!nl) nl = end;
    w = font_text_width(f, p, (size_t)(nl - p));
    if (w > best) best = w;
    if (nl >= end) break;
    p = nl + 1;
  }
  lua_pushnumber(L, best);
  return 1;
}

typedef struct WrapOut { lua_State *L; int tbl; int n; float maxw; } WrapOut;
static void wrap_collect(void *ud, const char *s, size_t len, float width, int last) {
  WrapOut *o = (WrapOut *)ud;
  (void)last;
  lua_pushlstring(o->L, s, len);
  lua_rawseti(o->L, o->tbl, ++o->n);
  if (width > o->maxw) o->maxw = width;
}
static int fo_getWrap(lua_State *L) {
  Font *f = font_check(L, 1);
  size_t len;
  const char *s;
  float limit = (float)luaL_checknumber(L, 3);
  WrapOut o;
  if (lua_istable(L, 2)) {
    luaL_Buffer b;
    int n = (int)lua_rawlen(L, 2), i;
    luaL_buffinit(L, &b);
    for (i = 1; i <= n; i++) {
      lua_rawgeti(L, 2, i);
      if (lua_type(L, -1) == LUA_TSTRING) luaL_addvalue(&b); else lua_pop(L, 1);
    }
    luaL_pushresult(&b);
    lua_replace(L, 2);
  }
  s = luaL_tolstring(L, 2, &len);
  lua_newtable(L);
  o.L = L; o.tbl = lua_gettop(L); o.n = 0; o.maxw = 0;
  font_wrap(f, s, len, limit, wrap_collect, &o);
  lua_pushnumber(L, o.maxw);
  lua_insert(L, -2);
  return 2;
}

static int fo_hasGlyphs(lua_State *L) {
  Font *f = font_check(L, 1);
  int i, top = lua_gettop(L);
  for (i = 2; i <= top; i++) {
    if (lua_isinteger(L, i)) {
      int cp = (int)lua_tointeger(L, i);
      if (f->kind == F_TTF && !stbtt_FindGlyphIndex(&f->info, cp)) { lua_pushboolean(L, 0); return 1; }
      if (f->kind == F_BITMAP && (cp < 0 || cp >= 128)) { lua_pushboolean(L, 0); return 1; }
    } else {
      size_t len;
      const char *s = luaL_checklstring(L, i, &len), *end = s + len;
      while (s < end) {
        int cp = utf8_next(&s, end);
        if (f->kind == F_TTF && !stbtt_FindGlyphIndex(&f->info, cp)) { lua_pushboolean(L, 0); return 1; }
        if (f->kind == F_BITMAP && cp >= 128) { lua_pushboolean(L, 0); return 1; }
        if (f->kind == F_IMAGE) {
          Glyph *g = glyph_slot(f, cp);
          if (!g || g->cp != cp) { lua_pushboolean(L, 0); return 1; }
        }
      }
    }
  }
  lua_pushboolean(L, 1);
  return 1;
}

int lp_font_newFont(lua_State *L) {
  float size;
  const char *hint;
  size_t len;
  char *data;
  Font *f;
  int asc, desc, gap;
  if (lua_isnoneornil(L, 1) || lua_isnumber(L, 1)) return font_push_default(L, (float)luaL_optnumber(L, 1, 12));
  size = (float)luaL_optnumber(L, 2, 12);
  hint = luaL_optstring(L, 3, "normal");
  data = lp_read_source(L, 1, &len, NULL);
  if (!data) return luaL_error(L, "could not read font");
  f = font_alloc(F_TTF, size);
  if (!f) { free(data); return luaL_error(L, "out of memory creating font"); }
  f->ttf = (unsigned char *)data;
  if (!stbtt_InitFont(&f->info, f->ttf, stbtt_GetFontOffsetForIndex(f->ttf, 0))) {
    font_free(f);
    return luaL_error(L, "Could not load font (not a TrueType font?)");
  }
  f->mono = !strcmp(hint, "mono");
  f->tt_scale = stbtt_ScaleForMappingEmToPixels(&f->info, size);
  stbtt_GetFontVMetrics(&f->info, &asc, &desc, &gap);
  f->ascent = floorf(asc * f->tt_scale + 0.5f);
  f->descent = floorf(desc * f->tt_scale - 0.5f);
  f->height = f->ascent - f->descent;
  push_font(L, f);
  return 1;
}

int lp_font_newImageFont(lua_State *L) {
  ImageData *src;
  const char *glyphs;
  size_t glen;
  const char *gp, *gend;
  Font *f;
  px_t sep;
  int x, h;
  if (lp_testobj(L, 1, &lp_ImageData_type)) src = imagedata_check(L, 1);
  else {
    lua_getglobal(L, "love");
    lua_getfield(L, -1, "image");
    lua_getfield(L, -1, "newImageData");
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);
    lua_replace(L, 1);
    lua_pop(L, 2);
    src = imagedata_check(L, 1);
  }
  glyphs = luaL_checklstring(L, 2, &glen);
  f = font_alloc(F_IMAGE, (float)src->h);
  if (!f) return luaL_error(L, "out of memory creating font");
  f->extra_spacing = (float)luaL_optnumber(L, 3, 0);
  h = src->h;
  f->height = (float)h; f->ascent = (float)h; f->descent = 0;
  sep = src->px[0];
  gp = glyphs; gend = glyphs + glen;
  x = 0;
  while (gp < gend) {
    int cp = utf8_next(&gp, gend), start, w, ax, ay, j, i;
    Glyph *g;
    while (x < src->w && src->px[x] == sep) x++;
    start = x;
    while (x < src->w && src->px[x] != sep) x++;
    w = x - start;
    if (w <= 0) break;
    g = glyph_slot(f, cp);
    if (!g) break;
    memset(g, 0, sizeof *g);
    g->cp = cp;
    f->count++;
    g->adv = (float)w;
    if (atlas_alloc(f, w, h, &ax, &ay)) {
      for (j = 0; j < h; j++)
        for (i = 0; i < w; i++) {
          px_t p = src->px[(long)j * src->w + start + i];
          f->atlas->px[(long)(ay + j) * f->atlas->w + ax + i] = p == sep ? 0 : p;
        }
      g->ax = ax; g->ay = ay; g->w = w; g->h = h;
    }
  }
  push_font(L, f);
  return 1;
}

void lp_font_register(lua_State *L) { lp_register_type(L, &lp_Font_type); }
