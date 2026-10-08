// lifetime_bridge: the game says when an object is deleted, so the mod can keep an object
// between ticks and check it later without ever touching freed memory.
//
// UE4SS 3.0.1's own Lua IsValid reads the object (IsUnreachable) before it consults its record
// of deleted objects, so it crashes on a freed one: the cause of this project's object-lifetime
// crashes. Here the deletion record is consulted alone. A delete listener registered with the
// engine's object array (through AddUObjectDeleteListener, which UE4SS.dll exports) notes the
// deletion of every object the mod watches.
//
//   lifetime.start()                -> ok, message   register (on the game thread, once)
//   lifetime.watch(address)         -> serial        watch an object (its GetAddress())
//   lifetime.alive(address, serial) -> bool          watched, and not deleted since that serial
//   lifetime.forget(address)
//   lifetime.clear()                                 forget everything (a new world)
//   lifetime.stats()                -> { started, notified, noted, watched, shutdown }
//   lifetime.test_notify(address)                    the callback, as the engine calls it (tests)
//
// Serials come from one counter for watches and deletions alike. alive() is true only if the
// address has been watched without a break since that serial was issued and no deletion at
// the address was noted after it. So an address the game reuses for a new object never
// revives an old serial, even if the mod forgot the address in between and watched it again.
//
// The callback can run on the garbage collector's thread. It takes a lock, does one lookup and
// stores a number: no allocation, no Lua, no logging, and the object is never read. The table
// and the lock are never destroyed, and the DLL pins itself in memory when it registers, so a
// late callback (after UE4SS closes the Lua state that loaded it, or at exit) finds them intact.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <new>
#include <unordered_map>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

namespace {

struct Record {
    uint64_t since = 0;          // first serial issued in this unbroken watch
    uint64_t last_deleted = 0;   // serial of the last deletion noted at this address, 0 = none
};

SRWLOCK g_lock = SRWLOCK_INIT;
std::unordered_map<uintptr_t, Record>* g_watched = nullptr;   // never freed (see above)
uint64_t g_serial = 0;           // under g_lock
uint64_t g_notified = 0;         // every deletion the engine reported, under g_lock
uint64_t g_noted = 0;            // deletions of watched objects, under g_lock
bool g_started = false;
volatile LONG g_shutdown = 0;

typedef void (*ListenerFn)(void*);
ListenerFn g_remove = nullptr;

struct Locked {
    Locked() { AcquireSRWLockExclusive(&g_lock); }
    ~Locked() { ReleaseSRWLockExclusive(&g_lock); }
};

// Same layout as RC::Unreal::FUObjectDeleteListener (UE4SS.pdb: 8 bytes, vtable = deleting
// destructor, NotifyUObjectDeleted(const UObjectBase*, int32), OnUObjectArrayShutdown).
// Nothing may be declared before the virtual functions or added as a member.
class DeleteListener {
public:
    virtual ~DeleteListener() {}
    virtual void NotifyUObjectDeleted(const void* object, int32_t /*index*/) {
        AcquireSRWLockExclusive(&g_lock);
        ++g_notified;
        if (g_watched && !g_watched->empty()) {
            auto it = g_watched->find(reinterpret_cast<uintptr_t>(object));
            if (it != g_watched->end()) {
                it->second.last_deleted = ++g_serial;
                ++g_noted;
            }
        }
        ReleaseSRWLockExclusive(&g_lock);
    }
    // The engine is shutting its object array down: every listener is to remove itself
    // (UE4SS's own does the same). From then on nothing counts as alive.
    virtual void OnUObjectArrayShutdown() {
        InterlockedExchange(&g_shutdown, 1);
        if (g_remove) {
            __try {
                g_remove(this);
            } __except (EXCEPTION_EXECUTE_HANDLER) {
            }
        }
    }
    // Later engine versions add this slot; a spare entry here costs nothing if never called.
    virtual size_t GetAllocatedSize() const { return 0; }
};

DeleteListener g_listener;

const char* register_listener() {
    HMODULE ue4ss = GetModuleHandleW(L"UE4SS.dll");
    if (!ue4ss) return "UE4SS.dll is not loaded";
    ListenerFn add = reinterpret_cast<ListenerFn>(GetProcAddress(ue4ss,
        "?AddUObjectDeleteListener@UObjectArray@Unreal@RC@@SAXPEAVFUObjectDeleteListener@23@@Z"));
    if (!add) return "UE4SS does not export AddUObjectDeleteListener";
    g_remove = reinterpret_cast<ListenerFn>(GetProcAddress(ue4ss,
        "?RemoveUObjectDeleteListener@UObjectArray@Unreal@RC@@SAXPEAVFUObjectDeleteListener@23@@Z"));
    // Once registered, the engine calls this DLL until the process ends: it must never unload,
    // even when UE4SS closes the Lua state that loaded it.
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                            reinterpret_cast<LPCWSTR>(&g_listener), &self)) {
        return "could not pin lifetime_bridge.dll in memory";
    }
    __try {
        add(&g_listener);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return "registering the delete listener faulted";
    }
    return nullptr;
}

uintptr_t lua_address(lua_State* L, int index) {
    if (lua_isinteger(L, index)) return static_cast<uintptr_t>(lua_tointeger(L, index));
    if (lua_islightuserdata(L, index)) return reinterpret_cast<uintptr_t>(lua_touserdata(L, index));
    if (lua_isstring(L, index)) return static_cast<uintptr_t>(_strtoui64(lua_tostring(L, index), nullptr, 0));
    return 0;
}

int l_start(lua_State* L) {
    if (!g_started) {
        if (const char* error = register_listener()) {
            lua_pushboolean(L, 0);
            lua_pushstring(L, error);
            return 2;
        }
        g_started = true;
    }
    lua_pushboolean(L, 1);
    lua_pushstring(L, g_remove ? "delete listener registered" : "delete listener registered (no remove export)");
    return 2;
}

int l_watch(lua_State* L) {
    uintptr_t address = lua_address(L, 1);
    if (!address) { lua_pushinteger(L, 0); return 1; }
    uint64_t serial = 0;
    {
        // No Lua errors while the lock is held: they would jump past its release.
        Locked lock;
        if (!g_watched) g_watched = new (std::nothrow) std::unordered_map<uintptr_t, Record>();
        if (g_watched) {
            try {
                Record& r = (*g_watched)[address];   // inserted here, never inside the callback
                serial = ++g_serial;
                if (!r.since) r.since = serial;
            } catch (...) {
                serial = 0;
            }
        }
    }
    if (!serial) return luaL_error(L, "lifetime_bridge: out of memory");
    lua_pushinteger(L, static_cast<lua_Integer>(serial));
    return 1;
}

int l_alive(lua_State* L) {
    uintptr_t address = lua_address(L, 1);
    uint64_t serial = static_cast<uint64_t>(luaL_optinteger(L, 2, 0));
    bool alive = false;
    if (address && serial) {
        Locked lock;
        if (g_watched && !g_shutdown) {
            auto it = g_watched->find(address);
            alive = it != g_watched->end() && it->second.since <= serial && it->second.last_deleted < serial;
        }
    }
    lua_pushboolean(L, alive ? 1 : 0);
    return 1;
}

int l_forget(lua_State* L) {
    uintptr_t address = lua_address(L, 1);
    Locked lock;
    if (g_watched) g_watched->erase(address);
    return 0;
}

int l_clear(lua_State*) {
    Locked lock;
    if (g_watched) g_watched->clear();
    return 0;
}

int l_stats(lua_State* L) {
    uint64_t notified, noted;
    size_t watched;
    {
        Locked lock;
        notified = g_notified;
        noted = g_noted;
        watched = g_watched ? g_watched->size() : 0;
    }
    lua_createtable(L, 0, 5);
    lua_pushboolean(L, g_started ? 1 : 0); lua_setfield(L, -2, "started");
    lua_pushinteger(L, static_cast<lua_Integer>(notified)); lua_setfield(L, -2, "notified");
    lua_pushinteger(L, static_cast<lua_Integer>(noted)); lua_setfield(L, -2, "noted");
    lua_pushinteger(L, static_cast<lua_Integer>(watched)); lua_setfield(L, -2, "watched");
    lua_pushboolean(L, g_shutdown ? 1 : 0); lua_setfield(L, -2, "shutdown");
    return 1;
}

// Called the way the engine calls it, through the vtable's second slot, so the offline test
// also checks the layout.
int l_test_notify(lua_State* L) {
    typedef void (*NotifyFn)(void* self, const void* object, int32_t index);
    void** vtable = *reinterpret_cast<void***>(&g_listener);
    reinterpret_cast<NotifyFn>(vtable[1])(&g_listener, reinterpret_cast<const void*>(lua_address(L, 1)), 0);
    return 0;
}

const luaL_Reg kFuncs[] = {
    {"start", l_start}, {"watch", l_watch}, {"alive", l_alive}, {"forget", l_forget},
    {"clear", l_clear}, {"stats", l_stats}, {"test_notify", l_test_notify}, {nullptr, nullptr},
};

}  // namespace

extern "C" __declspec(dllexport) int luaopen_lifetime_bridge(lua_State* L) {
    luaL_newlib(L, kFuncs);
    return 1;
}
