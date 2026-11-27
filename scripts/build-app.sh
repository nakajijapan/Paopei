#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

xcodebuild \
  -project NKJBlogPoster.xcodeproj \
  -scheme NKJBlogPoster \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT_DIR/.build/xcode" \
  CONFIGURATION_BUILD_DIR="$ROOT_DIR/dist" \
  -quiet build

print "$ROOT_DIR/dist/Paopei.app"
