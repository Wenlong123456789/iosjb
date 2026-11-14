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
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode / {print $2; exit}')"
XCODE_BUILD="$(xcodebuild -version | awk '/^Build version / {print $3; exit}')"
BUCKET_BUILD="$(sw_vers -buildVersion)"
rm -rf "$BUILD" "$DIST"
mkdir -p "$APP" "$DIST"

echo "== toolchain =="
xcodebuild -version
echo "$SDK_VERSION"

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

PLIST_BUDDY=/usr/libexec/PlistBuddy
"$PLIST_BUDDY" -c "Add :DTPlatformName string iphoneos" "$APP/Info.plist"
"$PLIST_BUDDY" -c "Add :DTPlatformVersion string $SDK_VERSION" "$APP/Info.plist"
"$PLIST_BUDDY" -c "Add :DTSDKName string iphoneos$SDK_VERSION" "$APP/Info.plist"
"$PLIST_BUDDY" -c "Add :DTXcode string $XCODE_VERSION" "$APP/Info.plist"
"$PLIST_BUDDY" -c "Add :DTXcodeBuild string $XCODE_BUILD" "$APP/Info.plist"
"$PLIST_BUDDY" -c "Add :BuildMachineOSBuild string $BUCKET_BUILD" "$APP/Info.plist"

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

