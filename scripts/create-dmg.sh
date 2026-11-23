#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 "Usage: $0 APP_PATH OUTPUT_DMG_PATH"
  exit 2
fi

APP_PATH="${1:A}"
OUTPUT_DMG_PATH="${2:A}"
VOLUME_NAME="Paopei"
APP_NAME="Paopei.app"
SCRIPT_DIR="${0:A:h}"
BACKGROUND_IMAGE="$SCRIPT_DIR/../Support/Installer/dmg-background-paopei.png"

if [[ ! -d "$APP_PATH" ]]; then
  print -u2 "App bundle not found: $APP_PATH"
  exit 1
fi
if [[ ! -f "$BACKGROUND_IMAGE" ]]; then
  print -u2 "Installer background not found: $BACKGROUND_IMAGE"
  exit 1
fi
if [[ -e "$OUTPUT_DMG_PATH" ]]; then
  print -u2 "Refusing to overwrite an existing disk image: $OUTPUT_DMG_PATH"
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nkjblogposter-dmg.XXXXXX")"
RW_DMG="$WORK_DIR/NKJBlogPoster-rw.dmg"
MOUNT_DIR=""
ATTACHED=0

cleanup() {
  if (( ATTACHED )); then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "${OUTPUT_DMG_PATH:h}"
hdiutil create \
  -size 100m \
  -fs HFS+ \
  -volname "$VOLUME_NAME" \
  -ov \
  "$RW_DMG" >/dev/null
ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT_DIR="$(print -r -- "$ATTACH_OUTPUT" | awk -F '\t' 'NF >= 3 && $NF ~ /^\// { print $NF }' | tail -n 1)"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  print -u2 "Could not determine the mounted disk image path."
  exit 1
fi
ATTACHED=1

ditto "$APP_PATH" "$MOUNT_DIR/$APP_NAME"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND_IMAGE" "$MOUNT_DIR/.background/background.png"
xcrun SetFile -a V "$MOUNT_DIR/.background"
if [[ -d "$MOUNT_DIR/.fseventsd" ]]; then
  xcrun SetFile -a V "$MOUNT_DIR/.fseventsd"
fi

osascript - "$MOUNT_DIR" "$APP_NAME" <<'APPLESCRIPT'
on run argv
  set mountPath to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    set installerDisk to (POSIX file mountPath) as alias
    tell folder installerDisk
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {100, 100, 1060, 580}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 128
      set text size of viewOptions to 14
      set background picture of viewOptions to file ".background:background.png"
      set position of item appName to {230, 240}
      set position of item "Applications" to {730, 240}
      -- Finder can show invisible files when the user enables that preference.
      -- Keep the supporting folders outside the initial window in that case.
      try
        set position of item ".background" to {3000, 3000}
      end try
      try
        set position of item ".fseventsd" to {3200, 3000}
      end try
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet
ATTACHED=0
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG_PATH" >/dev/null
hdiutil verify "$OUTPUT_DMG_PATH" >/dev/null
print "$OUTPUT_DMG_PATH"
