cmake_minimum_required(VERSION 3.20)
project(WandsongSetup LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# The version the setup reports and records; tools/build_release.ps1 passes -DWANDSONG_VERSION.
set(WANDSONG_VERSION "dev" CACHE STRING "Wandsong version")
set(WANDSONG_VERSION_MAJOR 0)
set(WANDSONG_VERSION_MINOR 0)
set(WANDSONG_VERSION_PATCH 0)
if(WANDSONG_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)")
    set(WANDSONG_VERSION_MAJOR ${CMAKE_MATCH_1})
    set(WANDSONG_VERSION_MINOR ${CMAKE_MATCH_2})
    set(WANDSONG_VERSION_PATCH ${CMAKE_MATCH_3})
endif()
configure_file(src/version.h.in ${CMAKE_CURRENT_BINARY_DIR}/version.h @ONLY)

# Self-contained: static runtime, Windows' own voice (SAPI) when no screen reader runs, and the
# mod's files appended to the program by the release build.
add_executable(WandsongSetup src/main.cpp src/version.rc)
target_include_directories(WandsongSetup PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_compile_definitions(WandsongSetup PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(WandsongSetup PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/utf-8>)
target_link_libraries(WandsongSetup PRIVATE ole32 advapi32 shell32 sapi)
