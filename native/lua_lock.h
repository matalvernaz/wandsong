/* Wandsong: forced into every file of the Lua copy the native modules carry (CMakeLists.txt).
 *
 * UE4SS 3.0.1 builds its Lua with one global lock (its luaconf.h maps lua_lock to LuaLock,
 * LuaRaw/src/luauser.c), taken on entering the Lua core and released on leaving it, and also
 * released while any C function runs. The modules work on UE4SS's own lua_State through this
 * copy, so it takes the same lock: without it, their API calls (and the garbage collection
 * steps those can trigger) ran beside Lua on UE4SS's async thread, and the state broke (the
 * Oct 9, 18:56 startup hang: a garbage to-be-closed list, private notebook). */
#ifndef WANDSONG_LUA_LOCK_H
#define WANDSONG_LUA_LOCK_H

struct lua_State;
void wandsong_lua_lock(struct lua_State *L);
void wandsong_lua_unlock(struct lua_State *L);
/* What the copy found: UE4SS 3.0.1's lock, or why it runs without one. */
const char *wandsong_lua_lock_status(void);
/* The same, as a module function ("lua_lock") for the mod's startup log. */
int wandsong_lua_lock_report(struct lua_State *L);

#define lua_lock(L)   wandsong_lua_lock(L)
#define lua_unlock(L) wandsong_lua_unlock(L)

#endif
