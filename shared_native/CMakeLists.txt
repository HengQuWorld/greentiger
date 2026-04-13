get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(GNUTLS_PREBUILT_DIR "${REPO_ROOT}/prebuilts/gnutls/ohos-arm64")
set(MBEDTLS_SOURCE_DIR "${REPO_ROOT}/third_party/mbedtls-3.6.6")
set(LIBSSH2_SOURCE_DIR "${REPO_ROOT}/third_party/libssh2")
set(SHARED_NATIVE_IS_OHOS FALSE)

if(NOT EXISTS "${MBEDTLS_SOURCE_DIR}/include/mbedtls/rsa.h")
  message(FATAL_ERROR "Missing required submodule: third_party/mbedtls-3.6.6")
endif()

if(DEFINED CMAKE_SYSTEM_NAME AND CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  set(SHARED_NATIVE_IS_OHOS TRUE)
endif()

if(SHARED_NATIVE_IS_OHOS AND NOT EXISTS "${GNUTLS_PREBUILT_DIR}/lib/libgnutls.a")
  message(STATUS "GnuTLS prebuilts not found. Downloading and compiling GnuTLS...")

  get_filename_component(OHOS_SDK_NATIVE_PATH "${CMAKE_SYSROOT}/.." ABSOLUTE)

  execute_process(
    COMMAND env
      "OHOS_SDK_NATIVE=${OHOS_SDK_NATIVE_PATH}"
      bash "${REPO_ROOT}/build_tools/gnutls/ohos/build.sh"
    WORKING_DIRECTORY "${REPO_ROOT}"
    RESULT_VARIABLE GNUTLS_BUILD_RESULT
  )
  if(NOT GNUTLS_BUILD_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to build GnuTLS. Check logs above.")
  endif()
endif()

set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(DISABLE_PACKAGE_CONFIG_AND_INSTALL ON CACHE BOOL "" FORCE)
add_subdirectory("${MBEDTLS_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/mbedtls")

# libssh2's FindMbedTLS.cmake short-circuits when it sees the in-tree
# tfpsacrypto target and does not add the classic mbedtls/include path.
# Export it here so libssh2 can still include headers like mbedtls/version.h.
if(TARGET tfpsacrypto_static)
  target_include_directories(tfpsacrypto_static PUBLIC "${MBEDTLS_SOURCE_DIR}/include")
endif()
if(TARGET tfpsacrypto)
  target_include_directories(tfpsacrypto PUBLIC "${MBEDTLS_SOURCE_DIR}/include")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(LIBSSH2_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(LIBSSH2_DISABLE_INSTALL ON CACHE BOOL "" FORCE)
set(CRYPTO_BACKEND "mbedTLS" CACHE STRING "" FORCE)
add_subdirectory("${LIBSSH2_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/libssh2")

add_library(tigervnc_shared_client STATIC
  ssh_tunnel.cpp
  vncclient.cpp
  monitor_segmentation.cpp
)

set_target_properties(tigervnc_shared_client PROPERTIES POSITION_INDEPENDENT_CODE ON)

target_include_directories(tigervnc_shared_client PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${TIGERVNC_SOURCE_DIR}/common
)

target_link_libraries(tigervnc_shared_client rfb)
target_link_libraries(tigervnc_shared_client libssh2::libssh2_static)
