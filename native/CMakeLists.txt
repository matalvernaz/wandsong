# Lua C modules loaded in-process by the UE4SS Lua mod with require().
#
# UE4SS exports no lua_* symbols, so each module statically links its own Lua. It must be
# exactly the version UE4SS embeds (5.4.4 for UE4SS 3.0.1: the string "Lua 5.4.4" appears in
# UE4SS.dll), because the module operates on UE4SS's own lua_State. It must also be built the
# way UE4SS builds its own: as C++ (Lua errors are C++ exceptions there, caught by UE4SS's
# frames; a C copy's longjmp would land in them) and taking UE4SS's global Lua lock
# (lua_lock.h, lua_lock.cpp). So the Lua sources, and the modules' and test host's C files,
# compile as C++.
cmake_minimum_required(VERSION 3.20)
project(wandsong_native LANGUAGES C CXX)

set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(LUA_SRC ${CMAKE_CURRENT_SOURCE_DIR}/lua-5.4.4/src)
file(GLOB LUA_SOURCES ${LUA_SRC}/*.c)
list(REMOVE_ITEM LUA_SOURCES ${LUA_SRC}/lua.c ${LUA_SRC}/luac.c ${LUA_SRC}/onelua.c ${LUA_SRC}/ltests.c)
set_source_files_properties(${LUA_SOURCES} prism_bridge.c input_bridge.c luahost.c PROPERTIES LANGUAGE CXX)
add_library(lua54 STATIC ${LUA_SOURCES} lua_lock.cpp)
target_include_directories(lua54 PUBLIC ${LUA_SRC} ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(lua54 PRIVATE _CRT_SECURE_NO_WARNINGS)
set(LUA_LOCK_H ${CMAKE_CURRENT_SOURCE_DIR}/lua_lock.h)
if(MSVC)
    target_compile_options(lua54 PRIVATE /FI${LUA_LOCK_H})
else()
    target_compile_options(lua54 PRIVATE "SHELL:-include ${LUA_LOCK_H}")
endif()
if(UNIX)
    target_compile_definitions(lua54 PRIVATE LUA_USE_LINUX)
    target_link_libraries(lua54 PUBLIC m ${CMAKE_DL_LIBS})
endif()

# Speech: loads prism.dll from beside itself at runtime.
add_library(prism_bridge SHARED prism_bridge.c)
target_include_directories(prism_bridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/prism/include)
target_link_libraries(prism_bridge PRIVATE lua54 user32)
target_compile_features(prism_bridge PRIVATE cxx_std_17)

# Clicks: broadcasts UButton.OnClicked through functions UE4SS.dll exports.
add_library(click_bridge SHARED click_bridge.cpp)
target_link_libraries(click_bridge PRIVATE lua54)

# Positioned sound: XAudio2 + X3DAudio (both in Windows 10's xaudio2_9.dll).
add_library(audio_bridge SHARED audio_bridge.cpp)
target_link_libraries(audio_bridge PRIVATE lua54 xaudio2 ole32)
target_compile_features(audio_bridge PRIVATE cxx_std_17)
target_compile_definitions(audio_bridge PRIVATE NOMINMAX)

# Autowalk: holds the forward key while the game window has focus.
add_library(input_bridge SHARED input_bridge.c)
target_link_libraries(input_bridge PRIVATE lua54 user32)

# Object lifetime: a delete listener registered through UE4SS.dll's exports. Build with MSVC:
# its vtable must match MSVC's layout of UE4SS's FUObjectDeleteListener.
add_library(lifetime_bridge SHARED lifetime_bridge.cpp)
target_link_libraries(lifetime_bridge PRIVATE lua54)
target_compile_features(lifetime_bridge PRIVATE cxx_std_17)

# Test host: runs a Lua script against the modules outside the game (dev only, not shipped).
add_executable(luahost luahost.c)
target_link_libraries(luahost PRIVATE lua54)
