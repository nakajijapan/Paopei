#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
mkdir -p "$SWIFTPM_MODULECACHE_OVERRIDE" "$CLANG_MODULE_CACHE_PATH"

swift build -c debug --disable-sandbox
BIN_DIR="$(swift build -c debug --disable-sandbox --show-bin-path)"
APP_DIR="$ROOT_DIR/dist/Paopei.app"
PROJECT_FILE="$ROOT_DIR/NKJBlogPoster.xcodeproj/project.pbxproj"
MARKETING_VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$PROJECT_FILE" | head -n 1)"
BUILD_VERSION="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$PROJECT_FILE" | head -n 1)"

if [[ -z "$MARKETING_VERSION" || -z "$BUILD_VERSION" ]]; then
  print -u2 "Could not read app version from $PROJECT_FILE."
  exit 1
fi

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/NKJBlogPoster" "$APP_DIR/Contents/MacOS/NKJBlogPoster"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
xcrun actool "$ROOT_DIR/Support/Assets.xcassets" \
  --compile "$APP_DIR/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$APP_DIR/Contents/assetcatalog-info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
