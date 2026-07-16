cmake_minimum_required(VERSION 3.5.0)
project(hmtrans_cast)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

add_library(hmtrans_cast SHARED
    screen_capture_module.cpp
)

target_include_directories(hmtrans_cast PRIVATE ${NATIVERENDER_ROOT_PATH})

target_link_libraries(hmtrans_cast PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_avscreen_capture.so
    libnative_media_core.so
)
