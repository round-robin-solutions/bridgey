cmake_minimum_required(VERSION 3.22)
project(bridgey_bench C)

# Official BLAKE3 C implementation (release 1.8.7, unmodified, CC0-1.0 or Apache-2.0).
# arm64-v8a uses the NEON path; any other ABI falls back to the portable code.
set(BLAKE3_DIR ${CMAKE_CURRENT_SOURCE_DIR}/blake3)
set(BLAKE3_SOURCES
    ${BLAKE3_DIR}/blake3.c
    ${BLAKE3_DIR}/blake3_dispatch.c
    ${BLAKE3_DIR}/blake3_portable.c)
if(ANDROID_ABI STREQUAL "arm64-v8a")
  list(APPEND BLAKE3_SOURCES ${BLAKE3_DIR}/blake3_neon.c)
  add_compile_definitions(BLAKE3_USE_NEON=1)
else()
  add_compile_definitions(BLAKE3_USE_NEON=0 BLAKE3_NO_SSE2 BLAKE3_NO_SSE41 BLAKE3_NO_AVX2 BLAKE3_NO_AVX512)
endif()

add_library(bridgeyblake3 SHARED ${BLAKE3_SOURCES} blake3_jni.c)
target_include_directories(bridgeyblake3 PRIVATE ${BLAKE3_DIR})
target_compile_options(bridgeyblake3 PRIVATE -O3)
target_link_options(bridgeyblake3 PRIVATE -Wl,-z,max-page-size=16384)
