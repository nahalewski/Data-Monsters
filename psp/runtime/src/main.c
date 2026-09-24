/* lovepsp entry point: bring up the platform, Lua 5.4 and the love modules,
 * then hand over to boot.lua (embedded at build time). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lp.h"
#include "plat.h"
#include "boot_lua.h" /* generated: static const char boot_lua[]; boot_lua_len */

int luaopen_lovepsp(lua_State *L);
int lp_newTransform(lua_State *L);

static int open_graphics(lua_State *L) {
  lp_open_graphics(L);
  return 1;
}

static void preload(lua_State *L, const char *name, lua_CFunction f) {
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, f);
  lua_setfield(L, -2, name);
  lua_pop(L, 1);
}

static int traceback(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  luaL_traceback(L, L, msg ? msg : "(error object is not a string)", 1);
  return 1;
}

/* last-resort error screen when boot.lua itself cannot run */
static void fatal(const char *msg) {
  Tex *b;
  plat_debug("lovepsp fatal: %s\n", msg);
  gfx_resize_backbuffer(PLAT_SCREEN_W, PLAT_SCREEN_H);
  b = gfx_backbuffer();
  if (b) {
    int i;
    for (i = 0; i < b->w * b->h; i++) b->px[i] = PX(90, 0, 0, 255);
    for (;;) {
      PlatInput in;
      plat_present(b->px, b->w, b->h, 0, 0);
      plat_poll(&in);
      if (in.quit || (in.buttons & PB_START)) break;
    }
  }
}

int main(int argc, char **argv) {
  lua_State *L;
  int status;
  if (plat_init(argc, argv) != 0) return 1;
  L = luaL_newstate();
  if (!L) { plat_debug("cannot create Lua state\n"); plat_shutdown(); return 1; }
  /* small heap: collect a little more eagerly than the default 200% pause */
  lua_gc(L, LUA_GCINC, 140, 200, 13);
  luaL_openlibs(L);

  fs_init(argc > 0 ? argv[0] : "", plat_base_dir(), plat_save_dir());

  preload(L, "lovepsp", luaopen_lovepsp);
  preload(L, "bit", luaopen_bit);
  preload(L, "love.graphics", open_graphics);
  preload(L, "love.filesystem", lp_open_filesystem);
  preload(L, "love.image", lp_open_image);
  preload(L, "love.sound", lp_open_sound);
  preload(L, "love.audio", lp_open_audio);
  lua_pushcfunction(L, lp_newTransform);
  lua_setfield(L, LUA_REGISTRYINDEX, "lovepsp.newTransform");

  lua_newtable(L);
  lua_pushstring(L, argc > 0 ? argv[0] : "EBOOT.PBP");
  lua_rawseti(L, -2, 0);
  lua_setglobal(L, "arg");

  lua_pushcfunction(L, traceback);
  if (luaL_loadbufferx(L, boot_lua, boot_lua_len, "@lovepsp/boot.lua", "t") != LUA_OK) {
    fatal(lua_tostring(L, -1));
    plat_shutdown();
    return 1;
  }
  lua_pushcfunction(L, lp_newTransform);
  status = lua_pcall(L, 1, 1, -3);
  if (status != LUA_OK) fatal(lua_tostring(L, -1));
  lua_close(L);
  plat_shutdown();
  return 0;
}
