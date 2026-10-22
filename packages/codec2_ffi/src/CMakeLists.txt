# Builds the Codec2 speech codec (vendored in codec2/, LGPL-2.1) as a shared
# library that Dart loads through FFI. Only the speech modes are included.
cmake_minimum_required(VERSION 3.10)

project(codec2_ffi_library VERSION 1.2.0 LANGUAGES C)

file(GLOB CODEC2_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/codec2/*.c")

add_library(codec2_ffi SHARED ${CODEC2_SOURCES})

target_include_directories(codec2_ffi PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/codec2"
  "${CMAKE_CURRENT_SOURCE_DIR}/codec2/codec2"
)

set_target_properties(codec2_ffi PROPERTIES OUTPUT_NAME "codec2_ffi")
target_compile_options(codec2_ffi PRIVATE -O2 -w)

if (NOT MSVC)
  target_link_libraries(codec2_ffi PRIVATE m)
endif()

if (ANDROID)
  # Support Android 15 16k page size devices.
  target_link_options(codec2_ffi PRIVATE "-Wl,-z,max-page-size=16384")
endif()
