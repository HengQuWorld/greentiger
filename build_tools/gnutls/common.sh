#!/bin/bash
# Shared helpers for the GnuTLS/Nettle prebuilt build scripts.
#
# Sourced by:
#   build_tools/gnutls/ohos/build.sh
#   build_tools/gnutls/android/build.sh
#
# Provides: version + checksum pins, archive download/verification, and
# discovery of the OHOS native SDK / Android NDK needed for cross-compiling.
# Stays bash 3.2 compatible (macOS system bash).

# ---------------------------------------------------------------------------
# Pinned upstream releases
# ---------------------------------------------------------------------------
# Both archives are fetched over TLS and verified against a pinned SHA-256.
# To upgrade, bump the version and replace the hash with the value obtained
# from an independently fetched copy of the official tarball.
NETTLE_VERSION="3.9"
GNUTLS_VERSION="3.8.4"
GNUTLS_SERIES="$(printf '%s' "${GNUTLS_VERSION}" | cut -d. -f1,2)"

NETTLE_TARBALL="nettle-${NETTLE_VERSION}.tar.gz"
GNUTLS_TARBALL="gnutls-${GNUTLS_VERSION}.tar.xz"

NETTLE_URL="${NETTLE_URL:-https://ftp.gnu.org/gnu/nettle/${NETTLE_TARBALL}}"
GNUTLS_URL="${GNUTLS_URL:-https://www.gnupg.org/ftp/gcrypt/gnutls/v${GNUTLS_SERIES}/${GNUTLS_TARBALL}}"

NETTLE_SHA256="0ee7adf5a7201610bb7fe0acbb7c9b3be83be44904dd35ebbcd965cd896bfeaa"
GNUTLS_SHA256="2bea4e154794f3f00180fa2a5c51fe8b005ac7a31cd58bd44cdfa7f36ebc3a9b"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
gnutls_log() {
    printf '[gnutls] %s\n' "$*"
}

gnutls_die() {
    printf '[gnutls] ERROR: %s\n' "$*" >&2
    exit 1
}

# Diagnostics for functions whose stdout is captured by the caller.
gnutls_warn() {
    printf '[gnutls] %s\n' "$*" >&2
}

# Cross-compiling GNU sources needs a small set of host tools.
gnutls_require_tools() {
    local tool
    local -a missing=()

    for tool in curl tar make awk sed; do
        command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        gnutls_die "missing required tool(s): ${missing[*]}
Install them and retry (macOS: 'xcode-select --install' provides make/tar; curl ships with macOS)."
    fi
}

# ---------------------------------------------------------------------------
# Property files (never echoed wholesale: these files can hold signing secrets)
# ---------------------------------------------------------------------------
read_property() {
    local file="$1"
    local key="$2"

    if [ ! -f "${file}" ]; then
        return 0
    fi

    awk -F= -v property_key="${key}" '
        $1 == property_key {
            sub(/^[^=]*=/, "", $0)
            gsub(/^[ \t]+|[ \t]+$/, "", $0)
            print
            exit
        }
    ' "${file}"
}

# ---------------------------------------------------------------------------
# Archive download + verification
# ---------------------------------------------------------------------------
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        gnutls_die "no SHA-256 tool available (need shasum or sha256sum)"
    fi
}

archive_extracts() {
    local archive="$1"
    if [ ! -f "${archive}" ]; then
        return 1
    fi
    case "${archive}" in
        *.tar.gz|*.tgz)
            tar -tzf "${archive}" >/dev/null 2>&1
            ;;
        *.tar.xz|*.txz)
            tar -tJf "${archive}" >/dev/null 2>&1
            ;;
        *)
            tar -tf "${archive}" >/dev/null 2>&1
            ;;
    esac
}

# archive_is_valid <archive> <expected_sha256>
archive_is_valid() {
    local archive="$1"
    local expected="$2"
    local actual

    archive_extracts "${archive}" || return 1
    actual="$(sha256_of "${archive}")"
    if [ "${actual}" != "${expected}" ]; then
        gnutls_log "Checksum mismatch for ${archive}"
        gnutls_log "  expected ${expected}"
        gnutls_log "  actual   ${actual}"
        return 1
    fi
    return 0
}

download_file() {
    local url="$1"
    local output="$2"
    local tmp_output="${output}.tmp"
    local -a curl_args=(-fL --retry 3 --retry-delay 2 --connect-timeout 15 -# -o "${tmp_output}")

    if [ -n "${GNUTLS_DOWNLOAD_PROXY:-}" ]; then
        curl_args=(-x "${GNUTLS_DOWNLOAD_PROXY}" "${curl_args[@]}")
    elif [ -n "${https_proxy:-}" ]; then
        curl_args=(-x "${https_proxy}" "${curl_args[@]}")
    elif [ -n "${http_proxy:-}" ]; then
        curl_args=(-x "${http_proxy}" "${curl_args[@]}")
    fi

    rm -f "${tmp_output}"
    gnutls_log "Downloading $(basename "${output}") from ${url}"
    if ! curl "${curl_args[@]}" "${url}"; then
        rm -f "${tmp_output}"
        gnutls_die "failed to download ${url}"
    fi
    mv "${tmp_output}" "${output}"
}

# ensure_archive <url> <output> <expected_sha256>
# Reuses a cached archive when it matches the pinned checksum, otherwise
# downloads it. Never leaves an unverified archive behind.
ensure_archive() {
    local url="$1"
    local output="$2"
    local expected="$3"

    if archive_is_valid "${output}" "${expected}"; then
        gnutls_log "Using cached $(basename "${output}") (checksum verified)"
        return 0
    fi

    rm -f "${output}"
    download_file "${url}" "${output}"

    if ! archive_is_valid "${output}" "${expected}"; then
        rm -f "${output}"
        gnutls_die "downloaded archive ${output} failed verification; refusing to build from it"
    fi
    gnutls_log "Verified $(basename "${output}") against pinned SHA-256"
}

# ---------------------------------------------------------------------------
# OHOS native SDK discovery
# ---------------------------------------------------------------------------
# A usable OHOS native SDK has llvm/bin/clang and a sysroot for the target ABI.
ohos_sdk_native_is_valid() {
    local dir="$1"
    [ -n "${dir}" ] && [ -x "${dir}/llvm/bin/clang" ] && [ -d "${dir}/sysroot" ]
}

# Expand an SDK root (or a directory that already is the native SDK) into
# candidate native-SDK directories. Newer DevEco layouts keep the SDK under
# <root>/default/openharmony/native; older ones use <root>/<api>/native.
ohos_sdk_native_candidates() {
    local root="$1"

    [ -n "${root}" ] && [ -d "${root}" ] || return 0

    local entry
    {
        printf '%s\n' "${root}"
        printf '%s\n' "${root}/native"
        printf '%s\n' "${root}/openharmony/native"
        printf '%s\n' "${root}/default/openharmony/native"
        for entry in "${root}"/*; do
            [ -d "${entry}" ] || continue
            printf '%s\n' "${entry}/native"
            printf '%s\n' "${entry}/openharmony"
            printf '%s\n' "${entry}/openharmony/native"
        done
    } | awk '!seen[$0]++'
}

# resolve_ohos_sdk_native <repo_root> — prints the native SDK path or returns 1
resolve_ohos_sdk_native() {
    local repo_root="$1"
    local candidate
    local root
    local -a roots=()

    if [ -n "${OHOS_SDK_NATIVE:-}" ]; then
        if ohos_sdk_native_is_valid "${OHOS_SDK_NATIVE}"; then
            printf '%s\n' "${OHOS_SDK_NATIVE}"
            return 0
        fi
        gnutls_warn "OHOS_SDK_NATIVE=${OHOS_SDK_NATIVE} is not a usable native SDK, searching further"
    fi

    roots+=("${DEVECO_SDK_HOME:-}")
    roots+=("/Applications/DevEco-Studio.app/Contents/sdk")
    roots+=("${HOME}/Applications/DevEco-Studio.app/Contents/sdk")

    # hvigor reads these same keys for the HarmonyOS SDK location.
    local props sdk_dir
    for props in "${repo_root}/ohos_app/local.properties" "${repo_root}/local.properties"; do
        sdk_dir="$(read_property "${props}" "hwsdk.dir")"
        if [ -z "${sdk_dir}" ]; then
            sdk_dir="$(read_property "${props}" "sdk.dir")"
        fi
        if [ -n "${sdk_dir}" ]; then
            if [ -d "${sdk_dir}" ]; then
                roots+=("${sdk_dir}")
            else
                gnutls_warn "ignoring ${props}: sdk.dir=${sdk_dir} does not exist"
            fi
        fi
    done

    roots+=("${HOME}/Library/OpenHarmony/Sdk")
    roots+=("${HOME}/Library/Huawei/Sdk")

    for root in "${roots[@]}"; do
        for candidate in $(ohos_sdk_native_candidates "${root}"); do
            if ohos_sdk_native_is_valid "${candidate}"; then
                printf '%s\n' "${candidate}"
                return 0
            fi
        done
    done

    gnutls_warn "no HarmonyOS native SDK found (need a directory with llvm/bin/clang and sysroot/)"
    return 1
}

# ---------------------------------------------------------------------------
# Android NDK discovery
# ---------------------------------------------------------------------------
# An NDK ships the LLVM cross toolchain under toolchains/llvm/prebuilt.
android_ndk_is_valid() {
    local dir="$1"
    [ -n "${dir}" ] && [ -d "${dir}/toolchains/llvm/prebuilt" ]
}

# GnuTLS 3.8.4 bundles a gnulib copy that cannot be compiled against bionic
# headers which already typedef timezone_t while hiding tzalloc/tzfree behind
# __INTRODUCED_IN gates (NDK 29+): the calls have no declaration left, which
# modern clang rejects, and forcing gnulib's own typedef collides with bionic's.
# Detect the condition in the NDK's headers instead of guessing version numbers;
# this stays true for whatever NDK release introduces the same change.
android_ndk_incompatible_with_gnutls() {
    local ndk="$1"
    local header

    for header in "${ndk}"/toolchains/llvm/prebuilt/*/sysroot/usr/include/time.h; do
        [ -f "${header}" ] || continue
        if grep -q "timezone_t" "${header}" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

# Ordered NDK candidates: anything configured explicitly first, then NDKs
# discovered in the installed SDKs, with versions that can build GnuTLS ahead of
# versions that cannot.
android_ndk_candidates() {
    local repo_root="$1"
    local candidate sdk_dir props version
    local -a sdk_roots=(
        "$(read_property "${repo_root}/android_app/local.properties" "sdk.dir")"
        "$(read_property "${repo_root}/local.properties" "sdk.dir")"
        "${ANDROID_SDK_ROOT:-}"
        "${ANDROID_HOME:-}"
        "${HOME}/Library/Android/sdk"
        "${HOME}/Android/Sdk"
        "/usr/local/share/android-sdk"
    )
    local -a compatible=()
    local -a incompatible=()

    for candidate in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK:-}"; do
        if android_ndk_is_valid "${candidate}"; then
            printf '%s\n' "${candidate}"
        fi
    done

    # ndk.dir is an explicit pin by the IDE, so it also wins outright.
    for props in "${repo_root}/android_app/local.properties" "${repo_root}/local.properties"; do
        candidate="$(read_property "${props}" "ndk.dir")"
        if android_ndk_is_valid "${candidate}"; then
            printf '%s\n' "${candidate}"
        fi
    done

    for sdk_dir in "${sdk_roots[@]}"; do
        [ -n "${sdk_dir}" ] && [ -d "${sdk_dir}/ndk" ] || continue
        for version in $(ls -1 "${sdk_dir}/ndk" 2>/dev/null | sort -V -r); do
            candidate="${sdk_dir}/ndk/${version}"
            android_ndk_is_valid "${candidate}" || continue
            if android_ndk_incompatible_with_gnutls "${candidate}"; then
                incompatible+=("${candidate}")
            else
                compatible+=("${candidate}")
            fi
        done
    done

    for candidate in ${compatible[@]+"${compatible[@]}"} ${incompatible[@]+"${incompatible[@]}"}; do
        printf '%s\n' "${candidate}"
    done
}

# resolve_android_ndk <repo_root> — prints the NDK path or returns 1
resolve_android_ndk() {
    local ndk

    if ndk="$(android_ndk_candidates "$1" | awk '!seen[$0]++' | head -n 1)" && [ -n "${ndk}" ]; then
        printf '%s\n' "${ndk}"
        return 0
    fi

    gnutls_warn "no Android NDK found (looked at ANDROID_NDK_HOME/ANDROID_NDK, local.properties, and standard SDK locations)"
    return 1
}
