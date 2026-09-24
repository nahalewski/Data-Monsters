/*
 * The native "lovepsp" helper module the Lua side of the runtime is built
 * on (boot.lua implements love.timer/event/keyboard/joystick/math/data/
 * system/window on top of it), plus LuaBitOp's `bit` and message digests.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lp.h"
#include "plat.h"

/* ------------------------------------------------------------ digests */

typedef struct { uint32_t s[4]; uint64_t n; unsigned char buf[64]; } Md5;
typedef struct { uint32_t s[5]; uint64_t n; unsigned char buf[64]; } Sha1;
typedef struct { uint32_t s[8]; uint64_t n; unsigned char buf[64]; } Sha256;

#define ROL(x, c) (((x) << (c)) | ((x) >> (32 - (c))))
#define ROR(x, c) (((x) >> (c)) | ((x) << (32 - (c))))

static void md5_block(uint32_t *s, const unsigned char *p) {
  static const uint32_t K[64] = {
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
  static const int R[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};
  uint32_t w[16], a = s[0], b = s[1], c = s[2], d = s[3], f, t;
  int i, g;
  for (i = 0; i < 16; i++) w[i] = p[i * 4] | (p[i * 4 + 1] << 8) | (p[i * 4 + 2] << 16) | ((uint32_t)p[i * 4 + 3] << 24);
  for (i = 0; i < 64; i++) {
    if (i < 16) { f = (b & c) | (~b & d); g = i; }
    else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) % 16; }
    else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) % 16; }
    else { f = c ^ (b | ~d); g = (7 * i) % 16; }
    t = d; d = c; c = b;
    b = b + ROL(a + f + K[i] + w[g], R[i]);
    a = t;
  }
  s[0] += a; s[1] += b; s[2] += c; s[3] += d;
}

static void sha1_block(uint32_t *s, const unsigned char *p) {
  uint32_t w[80], a = s[0], b = s[1], c = s[2], d = s[3], e = s[4], f, k, t;
  int i;
  for (i = 0; i < 16; i++) w[i] = ((uint32_t)p[i * 4] << 24) | (p[i * 4 + 1] << 16) | (p[i * 4 + 2] << 8) | p[i * 4 + 3];
  for (i = 16; i < 80; i++) w[i] = ROL(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
  for (i = 0; i < 80; i++) {
    if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999; }
    else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1; }
    else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
    else { f = b ^ c ^ d; k = 0xca62c1d6; }
    t = ROL(a, 5) + f + e + k + w[i];
    e = d; d = c; c = ROL(b, 30); b = a; a = t;
  }
  s[0] += a; s[1] += b; s[2] += c; s[3] += d; s[4] += e;
}

static void sha256_block(uint32_t *s, const unsigned char *p) {
  static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
  uint32_t w[64], a, b, c, d, e, f, g, h, t1, t2;
  int i;
  for (i = 0; i < 16; i++) w[i] = ((uint32_t)p[i * 4] << 24) | (p[i * 4 + 1] << 16) | (p[i * 4 + 2] << 8) | p[i * 4 + 3];
  for (i = 16; i < 64; i++) {
    uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  a = s[0]; b = s[1]; c = s[2]; d = s[3]; e = s[4]; f = s[5]; g = s[6]; h = s[7];
  for (i = 0; i < 64; i++) {
    t1 = h + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
    t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  s[0] += a; s[1] += b; s[2] += c; s[3] += d; s[4] += e; s[5] += f; s[6] += g; s[7] += h;
}

/* generic Merkle–Damgård driver; big = big-endian length/output */
static void digest(void (*block)(uint32_t *, const unsigned char *), uint32_t *st, int words, int big,
                   const unsigned char *data, size_t len, unsigned char *out) {
  unsigned char buf[128];
  size_t i, rem;
  uint64_t bits = (uint64_t)len * 8;
  int pad, k;
  for (i = 0; i + 64 <= len; i += 64) block(st, data + i);
  rem = len - i;
  memcpy(buf, data + i, rem);
  buf[rem] = 0x80;
  pad = rem < 56 ? 64 : 128;
  memset(buf + rem + 1, 0, pad - rem - 1);
  for (k = 0; k < 8; k++) buf[pad - 8 + k] = big ? (unsigned char)(bits >> (56 - 8 * k)) : (unsigned char)(bits >> (8 * k));
  block(st, buf);
  if (pad == 128) block(st, buf + 64);
  for (k = 0; k < words; k++) {
    if (big) { out[k * 4] = st[k] >> 24; out[k * 4 + 1] = st[k] >> 16; out[k * 4 + 2] = st[k] >> 8; out[k * 4 + 3] = st[k]; }
    else { out[k * 4] = st[k]; out[k * 4 + 1] = st[k] >> 8; out[k * 4 + 2] = st[k] >> 16; out[k * 4 + 3] = st[k] >> 24; }
  }
}

/* lovepsp.hash(alg, bytes) -> raw digest string */
static int c_hash(lua_State *L) {
  const char *alg = luaL_checkstring(L, 1);
  size_t len;
  const unsigned char *d = (const unsigned char *)luaL_checklstring(L, 2, &len);
  unsigned char out[32];
  if (!strcmp(alg, "md5")) {
    uint32_t s[4] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476};
    digest(md5_block, s, 4, 0, d, len, out);
    lua_pushlstring(L, (char *)out, 16);
  } else if (!strcmp(alg, "sha1")) {
    uint32_t s[5] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0};
    digest(sha1_block, s, 5, 1, d, len, out);
    lua_pushlstring(L, (char *)out, 20);
  } else if (!strcmp(alg, "sha256") || !strcmp(alg, "sha224")) {
    uint32_t s[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint32_t s224[8] = {0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939, 0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4};
    int is224 = alg[4] == '2' && alg[5] == '2';
    digest(sha256_block, is224 ? s224 : s, 8, 1, d, len, out);
    lua_pushlstring(L, (char *)out, is224 ? 28 : 32);
  } else {
    return luaL_error(L, "hash function '%s' is not supported on PSP", alg);
  }
  return 1;
}

/* lovepsp.hashFile(alg, path): stream a VFS file through the digest */
typedef struct HashCtx { int alg; uint32_t s[8]; unsigned char buf[64]; size_t n; uint64_t total; } HashCtx;
static void hash_chunk(void *ud, const unsigned char *d, size_t len) {
  HashCtx *c = (HashCtx *)ud;
  void (*block)(uint32_t *, const unsigned char *) = c->alg == 0 ? md5_block : c->alg == 1 ? sha1_block : sha256_block;
  c->total += len;
  while (len) {
    size_t take = 64 - c->n;
    if (take > len) take = len;
    memcpy(c->buf + c->n, d, take);
    c->n += take; d += take; len -= take;
    if (c->n == 64) { block(c->s, c->buf); c->n = 0; }
  }
}
int fs_stream(const char *path, void (*cb)(void *, const unsigned char *, size_t), void *ud);
static int c_hashFile(lua_State *L) {
  const char *alg = luaL_checkstring(L, 1);
  const char *path = luaL_checkstring(L, 2);
  HashCtx c;
  unsigned char out[32];
  unsigned char pad[128];
  int words, big, k, padlen;
  uint64_t bits;
  memset(&c, 0, sizeof c);
  if (!strcmp(alg, "md5")) { uint32_t s[4] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476}; memcpy(c.s, s, sizeof s); c.alg = 0; words = 4; big = 0; }
  else if (!strcmp(alg, "sha1")) { uint32_t s[5] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0}; memcpy(c.s, s, sizeof s); c.alg = 1; words = 5; big = 1; }
  else if (!strcmp(alg, "sha256")) { uint32_t s[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}; memcpy(c.s, s, sizeof s); c.alg = 2; words = 8; big = 1; }
  else return luaL_error(L, "hash function '%s' is not supported on PSP", alg);
  if (!fs_stream(path, hash_chunk, &c)) { lua_pushnil(L); lua_pushfstring(L, "Could not open file %s", path); return 2; }
  bits = c.total * 8;
  padlen = (int)((c.n < 56 ? 56 : 120) - c.n) + 8;
  memset(pad, 0, sizeof pad);
  pad[0] = 0x80;
  for (k = 0; k < 8; k++) pad[padlen - 8 + k] = big ? (unsigned char)(bits >> (56 - 8 * k)) : (unsigned char)(bits >> (8 * k));
  hash_chunk(&c, pad, (size_t)padlen);
  for (k = 0; k < words; k++) {
    if (big) { out[k * 4] = c.s[k] >> 24; out[k * 4 + 1] = c.s[k] >> 16; out[k * 4 + 2] = c.s[k] >> 8; out[k * 4 + 3] = c.s[k]; }
    else { out[k * 4] = c.s[k]; out[k * 4 + 1] = c.s[k] >> 8; out[k * 4 + 2] = c.s[k] >> 16; out[k * 4 + 3] = c.s[k] >> 24; }
  }
  lua_pushlstring(L, (char *)out, (size_t)words * 4);
  return 1;
}

/* ------------------------------------------------------------ encodings */

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int c_encode(lua_State *L) {
  const char *fmt = luaL_checkstring(L, 1);
  size_t len, i;
  const unsigned char *d = (const unsigned char *)luaL_checklstring(L, 2, &len);
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  if (!strcmp(fmt, "hex")) {
    static const char H[] = "0123456789abcdef";
    for (i = 0; i < len; i++) { luaL_addchar(&b, H[d[i] >> 4]); luaL_addchar(&b, H[d[i] & 15]); }
  } else if (!strcmp(fmt, "base64")) {
    for (i = 0; i < len; i += 3) {
      uint32_t v = (uint32_t)d[i] << 16 | (i + 1 < len ? d[i + 1] << 8 : 0) | (i + 2 < len ? d[i + 2] : 0);
      luaL_addchar(&b, B64[(v >> 18) & 63]);
      luaL_addchar(&b, B64[(v >> 12) & 63]);
      luaL_addchar(&b, i + 1 < len ? B64[(v >> 6) & 63] : '=');
      luaL_addchar(&b, i + 2 < len ? B64[v & 63] : '=');
    }
  } else return luaL_error(L, "unknown encoding '%s'", fmt);
  luaL_pushresult(&b);
  return 1;
}

static int b64val(int c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+' || c == '-') return 62;
  if (c == '/' || c == '_') return 63;
  return -1;
}

static int c_decode(lua_State *L) {
  const char *fmt = luaL_checkstring(L, 1);
  size_t len, i;
  const char *d = luaL_checklstring(L, 2, &len);
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  if (!strcmp(fmt, "hex")) {
    for (i = 0; i + 1 < len; i += 2) {
      char t[3] = {d[i], d[i + 1], 0};
      luaL_addchar(&b, (char)strtol(t, NULL, 16));
    }
  } else if (!strcmp(fmt, "base64")) {
    uint32_t acc = 0;
    int bits = 0;
    for (i = 0; i < len; i++) {
      int v = b64val((unsigned char)d[i]);
      if (v < 0) continue;
      acc = (acc << 6) | (uint32_t)v;
      bits += 6;
      if (bits >= 8) { bits -= 8; luaL_addchar(&b, (char)((acc >> bits) & 0xff)); }
    }
  } else return luaL_error(L, "unknown encoding '%s'", fmt);
  luaL_pushresult(&b);
  return 1;
}

unsigned char *lp_zlib_compress(const unsigned char *data, int len, int *outlen, int level);
char *lp_zlib_decompress(const char *data, int len, int *outlen, int zlib_header);

/* lovepsp.compress(fmt, bytes, level) -- zlib/deflate only; other formats
 * (lz4, gzip) fall back to zlib framing and are flagged by the caller */
static int c_compress(lua_State *L) {
  const char *fmt = luaL_checkstring(L, 1);
  size_t len;
  const unsigned char *d = (const unsigned char *)luaL_checklstring(L, 2, &len);
  int level = (int)luaL_optinteger(L, 3, -1), out = 0;
  unsigned char *c;
  (void)fmt;
  if (level < 0) level = 6;
  c = lp_zlib_compress(d, (int)len, &out, level);
  if (!c) return luaL_error(L, "compression failed");
  lua_pushlstring(L, (char *)c, (size_t)out);
  free(c);
  return 1;
}
static int c_decompress(lua_State *L) {
  const char *fmt = luaL_checkstring(L, 1);
  size_t len;
  const char *d = luaL_checklstring(L, 2, &len);
  int out = 0;
  char *c = lp_zlib_decompress(d, (int)len, &out, strcmp(fmt, "deflate") != 0);
  if (!c) return luaL_error(L, "Could not decompress data (%s)", fmt);
  lua_pushlstring(L, c, (size_t)out);
  free(c);
  return 1;
}

static int c_newByteData(lua_State *L) {
  size_t len;
  const char *d;
  if (lua_isnumber(L, 1)) {
    blob_push(L, &lp_ByteData_type, NULL, (size_t)luaL_checkinteger(L, 1), "");
    return 1;
  }
  d = luaL_checklstring(L, 1, &len);
  blob_push(L, &lp_ByteData_type, d, len, luaL_optstring(L, 2, ""));
  return 1;
}
static int c_newFileData(lua_State *L) {
  size_t len;
  const char *d = luaL_checklstring(L, 1, &len);
  blob_push(L, &lp_FileData_type, d, len, luaL_optstring(L, 2, ""));
  return 1;
}

/* ------------------------------------------------------------ platform */

/* lovepsp.touch([on]) -> enabled: the on-screen controls overlay */
static int c_touch(lua_State *L) {
  int on = lua_isnoneornil(L, 1) ? -1 : lua_toboolean(L, 1);
  lua_pushboolean(L, plat_touch(on));
  return 1;
}
/* lovepsp.touchPad([on]) -> whether the D-pad/A/B overlay is drawn */
static int c_touchPad(lua_State *L) {
  int on = lua_isnoneornil(L, 1) ? -1 : lua_toboolean(L, 1);
  lua_pushboolean(L, plat_touch_pad(on));
  return 1;
}
/* lovepsp.inject(mask): buttons a shell-drawn skin holds this frame */
static int c_inject(lua_State *L) {
  plat_inject((uint32_t)luaL_optinteger(L, 1, 0));
  return 0;
}
/* lovepsp.gameRect([x, y, w, h]): where the game is presented (skins); no args clears */
static int c_gameRect(lua_State *L) {
  if (lua_isnoneornil(L, 1)) plat_set_game_rect(0, 0, 0, 0);
  else plat_set_game_rect((int)luaL_checkinteger(L, 1), (int)luaL_checkinteger(L, 2),
                          (int)luaL_checkinteger(L, 3), (int)luaL_checkinteger(L, 4));
  return 0;
}
/* lovepsp.split() -> top, bottom heights of the DS halves */
static int c_split(lua_State *L) {
  int t, b;
  plat_get_split(&t, &b);
  lua_pushinteger(L, t); lua_pushinteger(L, b);
  return 2;
}
/* lovepsp.hinge() -> foldable hinge angle in degrees, or -1 without a sensor */
static int c_hinge(lua_State *L) { lua_pushnumber(L, plat_hinge()); return 1; }
/* lovepsp.openUrl(url) -> ok: the host browser (Android) */
static int c_openUrl(lua_State *L) { lua_pushboolean(L, plat_open_url(luaL_checkstring(L, 1))); return 1; }
/* lovepsp.touches() -> { {x=, y=}, ... } fingers on the screen (logical px) */
static int c_touches(lua_State *L) {
  int i = 0;
  float x, y;
  lua_newtable(L);
  while (i < 16 && plat_touch_get(i, &x, &y)) {
    lua_newtable(L);
    lua_pushnumber(L, x); lua_setfield(L, -2, "x");
    lua_pushnumber(L, y); lua_setfield(L, -2, "y");
    lua_rawseti(L, -2, i + 1);
    i++;
  }
  return 1;
}
static int c_time(lua_State *L) { lua_pushnumber(L, plat_time()); return 1; }
static int c_sleep(lua_State *L) { plat_sleep(luaL_checknumber(L, 1)); return 0; }
static int c_poll(lua_State *L) {
  PlatInput in;
  memset(&in, 0, sizeof in);
  plat_poll(&in);
  lua_pushinteger(L, in.buttons);
  lua_pushnumber(L, in.ax);
  lua_pushnumber(L, in.ay);
  lua_pushboolean(L, in.quit);
  lua_pushnumber(L, in.rx);
  lua_pushnumber(L, in.ry);
  lua_pushnumber(L, in.lt);
  lua_pushnumber(L, in.rt);
  return 8;
}
static int c_setMode(lua_State *L) {
  gfx_resize_backbuffer((int)luaL_checkinteger(L, 1), (int)luaL_checkinteger(L, 2));
  return 0;
}
static int c_getMode(lua_State *L) {
  Tex *b = gfx_backbuffer();
  lua_pushinteger(L, b ? b->w : PLAT_SCREEN_W);
  lua_pushinteger(L, b ? b->h : PLAT_SCREEN_H);
  return 2;
}
static int c_present(lua_State *L) { (void)L; gfx_present(); return 0; }
static int c_os(lua_State *L) { lua_pushstring(L, plat_os_name()); return 1; }
static int c_baseDir(lua_State *L) { lua_pushstring(L, plat_base_dir()); return 1; }
static int c_saveDir(lua_State *L) { lua_pushstring(L, plat_save_dir()); return 1; }
static int c_power(lua_State *L) {
  int pct, chg, secs;
  plat_power(&pct, &chg, &secs);
  lua_pushinteger(L, pct);
  lua_pushboolean(L, chg);
  lua_pushinteger(L, secs);
  return 3;
}
static int c_memory(lua_State *L) {
  lua_pushinteger(L, lua_gc(L, LUA_GCCOUNT, 0));
  lua_pushinteger(L, plat_free_memory());
  return 2;
}
static int c_log(lua_State *L) {
  plat_debug("%s\n", luaL_checkstring(L, 1));
  return 0;
}
static int c_screen(lua_State *L) {
  int w, h;
  plat_screen_size(&w, &h);
  lua_pushinteger(L, w);
  lua_pushinteger(L, h);
  return 2;
}
static int c_display(lua_State *L) {
  int w, h;
  plat_output_size(&w, &h);
  lua_pushinteger(L, w);
  lua_pushinteger(L, h);
  return 2;
}

void fs_save_real(const char *rel, char *out, size_t n);
int lp_unzip(const char *zip_path, const char *dest, char *err, size_t errn);

/* lovepsp.http_get(url, out_rel[, token]) -> ok, err: download into the save dir */
static int c_http_get(lua_State *L) {
  const char *url = luaL_checkstring(L, 1);
  const char *rel = luaL_checkstring(L, 2);
  const char *token = luaL_optstring(L, 3, "");
  char real[800], err[256] = "", auth[300] = "";
  if (*token) snprintf(auth, sizeof auth, "token %s", token);
  fs_save_real(rel, real, sizeof real);
  if (plat_http_get(url, auth, real, err, sizeof err) != 0) {
    lua_pushboolean(L, 0); lua_pushstring(L, err); return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}
/* lovepsp.unzip(zip_rel, dest_rel) -> files, err */
static int c_unzip(lua_State *L) {
  char zip[800], dest[800], err[256] = "";
  int n;
  fs_save_real(luaL_checkstring(L, 1), zip, sizeof zip);
  fs_save_real(luaL_checkstring(L, 2), dest, sizeof dest);
  n = lp_unzip(zip, dest, err, sizeof err);
  if (n < 0) { lua_pushnil(L); lua_pushstring(L, err); return 2; }
  lua_pushinteger(L, n);
  return 1;
}
/* lovepsp.rename(from_rel, to_rel) -> ok */
static int c_rename(lua_State *L) {
  char a[800], b[800];
  fs_save_real(luaL_checkstring(L, 1), a, sizeof a);
  fs_save_real(luaL_checkstring(L, 2), b, sizeof b);
  lua_pushboolean(L, rename(a, b) == 0);
  return 1;
}
static int c_network(lua_State *L) { lua_pushboolean(L, plat_has_network()); return 1; }
/* lovepsp.layout([mode]) -> "single" | "ds" */
static int c_layout(lua_State *L) {
  if (!lua_isnoneornil(L, 1)) {
    const char *m = luaL_checkstring(L, 1);
    plat_set_layout(!strcmp(m, "ds") ? 1 : !strcmp(m, "dual") ? 2 : 0);
  }
  if (lua_isnumber(L, 2) && lua_isnumber(L, 3)) plat_set_split((int)lua_tointeger(L, 2), (int)lua_tointeger(L, 3));
  lua_pushstring(L, plat_get_layout() == 1 ? "ds" : plat_get_layout() == 2 ? "dual" : "single");
  return 1;
}

static const luaL_Reg core_funcs[] = {
  {"hash", c_hash}, {"hashFile", c_hashFile}, {"encode", c_encode}, {"decode", c_decode},
  {"compress", c_compress}, {"decompress", c_decompress},
  {"newByteData", c_newByteData}, {"newFileData", c_newFileData},
  {"time", c_time}, {"sleep", c_sleep}, {"poll", c_poll}, {"setMode", c_setMode},
  {"getMode", c_getMode}, {"present", c_present}, {"os", c_os}, {"baseDir", c_baseDir},
  {"saveDir", c_saveDir}, {"power", c_power}, {"memory", c_memory}, {"log", c_log},
  {"screen", c_screen}, {"display", c_display}, {"touch", c_touch}, {"touchPad", c_touchPad}, {"touches", c_touches}, {"inject", c_inject}, {"gameRect", c_gameRect}, {"split", c_split}, {"hinge", c_hinge}, {"openUrl", c_openUrl}, {"http_get", c_http_get}, {"unzip", c_unzip},
  {"rename", c_rename}, {"network", c_network}, {"layout", c_layout}, {"apu_render", lp_apu_render}, {"apu_copy", lp_apu_copy}, {NULL, NULL}};

int luaopen_lovepsp(lua_State *L) {
  luaL_newlib(L, core_funcs);
  lua_pushliteral(L, LP_VERSION);
  lua_setfield(L, -2, "version");
  return 1;
}

/* ------------------------------------------------------------ bit (LuaBitOp API) */

static uint32_t barg(lua_State *L, int i) {
  lua_Number n = luaL_checknumber(L, i);
  /* wrap like LuaBitOp: modulo 2^32 of the integral value */
  if (lua_isinteger(L, i)) return (uint32_t)(lua_Unsigned)lua_tointeger(L, i);
  {
    double d = n;
    d = d - 4294967296.0 * (double)(long long)(d / 4294967296.0);
    return (uint32_t)(long long)d;
  }
}
static int bret(lua_State *L, uint32_t v) { lua_pushinteger(L, (lua_Integer)(int32_t)v); return 1; }

static int b_tobit(lua_State *L) { return bret(L, barg(L, 1)); }
static int b_bnot(lua_State *L) { return bret(L, ~barg(L, 1)); }
static int b_band(lua_State *L) { int i, n = lua_gettop(L); uint32_t v = barg(L, 1); for (i = 2; i <= n; i++) v &= barg(L, i); return bret(L, v); }
static int b_bor(lua_State *L) { int i, n = lua_gettop(L); uint32_t v = barg(L, 1); for (i = 2; i <= n; i++) v |= barg(L, i); return bret(L, v); }
static int b_bxor(lua_State *L) { int i, n = lua_gettop(L); uint32_t v = barg(L, 1); for (i = 2; i <= n; i++) v ^= barg(L, i); return bret(L, v); }
static int b_lshift(lua_State *L) { return bret(L, barg(L, 1) << (barg(L, 2) & 31)); }
static int b_rshift(lua_State *L) { return bret(L, barg(L, 1) >> (barg(L, 2) & 31)); }
static int b_arshift(lua_State *L) { return bret(L, (uint32_t)((int32_t)barg(L, 1) >> (barg(L, 2) & 31))); }
static int b_rol(lua_State *L) { uint32_t v = barg(L, 1), n = barg(L, 2) & 31; return bret(L, n ? (v << n) | (v >> (32 - n)) : v); }
static int b_ror(lua_State *L) { uint32_t v = barg(L, 1), n = barg(L, 2) & 31; return bret(L, n ? (v >> n) | (v << (32 - n)) : v); }
static int b_bswap(lua_State *L) {
  uint32_t v = barg(L, 1);
  return bret(L, (v >> 24) | ((v >> 8) & 0xff00) | ((v & 0xff00) << 8) | (v << 24));
}
static int b_tohex(lua_State *L) {
  uint32_t v = barg(L, 1);
  int n = lua_isnone(L, 2) ? 8 : (int)(int32_t)barg(L, 2);
  const char *hexd = "0123456789abcdef";
  char buf[8];
  int i;
  if (n < 0) { n = -n; hexd = "0123456789ABCDEF"; }
  if (n > 8) n = 8;
  for (i = n - 1; i >= 0; i--) { buf[i] = hexd[v & 15]; v >>= 4; }
  lua_pushlstring(L, buf, (size_t)n);
  return 1;
}
static const luaL_Reg bit_funcs[] = {
  {"tobit", b_tobit}, {"bnot", b_bnot}, {"band", b_band}, {"bor", b_bor}, {"bxor", b_bxor},
  {"lshift", b_lshift}, {"rshift", b_rshift}, {"arshift", b_arshift}, {"rol", b_rol},
  {"ror", b_ror}, {"bswap", b_bswap}, {"tohex", b_tohex}, {NULL, NULL}};

int luaopen_bit(lua_State *L) {
  luaL_newlib(L, bit_funcs);
  return 1;
}
