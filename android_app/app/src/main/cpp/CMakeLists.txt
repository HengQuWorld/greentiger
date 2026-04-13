cmake_minimum_required(VERSION 3.18.1)
project(vncbridge C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

get_filename_component(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../../" ABSOLUTE)
set(TIGERVNC_SOURCE_DIR "${REPO_ROOT}/third_party/tigervnc")
set(SHARED_NATIVE_DIR "${REPO_ROOT}/shared_native")

list(APPEND CMAKE_MODULE_PATH "${TIGERVNC_SOURCE_DIR}/cmake/Modules")
include(CMakeMacroLibtoolFile)

set(OHOS TRUE)
find_package(ZLIB REQUIRED)
add_compile_definitions(OHOS)

if(ANDROID)
  set(ANDROID_GNUTLS_DIR "${REPO_ROOT}/prebuilts/gnutls/android-${ANDROID_ABI}")
  if(NOT EXISTS "${ANDROID_GNUTLS_DIR}/lib/libgnutls.a")
    execute_process(
      COMMAND env
        "ANDROID_NDK_HOME=${ANDROID_NDK}"
        "ANDROID_ABI=${ANDROID_ABI}"
        "ANDROID_API_LEVEL=${ANDROID_PLATFORM_LEVEL}"
        "http_proxy=$ENV{http_proxy}"
        "https_proxy=$ENV{https_proxy}"
        bash "${REPO_ROOT}/build_tools/gnutls/android/build.sh" "${ANDROID_ABI}"
      WORKING_DIRECTORY "${REPO_ROOT}"
      RESULT_VARIABLE ANDROID_GNUTLS_BUILD_RESULT
    )
    if(NOT ANDROID_GNUTLS_BUILD_RESULT EQUAL 0)
      message(FATAL_ERROR "Failed to build Android GnuTLS/Nettle for ${ANDROID_ABI}")
    endif()
  endif()

  set(GNUTLS_FOUND TRUE)
  set(NETTLE_FOUND TRUE)
  set(GNUTLS_INCLUDE_DIR "${ANDROID_GNUTLS_DIR}/include")
  set(NETTLE_INCLUDE_DIRS "${ANDROID_GNUTLS_DIR}/include")
  set(GNUTLS_LIBRARIES "${ANDROID_GNUTLS_DIR}/lib/libgnutls.a")
  set(HOGWEED_LIBRARIES "${ANDROID_GNUTLS_DIR}/lib/libhogweed.a")
  set(NETTLE_LIBRARIES "${ANDROID_GNUTLS_DIR}/lib/libnettle.a")

  add_compile_definitions(HAVE_GNUTLS)
  add_compile_definitions(HAVE_NETTLE)
endif()

if(ANDROID)
  add_library(vncbridge SHARED vnc_jni.cpp)
else()
  find_package(JNI REQUIRED)
  add_library(vncbridge SHARED vnc_jni.cpp)
  target_include_directories(vncbridge PRIVATE ${JNI_INCLUDE_DIRS})
endif()

add_subdirectory("${TIGERVNC_SOURCE_DIR}/common" "${CMAKE_BINARY_DIR}/tigervnc_common")
add_subdirectory("${SHARED_NATIVE_DIR}" "${CMAKE_BINARY_DIR}/tigervnc_shared")

target_include_directories(vncbridge PRIVATE
  "${SHARED_NATIVE_DIR}"
)

target_link_libraries(vncbridge PRIVATE tigervnc_shared_client)

if(ANDROID)
  target_link_options(vncbridge PRIVATE "-Wl,--allow-multiple-definition")
  target_link_libraries(vncbridge PRIVATE log android jnigraphics)
endif()
