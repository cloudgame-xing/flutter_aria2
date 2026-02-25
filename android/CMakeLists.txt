cmake_minimum_required(VERSION 3.22.1)
project(flutter_aria2_native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
  message(FATAL_ERROR "Only arm64-v8a is supported. Current ABI: ${CMAKE_ANDROID_ARCH_ABI}")
endif()

execute_process(
  COMMAND dart run build_tool/sync_deps.dart android arm64 0.1.1
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
  RESULT_VARIABLE SYNC_DEPS_RESULT
)
if(NOT SYNC_DEPS_RESULT EQUAL 0)
  message(FATAL_ERROR "sync_deps.dart failed with code ${SYNC_DEPS_RESULT}")
endif()

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
  set(ARIA2_VARIANT "Debug")
else()
  set(ARIA2_VARIANT "Release")
endif()

set(ARIA2_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/aria2lib/${ARIA2_VARIANT}")
set(ARIA2_INCLUDE_DIR "${ARIA2_ROOT}/include")

set(ARIA2_LIB_FILE "")
if(DEFINED CMAKE_ANDROID_ARCH_ABI AND EXISTS "${ARIA2_ROOT}/lib/${CMAKE_ANDROID_ARCH_ABI}/libaria2_c_api.so")
  set(ARIA2_LIB_FILE "${ARIA2_ROOT}/lib/${CMAKE_ANDROID_ARCH_ABI}/libaria2_c_api.so")
elseif(EXISTS "${ARIA2_ROOT}/lib/libaria2_c_api.so")
  set(ARIA2_LIB_FILE "${ARIA2_ROOT}/lib/libaria2_c_api.so")
else()
  file(GLOB_RECURSE ARIA2_LIB_CANDIDATES "${ARIA2_ROOT}/lib/**/libaria2_c_api.so")
  list(LENGTH ARIA2_LIB_CANDIDATES ARIA2_LIB_CANDIDATES_COUNT)
  if(ARIA2_LIB_CANDIDATES_COUNT GREATER 0)
    list(GET ARIA2_LIB_CANDIDATES 0 ARIA2_LIB_FILE)
  endif()
endif()

if(NOT ARIA2_LIB_FILE)
  message(FATAL_ERROR
    "Cannot find libaria2_c_api.so under ${ARIA2_ROOT}/lib. "
    "Expected either ${ARIA2_ROOT}/lib/${CMAKE_ANDROID_ARCH_ABI}/libaria2_c_api.so "
    "or ${ARIA2_ROOT}/lib/libaria2_c_api.so.")
endif()

add_library(aria2_c_api SHARED IMPORTED)
set_target_properties(
  aria2_c_api
  PROPERTIES
  IMPORTED_LOCATION "${ARIA2_LIB_FILE}"
)

add_library(
  flutter_aria2_native
  SHARED
  src/main/cpp/flutter_aria2_native_jni.cpp
  ../common/aria2_core.cpp
)

target_include_directories(
  flutter_aria2_native
  PRIVATE
  "${ARIA2_INCLUDE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/.."
)

target_link_libraries(
  flutter_aria2_native
  aria2_c_api
  log
)
