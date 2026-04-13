#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANDROID_DIR="${REPO_ROOT}/android_app"
OHOS_DIR="${REPO_ROOT}/ohos_app"
ANDROID_APK_RELATIVE_DIR="app/build/outputs/apk"
OHOS_HAP_PATH="${OHOS_DIR}/entry/build/default/outputs/default/entry-default-signed.hap"
OHOS_APP_PATH="${OHOS_DIR}/build/outputs/default/ohos_app-default-signed.app"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

print_selected_mode() {
  local mode="$1"
  log "Selected build mode: ${mode}"
  log "HarmonyOS signing mode: ${mode} (passed via SIGN_ACTIVE)"
}

print_artifact_summary() {
  local mode="$1"
  local android_apk="${ANDROID_DIR}/${ANDROID_APK_RELATIVE_DIR}/${mode}/app-${mode}.apk"

  log "Build outputs"
  printf '  Android APK: %s\n' "${android_apk}"
  if [[ -f "${android_apk}" ]]; then
    printf '    Status: present\n'
  else
    printf '    Status: missing\n'
  fi

  printf '  HarmonyOS HAP: %s\n' "${OHOS_HAP_PATH}"
  if [[ -f "${OHOS_HAP_PATH}" ]]; then
    printf '    Status: present\n'
  else
    printf '    Status: missing\n'
  fi

  printf '  HarmonyOS APP: %s\n' "${OHOS_APP_PATH}"
  if [[ -f "${OHOS_APP_PATH}" ]]; then
    printf '    Status: present\n'
  else
    printf '    Status: missing\n'
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

bootstrap_sources() {
  log "Checking Python dependencies for Mbed TLS"
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import jsonschema, jinja2" >/dev/null 2>&1; then
      log "Installing missing python dependencies (jsonschema, jinja2)..."
      python3 -m pip install --user jsonschema jinja2 >/dev/null 2>&1 || \
      python3 -m pip install --break-system-packages jsonschema jinja2 >/dev/null 2>&1 || true
    fi
  fi
  log "Initializing required submodules"
  (
    cd "${REPO_ROOT}"
    git submodule sync --recursive
    git submodule update --init --recursive \
      third_party/tigervnc \
      third_party/libssh2 \
      third_party/mbedtls-3.6.6
  )
}

collect_native_changes() {
  if ! command -v git >/dev/null 2>&1; then
    return 0
  fi
  if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  {
    git -C "${REPO_ROOT}" diff --name-only HEAD -- \
      shared_native \
      android_app/app/src/main/cpp \
      ohos_app/entry/src/main/cpp \
      shared_native/CMakeLists.txt \
      android_app/app/src/main/cpp/CMakeLists.txt \
      ohos_app/entry/src/main/cpp/CMakeLists.txt 2>/dev/null || true
    git -C "${REPO_ROOT}" ls-files --others --exclude-standard -- \
      shared_native \
      android_app/app/src/main/cpp \
      ohos_app/entry/src/main/cpp 2>/dev/null || true
  } | awk 'NF && !seen[$0]++'
}

run_android_build() {
  local mode="$1"
  log "Building Android ${mode} package"
  (
    cd "${ANDROID_DIR}"
    if [[ "${mode}" == "release" ]]; then
      ./gradlew assembleRelease
    else
      ./gradlew assembleDebug
    fi
  )
}

run_ohos_build() {
  local native_changes="$1"
  local mode="$2"

  if [[ -n "${native_changes}" ]]; then
    log "Native or CMake changes detected, running HarmonyOS clean first"
    printf '%s\n' "${native_changes}"
    (
      cd "${OHOS_DIR}"
      "${SCRIPT_DIR}/hvigorw-ohos.sh" clean
    )
  fi

  log "Building HarmonyOS application package (${mode})"
  (
    cd "${OHOS_DIR}"
    if [[ "${mode}" == "release" ]]; then
      SIGN_ACTIVE="${mode}" \
        "${SCRIPT_DIR}/hvigorw-ohos.sh" assembleApp -p product=default -p buildMode=release
    else
      SIGN_ACTIVE="${mode}" \
        "${SCRIPT_DIR}/hvigorw-ohos.sh" assembleApp
    fi
  )
}

main() {
  require_command bash
  require_command git

  if [[ ! -x "${ANDROID_DIR}/gradlew" ]]; then
    printf 'Android Gradle wrapper is missing or not executable: %s\n' "${ANDROID_DIR}/gradlew" >&2
    exit 1
  fi
  if [[ ! -x "${SCRIPT_DIR}/hvigorw-ohos.sh" ]]; then
    printf 'HarmonyOS wrapper is missing or not executable: %s\n' "${SCRIPT_DIR}/hvigorw-ohos.sh" >&2
    exit 1
  fi

  local build_mode="debug"
  if [[ "${1:-}" == "--release" || "${1:-}" == "release" ]]; then
    build_mode="release"
  fi

  local native_changes
  native_changes="$(collect_native_changes)"

  log "Repository root: ${REPO_ROOT}"
  print_selected_mode "${build_mode}"
  bootstrap_sources
  run_android_build "${build_mode}"
  run_ohos_build "${native_changes}" "${build_mode}"
  log "All platform builds completed successfully (${build_mode})"
  print_artifact_summary "${build_mode}"
}

main "$@"
