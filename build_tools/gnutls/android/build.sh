#!/bin/bash
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

usage() {
    cat <<'EOF'
Usage: build.sh [<abi>] [--force]

Cross-compiles Nettle and GnuTLS into prebuilts/gnutls/android-<abi> for the
Android native build. The ABI defaults to $ANDROID_ABI, else arm64-v8a.

The Android NDK is discovered automatically (ANDROID_NDK_HOME/ANDROID_NDK,
android_app/local.properties ndk.dir or sdk.dir/ndk/<version>, ANDROID_SDK_ROOT,
ANDROID_HOME, or a standard SDK location).

Options:
  --force   Rebuild even when the prebuilt libraries already exist
  --help    Show this help
EOF
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../../.." && pwd)
# shellcheck source=../common.sh
. "${SCRIPT_DIR}/../common.sh"
gnutls_require_tools

FORCE=0
ABI_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            gnutls_die "unknown argument: $1"
            ;;
        *)
            if [ -n "${ABI_ARG}" ]; then
                usage >&2
                gnutls_die "unexpected extra argument: $1"
            fi
            ABI_ARG="$1"
            ;;
    esac
    shift
done

ABI="${ABI_ARG:-${ANDROID_ABI:-arm64-v8a}}"
API_LEVEL="${ANDROID_API_LEVEL:-26}"

case "$ABI" in
    arm64-v8a)
        TARGET="aarch64-linux-android"
        ;;
    x86_64)
        TARGET="x86_64-linux-android"
        ;;
    *)
        gnutls_die "unsupported ABI: ${ABI} (supported: arm64-v8a, x86_64)"
        ;;
esac

if ! NDK_DIR="$(resolve_android_ndk "${REPO_ROOT}")"; then
    gnutls_die "Android NDK not found.
Install it from Android Studio > SDK Manager > SDK Tools > NDK (or run
'sdkmanager \"ndk;26.1.10909125\"', the version Android Gradle Plugin 8.5.2 expects),
or point ANDROID_NDK_HOME / ndk.dir at an existing NDK installation."
fi

TOOLCHAIN_DIR="$(find "${NDK_DIR}/toolchains/llvm/prebuilt" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
if [ -z "${TOOLCHAIN_DIR}" ]; then
    gnutls_die "unable to locate the LLVM toolchain inside ${NDK_DIR}"
fi

if android_ndk_incompatible_with_gnutls "${NDK_DIR}"; then
    gnutls_warn "${NDK_DIR} typedefs timezone_t in its headers, which GnuTLS ${GNUTLS_VERSION}"
    gnutls_warn "cannot be compiled against. Install an older NDK (e.g. 26.1.10909125), or"
    gnutls_warn "point ANDROID_NDK_HOME at one; continuing because this NDK was pinned."
fi

CC_BIN="${TOOLCHAIN_DIR}/bin/${TARGET}${API_LEVEL}-clang"
CXX_BIN="${TOOLCHAIN_DIR}/bin/${TARGET}${API_LEVEL}-clang++"
if [ ! -x "${CC_BIN}" ] || [ ! -x "${CXX_BIN}" ]; then
    gnutls_die "missing Android compiler for ABI ${ABI} (looked for ${CC_BIN})"
fi

BUILD_TOOLS_DIR="${REPO_ROOT}/build_tools/gnutls"
CACHE_DIR="${BUILD_TOOLS_DIR}/cache"
INSTALL_DIR="${REPO_ROOT}/prebuilts/gnutls/android-${ABI}"
BUILD_ROOT="${BUILD_TOOLS_DIR}/work/android/${ABI}"
NETTLE_SOURCE_DIR="${BUILD_ROOT}/nettle-${NETTLE_VERSION}"
GNUTLS_SOURCE_DIR="${BUILD_ROOT}/gnutls-${GNUTLS_VERSION}"
NETTLE_ARCHIVE="${CACHE_DIR}/${NETTLE_TARBALL}"
GNUTLS_ARCHIVE="${CACHE_DIR}/${GNUTLS_TARBALL}"
SYSROOT="${TOOLCHAIN_DIR}/sysroot"

mkdir -p "${INSTALL_DIR}" "${BUILD_ROOT}" "${CACHE_DIR}"

nproc() {
    sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN
}

if [ "${FORCE}" -eq 0 ] \
    && [ -f "${INSTALL_DIR}/lib/libgnutls.a" ] \
    && [ -f "${INSTALL_DIR}/lib/libnettle.a" ] \
    && [ -f "${INSTALL_DIR}/lib/libhogweed.a" ]; then
    gnutls_log "Android GnuTLS prebuilts for ${ABI} already present at ${INSTALL_DIR} (use --force to rebuild)"
    exit 0
fi

gnutls_log "Android NDK: ${NDK_DIR}"
gnutls_log "Target: ${ABI} (${TARGET}, API ${API_LEVEL}) -> ${INSTALL_DIR}"

ensure_archive "${NETTLE_URL}" "${NETTLE_ARCHIVE}" "${NETTLE_SHA256}"
ensure_archive "${GNUTLS_URL}" "${GNUTLS_ARCHIVE}" "${GNUTLS_SHA256}"

if [ "${FORCE}" -eq 1 ] \
    || [ ! -f "${INSTALL_DIR}/lib/libnettle.a" ] \
    || [ ! -f "${INSTALL_DIR}/lib/libhogweed.a" ]; then
    rm -rf "${NETTLE_SOURCE_DIR}"
    tar -xzf "${NETTLE_ARCHIVE}" -C "${BUILD_ROOT}"
    cd "${NETTLE_SOURCE_DIR}"
    gnutls_log "Configuring Nettle for cross-compilation..."
    ./configure \
        --host="${TARGET}" \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static \
        --disable-assembler \
        --enable-mini-gmp \
        --with-include-path="${INSTALL_DIR}/include" \
        --with-lib-path="${INSTALL_DIR}/lib" \
        CC="${CC_BIN}" \
        CXX="${CXX_BIN}" \
        AR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        RANLIB="${TOOLCHAIN_DIR}/bin/llvm-ranlib" \
        CFLAGS="-fPIC -O2 --sysroot=${SYSROOT}" \
        CXXFLAGS="-fPIC -O2 --sysroot=${SYSROOT}" \
        LDFLAGS="--sysroot=${SYSROOT}" >/dev/null
    gnutls_log "Compiling Nettle..."
    make -j"$(nproc)" >/dev/null
    mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/include/nettle" "${INSTALL_DIR}/lib/pkgconfig"
    cp libnettle.a libhogweed.a "${INSTALL_DIR}/lib/"
    cp nettle.pc hogweed.pc "${INSTALL_DIR}/lib/pkgconfig/"
    cp ./*.h "${INSTALL_DIR}/include/nettle/"
    cp version.h "${INSTALL_DIR}/include/nettle/"
fi

if [ "${FORCE}" -eq 1 ] || [ ! -f "${INSTALL_DIR}/lib/libgnutls.a" ]; then
    rm -rf "${GNUTLS_SOURCE_DIR}"
    tar -xf "${GNUTLS_ARCHIVE}" -C "${BUILD_ROOT}"
    cd "${GNUTLS_SOURCE_DIR}"
    gnutls_log "Configuring GnuTLS for cross-compilation..."
    ./configure \
        --host="${TARGET}" \
        --prefix="${INSTALL_DIR}" \
        --disable-shared \
        --enable-static \
        --with-included-unistring \
        --with-included-libtasn1 \
        --without-p11-kit \
        --disable-doc \
        --disable-tests \
        --disable-tools \
        --disable-cxx \
        --disable-guile \
        --disable-valgrind-tests \
        --without-brotli \
        --without-zlib \
        --without-zstd \
        --without-idn \
        --with-nettle-mini \
        NETTLE_CFLAGS="-I${INSTALL_DIR}/include" \
        NETTLE_LIBS="-L${INSTALL_DIR}/lib -lnettle" \
        HOGWEED_CFLAGS="-I${INSTALL_DIR}/include" \
        HOGWEED_LIBS="-L${INSTALL_DIR}/lib -lhogweed" \
        CC="${CC_BIN}" \
        CXX="${CXX_BIN}" \
        AR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        RANLIB="${TOOLCHAIN_DIR}/bin/llvm-ranlib" \
        CFLAGS="-fPIC -O2 --sysroot=${SYSROOT}" \
        CXXFLAGS="-fPIC -O2 --sysroot=${SYSROOT}" \
        LDFLAGS="--sysroot=${SYSROOT}" >/dev/null
    gnutls_log "Compiling GnuTLS..."
    make -j"$(nproc)" >/dev/null
    gnutls_log "Installing GnuTLS to prebuilts..."
    make install >/dev/null
fi

for lib in libgnutls.a libnettle.a libhogweed.a; do
    if [ ! -f "${INSTALL_DIR}/lib/${lib}" ]; then
        gnutls_die "expected ${INSTALL_DIR}/lib/${lib} after install, but it is missing"
    fi
done

gnutls_log "Built Android GnuTLS/Nettle for ${ABI} at ${INSTALL_DIR}"
