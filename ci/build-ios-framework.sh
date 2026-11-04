#!/bin/bash
# 构建 Node 22.9.0 的 iOS 真机 arm64 静态 framework。
#
# 为什么不用上游 tools/ios_framework_prepare.sh：
#   在 arm64 macOS 宿主上，gyp 会把「宿主工具链」（out/Release/node_js2c、
#   torque 等，编到 obj.host 下）也套上 iPhoneOS SDK，产物是 iOS 可执行文件，
#   macOS 内核会直接 SIGKILL（Killed: 9 → make Error 137）。
#   这里用 ci/hostshim 下的编译器垫片，把宿主工具的编译/链接参数换回 macOS SDK。
set -euo pipefail

cd "$(dirname "$0")/.."
cd node

echo "== toolchain =="
xcodebuild -version
python3 --version
uname -m

echo "== venv（configure.py 会选 python3.12，3.12 没有 distutils） =="
python3 -m venv . || true
# shellcheck disable=SC1091
source bin/activate
python -m pip install --quiet --upgrade pip setuptools

echo "== configure =="
export GYP_DEFINES="target_arch=arm64 host_os=mac target_os=ios"
./configure \
  --dest-os=ios \
  --dest-cpu=arm64 \
  --with-intl=none \
  --cross-compiling \
  --enable-static \
  --openssl-no-asm \
  --v8-options=--jitless \
  --without-node-code-cache \
  --without-node-snapshot

echo "== 挂上宿主工具编译器垫片 =="
export MACSDK
MACSDK=$(xcrun --sdk macosx --show-sdk-path)
echo "MACSDK=$MACSDK"
SHIM="$(cd .. && pwd)/ci/hostshim"
chmod +x "$SHIM"/*
export PATH="$SHIM:$PATH"
echo "which g++: $(command -v g++)"
echo "which gcc: $(command -v gcc)"
echo "which c++: $(command -v c++)"

echo "== make（目标 iOS arm64，宿主工具走 macOS SDK） =="
make -j2

echo "== 收集静态库 =="
BIN=tools/ios-framework/bin
mkdir -p "$BIN"
LIBS="libada.a libbase64.a libbrotli.a libcares.a libgtest_main.a libgtest.a libhistogram.a \
libllhttp.a libnghttp2.a libnghttp3.a libngtcp2.a libnode.a libopenssl.a libsimdutf.a \
libuv.a libuvwasi.a libv8_base_without_compiler.a libv8_compiler.a libv8_initializers.a \
libv8_libbase.a libv8_libplatform.a libv8_snapshot.a libv8_zlib.a libzlib.a \
libbase64_neon64.a libzlib_inflate_chunk_simd.a"
for lib in $LIBS; do
  cp "out/Release/$lib" "$BIN/$lib"
done

echo "== 去掉 x64 专用库引用后构建 framework =="
PBX=tools/ios-framework/NodeMobile.xcodeproj/project.pbxproj
cp "$PBX" "$PBX.bak"
for lib in libbase64_avx.a libbase64_avx2.a libbase64_sse41.a libbase64_sse42.a libbase64_ssse3.a; do
  grep -vF "$lib" "$PBX" > "$PBX.tmp"
  mv "$PBX.tmp" "$PBX"
done

xcodebuild build \
  -project tools/ios-framework/NodeMobile.xcodeproj \
  -target NodeMobile \
  -configuration Release \
  -arch arm64 \
  -sdk iphoneos \
  SYMROOT="$(pwd)/out_ios_arm64/iphoneos-arm64"

mv "$PBX.bak" "$PBX"

echo "== 完成 =="
find out_ios_arm64 -maxdepth 4 -name "NodeMobile.framework" -print -exec du -sh {} \;
