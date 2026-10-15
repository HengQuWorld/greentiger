#!/bin/bash
set -euo pipefail

# Fix PATH to avoid broken tools from OpenHarmony SDK toolchains (like diff)
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

usage() {
    cat <<'EOF'
Usage: build.sh [--force]

Cross-compiles Nettle and GnuTLS into prebuilts/gnutls/ohos-<arch> for the
HarmonyOS native build.

The OHOS native SDK is discovered automatically (environment, hvigor
local.properties, or a DevEco Studio installation); it may also be forced with
OHOS_SDK_NATIVE. Target ABI is arm64-v8a by default, or x86_64 via OHOS_ARCH.

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
while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            gnutls_die "unknown argument: $1"
            ;;
    esac
    shift
done

OHOS_ARCH="${OHOS_ARCH:-arm64-v8a}"
case "$OHOS_ARCH" in
    arm64-v8a)
        TARGET="aarch64-linux-ohos"
        HOST="aarch64-linux-gnu"
        PREBUILT_DIR_NAME="ohos-arm64"
        ;;
    x86_64)
        TARGET="x86_64-linux-ohos"
        HOST="x86_64-linux-gnu"
        PREBUILT_DIR_NAME="ohos-x86_64"
        ;;
    *)
        gnutls_die "unsupported OHOS_ARCH=$OHOS_ARCH (supported: arm64-v8a, x86_64)"
        ;;
esac

if ! OHOS_SDK_NATIVE="$(resolve_ohos_sdk_native "${REPO_ROOT}")"; then
    gnutls_die "HarmonyOS native SDK not found.
Install DevEco Studio (its bundled SDK is detected automatically), or set OHOS_SDK_NATIVE
or hwsdk.dir/sdk.dir in ohos_app/local.properties to a HarmonyOS SDK that contains a
native/ directory with llvm/bin/clang and sysroot/."
fi
export OHOS_SDK_NATIVE
TOOLCHAIN_DIR="${OHOS_SDK_NATIVE}/llvm"

if [ ! -x "${TOOLCHAIN_DIR}/bin/clang" ]; then
    gnutls_die "OHOS toolchain not found at ${TOOLCHAIN_DIR}/bin/clang (from ${OHOS_SDK_NATIVE})"
fi
if [ ! -d "${OHOS_SDK_NATIVE}/sysroot" ]; then
    gnutls_die "OHOS sysroot not found at ${OHOS_SDK_NATIVE}/sysroot"
fi

# Define compilers
export CC="${TOOLCHAIN_DIR}/bin/clang --target=${TARGET}"
export CXX="${TOOLCHAIN_DIR}/bin/clang++ --target=${TARGET}"
export AR="${TOOLCHAIN_DIR}/bin/llvm-ar"
export AS="${TOOLCHAIN_DIR}/bin/llvm-as"
export LD="${TOOLCHAIN_DIR}/bin/ld.lld"
export RANLIB="${TOOLCHAIN_DIR}/bin/llvm-ranlib"
export STRIP="${TOOLCHAIN_DIR}/bin/llvm-strip"
export NM="${TOOLCHAIN_DIR}/bin/llvm-nm"

export CFLAGS="-fPIC -D__MUSL__ -O2"
export CXXFLAGS="-fPIC -D__MUSL__ -O2"
export LDFLAGS="-L${OHOS_SDK_NATIVE}/sysroot/usr/lib/${TARGET}"

export SYSROOT="${OHOS_SDK_NATIVE}/sysroot"

BUILD_TOOLS_DIR="${REPO_ROOT}/build_tools/gnutls"
CACHE_DIR="${BUILD_TOOLS_DIR}/cache"
BUILD_ROOT="${BUILD_TOOLS_DIR}/work/ohos/${PREBUILT_DIR_NAME}"
INSTALL_DIR="${REPO_ROOT}/prebuilts/gnutls/${PREBUILT_DIR_NAME}"
NETTLE_SOURCE_DIR="${BUILD_ROOT}/nettle-${NETTLE_VERSION}"
GNUTLS_SOURCE_DIR="${BUILD_ROOT}/gnutls-${GNUTLS_VERSION}"
NETTLE_ARCHIVE="${CACHE_DIR}/${NETTLE_TARBALL}"
GNUTLS_ARCHIVE="${CACHE_DIR}/${GNUTLS_TARBALL}"

mkdir -p "${INSTALL_DIR}" "${CACHE_DIR}" "${BUILD_ROOT}"

nproc() {
    sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN
}

if [ "${FORCE}" -eq 0 ] \
    && [ -f "${INSTALL_DIR}/lib/libgnutls.a" ] \
    && [ -f "${INSTALL_DIR}/lib/libnettle.a" ] \
    && [ -f "${INSTALL_DIR}/lib/libhogweed.a" ]; then
    gnutls_log "OHOS GnuTLS prebuilts for ${OHOS_ARCH} already present at ${INSTALL_DIR} (use --force to rebuild)"
    exit 0
fi

gnutls_log "OHOS native SDK: ${OHOS_SDK_NATIVE}"
gnutls_log "Target: ${OHOS_ARCH} (${TARGET}) -> ${INSTALL_DIR}"

echo "======================================"
echo " [1/2] Building Nettle (Cryptography library)"
echo "======================================"

ensure_archive "${NETTLE_URL}" "${NETTLE_ARCHIVE}" "${NETTLE_SHA256}"

rm -rf "${NETTLE_SOURCE_DIR}"
tar -xzf "${NETTLE_ARCHIVE}" -C "${BUILD_ROOT}"

cd "${NETTLE_SOURCE_DIR}"
gnutls_log "Configuring Nettle for cross-compilation (this may take a minute)..."
./configure --host="${HOST}" --prefix="${INSTALL_DIR}" --disable-shared --enable-static \
    --disable-assembler --enable-mini-gmp \
    --with-include-path="${INSTALL_DIR}/include" --with-lib-path="${INSTALL_DIR}/lib" \
    CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" CFLAGS="${CFLAGS} --sysroot=${SYSROOT}" \
    LDFLAGS="${LDFLAGS} --sysroot=${SYSROOT}" > /dev/null || { cat config.log; exit 1; }

gnutls_log "Compiling Nettle..."
make -j"$(nproc)" > /dev/null

gnutls_log "Installing Nettle to prebuilts..."
make install > /dev/null

echo "======================================"
echo " [2/2] Building GnuTLS (TLS implementation)"
echo "======================================"

ensure_archive "${GNUTLS_URL}" "${GNUTLS_ARCHIVE}" "${GNUTLS_SHA256}"

rm -rf "${GNUTLS_SOURCE_DIR}"
tar -xf "${GNUTLS_ARCHIVE}" -C "${BUILD_ROOT}"

cd "${GNUTLS_SOURCE_DIR}"
gnutls_log "Configuring GnuTLS for cross-compilation (this may take a minute)..."
./configure --host="${HOST}" --prefix="${INSTALL_DIR}" --disable-shared --enable-static \
    --with-included-unistring --with-included-libtasn1 \
    --without-p11-kit --disable-doc --disable-tests --disable-tools \
    --disable-cxx --disable-guile --disable-valgrind-tests \
    --without-brotli --without-zlib --without-zstd --without-idn \
    --with-nettle-mini \
    NETTLE_CFLAGS="-I${INSTALL_DIR}/include" NETTLE_LIBS="-L${INSTALL_DIR}/lib -lnettle" \
    HOGWEED_CFLAGS="-I${INSTALL_DIR}/include" HOGWEED_LIBS="-L${INSTALL_DIR}/lib -lhogweed" \
    CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" CFLAGS="${CFLAGS} --sysroot=${SYSROOT}" \
    LDFLAGS="${LDFLAGS} --sysroot=${SYSROOT}" > /dev/null || { cat config.log; exit 1; }

gnutls_log "Compiling GnuTLS..."
make -j"$(nproc)" > /dev/null

gnutls_log "Installing GnuTLS to prebuilts..."
make install > /dev/null

for lib in libgnutls.a libnettle.a libhogweed.a; do
    if [ ! -f "${INSTALL_DIR}/lib/${lib}" ]; then
        gnutls_die "expected ${INSTALL_DIR}/lib/${lib} after install, but it is missing"
    fi
done

echo "======================================"
echo " ✓ GnuTLS cross-compilation completed!"
echo "   prebuilts: ${INSTALL_DIR}"
echo "======================================"
