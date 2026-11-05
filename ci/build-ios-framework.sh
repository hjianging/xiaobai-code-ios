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
# 关掉调试信息：Release 默认 -gdwarf-2，host/target 两套对象会把 14GB 的 runner 盘撑爆
python3 - <<'PY'
import pathlib
p = pathlib.Path("common.gypi")
s = p.read_text()
n = s.count("'-gdwarf-2'")
p.write_text(s.replace("'-gdwarf-2'", "'-g0'"))
print("debug flags replaced:", n)
PY

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
# 每 3 分钟打一行磁盘/内存：万一再被 runner 掐断，能看出是不是盘满了
(
  while true; do
    sleep 180
    echo "[monitor] $(date +%H:%M:%S) disk=$(df -h / | tail -1 | awk '{print $4}') free, out=$(du -sh out 2>/dev/null | cut -f1)"
  done
) &
MON_PID=$!
trap 'kill $MON_PID 2>/dev/null || true' EXIT

make -j2

kill $MON_PID 2>/dev/null || true
df -h /

echo "== 收集静态库 =="
# 不再用上游的 NodeMobile.xcodeproj：它是给旧版 Node 写的，库名（libbase64*.a 等）
# 在 22.9.0 里已经没了。这里直接收集 make 产出的真机静态库，交给 App 端链接。
DIST=dist
rm -rf "$DIST"
mkdir -p "$DIST/libs"
cp out/Release/lib*.a "$DIST/libs/"
rm -f "$DIST/libs/libgtest.a" "$DIST/libs/libgtest_main.a"
ls -l "$DIST/libs" | tail -n +2 | awk '{print $5, $9}'
echo "libs = $(ls "$DIST/libs" | wc -l)"

echo "== 校验入口符号 node::Start =="
if ! nm -gU "$DIST/libs/libnode.a" 2>/dev/null | grep -q "_ZN4node5StartEiPPc"; then
  echo "!! libnode.a 里没有 node::Start"
  nm -gU "$DIST/libs/libnode.a" 2>/dev/null | grep -i "Start" | head -5 || true
  exit 1
fi
echo "node::Start OK"

echo "== 完成 =="
du -sh "$DIST"
