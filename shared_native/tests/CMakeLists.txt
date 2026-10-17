# Host-native tests for shared_native/.
#
# These run on the build machine with the host compiler: no HarmonyOS SDK, no
# Android NDK, no TigerVNC, no libssh2. Only translation units that are free of
# platform and third-party dependencies may be listed here.
#
#   cmake -S shared_native/tests -B build/native-tests
#   cmake --build build/native-tests
#   ctest --test-dir build/native-tests --output-on-failure
#
# or simply: ./scripts/test_native.sh

cmake_minimum_required(VERSION 3.16)
project(greentiger_native_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug CACHE STRING "" FORCE)
endif()

get_filename_component(SHARED_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

enable_testing()

add_library(test_support INTERFACE)
target_include_directories(test_support INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${SHARED_NATIVE_DIR}"
)

# ---------------------------------------------------------------------------
# Pixel conversion (header-only, shared by the NAPI and JNI bridges)
# ---------------------------------------------------------------------------
add_executable(pixel_convert_test pixel_convert_test.cpp)
target_link_libraries(pixel_convert_test PRIVATE test_support)
target_compile_options(pixel_convert_test PRIVATE -Wall -Wextra)
add_test(NAME pixel_convert COMMAND pixel_convert_test)

# ---------------------------------------------------------------------------
# Monitor segmentation (pure C++, no platform dependencies)
# ---------------------------------------------------------------------------
add_executable(monitor_segmentation_test
  monitor_segmentation_test.cpp
  "${SHARED_NATIVE_DIR}/monitor_segmentation.cpp"
)
target_link_libraries(monitor_segmentation_test PRIVATE test_support)
target_compile_options(monitor_segmentation_test PRIVATE -Wall -Wextra)
add_test(NAME monitor_segmentation COMMAND monitor_segmentation_test)

# ---------------------------------------------------------------------------
# SSH tunnel configuration rules (libssh2-free translation unit)
# ---------------------------------------------------------------------------
add_executable(ssh_tunnel_config_test
  ssh_tunnel_config_test.cpp
  "${SHARED_NATIVE_DIR}/ssh_tunnel_config.cpp"
)
target_link_libraries(ssh_tunnel_config_test PRIVATE test_support)
target_compile_options(ssh_tunnel_config_test PRIVATE -Wall -Wextra)
add_test(NAME ssh_tunnel_config COMMAND ssh_tunnel_config_test)
