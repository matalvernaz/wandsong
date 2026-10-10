/*
 * prism_bridge.c - Lua 5.4 C module exposing PRISM (screen reader) to UE4SS Lua.
 *
 * Adapted, with permission, from another access mod's code.
 * Wandsong additions: refresh() re-picks the
 * best backend (so starting a screen reader after the game is noticed) and copy()
 * puts text on the Windows clipboard.
 *
 * Approach (validated by another access mod's speech bridge): a Lua C
 * module that STATICALLY links its own Lua 5.4.4 (the exact version UE4SS v3.0.1
 * bundles, so the lua_State ABI matches) and DYNAMICALLY loads prism.dll at runtime.
 * UE4SS does `require("prism_bridge")`, which calls luaopen_prism_bridge with UE4SS's
 * lua_State; our statically-linked Lua manipulates that state. No UE4SS source build,
 * no UEPseudo, no Rust, no external process.
 *
 * Deploy prism_bridge.dll + prism.dll into the mod's Scripts/ folder (NOT tolk.dll: prism.dll
 * has NVDA/JAWS/SAPI built in and does not import it).
 *
 * Lua usage:
 *   local prism = require("prism_bridge")
 *   prism.say("Hello", true)   -- speak (interrupt previous); interrupt defaults true
 *   prism.say("queued", false) -- speak without interrupting
 *   prism.output("Hello", true)-- speak AND send to a braille display, in one backend call
 *   prism.braille("Hello")     -- braille display only, no speech
 *   prism.stop()
 *   prism.is_speaking()        -> bool
 *   prism.detect()             -> backend name (e.g. "NVDA") or nil
 *   prism.features()           -> table of booleans: what THIS backend actually supports
 *   prism.set_rate(v) / set_volume(v) / set_pitch(v)   -- v is a float
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"
#include "lua_lock.h"

/* PRISM types only; we resolve the functions ourselves, so suppress its dllimport decls. */
#define PRISM_STATIC
#include "prism.h"

/* ---- PRISM function pointer types (PRISM_CALL == __cdecl) ---- */
typedef PrismConfig   (PRISM_CALL *fn_config_init)(void);
typedef PrismContext* (PRISM_CALL *fn_init)(PrismConfig*);
typedef void          (PRISM_CALL *fn_shutdown)(PrismContext*);
typedef PrismBackend* (PRISM_CALL *fn_acquire_best)(PrismContext*);
typedef PrismBackend* (PRISM_CALL *fn_registry_create)(PrismContext*, PrismBackendId);
typedef size_t        (PRISM_CALL *fn_registry_count)(PrismContext*);
typedef PrismBackendId (PRISM_CALL *fn_registry_id_at)(PrismContext*, size_t);
typedef const char*   (PRISM_CALL *fn_registry_name)(PrismContext*, PrismBackendId);
typedef const char*   (PRISM_CALL *fn_backend_name)(PrismBackend*);
typedef PrismError    (PRISM_CALL *fn_backend_initialize)(PrismBackend*);
typedef PrismError    (PRISM_CALL *fn_speak)(PrismBackend*, const char*, bool);
typedef PrismError    (PRISM_CALL *fn_output)(PrismBackend*, const char*, bool);
typedef PrismError    (PRISM_CALL *fn_braille)(PrismBackend*, const char*);
typedef uint64_t      (PRISM_CALL *fn_get_features)(PrismBackend*);
typedef PrismError    (PRISM_CALL *fn_stop)(PrismBackend*);
typedef PrismError    (PRISM_CALL *fn_is_speaking)(PrismBackend*, bool*);
typedef PrismError    (PRISM_CALL *fn_set_float)(PrismBackend*, float);
typedef void          (PRISM_CALL *fn_backend_free)(PrismBackend*);

static HMODULE g_self = NULL;   /* our own module handle (set in DllMain) */
static HMODULE g_prism = NULL;  /* prism.dll */

static fn_config_init        p_config_init = NULL;
static fn_init               p_init = NULL;
static fn_shutdown           p_shutdown = NULL;
static fn_acquire_best       p_acquire_best = NULL;
static fn_registry_create    p_registry_create = NULL;
static fn_registry_count     p_registry_count = NULL;
static fn_registry_id_at     p_registry_id_at = NULL;
static fn_registry_name      p_registry_name = NULL;
static fn_backend_name       p_backend_name = NULL;
static fn_backend_initialize p_backend_initialize = NULL;
static fn_speak              p_speak = NULL;
static fn_output             p_output = NULL;
static fn_braille            p_braille = NULL;
static fn_get_features       p_get_features = NULL;
static fn_stop               p_stop = NULL;
static fn_is_speaking        p_is_speaking = NULL;
static fn_set_float          p_set_rate = NULL;
static fn_set_float          p_set_volume = NULL;
static fn_set_float          p_set_pitch = NULL;
static fn_backend_free       p_backend_free = NULL;

static PrismContext* g_ctx = NULL;
static PrismBackend* g_backend = NULL;
static int g_ready = 0;

/* ---- Lua-callable functions ---- */

static int l_say(lua_State *L) {
    const char* text = luaL_checkstring(L, 1);
    int interrupt = 1; /* default: interrupt */
    if (lua_gettop(L) >= 2) { interrupt = lua_toboolean(L, 2); }
    if (!g_ready) { lua_pushboolean(L, 0); return 1; }
    PrismError e = p_speak(g_backend, text, interrupt ? true : false);
    lua_pushboolean(L, e == PRISM_OK);
    return 1;
}

static int l_output(lua_State *L) {
    const char* text = luaL_checkstring(L, 1);
    int interrupt = 1;
    if (lua_gettop(L) >= 2) { interrupt = lua_toboolean(L, 2); }
    if (!g_ready) { lua_pushboolean(L, 0); return 1; }
    PrismError e = p_output(g_backend, text, interrupt ? true : false);
    lua_pushboolean(L, e == PRISM_OK);
    return 1;
}

/* braille(text) -> bool : send text to the BRAILLE DISPLAY only, no speech.
 *
 * Kept as its own call rather than routing speech through prism_backend_output (which is the
 * library's combined speak+braille path): output() is one call instead of two, but if its
 * semantics ever differ from what we assume, every line of speech in the mod goes with it.
 * speak() is the mod's lifeline, so it stays on the code path it has always used and braille
 * is strictly ADDITIVE — a braille failure can never cost the player their speech. */
static int l_braille(lua_State *L) {
    const char* text = luaL_checkstring(L, 1);
    if (!g_ready || !p_braille) { lua_pushboolean(L, 0); return 1; }
    PrismError e = p_braille(g_backend, text);
    lua_pushboolean(L, e == PRISM_OK);
    return 1;
}

static void feat_field(lua_State *L, const char *name, uint64_t feats, uint64_t bit) {
    lua_pushboolean(L, (feats & bit) != 0);
    lua_setfield(L, -2, name);
}

/* features() -> table of booleans describing what THIS backend can actually do.
 *
 * The bit values come from PrismBackendFeature in prism.h — the library's own declaration, not
 * numbers written here. `known` reports whether the query was answerable at all: an older
 * prism.dll without prism_backend_get_features leaves every flag false, and a caller must be
 * able to tell that apart from "this backend genuinely supports nothing" — otherwise braille
 * would silently disable itself on a DLL perfectly capable of it. */
static int l_features(lua_State *L) {
    uint64_t f = (g_ready && p_get_features) ? p_get_features(g_backend) : 0;
    lua_createtable(L, 0, 10);
    feat_field(L, "speak",       f, PRISM_BACKEND_SUPPORTS_SPEAK);
    feat_field(L, "braille",     f, PRISM_BACKEND_SUPPORTS_BRAILLE);
    feat_field(L, "output",      f, PRISM_BACKEND_SUPPORTS_OUTPUT);
    feat_field(L, "stop",        f, PRISM_BACKEND_SUPPORTS_STOP);
    feat_field(L, "is_speaking", f, PRISM_BACKEND_SUPPORTS_IS_SPEAKING);
    feat_field(L, "set_rate",    f, PRISM_BACKEND_SUPPORTS_SET_RATE);
    feat_field(L, "set_volume",  f, PRISM_BACKEND_SUPPORTS_SET_VOLUME);
    feat_field(L, "set_pitch",   f, PRISM_BACKEND_SUPPORTS_SET_PITCH);
    lua_pushboolean(L, p_get_features != NULL);
    lua_setfield(L, -2, "known");
    /* Whether the braille ENTRY POINT resolved, which is a different question from whether the
     * backend advertises the feature: with `known` false, this is all a caller has to go on. */
    lua_pushboolean(L, p_braille != NULL);
    lua_setfield(L, -2, "braille_available");
    return 1;
}

static int l_stop(lua_State *L) {
    if (g_ready) { p_stop(g_backend); }
    return 0;
}

static int l_is_speaking(lua_State *L) {
    bool speaking = false;
    if (g_ready) { p_is_speaking(g_backend, &speaking); }
    lua_pushboolean(L, speaking ? 1 : 0);
    return 1;
}

static int l_detect(lua_State *L) {
    const char* name = (g_ready && p_backend_name) ? p_backend_name(g_backend) : NULL;
    if (name) { lua_pushstring(L, name); } else { lua_pushnil(L); }
    return 1;
}

static int l_set_rate(lua_State *L) {
    float v = (float)luaL_checknumber(L, 1);
    if (g_ready && p_set_rate) { lua_pushboolean(L, p_set_rate(g_backend, v) == PRISM_OK); }
    else { lua_pushboolean(L, 0); }
    return 1;
}

static int l_set_volume(lua_State *L) {
    float v = (float)luaL_checknumber(L, 1);
    if (g_ready && p_set_volume) { lua_pushboolean(L, p_set_volume(g_backend, v) == PRISM_OK); }
    else { lua_pushboolean(L, 0); }
    return 1;
}

static int l_set_pitch(lua_State *L) {
    float v = (float)luaL_checknumber(L, 1);
    if (g_ready && p_set_pitch) { lua_pushboolean(L, p_set_pitch(g_backend, v) == PRISM_OK); }
    else { lua_pushboolean(L, 0); }
    return 1;
}

static int l_is_ready(lua_State *L) {
    lua_pushboolean(L, g_ready);
    return 1;
}

/* refresh() -> backend name : re-pick the best backend, e.g. when a screen reader was started
 * after the game. acquire_best is cached by Prism, so calling this every few seconds is cheap. */
static int l_refresh(lua_State *L) {
    PrismBackend *best;
    const char *old_name, *new_name;
    if (!g_ready) { lua_pushnil(L); return 1; }
    best = p_acquire_best(g_ctx);
    if (best) {
        old_name = p_backend_name ? p_backend_name(g_backend) : NULL;
        new_name = p_backend_name ? p_backend_name(best) : NULL;
        if (old_name && new_name && strcmp(old_name, new_name) != 0) {
            p_backend_free(g_backend);
            g_backend = best;
        } else if (best != g_backend) {
            p_backend_free(best);
        }
    }
    new_name = p_backend_name ? p_backend_name(g_backend) : NULL;
    if (new_name) { lua_pushstring(L, new_name); } else { lua_pushnil(L); }
    return 1;
}

/* copy(text) -> bool : put UTF-8 text on the Windows clipboard ("\n" becomes CRLF). */
static int l_copy(lua_State *L) {
    size_t len, i, j = 0;
    const char *text = luaL_checklstring(L, 1, &len);
    char *crlf = (char *)malloc(len * 2 + 1);
    int wlen, ok = 0, attempt;
    HGLOBAL mem;
    if (!crlf) { lua_pushboolean(L, 0); return 1; }
    for (i = 0; i < len; ++i) {
        if (text[i] == '\n' && (i == 0 || text[i - 1] != '\r')) crlf[j++] = '\r';
        crlf[j++] = text[i];
    }
    crlf[j] = '\0';
    wlen = MultiByteToWideChar(CP_UTF8, 0, crlf, -1, NULL, 0);
    mem = wlen > 0 ? GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)wlen * sizeof(wchar_t)) : NULL;
    if (mem) {
        MultiByteToWideChar(CP_UTF8, 0, crlf, -1, (wchar_t *)GlobalLock(mem), wlen);
        GlobalUnlock(mem);
        for (attempt = 0; attempt < 5 && !ok; ++attempt) {
            if (OpenClipboard(NULL)) {
                EmptyClipboard();
                if (SetClipboardData(CF_UNICODETEXT, mem)) { mem = NULL; ok = 1; }
                CloseClipboard();
            } else {
                Sleep(20);
            }
        }
        if (mem) GlobalFree(mem);
    }
    free(crlf);
    lua_pushboolean(L, ok);
    return 1;
}

static const luaL_Reg prism_funcs[] = {
    {"refresh", l_refresh},
    {"copy", l_copy},
    {"say", l_say},
    {"output", l_output},
    {"braille", l_braille},
    {"features", l_features},
    {"stop", l_stop},
    {"is_speaking", l_is_speaking},
    {"detect", l_detect},
    {"set_rate", l_set_rate},
    {"set_volume", l_set_volume},
    {"set_pitch", l_set_pitch},
    {"is_ready", l_is_ready},
    {"lua_lock", wandsong_lua_lock_report},
    {NULL, NULL}
};

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    (void)lpvReserved;
    if (fdwReason == DLL_PROCESS_ATTACH) { g_self = hinstDLL; }
    return TRUE;
}

/* LoadLibrary a DLL sitting next to prism_bridge.dll. */
static HMODULE load_from_own_dir(const char* dllName) {
    char path[MAX_PATH];
    DWORD len = GetModuleFileNameA(g_self, path, MAX_PATH);
    char* lastSlash;
    if (len == 0 || len >= MAX_PATH) { return NULL; }
    lastSlash = strrchr(path, '\\');
    if (!lastSlash) { return NULL; }
    lastSlash[1] = '\0';
    if (strlen(path) + strlen(dllName) >= MAX_PATH) { return NULL; }
    strcat(path, dllName);
    return LoadLibraryA(path);
}

#define RESOLVE(var, name) do { \
    (var) = reinterpret_cast<decltype(var)>(GetProcAddress(g_prism, (name))); \
    if (!(var)) { all = 0; } \
} while (0)

/* OPTIONAL export: a miss leaves the pointer NULL and the feature off, but must NOT fail the
 * whole module. Everything the mod says goes through here, so a prism.dll that predates an
 * export must never cost the player their screen reader over a nice-to-have. */
#define RESOLVE_OPT(var, name) do { \
    (var) = reinterpret_cast<decltype(var)>(GetProcAddress(g_prism, (name))); \
} while (0)

/* Built as C++ (CMakeLists.txt): the loader looks the name up unmangled. */
extern "C" __declspec(dllexport) int luaopen_prism_bridge(lua_State *L) {
    char modDir[MAX_PATH];
    DWORD dirLen;
    BOOL dirSet = FALSE;
    int all = 1;
    PrismConfig cfg;
    PrismError err;

    /* Make our own directory the DLL search dir so prism.dll itself resolves from beside us.
     * SetDllDirectory is PROCESS-GLOBAL and also drops the current directory from the search
     * order, so it is RESTORED (NULL = default order) as soon as prism.dll is loaded: leaving
     * it set would silently change every later LoadLibrary the game itself or another UE4SS
     * plugin performs. */
    dirLen = GetModuleFileNameA(g_self, modDir, MAX_PATH);
    if (dirLen > 0 && dirLen < MAX_PATH) {
        char* slash = strrchr(modDir, '\\');
        if (slash) { *slash = '\0'; }
        dirSet = SetDllDirectoryA(modDir);
    }

    g_prism = load_from_own_dir("prism.dll");
    /* Before the error path below: luaL_error never returns, so restoring after it would
     * leave the process-global setting behind whenever prism.dll is missing. */
    if (dirSet) { SetDllDirectoryA(NULL); }
    if (!g_prism) {
        luaL_error(L, "prism_bridge: failed to load prism.dll from mod dir (error %lu)", GetLastError());
        return 0;
    }

    RESOLVE(p_config_init, "prism_config_init");
    RESOLVE(p_init, "prism_init");
    RESOLVE(p_shutdown, "prism_shutdown");
    RESOLVE(p_acquire_best, "prism_registry_acquire_best");
    RESOLVE(p_registry_create, "prism_registry_create");
    RESOLVE(p_registry_count, "prism_registry_count");
    RESOLVE(p_registry_id_at, "prism_registry_id_at");
    RESOLVE(p_registry_name, "prism_registry_name");
    RESOLVE(p_backend_name, "prism_backend_name");
    RESOLVE(p_backend_initialize, "prism_backend_initialize");
    RESOLVE(p_speak, "prism_backend_speak");
    RESOLVE(p_output, "prism_backend_output");
    RESOLVE_OPT(p_braille, "prism_backend_braille");
    RESOLVE_OPT(p_get_features, "prism_backend_get_features");
    RESOLVE(p_stop, "prism_backend_stop");
    RESOLVE(p_is_speaking, "prism_backend_is_speaking");
    RESOLVE(p_set_rate, "prism_backend_set_rate");
    RESOLVE(p_set_volume, "prism_backend_set_volume");
    RESOLVE(p_set_pitch, "prism_backend_set_pitch");
    RESOLVE(p_backend_free, "prism_backend_free");
    if (!all) {
        luaL_error(L, "prism_bridge: prism.dll is missing expected exports");
        return 0;
    }

    cfg = p_config_init();
    g_ctx = p_init(&cfg);
    if (!g_ctx) { luaL_error(L, "prism_bridge: prism_init failed"); return 0; }

    g_backend = p_acquire_best(g_ctx);
    if (!g_backend) {
        /* Some packaged PRISM builds do not include standalone TTS in acquire_best's
         * automatic priority set. Explicit SAPI fallback keeps speech available even when
         * a running screen reader cannot be detected. */
        g_backend = p_registry_create(g_ctx, PRISM_BACKEND_SAPI);
        if (g_backend) {
            err = p_backend_initialize(g_backend);
            if (err != PRISM_OK && err != PRISM_ERROR_ALREADY_INITIALIZED) {
                p_backend_free(g_backend);
                g_backend = NULL;
            }
        }
    }
    if (!g_backend) {
        size_t i;
        size_t count = p_registry_count(g_ctx);
        for (i = 0; i < count; ++i) {
            PrismBackendId id = p_registry_id_at(g_ctx, i);
            PrismBackend *probe = p_registry_create(g_ctx, id);
            PrismError probe_err = probe ? p_backend_initialize(probe) : PRISM_ERROR_MEMORY_FAILURE;
            fprintf(stderr, "prism_bridge: backend %s init=%d\n",
                    p_registry_name(g_ctx, id), (int)probe_err);
            if (probe) p_backend_free(probe);
        }
        luaL_error(L, "prism_bridge: no screen-reader or SAPI backend available (registered=%d)",
                   (int)count);
        return 0;
    }

    /* acquire_best may already initialise the backend; "already initialized" is success. */
    err = p_backend_initialize(g_backend);
    if (err != PRISM_OK && err != PRISM_ERROR_ALREADY_INITIALIZED) {
        luaL_error(L, "prism_bridge: backend_initialize failed (%d)", (int)err);
        return 0;
    }

    g_ready = 1;
    luaL_newlib(L, prism_funcs);
    return 1;
}
