#!/bin/bash
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
ABI="${1:-${ANDROID_ABI:-arm64-v8a}}"
NDK_DIR="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
API_LEVEL="${ANDROID_API_LEVEL:-26}"

if [ -z "$NDK_DIR" ]; then
  echo "ANDROID_NDK_HOME or ANDROID_NDK is required"
  exit 1
fi

TOOLCHAIN_DIR=$(find "$NDK_DIR/toolchains/llvm/prebuilt" -maxdepth 1 -mindepth 1 -type d | head -n 1)
if [ -z "$TOOLCHAIN_DIR" ]; then
  echo "Unable to locate Android NDK LLVM toolchain"
  exit 1
fi

case "$ABI" in
  arm64-v8a)
    TARGET="aarch64-linux-android"
    CC_BIN="$TOOLCHAIN_DIR/bin/aarch64-linux-android${API_LEVEL}-clang"
    CXX_BIN="$TOOLCHAIN_DIR/bin/aarch64-linux-android${API_LEVEL}-clang++"
    ;;
  x86_64)
    TARGET="x86_64-linux-android"
    CC_BIN="$TOOLCHAIN_DIR/bin/x86_64-linux-android${API_LEVEL}-clang"
    CXX_BIN="$TOOLCHAIN_DIR/bin/x86_64-linux-android${API_LEVEL}-clang++"
    ;;
  *)
    echo "Unsupported ABI: $ABI"
    exit 1
    ;;
esac

if [ ! -x "$CC_BIN" ] || [ ! -x "$CXX_BIN" ]; then
  echo "Missing Android compiler for ABI $ABI"
  exit 1
fi

BUILD_TOOLS_DIR="$REPO_ROOT/build_tools/gnutls"
CACHE_DIR="$BUILD_TOOLS_DIR/cache"
INSTALL_DIR="$REPO_ROOT/prebuilts/gnutls/android-$ABI"
BUILD_ROOT="$BUILD_TOOLS_DIR/work/android/$ABI"
NETTLE_SOURCE_DIR="$BUILD_ROOT/nettle-3.9"
GNUTLS_SOURCE_DIR="$BUILD_ROOT/gnutls-3.8.4"
NETTLE_ARCHIVE="$CACHE_DIR/nettle-3.9.tar.gz"
GNUTLS_ARCHIVE="$CACHE_DIR/gnutls-3.8.4.tar.xz"
SYSROOT="$TOOLCHAIN_DIR/sysroot"

mkdir -p "$INSTALL_DIR" "$BUILD_ROOT" "$CACHE_DIR"

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
  local proxy_args=()

  if [ -n "${GNUTLS_DOWNLOAD_PROXY:-}" ]; then
    proxy_args=(-x "$GNUTLS_DOWNLOAD_PROXY")
  elif [ -n "${https_proxy:-}" ]; then
    proxy_args=(-x "$https_proxy")
  elif [ -n "${http_proxy:-}" ]; then
    proxy_args=(-x "$http_proxy")
  fi

  rm -f "$tmp_output"
  curl "${proxy_args[@]}" -fL --retry 3 --retry-delay 2 --connect-timeout 15 -# -o "$tmp_output" "$url"
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

ensure_archive "https://ftp.gnu.org/gnu/nettle/nettle-3.9.tar.gz" "$NETTLE_ARCHIVE"

ensure_archive "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.4.tar.xz" "$GNUTLS_ARCHIVE"

if [ ! -f "$INSTALL_DIR/lib/libnettle.a" ] || [ ! -f "$INSTALL_DIR/lib/libhogweed.a" ]; then
  rm -rf "$NETTLE_SOURCE_DIR"
  tar -xzf "$NETTLE_ARCHIVE" -C "$BUILD_ROOT"
  cd "$NETTLE_SOURCE_DIR"
  ./configure \
    --host="$TARGET" \
    --prefix="$INSTALL_DIR" \
    --disable-shared \
    --enable-static \
    --disable-assembler \
    --enable-mini-gmp \
    --with-include-path="$INSTALL_DIR/include" \
    --with-lib-path="$INSTALL_DIR/lib" \
    CC="$CC_BIN" \
    CXX="$CXX_BIN" \
    AR="$TOOLCHAIN_DIR/bin/llvm-ar" \
    RANLIB="$TOOLCHAIN_DIR/bin/llvm-ranlib" \
    CFLAGS="-fPIC -O2 --sysroot=$SYSROOT" \
    CXXFLAGS="-fPIC -O2 --sysroot=$SYSROOT" \
    LDFLAGS="--sysroot=$SYSROOT" >/dev/null
  make -j"$(nproc)" >/dev/null
  mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/include/nettle" "$INSTALL_DIR/lib/pkgconfig"
  cp libnettle.a libhogweed.a "$INSTALL_DIR/lib/"
  cp nettle.pc hogweed.pc "$INSTALL_DIR/lib/pkgconfig/"
  cp *.h "$INSTALL_DIR/include/nettle/"
  cp version.h "$INSTALL_DIR/include/nettle/"
fi

if [ ! -f "$INSTALL_DIR/lib/libgnutls.a" ]; then
  rm -rf "$GNUTLS_SOURCE_DIR"
  tar -xf "$GNUTLS_ARCHIVE" -C "$BUILD_ROOT"
  cd "$GNUTLS_SOURCE_DIR"
  ./configure \
    --host="$TARGET" \
    --prefix="$INSTALL_DIR" \
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
    NETTLE_CFLAGS="-I$INSTALL_DIR/include" \
    NETTLE_LIBS="-L$INSTALL_DIR/lib -lnettle" \
    HOGWEED_CFLAGS="-I$INSTALL_DIR/include" \
    HOGWEED_LIBS="-L$INSTALL_DIR/lib -lhogweed" \
    CC="$CC_BIN" \
    CXX="$CXX_BIN" \
    AR="$TOOLCHAIN_DIR/bin/llvm-ar" \
    RANLIB="$TOOLCHAIN_DIR/bin/llvm-ranlib" \
    CFLAGS="-fPIC -O2 --sysroot=$SYSROOT" \
    CXXFLAGS="-fPIC -O2 --sysroot=$SYSROOT" \
    LDFLAGS="--sysroot=$SYSROOT" >/dev/null
  make -j"$(nproc)" >/dev/null
  make install >/dev/null
fi

echo "Built Android GnuTLS/Nettle for $ABI at $INSTALL_DIR"
