#!/usr/bin/env bash
# Build and run the host-native tests for shared_native/.
#
# These tests need only a C++17 compiler: no HarmonyOS SDK, no Android NDK, no
# device. They cover the platform-independent pieces of the native layer.
#
# Usage:
#   ./scripts/test_native.sh           # configure, build, run
#   ./scripts/test_native.sh --clean   # start from a fresh build directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_SOURCE_DIR="${REPO_ROOT}/shared_native/tests"
BUILD_DIR="${REPO_ROOT}/build/native-tests"

log() {
  printf '[test_native] %s\n' "$1" >&2
}

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "${BUILD_DIR}"
fi

find_cmake() {
  if command -v cmake >/dev/null 2>&1; then
    command -v cmake
    return 0
  fi
  # The HarmonyOS SDK ships a host cmake that works for building ordinary
  # desktop binaries, so a DevEco-only machine needs no extra install.
  local sdk_cmake
  for sdk_cmake in \
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/build-tools/cmake/bin/cmake" \
    "${HOME}/Library/Huawei/Sdk/openharmony/native/build-tools/cmake/bin/cmake"; do
    if [[ -x "${sdk_cmake}" ]]; then
      printf '%s\n' "${sdk_cmake}"
      return 0
    fi
  done
  return 1
}

CMAKE_BIN="$(find_cmake)" || {
  printf 'cmake not found. Install CMake 3.16 or newer and retry.\n' >&2
  exit 1
}

CXX_COMPILER="${CXX:-}"
if [[ -z "${CXX_COMPILER}" ]]; then
  if command -v clang++ >/dev/null 2>&1; then
    CXX_COMPILER="$(command -v clang++)"
  elif command -v g++ >/dev/null 2>&1; then
    CXX_COMPILER="$(command -v g++)"
  else
    printf 'No C++ compiler found. Install clang++ or g++ and retry.\n' >&2
    exit 1
  fi
fi

log "compiler: ${CXX_COMPILER}"
log "cmake: ${CMAKE_BIN}"
log "build dir: ${BUILD_DIR}"

"${CMAKE_BIN}" -S "${TEST_SOURCE_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_CXX_COMPILER="${CXX_COMPILER}" \
  -DCMAKE_BUILD_TYPE=Debug >/dev/null

"${CMAKE_BIN}" --build "${BUILD_DIR}" --parallel >/dev/null

CTEST_BIN="$(dirname "${CMAKE_BIN}")/ctest"
if [[ -x "${CTEST_BIN}" ]]; then
  "${CTEST_BIN}" --test-dir "${BUILD_DIR}" --output-on-failure
else
  "${CMAKE_BIN}" --build "${BUILD_DIR}" --target test
fi
