#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

if (( $# != 1 )); then
  print -u2 "Usage: $0 VERSION"
  exit 2
fi

VERSION="${1#v}"
if [[ ! "$VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]]; then
  print -u2 "VERSION must be a stable release version, such as 1.0.1."
  exit 2
fi

required_variables=(
  APPLE_API_KEY_ID
  APPLE_API_ISSUER_ID
  APPLE_API_PRIVATE_KEY_BASE64
  APPLE_SIGNING_IDENTITY
  APPLE_TEAM_ID
  SPARKLE_ED_PRIVATE_KEY
)
for variable in "${required_variables[@]}"; do
  if [[ -z "${(P)variable:-}" ]]; then
    print -u2 "$variable is required."
    exit 2
  fi
done

sparkle_signing_seed="$SPARKLE_ED_PRIVATE_KEY"
unset SPARKLE_ED_PRIVATE_KEY
SPARKLE_PUBLIC_ED_KEY="$(printf '%s' "$sparkle_signing_seed" | swift -e '
import CryptoKit
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
guard let seed = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write(Data("SPARKLE_ED_PRIVATE_KEY must be the base64 seed exported by Sparkle generate_keys.\n".utf8))
    exit(2)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
')"

OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist/release/$VERSION}"
DMG_NAME="Paopei-$VERSION.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
APPCAST_PATH="$OUTPUT_DIR/appcast.xml"

if [[ -e "$DMG_PATH" || -e "$CHECKSUM_PATH" || -e "$APPCAST_PATH" ]]; then
  print -u2 "Refusing to overwrite an existing release artifact in $OUTPUT_DIR."
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nkjblogposter-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
KEY_PATH="$WORK_DIR/AuthKey_${APPLE_API_KEY_ID}.p8"
XCODE_ARCHIVE="$WORK_DIR/NKJBlogPoster.xcarchive"
APP_PATH="$XCODE_ARCHIVE/Products/Applications/Paopei.app"
SOURCE_PACKAGES_DIR="$ROOT_DIR/.build/xcode/SourcePackages"
SPARKLE_TOOLS="$SOURCE_PACKAGES_DIR/artifacts/sparkle/Sparkle/bin"

mkdir -p "$OUTPUT_DIR"
printf '%s' "$APPLE_API_PRIVATE_KEY_BASE64" | base64 -D > "$KEY_PATH"

xcodebuild \
  -project NKJBlogPoster.xcodeproj \
  -scheme NKJBlogPoster \
  -configuration Release \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  -archivePath "$XCODE_ARCHIVE" \
  archive \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  ENABLE_HARDENED_RUNTIME=YES

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/NKJBlogPoster" -verify_arch arm64
lipo "$APP_PATH/Contents/MacOS/NKJBlogPoster" -verify_arch x86_64
"$ROOT_DIR/scripts/create-dmg.sh" "$APP_PATH" "$DMG_PATH"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --key "$KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"

(cd "$OUTPUT_DIR" && shasum -a 256 "$DMG_NAME") > "$CHECKSUM_PATH"

mkdir "$WORK_DIR/appcast"
cp "$DMG_PATH" "$WORK_DIR/appcast/$DMG_NAME"
RELEASES_URL="https://github.com/nakajijapan/Paopei/releases"
printf '%s\n' "$sparkle_signing_seed" | "$SPARKLE_TOOLS/generate_appcast" \
  --ed-key-file - \
  --maximum-deltas 0 \
  --download-url-prefix "$RELEASES_URL/download/v$VERSION/" \
  --link "$RELEASES_URL/tag/v$VERSION" \
  -o "$WORK_DIR/appcast/appcast.xml" \
  "$WORK_DIR/appcast"
printf '%s\n' "$sparkle_signing_seed" | "$SPARKLE_TOOLS/sign_update" \
  --ed-key-file - --verify "$WORK_DIR/appcast/appcast.xml"
mv "$WORK_DIR/appcast/appcast.xml" "$APPCAST_PATH"
print "$DMG_PATH"
