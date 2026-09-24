/*
 * love.filesystem: a PhysFS-like virtual filesystem.
 *
 * Read path, first match wins:
 *   [prepended mounts...] save dir, <base>/game/ (loose overrides),
 *   the LPAK archive in the EBOOT's DATA.PSAR, [appended mounts...]
 * Writes always go to the save directory.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include "lp.h"
#include "plat.h"

/* ------------------------------------------------------------ archive */

typedef struct PakEntry {
  const char *name;
  uint32_t off, size, flags;
} PakEntry;

static FILE *g_pak;
static long g_pak_base;
static PakEntry *g_ents;
static uint32_t g_nents;
static char *g_names;
static char g_pak_path[512];

static uint32_t rd32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int pak_open(const char *path) {
  unsigned char hdr[40];
  long base = 0;
  uint32_t i, count, names_size;
  unsigned char *table;
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  if (fread(hdr, 1, 40, f) < 16) { fclose(f); return 0; }
  if (!memcmp(hdr, "\0PBP", 4)) base = (long)rd32(hdr + 8 + 7 * 4);
  else if (memcmp(hdr, "LPAK", 4)) { fclose(f); return 0; }
  if (fseek(f, base, SEEK_SET) || fread(hdr, 1, 16, f) != 16 || memcmp(hdr, "LPAK", 4)) {
    fclose(f);
    return 0;
  }
  count = rd32(hdr + 8);
  names_size = rd32(hdr + 12);
  table = (unsigned char *)malloc((size_t)count * 16);
  g_names = (char *)malloc(names_size + 1);
  g_ents = (PakEntry *)malloc(sizeof(PakEntry) * (count ? count : 1));
  if (!table || !g_names || !g_ents
      || fread(table, 16, count, f) != count
      || fread(g_names, 1, names_size, f) != names_size) {
    free(table); fclose(f);
    return 0;
  }
  g_names[names_size] = 0;
  for (i = 0; i < count; i++) {
    g_ents[i].name = g_names + rd32(table + i * 16);
    g_ents[i].off = rd32(table + i * 16 + 4);
    g_ents[i].size = rd32(table + i * 16 + 8);
    g_ents[i].flags = rd32(table + i * 16 + 12);
  }
  free(table);
  g_nents = count;
  g_pak = f;
  g_pak_base = base;
  strncpy(g_pak_path, path, sizeof g_pak_path - 1);
  return 1;
}

/* index of the first entry >= key */
static uint32_t pak_lower(const char *key) {
  uint32_t lo = 0, hi = g_nents;
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    if (strcmp(g_ents[mid].name, key) < 0) lo = mid + 1; else hi = mid;
  }
  return lo;
}

static PakEntry *pak_find(const char *name) {
  uint32_t i;
  if (!g_pak) return NULL;
  if (!*name) return NULL;
  i = pak_lower(name);
  if (i < g_nents && !strcmp(g_ents[i].name, name)) return &g_ents[i];
  return NULL;
}

static char *pak_read(PakEntry *e, size_t *len) {
  char *buf = (char *)malloc(e->size + 1);
  if (!buf) return NULL;
  if (fseek(g_pak, g_pak_base + (long)e->off, SEEK_SET)
      || fread(buf, 1, e->size, g_pak) != e->size) { free(buf); return NULL; }
  buf[e->size] = 0;
  if (len) *len = e->size;
  return buf;
}

/* ------------------------------------------------------------ mounts */

enum { M_DIR, M_PAK };
typedef struct Mount {
  int kind;
  char real[512];  /* directory with trailing '/' (M_DIR) */
  char point[256]; /* mount point without slashes, "" = root */
  char key[512];   /* what mount()/unmount() were given */
} Mount;

#define MAX_MOUNTS 48
static Mount g_mounts[MAX_MOUNTS];
static int g_nmounts;
static char g_save_root[512];  /* platform save dir */
static char g_save[600];       /* save root + identity + '/' */
static char g_identity[128] = "lovepsp";
static char g_base[512];
static char g_source[600];
static char g_require_path[512] = "?.lua;?/init.lua";

static void normalize(const char *in, char *out, size_t n) {
  size_t o = 0;
  while (*in == '/' || (in[0] == '.' && in[1] == '/')) in += (*in == '/') ? 1 : 2;
  for (; *in && o + 1 < n; in++) {
    if (*in == '\\') { if (o && out[o - 1] == '/') continue; out[o++] = '/'; continue; }
    if (*in == '/' && o && out[o - 1] == '/') continue;
    out[o++] = *in;
  }
  while (o && out[o - 1] == '/') o--;
  out[o] = 0;
}

static int is_dir_real(const char *p) {
  struct stat st;
  return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static void mkdirs(const char *path) {
  char tmp[700];
  size_t i, l;
  strncpy(tmp, path, sizeof tmp - 1); tmp[sizeof tmp - 1] = 0;
  l = strlen(tmp);
  for (i = 1; i < l; i++) {
    if (tmp[i] == '/' && tmp[i - 1] != ':') {
      tmp[i] = 0;
      mkdir(tmp, 0777);
      tmp[i] = '/';
    }
  }
  mkdir(tmp, 0777);
}

static void set_save_mount(void) {
  int i;
  snprintf(g_save, sizeof g_save, "%s%s/", g_save_root, g_identity);
  mkdirs(g_save);
  for (i = 0; i < g_nmounts; i++)
    if (!strcmp(g_mounts[i].key, "<save>")) strncpy(g_mounts[i].real, g_save, sizeof g_mounts[i].real - 1);
}

static void add_mount(int kind, const char *real, const char *point, const char *key, int append) {
  Mount *m;
  if (g_nmounts >= MAX_MOUNTS) return;
  if (append) m = &g_mounts[g_nmounts];
  else { memmove(&g_mounts[1], &g_mounts[0], sizeof(Mount) * g_nmounts); m = &g_mounts[0]; }
  g_nmounts++;
  memset(m, 0, sizeof *m);
  m->kind = kind;
  if (real) {
    strncpy(m->real, real, sizeof m->real - 2);
    if (m->real[0] && m->real[strlen(m->real) - 1] != '/') strcat(m->real, "/");
  }
  normalize(point ? point : "", m->point, sizeof m->point);
  strncpy(m->key, key, sizeof m->key - 1);
}

int fs_init(const char *argv0, const char *base_dir, const char *save_dir) {
  (void)argv0;
  strncpy(g_base, base_dir, sizeof g_base - 1);
  strncpy(g_save_root, save_dir, sizeof g_save_root - 1);
  snprintf(g_source, sizeof g_source, "%sgame/", g_base);
  g_nmounts = 0;
  add_mount(M_DIR, "", "", "<save>", 1);
  set_save_mount();
  if (is_dir_real(g_source)) add_mount(M_DIR, g_source, "", "<source>", 1);
  if (g_pak || pak_open(plat_self_path())) add_mount(M_PAK, NULL, "", "<pak>", 1);
  else {
    char p[600];
    snprintf(p, sizeof p, "%sgame.pak", g_base);
    if (pak_open(p)) add_mount(M_PAK, NULL, "", "<pak>", 1);
  }
  return g_pak != NULL || is_dir_real(g_source);
}

/* rel path inside mount m, or NULL when the mount does not cover path */
static const char *in_mount(const Mount *m, const char *path) {
  size_t pl = strlen(m->point);
  if (!pl) return path;
  if (strncmp(path, m->point, pl)) return NULL;
  if (path[pl] == 0) return path + pl;
  if (path[pl] == '/') return path + pl + 1;
  return NULL;
}

typedef struct Found {
  int kind;       /* -1 none, M_DIR, M_PAK */
  int is_dir;
  long size;
  long mtime;
  char real[800];
  PakEntry *ent;
  const Mount *mount;
} Found;

static int resolve(const char *raw, Found *f) {
  char path[600];
  int i;
  normalize(raw, path, sizeof path);
  f->kind = -1;
  for (i = 0; i < g_nmounts; i++) {
    const Mount *m = &g_mounts[i];
    const char *rel = in_mount(m, path);
    if (!rel) continue;
    if (m->kind == M_DIR) {
      struct stat st;
      snprintf(f->real, sizeof f->real, "%s%s", m->real, rel);
      if (!*rel) { size_t l = strlen(f->real); if (l > 1 && f->real[l - 1] == '/') f->real[l - 1] = 0; }
      if (stat(f->real, &st) == 0) {
        f->kind = M_DIR; f->mount = m;
        f->is_dir = S_ISDIR(st.st_mode);
        f->size = (long)st.st_size;
        f->mtime = (long)st.st_mtime;
        return 1;
      }
    } else {
      PakEntry *e;
      if (!*rel) { f->kind = M_PAK; f->is_dir = 1; f->size = 0; f->mtime = 0; f->ent = NULL; f->mount = m; return 1; }
      e = pak_find(rel);
      if (e) {
        f->kind = M_PAK; f->ent = e; f->mount = m;
        f->is_dir = (e->flags & 1) != 0;
        f->size = (long)e->size; f->mtime = 0;
        return 1;
      }
    }
  }
  return 0;
}

char *fs_read(const char *path, size_t *len) {
  Found f;
  if (!resolve(path, &f) || f.is_dir) return NULL;
  if (f.kind == M_PAK) return pak_read(f.ent, len);
  {
    FILE *fp = fopen(f.real, "rb");
    char *buf;
    long n;
    if (!fp) return NULL;
    fseek(fp, 0, SEEK_END); n = ftell(fp); fseek(fp, 0, SEEK_SET);
    if (n < 0) { fclose(fp); return NULL; }
    buf = (char *)malloc((size_t)n + 1);
    if (!buf) { fclose(fp); return NULL; }
    if (n && fread(buf, 1, (size_t)n, fp) != (size_t)n) { free(buf); fclose(fp); return NULL; }
    buf[n] = 0;
    fclose(fp);
    if (len) *len = (size_t)n;
    return buf;
  }
}

int fs_exists(const char *path) { Found f; return resolve(path, &f); }

/* feed a file to cb in 64 KiB pieces without loading it whole */
int fs_stream(const char *path, void (*cb)(void *, const unsigned char *, size_t), void *ud) {
  Found f;
  static unsigned char buf[65536];
  if (!resolve(path, &f) || f.is_dir) return 0;
  if (f.kind == M_PAK) {
    uint32_t left = f.ent->size;
    if (fseek(g_pak, g_pak_base + (long)f.ent->off, SEEK_SET)) return 0;
    while (left) {
      size_t n = left < sizeof buf ? left : sizeof buf;
      if (fread(buf, 1, n, g_pak) != n) return 0;
      cb(ud, buf, n);
      left -= (uint32_t)n;
    }
    return 1;
  }
  {
    FILE *fp = fopen(f.real, "rb");
    size_t n;
    if (!fp) return 0;
    while ((n = fread(buf, 1, sizeof buf, fp)) > 0) cb(ud, buf, n);
    fclose(fp);
    return 1;
  }
}

static void save_path(const char *raw, char *out, size_t n) {
  char path[600];
  normalize(raw, path, sizeof path);
  snprintf(out, n, "%s%s", g_save, path);
}

/* ------------------------------------------------------------ Blob types */

static int blob_gc(lua_State *L) {
  Blob *b = (Blob *)lua_touserdata(L, 1);
  if (b->data) { free(b->data); b->data = NULL; }
  return 0;
}
static int blob_getString(lua_State *L) {
  Blob *b = (Blob *)lua_touserdata(L, 1);
  if (!b->data) { lua_pushliteral(L, ""); return 1; }
  if (!lua_isnoneornil(L, 2)) {
    lua_Integer off = luaL_optinteger(L, 2, 0), sz = luaL_optinteger(L, 3, (lua_Integer)b->len - off);
    if (off < 0) off = 0;
    if (off > (lua_Integer)b->len) off = (lua_Integer)b->len;
    if (sz > (lua_Integer)b->len - off) sz = (lua_Integer)b->len - off;
    lua_pushlstring(L, b->data + off, (size_t)sz);
    return 1;
  }
  lua_pushlstring(L, b->data, b->len);
  return 1;
}
static int blob_getSize(lua_State *L) { Blob *b = (Blob *)lua_touserdata(L, 1); lua_pushinteger(L, (lua_Integer)b->len); return 1; }
static int blob_getPointer(lua_State *L) { Blob *b = (Blob *)lua_touserdata(L, 1); lua_pushlightuserdata(L, b->data); return 1; }
static int blob_getFilename(lua_State *L) { Blob *b = (Blob *)lua_touserdata(L, 1); lua_pushstring(L, b->name); return 1; }
static int blob_getExtension(lua_State *L) {
  Blob *b = (Blob *)lua_touserdata(L, 1);
  const char *dot = strrchr(b->name, '.');
  lua_pushstring(L, dot ? dot + 1 : "");
  return 1;
}
static int blob_clone(lua_State *L);

static const luaL_Reg blob_methods[] = {
  {"getString", blob_getString}, {"getSize", blob_getSize}, {"getPointer", blob_getPointer},
  {"getFFIPointer", blob_getPointer}, {"getFilename", blob_getFilename},
  {"getExtension", blob_getExtension}, {"clone", blob_clone}, {NULL, NULL}};
static const char *const filedata_chain[] = {"Data", NULL};
const LPType lp_FileData_type = {"FileData", filedata_chain, blob_methods, blob_gc};
const LPType lp_ByteData_type = {"ByteData", filedata_chain, blob_methods, blob_gc};

Blob *blob_push(lua_State *L, const LPType *t, const void *data, size_t len, const char *name) {
  Blob *b = (Blob *)lp_newobj(L, t, sizeof(Blob));
  b->data = (char *)malloc(len + 1);
  if (!b->data) luaL_error(L, "out of memory (%d bytes)", (int)len);
  if (data) memcpy(b->data, data, len); else memset(b->data, 0, len);
  b->data[len] = 0;
  b->len = len;
  if (name) strncpy(b->name, name, sizeof b->name - 1);
  return b;
}

static int blob_clone(lua_State *L) {
  Blob *b = (Blob *)lua_touserdata(L, 1);
  lua_getmetatable(L, 1);
  lua_getfield(L, -1, "__typename");
  blob_push(L, !strcmp(lua_tostring(L, -1), "FileData") ? &lp_FileData_type : &lp_ByteData_type,
            b->data, b->len, b->name);
  return 1;
}

/* bytes of a Data-ish argument (string, FileData/ByteData, or anything
 * with :getString()) -- pushes the string it used onto the stack */
static const char *data_arg(lua_State *L, int idx, size_t *len) {
  Blob *b;
  if (lua_type(L, idx) == LUA_TSTRING) { lua_pushvalue(L, idx); return lua_tolstring(L, -1, len); }
  b = (Blob *)lp_testobj(L, idx, &lp_FileData_type);
  if (!b) b = (Blob *)lp_testobj(L, idx, &lp_ByteData_type);
  if (b) { lua_pushlstring(L, b->data, b->len); return lua_tolstring(L, -1, len); }
  if (luaL_getmetafield(L, idx, "__index") != LUA_TNIL) {
    lua_getfield(L, -1, "getString");
    lua_remove(L, -2);
    if (lua_isfunction(L, -1)) {
      lua_pushvalue(L, idx);
      lua_call(L, 1, 1);
      return lua_tolstring(L, -1, len);
    }
    lua_pop(L, 1);
  }
  luaL_argerror(L, idx, "string or Data expected");
  return NULL;
}

char *lp_read_source(lua_State *L, int idx, size_t *len, const char **name) {
  Blob *b = (Blob *)lp_testobj(L, idx, &lp_FileData_type);
  if (!b) b = (Blob *)lp_testobj(L, idx, &lp_ByteData_type);
  if (b) {
    char *c = (char *)malloc(b->len + 1);
    if (!c) return NULL;
    memcpy(c, b->data, b->len); c[b->len] = 0;
    *len = b->len;
    if (name) *name = b->name;
    return c;
  }
  if (lua_type(L, idx) == LUA_TSTRING) {
    const char *p = lua_tostring(L, idx);
    char *buf = fs_read(p, len);
    if (name) *name = p;
    if (!buf) luaL_error(L, "Could not open file %s. Does not exist.", p);
    return buf;
  }
  luaL_argerror(L, idx, "filename or FileData expected");
  return NULL;
}

/* ------------------------------------------------------------ File */

typedef struct LFile {
  char path[600];
  char mode; /* 'c' closed, 'r', 'w', 'a' */
  char *buf; size_t len, pos; /* read mode: whole content */
  FILE *fp;                   /* write/append */
} LFile;

static LPType g_file_type; /* filled in by lp_open_filesystem */

static int file_close_impl(LFile *f) {
  int ok = f->mode != 'c';
  if (f->buf) { free(f->buf); f->buf = NULL; }
  if (f->fp) { fclose(f->fp); f->fp = NULL; }
  f->mode = 'c';
  return ok;
}

static int file_gc(lua_State *L) { file_close_impl((LFile *)lua_touserdata(L, 1)); return 0; }

static int file_open_impl(lua_State *L, LFile *f, const char *mode) {
  file_close_impl(f);
  if (mode[0] == 'r') {
    f->buf = fs_read(f->path, &f->len);
    if (!f->buf) { lua_pushboolean(L, 0); lua_pushfstring(L, "Could not open file %s. Does not exist.", f->path); return 2; }
    f->pos = 0; f->mode = 'r';
  } else if (mode[0] == 'w' || mode[0] == 'a') {
    char real[700], dir[700], *slash;
    save_path(f->path, real, sizeof real);
    strcpy(dir, real);
    slash = strrchr(dir, '/');
    if (slash) { *slash = 0; mkdirs(dir); }
    f->fp = fopen(real, mode[0] == 'w' ? "wb" : "ab");
    if (!f->fp) { lua_pushboolean(L, 0); lua_pushfstring(L, "Could not open file %s (%s)", f->path, strerror(errno)); return 2; }
    f->mode = mode[0];
  } else {
    lua_pushboolean(L, 1);
    return 1;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static LFile *checkfile(lua_State *L) { return (LFile *)lp_checkobj(L, 1, &g_file_type); }

static int file_open(lua_State *L) { LFile *f = checkfile(L); return file_open_impl(L, f, luaL_checkstring(L, 2)); }
static int file_close(lua_State *L) { lua_pushboolean(L, file_close_impl(checkfile(L))); return 1; }
static int file_isOpen(lua_State *L) { lua_pushboolean(L, checkfile(L)->mode != 'c'); return 1; }
static int file_getMode(lua_State *L) {
  LFile *f = checkfile(L);
  lua_pushstring(L, f->mode == 'r' ? "r" : f->mode == 'w' ? "w" : f->mode == 'a' ? "a" : "c");
  return 1;
}
static int file_getFilename(lua_State *L) { lua_pushstring(L, checkfile(L)->path); return 1; }
static int file_getSize(lua_State *L) {
  LFile *f = checkfile(L);
  if (f->mode == 'r') lua_pushinteger(L, (lua_Integer)f->len);
  else if (f->fp) { long p = ftell(f->fp); fseek(f->fp, 0, SEEK_END); lua_pushinteger(L, ftell(f->fp)); fseek(f->fp, p, SEEK_SET); }
  else { Found fd; lua_pushinteger(L, resolve(f->path, &fd) ? fd.size : 0); }
  return 1;
}
static int file_read(lua_State *L) {
  LFile *f = checkfile(L);
  size_t n;
  int as_data = 0, argi = 2;
  if (lua_type(L, 2) == LUA_TSTRING && !lua_isnumber(L, 2)) {
    as_data = !strcmp(lua_tostring(L, 2), "data");
    argi = 3;
  }
  if (f->mode == 'c') {
    int r = file_open_impl(L, f, "r");
    if (!lua_toboolean(L, -r)) return luaL_error(L, "%s", lua_tostring(L, -1));
    lua_pop(L, r);
  }
  if (f->mode != 'r') return luaL_error(L, "File is not opened for reading.");
  n = f->len - f->pos;
  if (!lua_isnoneornil(L, argi)) {
    lua_Integer want = luaL_checkinteger(L, argi);
    if (want >= 0 && (size_t)want < n) n = (size_t)want;
  }
  if (as_data) blob_push(L, &lp_FileData_type, f->buf + f->pos, n, f->path);
  else lua_pushlstring(L, f->buf + f->pos, n);
  f->pos += n;
  lua_pushinteger(L, (lua_Integer)n);
  return 2;
}
static int file_write(lua_State *L) {
  LFile *f = checkfile(L);
  size_t len;
  lua_Integer want = luaL_optinteger(L, 3, -1);
  const char *d = data_arg(L, 2, &len);
  if (want >= 0 && (size_t)want < len) len = (size_t)want;
  if (!f->fp) return luaL_error(L, "File is not opened for writing.");
  lua_pushboolean(L, fwrite(d, 1, len, f->fp) == len);
  return 1;
}
static int file_flush(lua_State *L) { LFile *f = checkfile(L); if (f->fp) fflush(f->fp); lua_pushboolean(L, 1); return 1; }
static int file_seek(lua_State *L) {
  LFile *f = checkfile(L);
  lua_Integer p = luaL_checkinteger(L, 2);
  if (f->mode == 'r') { if (p < 0 || (size_t)p > f->len) { lua_pushboolean(L, 0); return 1; } f->pos = (size_t)p; }
  else if (f->fp) fseek(f->fp, (long)p, SEEK_SET);
  lua_pushboolean(L, 1);
  return 1;
}
static int file_tell(lua_State *L) {
  LFile *f = checkfile(L);
  lua_pushinteger(L, f->mode == 'r' ? (lua_Integer)f->pos : f->fp ? ftell(f->fp) : 0);
  return 1;
}
static int file_isEOF(lua_State *L) { LFile *f = checkfile(L); lua_pushboolean(L, f->mode != 'r' || f->pos >= f->len); return 1; }
static int file_setBuffer(lua_State *L) { (void)L; lua_pushboolean(L, 1); return 1; }
static int file_getBuffer(lua_State *L) { lua_pushstring(L, "none"); lua_pushinteger(L, 0); return 2; }

static int lines_iter(lua_State *L) {
  LFile *f = (LFile *)lua_touserdata(L, lua_upvalueindex(1));
  size_t start, end;
  if (f->mode != 'r' || f->pos >= f->len) {
    if (lua_toboolean(L, lua_upvalueindex(2))) file_close_impl(f);
    return 0;
  }
  start = f->pos;
  end = start;
  while (end < f->len && f->buf[end] != '\n') end++;
  f->pos = end < f->len ? end + 1 : end;
  if (end > start && f->buf[end - 1] == '\r') end--;
  lua_pushlstring(L, f->buf + start, end - start);
  return 1;
}

static int file_lines(lua_State *L) {
  LFile *f = checkfile(L);
  if (f->mode != 'r') {
    int r = file_open_impl(L, f, "r");
    if (!lua_toboolean(L, -r)) return luaL_error(L, "%s", lua_tostring(L, -1));
    lua_pop(L, r);
  }
  lua_pushvalue(L, 1);
  lua_pushboolean(L, 0);
  lua_pushcclosure(L, lines_iter, 2);
  return 1;
}

static const luaL_Reg file_methods[] = {
  {"open", file_open}, {"close", file_close}, {"isOpen", file_isOpen}, {"getMode", file_getMode},
  {"getFilename", file_getFilename}, {"getSize", file_getSize}, {"read", file_read},
  {"write", file_write}, {"flush", file_flush}, {"seek", file_seek}, {"tell", file_tell},
  {"isEOF", file_isEOF}, {"eof", file_isEOF}, {"setBuffer", file_setBuffer},
  {"getBuffer", file_getBuffer}, {"lines", file_lines}, {NULL, NULL}};

static LFile *file_new(lua_State *L, const char *path) {
  LFile *f = (LFile *)lp_newobj(L, &g_file_type, sizeof(LFile));
  normalize(path, f->path, sizeof f->path);
  f->mode = 'c';
  return f;
}

/* ------------------------------------------------------------ module functions */

static int fs_newFile(lua_State *L) {
  LFile *f = file_new(L, luaL_checkstring(L, 1));
  if (!lua_isnoneornil(L, 2)) {
    int r = file_open_impl(L, f, luaL_checkstring(L, 2));
    if (!lua_toboolean(L, -r)) { lua_pushnil(L); lua_pushvalue(L, -2); return 2; }
    lua_pop(L, r);
  }
  return 1;
}

static int fs_read_l(lua_State *L) {
  int argi = 1, as_data = 0;
  const char *path;
  size_t len;
  char *buf;
  if (lua_gettop(L) >= 2 && lua_type(L, 2) == LUA_TSTRING) {
    as_data = !strcmp(luaL_checkstring(L, 1), "data");
    argi = 2;
  }
  path = luaL_checkstring(L, argi);
  buf = fs_read(path, &len);
  if (!buf) { lua_pushnil(L); lua_pushfstring(L, "Could not open file %s. Does not exist.", path); return 2; }
  if (!lua_isnoneornil(L, argi + 1)) {
    lua_Integer want = luaL_checkinteger(L, argi + 1);
    if (want >= 0 && (size_t)want < len) len = (size_t)want;
  }
  if (as_data) blob_push(L, &lp_FileData_type, buf, len, path);
  else lua_pushlstring(L, buf, len);
  free(buf);
  lua_pushinteger(L, (lua_Integer)len);
  return 2;
}

/* real path of a save-relative file, for the native downloader/unzipper */
void fs_save_real(const char *rel, char *out, size_t n) {
  char dir[700], *slash;
  save_path(rel, out, n);
  strcpy(dir, out);
  slash = strrchr(dir, '/');
  if (slash) { *slash = 0; mkdirs(dir); }
}

static int write_impl(lua_State *L, const char *mode) {
  const char *path = luaL_checkstring(L, 1);
  size_t len;
  lua_Integer want = luaL_optinteger(L, 3, -1);
  const char *d = data_arg(L, 2, &len);
  char real[700], dir[700], *slash;
  FILE *fp;
  if (want >= 0 && (size_t)want < len) len = (size_t)want;
  save_path(path, real, sizeof real);
  strcpy(dir, real);
  slash = strrchr(dir, '/');
  if (slash) { *slash = 0; mkdirs(dir); }
  fp = fopen(real, mode);
  if (!fp) { lua_pushboolean(L, 0); lua_pushfstring(L, "Could not open file %s (%s)", path, strerror(errno)); return 2; }
  if (len && fwrite(d, 1, len, fp) != len) { fclose(fp); lua_pushboolean(L, 0); lua_pushliteral(L, "write failed"); return 2; }
  fclose(fp);
  lua_pushboolean(L, 1);
  return 1;
}
static int fs_write_l(lua_State *L) { return write_impl(L, "wb"); }
static int fs_append_l(lua_State *L) { return write_impl(L, "ab"); }

static int fs_getInfo(lua_State *L) {
  Found f;
  const char *filter = NULL;
  int tidx = 0;
  if (lua_type(L, 2) == LUA_TSTRING) filter = lua_tostring(L, 2);
  else if (lua_istable(L, 2)) tidx = 2;
  if (lua_istable(L, 3)) tidx = 3;
  if (!resolve(luaL_checkstring(L, 1), &f)) { lua_pushnil(L); return 1; }
  if (filter) {
    if (!strcmp(filter, "file") && f.is_dir) { lua_pushnil(L); return 1; }
    if (!strcmp(filter, "directory") && !f.is_dir) { lua_pushnil(L); return 1; }
    if (!strcmp(filter, "symlink")) { lua_pushnil(L); return 1; }
  }
  if (tidx) lua_pushvalue(L, tidx); else lua_createtable(L, 0, 3);
  lua_pushstring(L, f.is_dir ? "directory" : "file"); lua_setfield(L, -2, "type");
  if (!f.is_dir) { lua_pushinteger(L, f.size); lua_setfield(L, -2, "size"); }
  if (f.mtime) { lua_pushinteger(L, f.mtime); lua_setfield(L, -2, "modtime"); }
  return 1;
}

static int fs_exists_l(lua_State *L) { lua_pushboolean(L, fs_exists(luaL_checkstring(L, 1))); return 1; }
static int fs_isDirectory(lua_State *L) { Found f; lua_pushboolean(L, resolve(luaL_checkstring(L, 1), &f) && f.is_dir); return 1; }
static int fs_isFile(lua_State *L) { Found f; lua_pushboolean(L, resolve(luaL_checkstring(L, 1), &f) && !f.is_dir); return 1; }
static int fs_getSize(lua_State *L) { Found f; if (!resolve(luaL_checkstring(L, 1), &f)) return luaL_error(L, "file does not exist"); lua_pushinteger(L, f.size); return 1; }
static int fs_getLastModified(lua_State *L) { Found f; if (!resolve(luaL_checkstring(L, 1), &f)) { lua_pushnil(L); return 1; } lua_pushinteger(L, f.mtime); return 1; }

static void add_item(lua_State *L, int set, int list, const char *name) {
  size_t n;
  lua_getfield(L, set, name);
  if (!lua_isnil(L, -1)) { lua_pop(L, 1); return; }
  lua_pop(L, 1);
  lua_pushboolean(L, 1); lua_setfield(L, set, name);
  n = lua_rawlen(L, list);
  lua_pushstring(L, name); lua_rawseti(L, list, (lua_Integer)n + 1);
}

static int fs_getDirectoryItems(lua_State *L) {
  char path[600];
  int i, set, list;
  size_t plen;
  normalize(luaL_checkstring(L, 1), path, sizeof path);
  plen = strlen(path);
  lua_newtable(L); list = lua_gettop(L);
  lua_newtable(L); set = lua_gettop(L);
  for (i = 0; i < g_nmounts; i++) {
    const Mount *m = &g_mounts[i];
    const char *rel = in_mount(m, path);
    if (!rel) {
      /* path is a parent of this mount point: expose the next component */
      size_t ml = strlen(m->point);
      if (ml > plen && (plen == 0 || (!strncmp(m->point, path, plen) && m->point[plen] == '/'))) {
        char comp[256];
        const char *s = m->point + (plen ? plen + 1 : 0);
        size_t k = 0;
        while (s[k] && s[k] != '/' && k < sizeof comp - 1) { comp[k] = s[k]; k++; }
        comp[k] = 0;
        if (k) add_item(L, set, list, comp);
      }
      continue;
    }
    if (m->kind == M_DIR) {
      char real[900];
      DIR *d;
      struct dirent *de;
      snprintf(real, sizeof real, "%s%s", m->real, rel);
      d = opendir(real);
      if (!d) continue;
      while ((de = readdir(d)) != NULL) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        add_item(L, set, list, de->d_name);
      }
      closedir(d);
    } else if (g_pak) {
      char prefix[600];
      size_t pl;
      uint32_t k;
      if (*rel) snprintf(prefix, sizeof prefix, "%s/", rel); else prefix[0] = 0;
      pl = strlen(prefix);
      for (k = pak_lower(prefix); k < g_nents; k++) {
        const char *n = g_ents[k].name;
        if (strncmp(n, prefix, pl)) break;
        if (!n[pl] || strchr(n + pl, '/')) continue;
        add_item(L, set, list, n + pl);
      }
    }
  }
  lua_pop(L, 1);
  return 1;
}

static int fs_createDirectory(lua_State *L) {
  char real[700];
  save_path(luaL_checkstring(L, 1), real, sizeof real);
  mkdirs(real);
  lua_pushboolean(L, is_dir_real(real));
  return 1;
}

static int fs_remove(lua_State *L) {
  char real[700];
  struct stat st;
  save_path(luaL_checkstring(L, 1), real, sizeof real);
  if (stat(real, &st) != 0) { lua_pushboolean(L, 0); return 1; }
  if (S_ISDIR(st.st_mode)) lua_pushboolean(L, rmdir(real) == 0);
  else lua_pushboolean(L, remove(real) == 0);
  return 1;
}

static int fs_load(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  size_t len;
  char *buf = fs_read(path, &len);
  int r;
  if (!buf) { lua_pushnil(L); lua_pushfstring(L, "Could not open file %s. Does not exist.", path); return 2; }
  lua_pushfstring(L, "@%s", path);
  r = luaL_loadbufferx(L, buf, len, lua_tostring(L, -1), NULL);
  free(buf);
  if (r != LUA_OK) { lua_pushnil(L); lua_insert(L, -2); return 2; }
  return 1;
}

static int fs_lines(lua_State *L) {
  LFile *f = file_new(L, luaL_checkstring(L, 1));
  int r = file_open_impl(L, f, "r");
  if (!lua_toboolean(L, -r)) return luaL_error(L, "%s", lua_tostring(L, -1));
  lua_pop(L, r);
  lua_pushboolean(L, 1);
  lua_pushcclosure(L, lines_iter, 2);
  return 1;
}

static int fs_newFileData(lua_State *L) {
  if (lua_gettop(L) >= 2) {
    size_t len;
    const char *d = data_arg(L, 1, &len);
    blob_push(L, &lp_FileData_type, d, len, luaL_checkstring(L, 2));
    return 1;
  }
  if (lp_testobj(L, 1, &g_file_type)) {
    LFile *f = (LFile *)lua_touserdata(L, 1);
    size_t len; char *buf = fs_read(f->path, &len);
    if (!buf) { lua_pushnil(L); lua_pushliteral(L, "could not read file"); return 2; }
    blob_push(L, &lp_FileData_type, buf, len, f->path);
    free(buf);
    return 1;
  }
  {
    const char *path = luaL_checkstring(L, 1);
    size_t len; char *buf = fs_read(path, &len);
    if (!buf) { lua_pushnil(L); lua_pushfstring(L, "Could not open file %s. Does not exist.", path); return 2; }
    blob_push(L, &lp_FileData_type, buf, len, path);
    free(buf);
    return 1;
  }
}

static int fs_mount(lua_State *L) {
  const char *arch = luaL_checkstring(L, 1);
  const char *point = luaL_optstring(L, 2, "");
  int append = lua_toboolean(L, 3);
  char real[800];
  int i;
  size_t sl = strlen(g_save), bl = strlen(g_base);
  for (i = 0; i < g_nmounts; i++)
    if (!strcmp(g_mounts[i].key, arch)) { lua_pushboolean(L, 1); return 1; }
  /* absolute path inside the save or base directory, or a save-relative dir */
  if (!strncmp(arch, g_save, sl - 1) || !strncmp(arch, g_base, bl - 1)
      || arch[0] == '/' || strstr(arch, ":/")) {
    strncpy(real, arch, sizeof real - 1); real[sizeof real - 1] = 0;
  } else {
    save_path(arch, real, sizeof real);
  }
  if (!is_dir_real(real)) { lua_pushboolean(L, 0); return 1; }
  add_mount(M_DIR, real, point, arch, append);
  lua_getfield(L, lua_upvalueindex(1), "_mounts");
  if (lua_istable(L, -1)) { lua_pushstring(L, point); lua_setfield(L, -2, arch); }
  lua_pushboolean(L, 1);
  return 1;
}

static int fs_unmount(lua_State *L) {
  const char *arch = luaL_checkstring(L, 1);
  int i;
  for (i = 0; i < g_nmounts; i++) {
    if (!strcmp(g_mounts[i].key, arch) && g_mounts[i].key[0] != '<') {
      memmove(&g_mounts[i], &g_mounts[i + 1], sizeof(Mount) * (g_nmounts - i - 1));
      g_nmounts--;
      lua_getfield(L, lua_upvalueindex(1), "_mounts");
      if (lua_istable(L, -1)) { lua_pushnil(L); lua_setfield(L, -2, arch); }
      lua_pushboolean(L, 1);
      return 1;
    }
  }
  lua_pushboolean(L, 0);
  return 1;
}

static int fs_getRealDirectory(lua_State *L) {
  Found f;
  if (!resolve(luaL_checkstring(L, 1), &f)) { lua_pushnil(L); lua_pushliteral(L, "File does not exist"); return 2; }
  if (f.kind == M_PAK) lua_pushstring(L, g_pak_path);
  else {
    char d[600];
    strncpy(d, f.mount->real, sizeof d - 1); d[sizeof d - 1] = 0;
    if (strlen(d) > 1 && d[strlen(d) - 1] == '/') d[strlen(d) - 1] = 0;
    lua_pushstring(L, d);
  }
  return 1;
}

static void push_dir(lua_State *L, const char *d) {
  size_t l = strlen(d);
  if (l > 1 && d[l - 1] == '/') lua_pushlstring(L, d, l - 1); else lua_pushstring(L, d);
}
static int fs_getSaveDirectory(lua_State *L) { push_dir(L, g_save); return 1; }
static int fs_getSource(lua_State *L) { if (g_pak) lua_pushstring(L, g_pak_path); else push_dir(L, g_source); return 1; }
static int fs_getBaseDir(lua_State *L) { push_dir(L, g_base); return 1; }
static int fs_getIdentity(lua_State *L) { lua_pushstring(L, g_identity); return 1; }
static int fs_setIdentity(lua_State *L) {
  strncpy(g_identity, luaL_checkstring(L, 1), sizeof g_identity - 1);
  set_save_mount();
  return 0;
}
static int fs_true(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static int fs_false(lua_State *L) { lua_pushboolean(L, 0); return 1; }
static int fs_noop(lua_State *L) { (void)L; return 0; }
static int fs_getRequirePath(lua_State *L) { lua_pushstring(L, g_require_path); return 1; }
static int fs_setRequirePath(lua_State *L) { strncpy(g_require_path, luaL_checkstring(L, 1), sizeof g_require_path - 1); return 0; }
static int fs_getCRequirePath(lua_State *L) { lua_pushliteral(L, "??"); return 1; }

/* package.searchers entry */
static int fs_searcher(lua_State *L) {
  const char *mod = luaL_checkstring(L, 1);
  char name[400], tmpl[512], path[800], *tok, *save;
  size_t i, len;
  char *buf;
  strncpy(name, mod, sizeof name - 1); name[sizeof name - 1] = 0;
  for (i = 0; name[i]; i++) if (name[i] == '.') name[i] = '/';
  strncpy(tmpl, g_require_path, sizeof tmpl - 1); tmpl[sizeof tmpl - 1] = 0;
  for (tok = strtok_r(tmpl, ";", &save); tok; tok = strtok_r(NULL, ";", &save)) {
    char *q = strchr(tok, '?');
    size_t o = 0;
    if (!q) continue;
    for (i = 0; tok[i] && o < sizeof path - 1; i++) {
      if (tok[i] == '?') { size_t n = strlen(name); if (o + n >= sizeof path) break; memcpy(path + o, name, n); o += n; }
      else path[o++] = tok[i];
    }
    path[o] = 0;
    buf = fs_read(path, &len);
    if (buf) {
      int r;
      lua_pushfstring(L, "@%s", path);
      r = luaL_loadbufferx(L, buf, len, lua_tostring(L, -1), NULL);
      free(buf);
      if (r != LUA_OK) return lua_error(L);
      lua_pushstring(L, path);
      return 2;
    }
  }
  lua_pushfstring(L, "\n\tno '%s' in LOVE game directories.", name);
  return 1;
}

static const luaL_Reg fs_funcs[] = {
  {"newFile", fs_newFile}, {"read", fs_read_l}, {"write", fs_write_l}, {"append", fs_append_l},
  {"getInfo", fs_getInfo}, {"exists", fs_exists_l}, {"isDirectory", fs_isDirectory},
  {"isFile", fs_isFile}, {"getSize", fs_getSize}, {"getLastModified", fs_getLastModified},
  {"getDirectoryItems", fs_getDirectoryItems}, {"createDirectory", fs_createDirectory},
  {"remove", fs_remove}, {"load", fs_load}, {"lines", fs_lines}, {"newFileData", fs_newFileData},
  {"getRealDirectory", fs_getRealDirectory}, {"getSaveDirectory", fs_getSaveDirectory},
  {"getSource", fs_getSource}, {"getSourceBaseDirectory", fs_getBaseDir},
  {"getUserDirectory", fs_getBaseDir}, {"getAppdataDirectory", fs_getBaseDir},
  {"getWorkingDirectory", fs_getBaseDir}, {"getIdentity", fs_getIdentity},
  {"setIdentity", fs_setIdentity}, {"isFused", fs_true}, {"areSymlinksEnabled", fs_false},
  {"setSymlinksEnabled", fs_noop}, {"isSymlink", fs_false}, {"init", fs_noop},
  {"setSource", fs_noop}, {"setFused", fs_noop}, {"getRequirePath", fs_getRequirePath},
  {"setRequirePath", fs_setRequirePath}, {"getCRequirePath", fs_getCRequirePath},
  {"setCRequirePath", fs_noop}, {NULL, NULL}};

int lp_open_filesystem(lua_State *L) {
  g_file_type.name = "File";
  g_file_type.chain = NULL;
  g_file_type.methods = file_methods;
  g_file_type.gc = file_gc;
  lp_register_type(L, &g_file_type);
  lp_register_type(L, &lp_FileData_type);
  lp_register_type(L, &lp_ByteData_type);
  lua_newtable(L);
  lua_pushvalue(L, -1);
  luaL_setfuncs(L, fs_funcs, 0);
  lua_pop(L, 1);
  /* mount/unmount keep love.filesystem._mounts in step (CacheFs reads it) */
  lua_newtable(L); lua_setfield(L, -2, "_mounts");
  lua_pushvalue(L, -1); lua_pushcclosure(L, fs_mount, 1); lua_setfield(L, -2, "mount");
  lua_pushvalue(L, -1); lua_pushcclosure(L, fs_unmount, 1); lua_setfield(L, -2, "unmount");
  /* install the searcher at package.searchers[2], as LÖVE does */
  lua_getglobal(L, "table");
  lua_getfield(L, -1, "insert");
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchers");
  lua_remove(L, -2);
  lua_pushinteger(L, 2);
  lua_pushcfunction(L, fs_searcher);
  lua_call(L, 3, 0);
  lua_pop(L, 1);
  return 1;
}
