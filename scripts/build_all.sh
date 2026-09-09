#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANDROID_DIR="${REPO_ROOT}/android_app"
OHOS_DIR="${REPO_ROOT}/ohos_app"
ANDROID_APK_RELATIVE_DIR="app/build/outputs/apk"
OHOS_HAP_SRC="${OHOS_DIR}/entry/build/default/outputs/default/entry-default-signed.hap"
OHOS_HAP_SRC_UNSIGNED="${OHOS_DIR}/entry/build/default/outputs/default/entry-default-unsigned.hap"
OHOS_APP_SRC="${OHOS_DIR}/build/outputs/default/ohos_app-default-signed.app"
OHOS_APP_SRC_UNSIGNED="${OHOS_DIR}/build/outputs/default/ohos_app-default-unsigned.app"
ANDROID_CXX_DIR="${ANDROID_DIR}/app/.cxx"
ANDROID_NATIVE_CACHE_DIR="${ANDROID_DIR}/app/.native-libs-cache"
OHOS_CXX_DIR="${OHOS_DIR}/entry/.cxx"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

print_selected_mode() {
  local mode="$1"
  log "Selected build mode: ${mode}"
  log "HarmonyOS signing mode: ${mode} (via .build-signing-mode file)"
}

print_artifact_summary() {
  local mode="$1"
  local android_apk="${ANDROID_DIR}/${ANDROID_APK_RELATIVE_DIR}/${mode}/app-${mode}.apk"
  local ohos_hap="${OHOS_DIR}/build/outputs/default/${mode}/entry-default-signed.hap"
  local ohos_app="${OHOS_DIR}/build/outputs/default/${mode}/ohos_app-default-signed.app"

  log "Build outputs"
  printf '  Android APK: %s\n' "${android_apk}"
  if [[ -f "${android_apk}" ]]; then
    printf '    Status: present\n'
  else
    printf '    Status: missing\n'
  fi

  printf '  HarmonyOS HAP: %s\n' "${ohos_hap}"
  if [[ -f "${ohos_hap}" ]]; then
    printf '    Status: present\n'
  else
    printf '    Status: missing\n'
  fi

  printf '  HarmonyOS APP: %s\n' "${ohos_app}"
  if [[ -f "${ohos_app}" ]]; then
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

clean_native_build_cache() {
  log "Cleaning native build cache (forcing full C++ rebuild)"
  rm -rf "${ANDROID_CXX_DIR}" "${ANDROID_NATIVE_CACHE_DIR}" "${OHOS_CXX_DIR}"
}

run_android_build() {
  local mode="$1"
  local skip_native="$2"
  local native_note=""
  if [[ "${skip_native}" == "true" ]]; then
    native_note=" (skipping native)"
  fi
  log "Building Android ${mode} package${native_note}"
  (
    cd "${ANDROID_DIR}"
    local gradle_args=()
    if [[ "${mode}" == "release" ]]; then
      gradle_args+=("assembleRelease")
    else
      gradle_args+=("assembleDebug")
    fi
    if [[ "${skip_native}" == "true" ]]; then
      gradle_args+=("-PskipNativeBuild")
    fi
    ./gradlew "${gradle_args[@]}"
  )
}

run_ohos_build() {
  local native_changes="$1"
  local mode="$2"

  local mode_file="${OHOS_DIR}/.build-signing-mode"
  echo "${mode}" > "${mode_file}"
  trap "rm -f '${mode_file}'" RETURN

  if [[ -n "${native_changes}" ]]; then
    log "Native or CMake changes detected, running HarmonyOS clean first"
    printf '%s\n' "${native_changes}"
    # hvigor clean only removes hvigor's build/ output, not the CMake/Ninja
    # intermediates under entry/.cxx. Drop that dir too so stale .o files are
    # not reused and the C++ sources are actually recompiled.
    rm -rf "${OHOS_CXX_DIR}"
    (
      cd "${OHOS_DIR}"
      "${SCRIPT_DIR}/hvigorw-ohos.sh" clean
    )
  fi

  log "Building HarmonyOS application package (${mode})"
  (
    cd "${OHOS_DIR}"
    if [[ "${mode}" == "release" ]]; then
      "${SCRIPT_DIR}/hvigorw-ohos.sh" assembleApp -p product=default -p buildMode=release
    else
      "${SCRIPT_DIR}/hvigorw-ohos.sh" assembleApp -p product=default -p buildMode=debug
    fi
  )

  local out_dir="${OHOS_DIR}/build/outputs/default/${mode}"
  mkdir -p "${out_dir}"

  if [[ -f "${OHOS_HAP_SRC}" ]]; then
    cp "${OHOS_HAP_SRC}" "${out_dir}/entry-default-signed.hap"
  fi
  if [[ -f "${OHOS_HAP_SRC_UNSIGNED}" ]]; then
    cp "${OHOS_HAP_SRC_UNSIGNED}" "${out_dir}/entry-default-unsigned.hap"
  fi
  if [[ -f "${OHOS_APP_SRC}" ]]; then
    cp "${OHOS_APP_SRC}" "${out_dir}/ohos_app-default-signed.app"
  fi
  if [[ -f "${OHOS_APP_SRC_UNSIGNED}" ]]; then
    cp "${OHOS_APP_SRC_UNSIGNED}" "${out_dir}/ohos_app-default-unsigned.app"
  fi

  log "HarmonyOS artifacts saved to: ${out_dir}"
  ls -la "${out_dir}/"
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
  local platform="all"
  local skip_native="auto"
  local force_native="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release|release)
        build_mode="release"
        ;;
      --android|android)
        platform="android"
        ;;
      --ohos|ohos)
        platform="ohos"
        ;;
      --skip-native|fast)
        skip_native="true"
        ;;
      --full|full)
        skip_native="false"
        ;;
      --clean-native|--force-native|--force)
        force_native="true"
        ;;
      --help|-h)
        printf 'Usage: %s [OPTIONS]\n\n' "${BASH_SOURCE[0]}"
        printf 'Options:\n'
        printf '  --release     Release build (default: debug)\n'
        printf '  --android     Build Android only\n'
        printf '  --ohos        Build HarmonyOS only\n'
        printf '  --skip-native Skip native CMake build (requires prior full build)\n'
        printf '  --full        Force full build including native code\n'
        printf '  --clean-native Clean native build cache and force full C++ rebuild\n'
        printf '  --help        Show this help\n'
        printf '\nAuto-detection (default):\n'
        printf '  If neither --skip-native nor --full is specified, the script\n'
        printf '  automatically detects native code changes and skips CMake when\n'
        printf '  only frontend (Kotlin/Compose) code has been modified.\n'
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
    shift
  done

  local native_changes
  native_changes="$(collect_native_changes)"

  if [[ "${skip_native}" == "auto" ]]; then
    local native_cache="${ANDROID_DIR}/app/.native-libs-cache"
    if [[ -n "${native_changes}" ]]; then
      skip_native="false"
      log "Auto-detect: native code changed, full build required"
      printf '  Changed files:\n'
      printf '%s\n' "${native_changes}" | sed 's/^/    /'
    elif [[ ! -d "${native_cache}" ]] || [[ -z "$(ls -A "${native_cache}" 2>/dev/null)" ]]; then
      skip_native="false"
      log "Auto-detect: no cached native libs found, full build required"
    else
      skip_native="true"
      log "Auto-detect: no native code changes, skipping CMake build"
    fi
  fi

  if [[ "${force_native}" == "true" ]]; then
    clean_native_build_cache
    skip_native="false"
    log "Forced native rebuild: native cache cleared"
  fi

  log "Repository root: ${REPO_ROOT}"
  print_selected_mode "${build_mode}"
  if [[ "${platform}" != "ohos" ]]; then
    bootstrap_sources
  fi

  if [[ "${platform}" == "ohos" ]]; then
    bootstrap_sources
    run_ohos_build "${native_changes}" "${build_mode}"
  elif [[ "${platform}" == "android" ]]; then
    run_android_build "${build_mode}" "${skip_native}"
  else
    run_android_build "${build_mode}" "${skip_native}"
    run_ohos_build "${native_changes}" "${build_mode}"
  fi

  log "Build completed successfully (${build_mode}, platform=${platform}${skip_native:+, skip-native})"
  print_artifact_summary "${build_mode}"
}

main "$@"
