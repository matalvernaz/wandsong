// Generic UButton.OnClicked broadcaster for Wandsong.
// Adapted, with permission, from another access mod's code. Wandsong
// change: also accept the FName overload as exported by official UE4SS 3.0.1
// (mangled as a struct, "UFName", instead of the class "VFName" of later builds;
// same calling convention on x64).
// Resolves the ABI from the UE4SS DLL already loaded by the game. No game
// addresses, UObject offsets, or option-specific Blueprint handlers are used.

#include <windows.h>
#include <stdint.h>
#include <stdlib.h>

// Lua is built as C++ here, as UE4SS builds its own (CMakeLists.txt): no extern "C".
#include "lua.h"
#include "lauxlib.h"
#include "lua_lock.h"

struct FWeakObjectPtrLayout { int32_t object_index; int32_t object_serial_number; };
struct FNameLayout { uint32_t comparison_index; uint32_t number; };
struct ScriptDelegateLayout { FWeakObjectPtrLayout object; FNameLayout function_name; };
struct MulticastDelegateLayout { ScriptDelegateLayout* data; int32_t count; int32_t capacity; };

typedef void* (__fastcall *GetPropertyPtrFn)(void*, const wchar_t*);
typedef void* (__fastcall *WeakObjectGetFn)(const FWeakObjectPtrLayout*);
typedef void* (__fastcall *GetFunctionByFNameFn)(void*, FNameLayout);
typedef void  (__fastcall *ProcessEventFn)(void*, void*, void*);

static GetPropertyPtrFn g_get_property = nullptr;
static WeakObjectGetFn g_weak_get = nullptr;
static GetFunctionByFNameFn g_get_function = nullptr;
static ProcessEventFn g_process_event = nullptr;
static const char* g_api_error = "not initialized";

static bool resolve_api() {
    if (g_get_property && g_weak_get && g_get_function && g_process_event) return true;
    HMODULE ue4ss = GetModuleHandleW(L"UE4SS.dll");
    if (!ue4ss) { g_api_error = "UE4SS.dll not loaded"; return false; }

    g_get_property = reinterpret_cast<GetPropertyPtrFn>(GetProcAddress(ue4ss,
        "?GetValuePtrByPropertyNameInChain@UObject@Unreal@RC@@QEAAPEAXPEB_W@Z"));
    g_weak_get = reinterpret_cast<WeakObjectGetFn>(GetProcAddress(ue4ss,
        "?Get@FWeakObjectPtr@Unreal@RC@@QEBAPEAVUObject@23@XZ"));
    g_get_function = reinterpret_cast<GetFunctionByFNameFn>(GetProcAddress(ue4ss,
        "?GetFunctionByNameInChain@UObject@Unreal@RC@@QEAAPEAVUFunction@23@VFName@23@@Z"));
    if (!g_get_function) {
        g_get_function = reinterpret_cast<GetFunctionByFNameFn>(GetProcAddress(ue4ss,
            "?GetFunctionByNameInChain@UObject@Unreal@RC@@QEAAPEAVUFunction@23@UFName@23@@Z"));
    }
    g_process_event = reinterpret_cast<ProcessEventFn>(GetProcAddress(ue4ss,
        "?ProcessEvent@UObject@Unreal@RC@@QEAAXPEAVUFunction@23@PEAX@Z"));
    if (!g_get_property || !g_weak_get || !g_get_function || !g_process_event) {
        g_api_error = "required UE4SS exports unavailable";
        return false;
    }
    g_api_error = nullptr;
    return true;
}

static uintptr_t lua_address(lua_State* L, int index) {
    if (lua_isinteger(L, index)) return static_cast<uintptr_t>(lua_tointeger(L, index));
    if (lua_islightuserdata(L, index)) return reinterpret_cast<uintptr_t>(lua_touserdata(L, index));
    if (lua_isstring(L, index)) return static_cast<uintptr_t>(_strtoui64(lua_tostring(L, index), nullptr, 0));
    return 0;
}

static int result(lua_State* L, bool ok, const char* message, int count) {
    lua_pushboolean(L, ok ? 1 : 0);
    lua_pushstring(L, message);
    lua_pushinteger(L, count);
    return 3;
}

static int broadcast_delegate(lua_State* L, uintptr_t address,
                              const wchar_t* property_name, void* params,
                              const char* success_message) {
    int invoked = 0;
    const char* failure = nullptr;
    __try {
        void* property = g_get_property(reinterpret_cast<void*>(address), property_name);
        if (!property) {
            failure = "delegate property unavailable";
        } else {
            const MulticastDelegateLayout* delegate = reinterpret_cast<const MulticastDelegateLayout*>(property);
            // Unexpected ABI/layout becomes a clean failure, not an arbitrary walk.
            if (delegate->count < 0 || delegate->count > 64 ||
                delegate->capacity < delegate->count || delegate->capacity > 4096 ||
                (delegate->count > 0 && !delegate->data)) {
                failure = "invalid delegate layout";
            } else if (delegate->count == 0) {
                failure = "delegate has no bindings";
            } else {
                for (int32_t i = 0; i < delegate->count; ++i) {
                    const ScriptDelegateLayout* binding = &delegate->data[i];
                    void* target = g_weak_get(&binding->object);
                    if (!target || binding->function_name.comparison_index == 0) continue;
                    void* function = g_get_function(target, binding->function_name);
                    if (!function) continue;
                    g_process_event(target, function, params);
                    ++invoked;
                }
                if (invoked == 0) failure = "no valid delegate bindings";
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        failure = "native exception while broadcasting delegate";
    }
    if (failure) return result(L, false, failure, invoked);
    return result(L, true, success_message, invoked);
}

// Caller must be on the game thread. logical_nav.lua guarantees this.
static int l_broadcast_on_clicked(lua_State* L) {
    uintptr_t address = lua_address(L, 1);
    if (!address) return result(L, false, "invalid button address", 0);
    if (!resolve_api()) return result(L, false, g_api_error, 0);
    return broadcast_delegate(L, address, L"OnClicked", nullptr, "OnClicked broadcast");
}

static int broadcast_empty_named(lua_State* L, const wchar_t* property_name,
                                 const char* success_message) {
    uintptr_t address = lua_address(L, 1);
    if (!address) return result(L, false, "invalid widget address", 0);
    if (!resolve_api()) return result(L, false, g_api_error, 0);
    return broadcast_delegate(L, address, property_name, nullptr, success_message);
}

static int l_broadcast_on_hovered(lua_State* L) {
    return broadcast_empty_named(L, L"OnHovered", "OnHovered broadcast");
}

static int l_broadcast_on_unhovered(lua_State* L) {
    return broadcast_empty_named(L, L"OnUnhovered", "OnUnhovered broadcast");
}

static int l_broadcast_on_value_changed(lua_State* L) {
    uintptr_t address = lua_address(L, 1);
    float value = static_cast<float>(luaL_checknumber(L, 2));
    if (!address) return result(L, false, "invalid slider address", 0);
    if (!resolve_api()) return result(L, false, g_api_error, 0);
    return broadcast_delegate(L, address, L"OnValueChanged", &value,
                              "OnValueChanged broadcast");
}

static int l_broadcast_dropdown_changed(lua_State* L) {
    uintptr_t address = lua_address(L, 1);
    int32_t index = static_cast<int32_t>(luaL_checkinteger(L, 2));
    if (!address) return result(L, false, "invalid dropdown address", 0);
    if (!resolve_api()) return result(L, false, g_api_error, 0);
    return broadcast_delegate(L, address, L"DropDownOptionChanged", &index,
                              "DropDownOptionChanged broadcast");
}

static int l_broadcast_capture_begin(lua_State* L) {
    uintptr_t address = lua_address(L, 1);
    if (!address) return result(L, false, "invalid slider address", 0);
    if (!resolve_api()) return result(L, false, g_api_error, 0);
    return broadcast_delegate(L, address, L"OnControllerCaptureBegin", nullptr,
                              "OnControllerCaptureBegin broadcast");
}

static int l_broadcast_capture_end(lua_State* L) {
    uintptr_t address = lua_address(L, 1);
    if (!address) return result(L, false, "invalid slider address", 0);
    if (!resolve_api()) return result(L, false, g_api_error, 0);
    return broadcast_delegate(L, address, L"OnControllerCaptureEnd", nullptr,
                              "OnControllerCaptureEnd broadcast");
}

static int l_ready(lua_State* L) {
    bool ok = resolve_api();
    lua_pushboolean(L, ok ? 1 : 0);
    lua_pushstring(L, ok ? "ready" : g_api_error);
    return 2;
}

static const luaL_Reg functions[] = {
    {"ready", l_ready},
    {"broadcast_on_clicked", l_broadcast_on_clicked},
    {"broadcast_on_hovered", l_broadcast_on_hovered},
    {"broadcast_on_unhovered", l_broadcast_on_unhovered},
    {"broadcast_on_value_changed", l_broadcast_on_value_changed},
    {"broadcast_dropdown_changed", l_broadcast_dropdown_changed},
    {"broadcast_capture_begin", l_broadcast_capture_begin},
    {"broadcast_capture_end", l_broadcast_capture_end},
    {"lua_lock", wandsong_lua_lock_report}, {nullptr, nullptr}
};

extern "C" __declspec(dllexport) int luaopen_click_bridge(lua_State* L) {
    luaL_newlib(L, functions);
    return 1;
}
