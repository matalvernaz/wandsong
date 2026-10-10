// UE4SS's own Lua lock for the Lua copy in each native module (lua_lock.h). UE4SS exports no
// Lua functions, so LuaLock and LuaUnlock are found where the UE4SS 3.0.1 release build has
// them (from its PDB: section 1 offsets 10164928 and 10164976), once the module is checked to
// be that build and the code there to be theirs. Anywhere else (no UE4SS, as in the offline
// tests, or another build) the copy runs without a lock, as it always did.
//
// The first lock call resolves them. Each module's first one comes from its own luaopen
// function, on the thread that loads it, before anything else can reach that copy.
#include "lua_lock.h"
#include "lua.h"

int wandsong_lua_lock_report(lua_State *L) {
    lua_pushstring(L, wandsong_lua_lock_status());
    return 1;
}

#ifdef _WIN32
#include <windows.h>
#include <cstring>

namespace {

using LockFn = void (*)(lua_State *);
LockFn g_lock = nullptr;
LockFn g_unlock = nullptr;
const char *g_status = nullptr;

// UE4SS_v3.0.1.zip's UE4SS.dll (Feb 14, 2024; sha256 8ac18fbffc1ef96b...).
constexpr DWORD kStamp = 0x65CD1B94;
constexpr DWORD kImageSize = 16351232;
constexpr DWORD kLockRva = 0x9B2AC0;
constexpr DWORD kUnlockRva = 0x9B2AF0;
// LuaLock: mov [rsp+8],rcx; sub rsp,28h; mov rcx,[rsp+30h]; call LuaLockInitial.
constexpr unsigned char kLockCode[] = { 0x48, 0x89, 0x4c, 0x24, 0x08, 0x48, 0x83, 0xec, 0x28, 0x48,
                                        0x8b, 0x4c, 0x24, 0x30, 0xe8, 0x4d, 0x00, 0x00, 0x00 };
// LuaUnlock: mov [rsp+8],rcx; sub rsp,28h; lea rcx,[the lock]; call [LeaveCriticalSection].
constexpr unsigned char kUnlockCode[] = { 0x48, 0x89, 0x4c, 0x24, 0x08, 0x48, 0x83, 0xec, 0x28, 0x48,
                                          0x8d, 0x0d, 0xe0, 0xb1, 0x53, 0x00, 0xff, 0x15 };

void resolve() {
    HMODULE ue4ss = GetModuleHandleW(L"UE4SS.dll");
    if (!ue4ss) { g_status = "no UE4SS.dll: no lock"; return; }
    const auto *base = reinterpret_cast<const unsigned char *>(ue4ss);
    const auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
    const auto *nt = reinterpret_cast<const IMAGE_NT_HEADERS64 *>(base + dos->e_lfanew);
    if (nt->FileHeader.TimeDateStamp != kStamp || nt->OptionalHeader.SizeOfImage != kImageSize) {
        g_status = "not the UE4SS 3.0.1 release build: no lock";
        return;
    }
    if (std::memcmp(base + kLockRva, kLockCode, sizeof kLockCode) != 0 ||
        std::memcmp(base + kUnlockRva, kUnlockCode, sizeof kUnlockCode) != 0) {
        g_status = "UE4SS 3.0.1's lock functions aren't where expected: no lock";
        return;
    }
    g_lock = reinterpret_cast<LockFn>(const_cast<unsigned char *>(base + kLockRva));
    g_unlock = reinterpret_cast<LockFn>(const_cast<unsigned char *>(base + kUnlockRva));
    g_status = "UE4SS 3.0.1's Lua lock";
}

}  // namespace

void wandsong_lua_lock(lua_State *L) {
    if (!g_status) resolve();
    if (g_lock) g_lock(L);
}

void wandsong_lua_unlock(lua_State *L) {
    if (g_unlock) g_unlock(L);
}

const char *wandsong_lua_lock_status(void) {
    if (!g_status) resolve();
    return g_status;
}

#else

void wandsong_lua_lock(lua_State *) {}
void wandsong_lua_unlock(lua_State *) {}
const char *wandsong_lua_lock_status(void) { return "not Windows: no lock"; }

#endif
