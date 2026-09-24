/* Minimal zip extraction (stored and deflate entries) for mod updates;
 * inflate comes from stb_image's zlib decoder. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "stb_image.h"

static unsigned rd16(const unsigned char *p) { return p[0] | (p[1] << 8); }
static unsigned rd32(const unsigned char *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((unsigned)p[3] << 24); }

static void mkdirs(const char *path) {
  char tmp[1024];
  size_t i;
  strncpy(tmp, path, sizeof tmp - 1); tmp[sizeof tmp - 1] = 0;
  for (i = 1; tmp[i]; i++) {
    if (tmp[i] == '/') { tmp[i] = 0; mkdir(tmp, 0777); tmp[i] = '/'; }
  }
  mkdir(tmp, 0777);
}

static int safe_name(const char *n) {
  const char *p = n;
  if (!*n || *n == '/' || strchr(n, '\\') || strstr(n, "..")) return 0;
  while (*p) { if (*p < 32) return 0; p++; }
  return 1;
}

int lp_unzip(const char *zip_path, const char *dest, char *err, size_t errn) {
  FILE *fp = fopen(zip_path, "rb");
  long size;
  unsigned char *d;
  long i, cd_off = -1, cd_n = 0, k;
  int files = 0;
  if (!fp) { snprintf(err, errn, "cannot open %s", zip_path); return -1; }
  fseek(fp, 0, SEEK_END); size = ftell(fp); fseek(fp, 0, SEEK_SET);
  if (size < 22 || size > 256L * 1024 * 1024) { fclose(fp); snprintf(err, errn, "bad zip size"); return -1; }
  d = (unsigned char *)malloc((size_t)size);
  if (!d || fread(d, 1, (size_t)size, fp) != (size_t)size) { free(d); fclose(fp); snprintf(err, errn, "read failed"); return -1; }
  fclose(fp);
  for (i = size - 22; i >= 0 && i >= size - 66000; i--) {
    if (rd32(d + i) == 0x06054b50) { cd_n = rd16(d + i + 10); cd_off = (long)rd32(d + i + 16); break; }
  }
  if (cd_off < 0 || cd_off >= size) { free(d); snprintf(err, errn, "no central directory"); return -1; }
  for (k = 0, i = cd_off; k < cd_n && i + 46 <= size; k++) {
    unsigned method, csize, usize, nlen, elen, clen, loff;
    char name[512], path[1200];
    const unsigned char *lh;
    unsigned lnlen, lelen;
    if (rd32(d + i) != 0x02014b50) break;
    method = rd16(d + i + 10); csize = rd32(d + i + 20); usize = rd32(d + i + 24);
    nlen = rd16(d + i + 28); elen = rd16(d + i + 30); clen = rd16(d + i + 32);
    loff = rd32(d + i + 42);
    if (nlen >= sizeof name) { free(d); snprintf(err, errn, "name too long"); return -1; }
    memcpy(name, d + i + 46, nlen); name[nlen] = 0;
    i += 46 + nlen + elen + clen;
    if (!safe_name(name)) continue;
    if (name[nlen - 1] == '/') { snprintf(path, sizeof path, "%s/%s", dest, name); mkdirs(path); continue; }
    if ((long)loff + 30 > size) continue;
    lh = d + loff;
    if (rd32(lh) != 0x04034b50) continue;
    lnlen = rd16(lh + 26); lelen = rd16(lh + 28);
    {
      const unsigned char *data = lh + 30 + lnlen + lelen;
      unsigned char *out = NULL;
      int outlen = 0;
      char *slash;
      FILE *w;
      if ((long)(data - d) + (long)csize > size) continue;
      if (method == 0) { out = (unsigned char *)data; outlen = (int)csize; }
      else if (method == 8) {
        out = (unsigned char *)stbi_zlib_decode_noheader_malloc((const char *)data, (int)csize, &outlen);
        if (!out) { free(d); snprintf(err, errn, "inflate failed: %s", name); return -1; }
      } else { continue; }
      if ((unsigned)outlen != usize && method == 8) { free(out); free(d); snprintf(err, errn, "size mismatch: %s", name); return -1; }
      snprintf(path, sizeof path, "%s/%s", dest, name);
      slash = strrchr(path, '/');
      if (slash) { *slash = 0; mkdirs(path); *slash = '/'; }
      w = fopen(path, "wb");
      if (!w || fwrite(out, 1, (size_t)outlen, w) != (size_t)outlen) {
        if (w) fclose(w);
        if (method == 8) free(out);
        free(d); snprintf(err, errn, "cannot write %s", name); return -1;
      }
      fclose(w);
      if (method == 8) free(out);
      files++;
    }
  }
  free(d);
  return files;
}
