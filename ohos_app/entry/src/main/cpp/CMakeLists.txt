cmake_minimum_required(VERSION 3.16)
project(vncviewer_napi C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(vncviewer SHARED napi_vnc.cpp)

get_filename_component(TIGERVNC_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/tigervnc" ABSOLUTE)
get_filename_component(SHARED_NATIVE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../../shared_native" ABSOLUTE)

list(APPEND CMAKE_MODULE_PATH "${TIGERVNC_SOURCE_DIR}/cmake/Modules")
include(CMakeMacroLibtoolFile)

set(OHOS FALSE)
if(DEFINED CMAKE_SYSTEM_NAME AND CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  set(OHOS TRUE)

  if(DEFINED CMAKE_OHOS_ARCH_ABI)
    set(OHOS_GNUTLS_ARCH "${CMAKE_OHOS_ARCH_ABI}")
  elseif(DEFINED OHOS_ARCH)
    set(OHOS_GNUTLS_ARCH "${OHOS_ARCH}")
  else()
    set(OHOS_GNUTLS_ARCH "arm64-v8a")
  endif()

  if(OHOS_GNUTLS_ARCH STREQUAL "arm64-v8a")
    set(OHOS_GNUTLS_PREBUILT_NAME "ohos-arm64")
  elseif(OHOS_GNUTLS_ARCH STREQUAL "x86_64")
    set(OHOS_GNUTLS_PREBUILT_NAME "ohos-x86_64")
  else()
    message(FATAL_ERROR "Unsupported OHOS ABI for GnuTLS prebuilts: ${OHOS_GNUTLS_ARCH}")
  endif()

  get_filename_component(GNUTLS_PREBUILT_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../../prebuilts/gnutls/${OHOS_GNUTLS_PREBUILT_NAME}" ABSOLUTE)
  if(NOT EXISTS "${GNUTLS_PREBUILT_DIR}/lib/libgnutls.a")
    message(FATAL_ERROR "Missing OHOS GnuTLS prebuilts for ${OHOS_GNUTLS_PREBUILT_NAME}. Build them with build_tools/gnutls/ohos/build.sh.")
  endif()

  set(GNUTLS_FOUND TRUE)
  set(NETTLE_FOUND TRUE)
  set(GNUTLS_INCLUDE_DIR "${GNUTLS_PREBUILT_DIR}/include")
  set(GNUTLS_LIBRARIES 
      "${GNUTLS_PREBUILT_DIR}/lib/libgnutls.a"
  )
  set(NETTLE_INCLUDE_DIRS "${GNUTLS_PREBUILT_DIR}/include")
  set(HOGWEED_LIBRARIES "${GNUTLS_PREBUILT_DIR}/lib/libhogweed.a")
  set(NETTLE_LIBRARIES "${GNUTLS_PREBUILT_DIR}/lib/libnettle.a")
  
  # Allow multiple definitions since GnuTLS backports some Nettle/Hogweed functions
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,--allow-multiple-definition")
else()
  find_package(GnuTLS QUIET)
  find_package(Nettle QUIET)

  if(DEFINED GnuTLS_FOUND AND NOT DEFINED GNUTLS_FOUND)
    set(GNUTLS_FOUND ${GnuTLS_FOUND})
  endif()
  if(DEFINED Nettle_FOUND AND NOT DEFINED NETTLE_FOUND)
    set(NETTLE_FOUND ${Nettle_FOUND})
  endif()
endif()

find_package(ZLIB REQUIRED)

if(GNUTLS_FOUND)
  if(NOT DEFINED GNUTLS_INCLUDE_DIR AND DEFINED GNUTLS_INCLUDE_DIRS)
    list(GET GNUTLS_INCLUDE_DIRS 0 GNUTLS_INCLUDE_DIR)
  endif()
  add_compile_definitions(HAVE_GNUTLS)
endif()
if(NETTLE_FOUND)
  add_compile_definitions(HAVE_NETTLE)
endif()

add_compile_definitions(OHOS)

add_subdirectory("${TIGERVNC_SOURCE_DIR}/common" "${CMAKE_BINARY_DIR}/tigervnc_common")
add_subdirectory("${SHARED_NATIVE_DIR}" "${CMAKE_BINARY_DIR}/tigervnc_shared")

target_include_directories(vncviewer PRIVATE
  "${TIGERVNC_SOURCE_DIR}/common"
  "${SHARED_NATIVE_DIR}"
)

target_link_libraries(vncviewer PRIVATE tigervnc_shared_client)
target_link_libraries(vncviewer PRIVATE ace_napi.z)
