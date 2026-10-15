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
GNUTLS_TOOLS_DIR="${REPO_ROOT}/build_tools/gnutls"
GNUTLS_PREBUILTS_DIR="${REPO_ROOT}/prebuilts/gnutls"
# Keep in sync with abiFilters in android_app/app/build.gradle.kts and with the
# ABI list the HarmonyOS product builds. Override with ANDROID_ABIS / OHOS_ARCH.
ANDROID_GNUTLS_ABIS=(${ANDROID_ABIS:-arm64-v8a x86_64})
OHOS_GNUTLS_ARCH="${OHOS_ARCH:-arm64-v8a}"

# Shared discovery helpers (HarmonyOS SDK / Android NDK) live next to the
# GnuTLS prebuilt scripts and are reused here for the preflight check.
if [[ -f "${GNUTLS_TOOLS_DIR}/common.sh" ]]; then
  # shellcheck source=../build_tools/gnutls/common.sh
  . "${GNUTLS_TOOLS_DIR}/common.sh"
fi

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

print_selected_mode() {
  local mode="$1"
  log "Selected build mode: ${mode}"
  log "HarmonyOS signing mode: ${mode} (via .build-signing-mode file)"
}

report_artifact() {
  local label="$1"
  local path="$2"
  local fallback_path="${3:-}"

  printf '  %s: %s\n' "${label}" "${path}"
  if [[ -f "${path}" ]]; then
    printf '    Status: present\n'
  elif [[ -n "${fallback_path}" && -f "${fallback_path}" ]]; then
    printf '    Status: present (unsigned): %s\n' "${fallback_path}"
  else
    printf '    Status: missing\n'
  fi
}

print_artifact_summary() {
  local mode="$1"
  local android_apk="${ANDROID_DIR}/${ANDROID_APK_RELATIVE_DIR}/${mode}/app-${mode}.apk"
  local ohos_hap="${OHOS_DIR}/build/outputs/default/${mode}/entry-default-signed.hap"
  local ohos_hap_unsigned="${OHOS_DIR}/build/outputs/default/${mode}/entry-default-unsigned.hap"
  local ohos_app="${OHOS_DIR}/build/outputs/default/${mode}/ohos_app-default-signed.app"
  local ohos_app_unsigned="${OHOS_DIR}/build/outputs/default/${mode}/ohos_app-default-unsigned.app"

  log "Build outputs"
  report_artifact "Android APK" "${android_apk}"
  report_artifact "HarmonyOS HAP" "${ohos_hap}" "${ohos_hap_unsigned}"
  report_artifact "HarmonyOS APP" "${ohos_app}" "${ohos_app_unsigned}"

  if [[ ! -f "${ohos_hap}" && -f "${ohos_hap_unsigned}" ]]; then
    printf '    Note: HarmonyOS signing skipped; set sign.%s.* keys in ohos_app/local.properties\n' "${mode}"
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
  if ! (
    cd "${REPO_ROOT}"
    git submodule sync --recursive &&
      git submodule update --init --recursive \
        third_party/tigervnc \
        third_party/libssh2 \
        third_party/mbedtls-3.6.6
  ); then
    printf 'Failed to initialize git submodules (the first build needs network access).\n' >&2
    printf 'Retry with: git submodule update --init --recursive\n' >&2
    exit 1
  fi
}

# Kotlin 1.9.24 (and Gradle 8.7) cannot run on JDKs newer than 21: the embedded
# Kotlin compiler fails to parse the Java version (e.g. "25.0.3").
MIN_ANDROID_JDK=17
MAX_ANDROID_JDK=21

jdk_major_version() {
  local home="${1:-}"
  [[ -n "${home}" && -x "${home}/bin/java" ]] || return 1

  local version
  version="$("${home}/bin/java" -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -n "${version}" ]] || return 1

  case "${version}" in
    1.*) printf '%s\n' "$(printf '%s' "${version}" | cut -d. -f2)" ;;
    *) printf '%s\n' "${version%%[.-]*}" ;;
  esac
}

# Highest JDK found within [MIN_ANDROID_JDK, MAX_ANDROID_JDK].
# Filled in by preflight_toolchain so the Gradle build does not re-discover it.
ANDROID_BUILD_JDK=""

resolve_android_build_jdk() {
  local -a candidates=()
  local candidate major best="" best_major=0

  candidates+=("${JAVA_HOME:-}")

  # macOS keeps JDKs in one place; java_home -V lists all of them in one call.
  if [[ -x /usr/libexec/java_home ]]; then
    while read -r candidate; do
      candidates+=("${candidate}")
    done < <(/usr/libexec/java_home -V 2>&1 | awk '$NF ~ /^\// {print $NF}')
  fi

  candidates+=(
    "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    "${HOME}/Library/Java/JavaVirtualMachines"/*/Contents/Home
  )

  for candidate in "${candidates[@]}"; do
    major="$(jdk_major_version "${candidate}" 2>/dev/null)" || continue
    if [[ "${major}" -ge "${MIN_ANDROID_JDK}" && "${major}" -le "${MAX_ANDROID_JDK}" && "${major}" -gt "${best_major}" ]]; then
      best="${candidate}"
      best_major="${major}"
    fi
  done

  [[ -n "${best}" ]] || return 1
  printf '%s\n' "${best}"
}

# Report the local toolchain up front so a fresh machine fails here with an
# actionable message instead of minutes later inside a toolchain error.
preflight_toolchain() {
  local platform="$1"
  local skip_native="$2"
  local failures=0
  local ohos_sdk="" ndk="" jdk=""

  log "Checking local toolchain"

  if [[ "${platform}" != "android" ]]; then
    if ohos_sdk="$(resolve_ohos_sdk_native "${REPO_ROOT}")"; then
      printf '  HarmonyOS native SDK: %s\n' "${ohos_sdk}"
    else
      printf '  HarmonyOS native SDK: NOT FOUND\n' >&2
      printf '    Install DevEco Studio (its bundled SDK is detected automatically), or set\n' >&2
      printf '    OHOS_SDK_NATIVE / ohos_app/local.properties (hwsdk.dir|sdk.dir).\n' >&2
      failures=$((failures + 1))
    fi
  fi

  if [[ "${platform}" != "ohos" ]]; then
    if jdk="$(resolve_android_build_jdk)"; then
      ANDROID_BUILD_JDK="${jdk}"
      printf '  Android Gradle JDK : Java %s (%s)\n' "$(jdk_major_version "${jdk}")" "${jdk}"
    else
      printf '  Android Gradle JDK : NOT FOUND (need Java %s-%s)\n' "${MIN_ANDROID_JDK}" "${MAX_ANDROID_JDK}" >&2
      printf '    Kotlin 1.9.24 cannot run on newer JDKs. Install a JDK %s-%s, set JAVA_HOME,\n' "${MIN_ANDROID_JDK}" "${MAX_ANDROID_JDK}" >&2
      printf '    or set "Gradle JDK" to %s-%s in Android Studio.\n' "${MIN_ANDROID_JDK}" "${MAX_ANDROID_JDK}" >&2
      failures=$((failures + 1))
    fi

    if [[ "${skip_native}" == "true" ]]; then
      printf '  Android NDK        : not needed (--skip-native)\n'
    elif ndk="$(resolve_android_ndk "${REPO_ROOT}")"; then
      printf '  Android NDK        : %s\n' "${ndk}"
    else
      printf '  Android NDK        : NOT FOUND\n' >&2
      printf '    Install it from Android Studio > SDK Manager > NDK, or set ANDROID_NDK_HOME.\n' >&2
      printf '    Pass --skip-native if you only changed frontend code.\n' >&2
      failures=$((failures + 1))
    fi
  fi

  if [[ "${failures}" -gt 0 ]]; then
    printf '\nMissing prerequisites listed above: install them and rerun.\n' >&2
    printf 'GnuTLS/Nettle prebuilts are downloaded and cross-compiled automatically once the SDK/NDK is available.\n' >&2
    exit 1
  fi

  if [[ -n "${ndk}" ]] && android_ndk_incompatible_with_gnutls "${ndk}"; then
    printf '  note: this NDK typedefs timezone_t, which GnuTLS %s cannot build against;\n' "${GNUTLS_VERSION}" >&2
    printf '        install an older NDK (e.g. 26.1.10909125) or pin ANDROID_NDK_HOME to one.\n' >&2
  fi
}

gnutls_prebuilts_present() {
  local dir="$1"
  [[ -f "${dir}/lib/libgnutls.a" && -f "${dir}/lib/libnettle.a" && -f "${dir}/lib/libhogweed.a" ]]
}

ohos_prebuilt_dir_name() {
  case "$1" in
    arm64-v8a) printf 'ohos-arm64\n' ;;
    x86_64) printf 'ohos-x86_64\n' ;;
    *) return 1 ;;
  esac
}

ensure_gnutls_prebuilt() {
  # <label> <prebuilt-dir-name> <hint-on-failure> <command...>
  local label="$1"
  local prebuilt_name="$2"
  local hint="$3"
  shift 3
  local prebuilt_dir="${GNUTLS_PREBUILTS_DIR}/${prebuilt_name}"

  if gnutls_prebuilts_present "${prebuilt_dir}"; then
    log "${label} GnuTLS prebuilts ready (${prebuilt_name})"
    return 0
  fi

  log "Preparing ${label} GnuTLS prebuilts (${prebuilt_name}): downloads and cross-compiles Nettle + GnuTLS"
  if ! "$@"; then
    printf 'Failed to prepare GnuTLS prebuilts in %s\n%s\n' "${prebuilt_dir}" "${hint}" >&2
    exit 1
  fi
  if ! gnutls_prebuilts_present "${prebuilt_dir}"; then
    printf 'GnuTLS prebuilt step did not produce %s\n' "${prebuilt_dir}/lib/libgnutls.a" >&2
    exit 1
  fi
}

ensure_ohos_gnutls_prebuilts() {
  local prebuilt_name
  if ! prebuilt_name="$(ohos_prebuilt_dir_name "${OHOS_GNUTLS_ARCH}")"; then
    printf 'Unsupported HarmonyOS ABI for GnuTLS prebuilts: %s (supported: arm64-v8a, x86_64)\n' "${OHOS_GNUTLS_ARCH}" >&2
    exit 1
  fi

  ensure_gnutls_prebuilt "HarmonyOS" "${prebuilt_name}" \
    "Set OHOS_SDK_NATIVE to your HarmonyOS native SDK, or run build_tools/gnutls/ohos/build.sh for the full log." \
    env "OHOS_ARCH=${OHOS_GNUTLS_ARCH}" bash "${GNUTLS_TOOLS_DIR}/ohos/build.sh"
}

ensure_android_gnutls_prebuilts() {
  local abi

  for abi in "${ANDROID_GNUTLS_ABIS[@]}"; do
    ensure_gnutls_prebuilt "Android" "android-${abi}" \
      "Install an Android NDK (Android Studio > SDK Manager, or set ANDROID_NDK_HOME), or rerun with --skip-native to skip the native build." \
      bash "${GNUTLS_TOOLS_DIR}/android/build.sh" "${abi}"
  done
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

  # preflight_toolchain normally fills this in; resolve again when the build is
  # invoked through a path that skips preflight.
  local jdk_home="${ANDROID_BUILD_JDK}"
  if [[ -z "${jdk_home}" ]]; then
    if ! jdk_home="$(resolve_android_build_jdk)"; then
      printf 'No JDK %s-%s found for the Android build; install one or set JAVA_HOME.\n' \
        "${MIN_ANDROID_JDK}" "${MAX_ANDROID_JDK}" >&2
      exit 1
    fi
  fi
  log "Android build JDK: ${jdk_home} (Java $(jdk_major_version "${jdk_home}"))"

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
    JAVA_HOME="${jdk_home}" PATH="${jdk_home}/bin:${PATH}" ./gradlew "${gradle_args[@]}"
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

  require_command curl

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
      --debug|debug)
        build_mode="debug"
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
        printf '  --debug       Debug build (default)\n'
        printf '  --android     Build Android only\n'
        printf '  --ohos        Build HarmonyOS only\n'
        printf '  --skip-native Skip native CMake build (requires prior full build)\n'
        printf '  --full        Force full build including native code\n'
        printf '  --clean-native Clean native build cache and force full C++ rebuild\n'
        printf '  --help        Show this help\n'
        printf '\nPrebuilts:\n'
        printf '  GnuTLS/Nettle prebuilts under prebuilts/gnutls/ are produced on demand\n'
        printf '  by build_tools/gnutls/{ohos,android}/build.sh, which download the\n'
        printf '  pinned upstream sources and cross-compile them for the target ABI.\n'
        printf '  Override the HarmonyOS ABI with OHOS_ARCH and the Android ABI list\n'
        printf '  with ANDROID_ABIS (default: arm64-v8a x86_64).\n'
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
  preflight_toolchain "${platform}" "${skip_native}"
  bootstrap_sources

  if [[ "${platform}" == "ohos" ]]; then
    ensure_ohos_gnutls_prebuilts
    run_ohos_build "${native_changes}" "${build_mode}"
  elif [[ "${platform}" == "android" ]]; then
    if [[ "${skip_native}" != "true" ]]; then
      ensure_android_gnutls_prebuilts
    fi
    run_android_build "${build_mode}" "${skip_native}"
  else
    if [[ "${skip_native}" != "true" ]]; then
      ensure_android_gnutls_prebuilts
    fi
    run_android_build "${build_mode}" "${skip_native}"
    ensure_ohos_gnutls_prebuilts
    run_ohos_build "${native_changes}" "${build_mode}"
  fi

  log "Build completed successfully (${build_mode}, platform=${platform}${skip_native:+, skip-native})"
  print_artifact_summary "${build_mode}"
}

main "$@"
