/*
 * lpluac: compile Lua sources to stripped Lua 5.4 bytecode for the archive.
 *
 * Built from the same Lua sources as the runtime, so the bytecode format
 * always matches.  Lua 5.4 chunks encode sizes as varints and fix
 * lua_Integer/lua_Number to 8 bytes, so a 64-bit host's output loads on the
 * 32-bit, little-endian PSP.
 *
 *   lpluac [-g] in.lua out.luac     (-g keeps debug info)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

static int writer(lua_State *L, const void *p, size_t sz, void *ud) {
  (void)L;
  return fwrite(p, 1, sz, (FILE *)ud) != sz;
}

int main(int argc, char **argv) {
  int strip = 1, a = 1;
  lua_State *L;
  FILE *out;
  const char *in, *outp, *chunkname;
  if (argc > 1 && !strcmp(argv[1], "-g")) { strip = 0; a = 2; }
  if (argc - a < 2) {
    fprintf(stderr, "usage: lpluac [-g] in.lua out.luac [chunkname]\n");
    return 2;
  }
  in = argv[a]; outp = argv[a + 1];
  chunkname = argc - a >= 3 ? argv[a + 2] : NULL;
  L = luaL_newstate();
  {
    FILE *f = fopen(in, "rb");
    char *buf;
    long n;
    int r;
    char name[1024];
    if (!f) { fprintf(stderr, "lpluac: cannot open %s\n", in); return 1; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    buf = (char *)malloc((size_t)n + 1);
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "lpluac: read error %s\n", in); return 1; }
    fclose(f);
    snprintf(name, sizeof name, "@%s", chunkname ? chunkname : in);
    /* skip a leading #! line like luaL_loadfile does (keep the newline so
     * line numbers stay right) */
    {
      long skip = 0;
      if (n > 0 && buf[0] == '#') while (skip < n && buf[skip] != '\n') skip++;
      r = luaL_loadbufferx(L, buf + skip, (size_t)(n - skip), name, "t");
    }
    free(buf);
    if (r != LUA_OK) { fprintf(stderr, "lpluac: %s\n", lua_tostring(L, -1)); return 1; }
  }
  out = fopen(outp, "wb");
  if (!out) { fprintf(stderr, "lpluac: cannot write %s\n", outp); return 1; }
  if (lua_dump(L, writer, out, strip)) { fprintf(stderr, "lpluac: dump failed\n"); return 1; }
  fclose(out);
  lua_close(L);
  return 0;
}
