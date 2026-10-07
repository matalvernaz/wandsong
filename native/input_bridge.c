/* input_bridge: hold or release one key for the game, as a Lua C module.
 *
 * Used by autowalk to hold the forward key while the mod steers the camera. Keys are sent
 * as hardware scancodes (games read those), and only while this game's own window has
 * focus: if the player alt-tabs, nothing is typed into another window.
 *
 *   input_bridge.focused()         -> true when the foreground window is this process's
 *   input_bridge.key(vk, down)     -> true if sent (vk: Windows virtual-key code)
 *   input_bridge.mouse_move(dx, dy) -> true if sent: a relative mouse move, which turns the
 *                                     camera exactly as the player's own mouse does
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "lua.h"
#include "lauxlib.h"

static int game_focused(void) {
    HWND w = GetForegroundWindow();
    DWORD pid = 0;
    if (!w) return 0;
    GetWindowThreadProcessId(w, &pid);
    return pid == GetCurrentProcessId();
}

static int l_focused(lua_State *L) {
    lua_pushboolean(L, game_focused());
    return 1;
}

static int l_key(lua_State *L) {
    UINT vk = (UINT)luaL_checkinteger(L, 1);
    int down = lua_toboolean(L, 2);
    if (vk == 0 || vk > 255) { lua_pushboolean(L, 0); return 1; }
    /* A release is always allowed (never leave a key stuck); a press needs focus. */
    if (down && !game_focused()) { lua_pushboolean(L, 0); return 1; }
    INPUT in;
    ZeroMemory(&in, sizeof(in));
    in.type = INPUT_KEYBOARD;
    UINT scan = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX);
    if (!scan) { lua_pushboolean(L, 0); return 1; }
    in.ki.wScan = (WORD)(scan & 0xff);
    in.ki.dwFlags = KEYEVENTF_SCANCODE | (down ? 0 : KEYEVENTF_KEYUP);
    /* Remapped arrows and right-hand modifiers use extended scan codes. Without this
       flag an up arrow becomes numpad 8, and right control becomes left control. */
    if ((scan & 0xff00) == 0xe000) in.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    lua_pushboolean(L, SendInput(1, &in, sizeof(in)) == 1);
    return 1;
}

static int l_mouse_move(lua_State *L) {
    LONG dx = (LONG)luaL_checkinteger(L, 1);
    LONG dy = (LONG)luaL_optinteger(L, 2, 0);
    if (!game_focused()) { lua_pushboolean(L, 0); return 1; }
    INPUT in;
    ZeroMemory(&in, sizeof(in));
    in.type = INPUT_MOUSE;
    in.mi.dx = dx;
    in.mi.dy = dy;
    in.mi.dwFlags = MOUSEEVENTF_MOVE;
    lua_pushboolean(L, SendInput(1, &in, sizeof(in)) == 1);
    return 1;
}

static const luaL_Reg funcs[] = {
    {"focused", l_focused},
    {"key", l_key},
    {"mouse_move", l_mouse_move},
    {NULL, NULL},
};

__declspec(dllexport) int luaopen_input_bridge(lua_State *L) {
    luaL_newlib(L, funcs);
    return 1;
}
