#!/usr/bin/env bash
#
# Cross-compile nodejs-mobile into a tvOS xcframework for OrivioTV's on-device
# P2P streaming server (the same runtime technique Stremio uses).
#
# nodejs-mobile ships NO tvOS prebuilt — only iOS — so we build our own from
# source. Run this on a Mac with Xcode + the tvOS SDK and GitHub access
# (it clones nodejs-mobile). Output: NodeMobile.xcframework, which you drop in
# and reference from project.yml (see nodeserver/README.md).
#
# This is intentionally a separate, out-of-band build: it takes ~30–60 min and
# a lot of RAM, and can't run in a restricted CI sandbox.
set -euo pipefail

NODE_MOBILE_REF="${NODE_MOBILE_REF:-v18.20.4}"        # a tag/branch of nodejs-mobile
WORK="${WORK:-$HOME/nodejs-mobile-tvos-build}"
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/Vendor}"

echo "==> Cloning nodejs-mobile ($NODE_MOBILE_REF) into $WORK"
mkdir -p "$WORK"
if [ ! -d "$WORK/nodejs-mobile" ]; then
  git clone --depth 1 --branch "$NODE_MOBILE_REF" \
    https://github.com/nodejs-mobile/nodejs-mobile.git "$WORK/nodejs-mobile"
fi
cd "$WORK/nodejs-mobile"

# nodejs-mobile's tools/ios_framework build targets iphoneos/iphonesimulator.
# For tvOS we point the same machinery at the appletvos SDK and the tvOS
# min-version, and keep V8 jitless (tvOS forbids JIT for sandboxed apps).
export SDKROOT_DEVICE="$(xcrun --sdk appletvos --show-sdk-path)"
export TVOS_MIN="13.0"

echo "==> Configuring Node for tvOS (arm64, jitless V8)"
# --dest-os=ios reuses the iOS toolchain wiring; --dest-cpu=arm64 for Apple TV;
# --without-* trims what a streaming server doesn't need and keeps it lean.
GYP_DEFINES="OS=tvos" \
./configure \
  --dest-os=ios \
  --dest-cpu=arm64 \
  --with-intl=none \
  --cross-compiling \
  --v8-options=--jitless \
  --openssl-no-asm \
  --without-npm \
  --without-inspector \
  --enable-static

echo "==> Building libnode (this is the slow part)"
CFLAGS="-mappletvos-version-min=$TVOS_MIN -isysroot $SDKROOT_DEVICE -arch arm64" \
CXXFLAGS="-mappletvos-version-min=$TVOS_MIN -isysroot $SDKROOT_DEVICE -arch arm64" \
make -j"$(sysctl -n hw.ncpu)" libnode

echo "==> Packaging NodeMobile.xcframework"
mkdir -p "$OUT"
LIB="$WORK/nodejs-mobile/out/Release/libnode.a"
HDR="$WORK/nodejs-mobile/src"    # node.h / node_api.h live here
rm -rf "$OUT/NodeMobile.xcframework"
xcodebuild -create-xcframework \
  -library "$LIB" -headers "$HDR" \
  -output "$OUT/NodeMobile.xcframework"

echo "==> Done: $OUT/NodeMobile.xcframework"
echo "Next: add it to project.yml (see nodeserver/README.md) and rebuild."
