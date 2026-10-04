/* luahost: a minimal Lua 5.4.4 runner for testing the native modules outside the game.
 * Usage: luahost.exe script.lua   (modules are found beside the exe via package.cpath) */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(int argc, char** argv) {
    lua_State* L;
    if (argc < 2) { fprintf(stderr, "usage: luahost script.lua\n"); return 2; }
    L = luaL_newstate();
    luaL_openlibs(L);
    if (luaL_dofile(L, argv[1]) != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
