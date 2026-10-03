cmake_minimum_required(VERSION 3.20)
project(wandsong_helper VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Static CRT so the helper itself needs no redistributable.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(PRISM_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/prism)

add_executable(wandsong_helper WIN32 src/main.cpp src/version.rc)
target_include_directories(wandsong_helper PRIVATE ${PRISM_DIR}/include)
target_compile_definitions(wandsong_helper PRIVATE UNICODE _UNICODE NOMINMAX)
target_link_libraries(wandsong_helper PRIVATE ${PRISM_DIR}/dynamic/release/lib/prism.lib ole32)

add_custom_command(TARGET wandsong_helper POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${PRISM_DIR}/dynamic/release/bin/prism.dll $<TARGET_FILE_DIR:wandsong_helper>)
