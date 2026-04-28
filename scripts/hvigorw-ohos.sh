#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OHOS_DIR="${REPO_ROOT}/ohos_app"

log() {
  printf '[hvigorw-ohos] %s\n' "$1" >&2
}

read_local_property() {
  local properties_file="$1"
  local key="$2"

  if [[ ! -f "${properties_file}" ]]; then
    return 0
  fi

  awk -F= -v property_key="${key}" '
    $1 == property_key {
      sub(/^[^=]*=/, "", $0)
      print
      exit
    }
  ' "${properties_file}"
}

resolve_sdk_dir() {
  local properties_file="${OHOS_DIR}/local.properties"
  local sdk_dir=""

  sdk_dir="$(read_local_property "${properties_file}" "hwsdk.dir")"
  if [[ -z "${sdk_dir}" ]]; then
    sdk_dir="$(read_local_property "${properties_file}" "sdk.dir")"
  fi
  if [[ -z "${sdk_dir}" ]]; then
    sdk_dir="/Applications/DevEco-Studio.app/Contents/sdk"
  fi

  if [[ ! -d "${sdk_dir}" ]]; then
    printf 'Invalid HarmonyOS SDK directory: %s\n' "${sdk_dir}" >&2
    exit 1
  fi

  printf '%s\n' "${sdk_dir}"
}

resolve_hvigor_bin() {
  local sdk_dir="$1"
  local deveco_root
  local hvigor_bin=""

  deveco_root="$(cd "${sdk_dir}/.." && pwd)"
  hvigor_bin="${deveco_root}/tools/hvigor/bin/hvigorw"

  if [[ -x "${hvigor_bin}" ]]; then
    printf '%s\n' "${hvigor_bin}"
    return 0
  fi

  if command -v hvigorw >/dev/null 2>&1; then
    command -v hvigorw
    return 0
  fi

  printf 'Unable to find hvigorw. Expected: %s\n' "${hvigor_bin}" >&2
  exit 1
}

stop_daemon_once_per_sdk() {
  local sdk_dir="$1"
  local hvigor_bin="$2"
  local repo_id=""
  local stamp_file=""
  local previous_sdk=""

  repo_id="$(printf '%s\n' "${REPO_ROOT}" | cksum | awk '{print $1}')"
  stamp_file="${TMPDIR:-/tmp}/hvigorw-ohos-sdk-${repo_id}.stamp"

  if [[ -f "${stamp_file}" ]]; then
    previous_sdk="$(<"${stamp_file}")"
  fi

  if [[ "${previous_sdk}" != "${sdk_dir}" ]]; then
    log "Refreshing hvigor daemon for SDK ${sdk_dir}"
    env -u DEVECO_SDK_HOME -u HOS_SDK_HOME -u OHOS_SDK_HOME -u OHOS_BASE_SDK_HOME \
      DEVECO_SDK_HOME="${sdk_dir}" \
      "${hvigor_bin}" --stop-daemon >/dev/null 2>&1 || true
    printf '%s\n' "${sdk_dir}" > "${stamp_file}"
  fi
}

main() {
  if [[ $# -eq 0 ]]; then
    printf 'Usage: %s <hvigor args...>\n' "${0##*/}" >&2
    exit 1
  fi

  local sdk_dir
  local hvigor_bin

  sdk_dir="$(resolve_sdk_dir)"
  hvigor_bin="$(resolve_hvigor_bin "${sdk_dir}")"
  stop_daemon_once_per_sdk "${sdk_dir}" "${hvigor_bin}"

  (
    cd "${OHOS_DIR}"
    env -u DEVECO_SDK_HOME -u HOS_SDK_HOME -u OHOS_SDK_HOME -u OHOS_BASE_SDK_HOME \
      DEVECO_SDK_HOME="${sdk_dir}" \
      SIGN_ACTIVE="${SIGN_ACTIVE:-}" \
      "${hvigor_bin}" "$@"
  )
}

main "$@"
