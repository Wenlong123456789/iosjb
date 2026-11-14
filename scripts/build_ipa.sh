#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$BUILD/Payload/IOSJB.app"
MIN_IOS="16.0"
TARGET="arm64-apple-ios${MIN_IOS}"

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "error: full Xcode with the iOS SDK is required" >&2
    exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
rm -rf "$BUILD" "$DIST"
mkdir -p "$APP" "$DIST"

echo "== toolchain =="
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

echo "== compile C bridge =="
xcrun --sdk iphoneos clang \
    -target "$TARGET" \
    -isysroot "$SDK" \
    -O2 \
    -fno-common \
    -Wall -Wextra -Werror \
    -c "$ROOT/Sources/SocketUAF.c" \
    -o "$BUILD/SocketUAF.o"

echo "== compile SwiftUI app =="
xcrun --sdk iphoneos swiftc \
    -target "$TARGET" \
    -sdk "$SDK" \
    -O \
    -whole-module-optimization \
    -parse-as-library \
    -swift-version 5 \
    -module-name IOSJB \
    -import-objc-header "$ROOT/Sources/IOSJB-Bridging-Header.h" \
    "$ROOT/Sources/IOSJBApp.swift" \
    "$ROOT/Sources/ContentView.swift" \
    "$BUILD/SocketUAF.o" \
    -framework SwiftUI \
    -framework UIKit \
    -framework Foundation \
    -o "$APP/IOSJB"

cp "$ROOT/Resources/Info.plist" "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
/usr/bin/plutil -lint "$APP/Info.plist"
file "$APP/IOSJB"
otool -L "$APP/IOSJB"

echo "== package unsigned IPA =="
(
    cd "$BUILD"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$DIST/IOSJB-unsigned.ipa"
)
(
    cd "$DIST"
    shasum -a 256 "IOSJB-unsigned.ipa" > "IOSJB-unsigned.ipa.sha256"
)

ls -lh "$DIST"
cat "$DIST/IOSJB-unsigned.ipa.sha256"

