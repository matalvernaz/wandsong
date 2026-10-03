cmake_minimum_required(VERSION 3.20)
project(WandsongSetup VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(PRISM_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/prism)

add_executable(WandsongSetup src/main.cpp src/version.rc)
target_include_directories(WandsongSetup PRIVATE ${PRISM_DIR}/include)
target_compile_definitions(WandsongSetup PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(WandsongSetup PRIVATE /utf-8)
target_link_libraries(WandsongSetup PRIVATE ${PRISM_DIR}/dynamic/release/lib/prism.lib ole32 advapi32)

add_custom_command(TARGET WandsongSetup POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${PRISM_DIR}/dynamic/release/bin/prism.dll $<TARGET_FILE_DIR:WandsongSetup>)
