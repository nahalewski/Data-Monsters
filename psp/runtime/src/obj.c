/* love.Object plumbing: typed userdata with LÖVE's type()/typeOf()/release(). */
#include <stdio.h>
#include <string.h>
#include "lp.h"

static int obj_type(lua_State *L) {
  lua_getmetatable(L, 1);
  lua_getfield(L, -1, "__typename");
  return 1;
}

static int obj_typeOf(lua_State *L) {
  const char *want = luaL_checkstring(L, 2);
  if (!lua_getmetatable(L, 1)) { lua_pushboolean(L, 0); return 1; }
  lua_getfield(L, -1, "__types");
  lua_getfield(L, -1, want);
  lua_pushboolean(L, lua_toboolean(L, -1));
  return 1;
}

static int obj_release(lua_State *L) {
  /* run the finalizer now; the gc hook must tolerate being called twice */
  if (lua_getmetatable(L, 1)) {
    lua_getfield(L, -1, "__gc");
    if (lua_isfunction(L, -1)) {
      lua_pushvalue(L, 1);
      lua_call(L, 1, 0);
    }
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int obj_tostring(lua_State *L) {
  lua_getmetatable(L, 1);
  lua_getfield(L, -1, "__typename");
  lua_pushfstring(L, "%s: %p", lua_tostring(L, -1), lua_touserdata(L, 1));
  return 1;
}

static int obj_eq(lua_State *L) {
  lua_pushboolean(L, lua_touserdata(L, 1) == lua_touserdata(L, 2));
  return 1;
}

void lp_register_type(lua_State *L, const LPType *t) {
  char key[64];
  int i;
  snprintf(key, sizeof key, "love.%s", t->name);
  if (!luaL_newmetatable(L, key)) { lua_pop(L, 1); return; }
  lua_pushstring(L, t->name);
  lua_setfield(L, -2, "__typename");
  /* __types set */
  lua_newtable(L);
  lua_pushboolean(L, 1); lua_setfield(L, -2, t->name);
  lua_pushboolean(L, 1); lua_setfield(L, -2, "Object");
  for (i = 0; t->chain && t->chain[i]; i++) {
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, t->chain[i]);
  }
  lua_setfield(L, -2, "__types");
  /* methods table as __index */
  lua_newtable(L);
  luaL_setfuncs(L, t->methods, 0);
  lua_pushcfunction(L, obj_type); lua_setfield(L, -2, "type");
  lua_pushcfunction(L, obj_typeOf); lua_setfield(L, -2, "typeOf");
  lua_pushcfunction(L, obj_release); lua_setfield(L, -2, "release");
  lua_setfield(L, -2, "__index");
  if (t->gc) { lua_pushcfunction(L, t->gc); lua_setfield(L, -2, "__gc"); }
  lua_pushcfunction(L, obj_tostring); lua_setfield(L, -2, "__tostring");
  lua_pushcfunction(L, obj_eq); lua_setfield(L, -2, "__eq");
  lua_pop(L, 1);
}

void *lp_newobj(lua_State *L, const LPType *t, size_t size) {
  char key[64];
  void *p = lua_newuserdatauv(L, size, 4);
  memset(p, 0, size);
  snprintf(key, sizeof key, "love.%s", t->name);
  luaL_getmetatable(L, key);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lp_register_type(L, t);
    luaL_getmetatable(L, key);
  }
  lua_setmetatable(L, -2);
  return p;
}

void *lp_testobj(lua_State *L, int idx, const LPType *t) {
  char key[64];
  snprintf(key, sizeof key, "love.%s", t->name);
  return luaL_testudata(L, idx, key);
}

void *lp_checkobj(lua_State *L, int idx, const LPType *t) {
  void *p = lp_testobj(L, idx, t);
  if (!p) {
    const char *got = luaL_typename(L, idx);
    if (lua_getmetatable(L, idx)) {
      lua_getfield(L, -1, "__typename");
      if (lua_isstring(L, -1)) got = lua_tostring(L, -1);
    }
    luaL_error(L, "bad argument #%d: %s expected, got %s", idx, t->name, got);
  }
  return p;
}

int lp_is_type(lua_State *L, int idx, const char *name) {
  int r = 0;
  if (lua_type(L, idx) != LUA_TUSERDATA) return 0;
  if (lua_getmetatable(L, idx)) {
    lua_getfield(L, -1, "__types");
    if (lua_istable(L, -1)) {
      lua_getfield(L, -1, name);
      r = lua_toboolean(L, -1);
      lua_pop(L, 1);
    }
    lua_pop(L, 2);
  }
  return r;
}

void lp_setref(lua_State *L, int obj, int slot, int val) {
  obj = lua_absindex(L, obj);
  lua_pushvalue(L, val);
  lua_setiuservalue(L, obj, slot);
}
