/* love.image: ImageData, PNG/JPG decode (stb_image) and PNG encode. */
#include <stdlib.h>
#include <string.h>
#include "lp.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_TGA
#define STBI_NO_STDIO
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

px_t *image_decode(const void *data, size_t len, int *w, int *h) {
  int n;
  unsigned char *p = stbi_load_from_memory((const stbi_uc *)data, (int)len, w, h, &n, 4);
  return (px_t *)p; /* stbi uses malloc, so free() releases it */
}

int lp_write_png(const char *path, const uint32_t *px, int w, int h) {
  return stbi_write_png(path, w, h, 4, px, w * 4);
}

/* deflate/inflate for love.data (zlib streams) */
unsigned char *lp_zlib_compress(const unsigned char *data, int len, int *outlen, int level) {
  return stbi_zlib_compress((unsigned char *)data, len, outlen, level);
}
char *lp_zlib_decompress(const char *data, int len, int *outlen, int zlib_header) {
  return stbi_zlib_decode_malloc_guesssize_headerflag(data, len, len * 4 + 1024, outlen, zlib_header);
}

/* ------------------------------------------------------------ ImageData */

static int id_gc(lua_State *L) {
  ImageData *d = (ImageData *)lua_touserdata(L, 1);
  if (d->px) { free(d->px); d->px = NULL; }
  return 0;
}

ImageData *imagedata_check(lua_State *L, int idx) {
  ImageData *d = (ImageData *)lp_checkobj(L, idx, &lp_ImageData_type);
  if (!d->px) luaL_error(L, "ImageData has been released");
  return d;
}

static int id_getWidth(lua_State *L) { lua_pushinteger(L, imagedata_check(L, 1)->w); return 1; }
static int id_getHeight(lua_State *L) { lua_pushinteger(L, imagedata_check(L, 1)->h); return 1; }
static int id_getDimensions(lua_State *L) {
  ImageData *d = imagedata_check(L, 1);
  lua_pushinteger(L, d->w); lua_pushinteger(L, d->h);
  return 2;
}
static int id_getFormat(lua_State *L) { lua_pushliteral(L, "rgba8"); return 1; }
static int id_getSize(lua_State *L) { ImageData *d = imagedata_check(L, 1); lua_pushinteger(L, (lua_Integer)d->w * d->h * 4); return 1; }
static int id_getString(lua_State *L) {
  ImageData *d = imagedata_check(L, 1);
  lua_pushlstring(L, (const char *)d->px, (size_t)d->w * d->h * 4);
  return 1;
}
static int id_getPointer(lua_State *L) { lua_pushlightuserdata(L, imagedata_check(L, 1)->px); return 1; }

static int id_getPixel(lua_State *L) {
  ImageData *d = imagedata_check(L, 1);
  lua_Integer x = (lua_Integer)luaL_checknumber(L, 2), y = (lua_Integer)luaL_checknumber(L, 3);
  px_t p;
  if (x < 0 || y < 0 || x >= d->w || y >= d->h)
    return luaL_error(L, "Attempt to get out-of-range pixel (%d,%d)!", (int)x, (int)y);
  p = d->px[y * d->w + x];
  lua_pushnumber(L, PX_R(p) / 255.0);
  lua_pushnumber(L, PX_G(p) / 255.0);
  lua_pushnumber(L, PX_B(p) / 255.0);
  lua_pushnumber(L, PX_A(p) / 255.0);
  return 4;
}

static int id_setPixel(lua_State *L) {
  ImageData *d = imagedata_check(L, 1);
  lua_Integer x = (lua_Integer)luaL_checknumber(L, 2), y = (lua_Integer)luaL_checknumber(L, 3);
  double r, g, b, a;
  if (lua_istable(L, 4)) {
    lua_rawgeti(L, 4, 1); lua_rawgeti(L, 4, 2); lua_rawgeti(L, 4, 3); lua_rawgeti(L, 4, 4);
    r = luaL_optnumber(L, -4, 0); g = luaL_optnumber(L, -3, 0); b = luaL_optnumber(L, -2, 0); a = luaL_optnumber(L, -1, 1);
    lua_pop(L, 4);
  } else {
    r = luaL_checknumber(L, 4); g = luaL_checknumber(L, 5); b = luaL_checknumber(L, 6);
    a = luaL_optnumber(L, 7, 1.0);
  }
  if (x < 0 || y < 0 || x >= d->w || y >= d->h)
    return luaL_error(L, "Attempt to set out-of-range pixel (%d,%d)!", (int)x, (int)y);
  d->px[y * d->w + x] = PX(lp_f2b(r), lp_f2b(g), lp_f2b(b), lp_f2b(a));
  return 0;
}

static int id_mapPixel(lua_State *L) {
  ImageData *d = imagedata_check(L, 1);
  int sx = (int)luaL_optinteger(L, 3, 0), sy = (int)luaL_optinteger(L, 4, 0);
  int w = (int)luaL_optinteger(L, 5, d->w), h = (int)luaL_optinteger(L, 6, d->h);
  int x, y;
  luaL_checktype(L, 2, LUA_TFUNCTION);
  if (sx < 0 || sy < 0 || w < 0 || h < 0 || sx + w > d->w || sy + h > d->h)
    return luaL_error(L, "Invalid rectangle dimensions.");
  for (y = sy; y < sy + h; y++) {
    for (x = sx; x < sx + w; x++) {
      px_t *p = &d->px[y * d->w + x];
      lua_pushvalue(L, 2);
      lua_pushinteger(L, x); lua_pushinteger(L, y);
      lua_pushnumber(L, PX_R(*p) / 255.0); lua_pushnumber(L, PX_G(*p) / 255.0);
      lua_pushnumber(L, PX_B(*p) / 255.0); lua_pushnumber(L, PX_A(*p) / 255.0);
      lua_call(L, 6, 4);
      *p = PX(lp_f2b(luaL_optnumber(L, -4, 0)), lp_f2b(luaL_optnumber(L, -3, 0)),
              lp_f2b(luaL_optnumber(L, -2, 0)), lp_f2b(luaL_optnumber(L, -1, 1)));
      lua_pop(L, 4);
    }
  }
  return 0;
}

static int id_paste(lua_State *L) {
  ImageData *d = imagedata_check(L, 1), *s = imagedata_check(L, 2);
  int dx = (int)luaL_optnumber(L, 3, 0), dy = (int)luaL_optnumber(L, 4, 0);
  int sx = (int)luaL_optnumber(L, 5, 0), sy = (int)luaL_optnumber(L, 6, 0);
  int sw = (int)luaL_optnumber(L, 7, s->w), sh = (int)luaL_optnumber(L, 8, s->h);
  int y;
  if (dx < 0) { sw += dx; sx -= dx; dx = 0; }
  if (dy < 0) { sh += dy; sy -= dy; dy = 0; }
  if (sx < 0) { sw += sx; dx -= sx; sx = 0; }
  if (sy < 0) { sh += sy; dy -= sy; sy = 0; }
  if (dx + sw > d->w) sw = d->w - dx;
  if (dy + sh > d->h) sh = d->h - dy;
  if (sx + sw > s->w) sw = s->w - sx;
  if (sy + sh > s->h) sh = s->h - sy;
  if (sw <= 0 || sh <= 0) return 0;
  for (y = 0; y < sh; y++)
    memmove(&d->px[(dy + y) * d->w + dx], &s->px[(sy + y) * s->w + sx], (size_t)sw * 4);
  return 0;
}

ImageData *imagedata_push(lua_State *L, int w, int h) {
  ImageData *d = (ImageData *)lp_newobj(L, &lp_ImageData_type, sizeof(ImageData));
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  d->w = w; d->h = h;
  d->px = (px_t *)calloc((size_t)w * h, 4);
  if (!d->px) luaL_error(L, "out of memory creating %dx%d ImageData", w, h);
  return d;
}

static int id_clone(lua_State *L) {
  ImageData *s = imagedata_check(L, 1);
  ImageData *d = imagedata_push(L, s->w, s->h);
  memcpy(d->px, s->px, (size_t)s->w * s->h * 4);
  return 1;
}

static int id_encode(lua_State *L) {
  ImageData *d = imagedata_check(L, 1);
  const char *fmt = luaL_optstring(L, 2, "png");
  int len = 0;
  unsigned char *png;
  if (strcmp(fmt, "png") && strcmp(fmt, "tga"))
    return luaL_error(L, "Image format '%s' not supported on this platform", fmt);
  png = stbi_write_png_to_mem((const unsigned char *)d->px, d->w * 4, d->w, d->h, 4, &len);
  if (!png) return luaL_error(L, "PNG encoding failed");
  blob_push(L, &lp_FileData_type, png, (size_t)len,
            lua_isstring(L, 3) ? lua_tostring(L, 3) : "Image.png");
  STBIW_FREE(png);
  if (lua_isstring(L, 3)) {
    /* love.filesystem.write(filename, filedata) */
    lua_getglobal(L, "love");
    lua_getfield(L, -1, "filesystem");
    lua_getfield(L, -1, "write");
    lua_pushvalue(L, 3);
    lua_pushvalue(L, -5);
    lua_call(L, 2, 0);
    lua_pop(L, 2);
  }
  return 1;
}

static const luaL_Reg id_methods[] = {
  {"getWidth", id_getWidth}, {"getHeight", id_getHeight}, {"getDimensions", id_getDimensions},
  {"getFormat", id_getFormat}, {"getSize", id_getSize}, {"getString", id_getString},
  {"getPointer", id_getPointer}, {"getFFIPointer", id_getPointer},
  {"getPixel", id_getPixel}, {"setPixel", id_setPixel}, {"mapPixel", id_mapPixel},
  {"paste", id_paste}, {"clone", id_clone}, {"encode", id_encode}, {NULL, NULL}};
static const char *const id_chain[] = {"Data", NULL};
const LPType lp_ImageData_type = {"ImageData", id_chain, id_methods, id_gc};

static int img_newImageData(lua_State *L) {
  if (lua_isnumber(L, 1)) {
    int w = (int)luaL_checkinteger(L, 1), h = (int)luaL_checkinteger(L, 2);
    ImageData *d = imagedata_push(L, w, h);
    if (lua_gettop(L) >= 5 && !lua_isnil(L, 4)) {
      size_t len;
      const char *raw = NULL;
      if (lua_type(L, 4) == LUA_TSTRING) raw = lua_tolstring(L, 4, &len);
      else {
        Blob *b = (Blob *)lp_testobj(L, 4, &lp_ByteData_type);
        if (!b) b = (Blob *)lp_testobj(L, 4, &lp_FileData_type);
        if (b) { raw = b->data; len = b->len; }
      }
      if (raw) memcpy(d->px, raw, len < (size_t)w * h * 4 ? len : (size_t)w * h * 4);
    }
    return 1;
  }
  {
    size_t len;
    const char *name = NULL;
    char *buf = lp_read_source(L, 1, &len, &name);
    int w, h;
    px_t *px;
    ImageData *d;
    if (!buf) return luaL_error(L, "could not read image");
    px = image_decode(buf, len, &w, &h);
    free(buf);
    if (!px) return luaL_error(L, "Could not decode image %s (%s)", name ? name : "?", stbi_failure_reason());
    d = (ImageData *)lp_newobj(L, &lp_ImageData_type, sizeof(ImageData));
    d->w = w; d->h = h; d->px = px;
    return 1;
  }
}

static int img_isCompressed(lua_State *L) { lua_pushboolean(L, 0); return 1; }

static const luaL_Reg img_funcs[] = {
  {"newImageData", img_newImageData}, {"isCompressed", img_isCompressed}, {NULL, NULL}};

int lp_open_image(lua_State *L) {
  lp_register_type(L, &lp_ImageData_type);
  luaL_newlib(L, img_funcs);
  return 1;
}
