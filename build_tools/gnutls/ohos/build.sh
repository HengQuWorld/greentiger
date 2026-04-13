#!/bin/bash
set -euo pipefail

# Fix PATH to avoid broken tools from OpenHarmony SDK toolchains (like diff)
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [ -z "$OHOS_SDK_NATIVE" ]; then
    echo "Error: OHOS_SDK_NATIVE environment variable is not set."
    echo "It should be provided by CMake or set externally (e.g., /Users/user/Library/OpenHarmony/Sdk/12/native)"
    exit 1
fi
export TOOLCHAIN_DIR="$OHOS_SDK_NATIVE/llvm"

OHOS_ARCH="${OHOS_ARCH:-arm64-v8a}"
case "$OHOS_ARCH" in
    arm64-v8a)
        export TARGET="aarch64-linux-ohos"
        export HOST="aarch64-linux-gnu"
        PREBUILT_DIR_NAME="ohos-arm64"
        ;;
    x86_64)
        export TARGET="x86_64-linux-ohos"
        export HOST="x86_64-linux-gnu"
        PREBUILT_DIR_NAME="ohos-x86_64"
        ;;
    *)
        echo "Error: unsupported OHOS_ARCH=$OHOS_ARCH"
        echo "Supported values: arm64-v8a, x86_64"
        exit 1
        ;;
esac

# Define compilers
export CC="$TOOLCHAIN_DIR/bin/clang --target=$TARGET"
export CXX="$TOOLCHAIN_DIR/bin/clang++ --target=$TARGET"
export AR="$TOOLCHAIN_DIR/bin/llvm-ar"
export AS="$TOOLCHAIN_DIR/bin/llvm-as"
export LD="$TOOLCHAIN_DIR/bin/ld.lld"
export RANLIB="$TOOLCHAIN_DIR/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN_DIR/bin/llvm-strip"
export NM="$TOOLCHAIN_DIR/bin/llvm-nm"

export CFLAGS="-fPIC -D__MUSL__ -O2"
export CXXFLAGS="-fPIC -D__MUSL__ -O2"
export LDFLAGS="-L$OHOS_SDK_NATIVE/sysroot/usr/lib/$TARGET"

export SYSROOT="$OHOS_SDK_NATIVE/sysroot"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
BUILD_TOOLS_DIR="$REPO_ROOT/build_tools/gnutls"
CACHE_DIR="$BUILD_TOOLS_DIR/cache"
BUILD_ROOT="$BUILD_TOOLS_DIR/work/ohos"
INSTALL_DIR="$REPO_ROOT/prebuilts/gnutls/$PREBUILT_DIR_NAME"
NETTLE_SOURCE_DIR="$BUILD_ROOT/nettle-3.9"
GNUTLS_SOURCE_DIR="$BUILD_ROOT/gnutls-3.8.4"
NETTLE_ARCHIVE="$CACHE_DIR/nettle-3.9.tar.gz"
GNUTLS_ARCHIVE="$CACHE_DIR/gnutls-3.8.4.tar.xz"
mkdir -p "$INSTALL_DIR" "$CACHE_DIR" "$BUILD_ROOT"

nproc() {
    sysctl -n hw.ncpu
}

archive_is_valid() {
    local archive=$1
    if [ ! -f "$archive" ]; then
        return 1
    fi
    case "$archive" in
        *.tar.gz|*.tgz)
            tar -tzf "$archive" >/dev/null 2>&1
            ;;
        *.tar.xz|*.txz)
            tar -tJf "$archive" >/dev/null 2>&1
            ;;
        *)
            tar -tf "$archive" >/dev/null 2>&1
            ;;
    esac
}

download_file() {
    local url=$1
    local output=$2
    local tmp_output="${output}.tmp"
    local -a curl_args=(-fL --retry 3 --retry-delay 2 --connect-timeout 15 -# -o "$tmp_output")

    if [ -n "${GNUTLS_DOWNLOAD_PROXY:-}" ]; then
        curl_args=(-x "$GNUTLS_DOWNLOAD_PROXY" "${curl_args[@]}")
    elif [ -n "${https_proxy:-}" ]; then
        curl_args=(-x "$https_proxy" "${curl_args[@]}")
    elif [ -n "${http_proxy:-}" ]; then
        curl_args=(-x "$http_proxy" "${curl_args[@]}")
    fi

    rm -f "$tmp_output"
    echo "Downloading $output from $url..."
    curl "${curl_args[@]}" "$url"
    mv "$tmp_output" "$output"
}

ensure_archive() {
    local url=$1
    local output=$2
    if archive_is_valid "$output"; then
        return 0
    fi
    rm -f "$output"
    download_file "$url" "$output"
    archive_is_valid "$output"
}

echo "======================================"
echo " [1/2] Building Nettle (Cryptography library)"
echo "======================================"

ensure_archive "https://ftp.gnu.org/gnu/nettle/nettle-3.9.tar.gz" "$NETTLE_ARCHIVE"

rm -rf "$NETTLE_SOURCE_DIR"
tar -xzf "$NETTLE_ARCHIVE" -C "$BUILD_ROOT"

cd "$NETTLE_SOURCE_DIR"
echo "=> Configuring Nettle for cross-compilation (this may take a minute)..."
./configure --host=$HOST --prefix="$INSTALL_DIR" --disable-shared --enable-static \
    --disable-assembler --enable-mini-gmp \
    --with-include-path="$INSTALL_DIR/include" --with-lib-path="$INSTALL_DIR/lib" \
    CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS --sysroot=$SYSROOT" \
    LDFLAGS="$LDFLAGS --sysroot=$SYSROOT" > /dev/null || { cat config.log; exit 1; }

echo "=> Compiling Nettle..."
make -j"$(nproc)" > /dev/null

echo "=> Installing Nettle to prebuilts..."
make install > /dev/null

echo "======================================"
echo " [2/2] Building GnuTLS (TLS implementation)"
echo "======================================"

ensure_archive "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.4.tar.xz" "$GNUTLS_ARCHIVE"

rm -rf "$GNUTLS_SOURCE_DIR"
tar -xf "$GNUTLS_ARCHIVE" -C "$BUILD_ROOT"

cd "$GNUTLS_SOURCE_DIR"
echo "=> Configuring GnuTLS for cross-compilation (this may take a minute)..."
./configure --host=$HOST --prefix="$INSTALL_DIR" --disable-shared --enable-static \
    --with-included-unistring --with-included-libtasn1 \
    --without-p11-kit --disable-doc --disable-tests --disable-tools \
    --disable-cxx --disable-guile --disable-valgrind-tests \
    --without-brotli --without-zlib --without-zstd --without-idn \
    --with-nettle-mini \
    NETTLE_CFLAGS="-I$INSTALL_DIR/include" NETTLE_LIBS="-L$INSTALL_DIR/lib -lnettle" \
    HOGWEED_CFLAGS="-I$INSTALL_DIR/include" HOGWEED_LIBS="-L$INSTALL_DIR/lib -lhogweed" \
    CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" CFLAGS="$CFLAGS --sysroot=$SYSROOT" \
    LDFLAGS="$LDFLAGS --sysroot=$SYSROOT" > /dev/null || { cat config.log; exit 1; }

echo "=> Compiling GnuTLS..."
make -j"$(nproc)" > /dev/null

echo "=> Installing GnuTLS to prebuilts..."
make install > /dev/null

echo "======================================"
echo " ✓ GnuTLS Cross-compilation completed!"
echo "======================================"
