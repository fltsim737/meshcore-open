cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "codec2_ffi")
project(${PROJECT_NAME} LANGUAGES C CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(codec2_ffi_bundled_libraries
  $<TARGET_FILE:codec2_ffi>
  PARENT_SCOPE
)
