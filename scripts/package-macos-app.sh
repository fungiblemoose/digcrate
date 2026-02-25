#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/DeepCrateMac"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$ROOT_DIR/.packaging"
ICON_SCRIPT="$ROOT_DIR/scripts/build-macos-icon.sh"
ICON_SOURCE_PNG="${DEEPCRATE_ICON_PNG:-$ROOT_DIR/assets/branding/deepcrate-logo-mark.png}"
ICON_OUTPUT_ICNS="$ROOT_DIR/assets/branding/DeepCrate.icns"

APP_NAME="DeepCrate"
EXECUTABLE_NAME="DeepCrateMac"
VOL_NAME="DeepCrate"
ARCH_NAME="$(uname -m)"
BUNDLE_ID="${DEEPCRATE_BUNDLE_ID:-com.fungiblemoose.deepcrate}"
ICON_BASENAME="DeepCrate"

PYTHON_BIN="${DEEPCRATE_PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3.12 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3.12)"
  else
    PYTHON_BIN="$(command -v python3)"
  fi
fi

read_version() {
  if [[ -n "${DEEPCRATE_VERSION:-}" ]]; then
    printf '%s' "$DEEPCRATE_VERSION"
    return
  fi

  "$PYTHON_BIN" - <<'PY'
from pathlib import Path
import re

content = Path("pyproject.toml").read_text(encoding="utf-8")
match = re.search(r'^\s*version\s*=\s*"([^"]+)"\s*$', content, re.MULTILINE)
print(match.group(1) if match else "0.0.0")
PY
}

VERSION="$(cd "$ROOT_DIR" && read_version)"
PLIST_VERSION="${VERSION#v}"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
RUNTIME_DIR="$RESOURCES_DIR/DeepCrateRuntime"
DMG_STAGING_DIR="$STAGE_DIR/dmg"

DMG_NAME="$APP_NAME-$VERSION-macOS-$ARCH_NAME.dmg"
ZIP_NAME="$APP_NAME-$VERSION-macOS-$ARCH_NAME.zip"
DMG_PATH="$DIST_DIR/$DMG_NAME"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd swift
require_cmd "$PYTHON_BIN"
require_cmd hdiutil
require_cmd ditto

mkdir -p "$DIST_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "Building Swift app executable..."
swift build --package-path "$SWIFT_DIR" -c release --product "$EXECUTABLE_NAME"

BIN_DIR="$(swift build --package-path "$SWIFT_DIR" -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/$EXECUTABLE_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Built executable not found at $BIN_PATH" >&2
  exit 1
fi

cp "$BIN_PATH" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"

if [[ -x "$ICON_SCRIPT" && -f "$ICON_SOURCE_PNG" ]]; then
  echo "Building app icon from $ICON_SOURCE_PNG..."
  "$ICON_SCRIPT" "$ICON_SOURCE_PNG" "$ICON_OUTPUT_ICNS"
fi

if [[ -f "$ICON_OUTPUT_ICNS" ]]; then
  cp "$ICON_OUTPUT_ICNS" "$RESOURCES_DIR/$ICON_BASENAME.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_BASENAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$PLIST_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$PLIST_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$RESOURCES_DIR/PackagingNotes.txt" <<'TXT'
DeepCrate bundle notes

- The embedded Python bridge uses a bundled virtual environment under
  Contents/Resources/DeepCrateRuntime/.venv.
- User data and the default database path resolve to:
  ~/Library/Application Support/DeepCrate/data/deepcrate.sqlite
- API keys can be set in-app (Settings) and are forwarded to the bridge.
TXT

if [[ -f "$ROOT_DIR/.env.example" ]]; then
  cp "$ROOT_DIR/.env.example" "$RESOURCES_DIR/.env.example"
fi

echo "Creating embedded Python runtime..."
"$PYTHON_BIN" -m venv --copies "$RUNTIME_DIR/.venv"
"$RUNTIME_DIR/.venv/bin/python3" -m pip install --upgrade pip setuptools wheel
"$RUNTIME_DIR/.venv/bin/python3" -m pip install --no-deps "$ROOT_DIR"
"$RUNTIME_DIR/.venv/bin/python3" -m pip install \
  "rich>=13.0.0" \
  "librosa>=0.10.0" \
  "soundfile>=0.12.0" \
  "mutagen>=1.47.0" \
  "openai>=1.0.0" \
  "spotipy>=2.23.0" \
  "pydantic-settings>=2.0.0" \
  "aiosqlite>=0.19.0" \
  "numpy>=1.26.0"

if [[ -n "${DEEPCRATE_CODESIGN_IDENTITY:-}" ]]; then
  require_cmd codesign
  echo "Codesigning app bundle..."
  codesign --force --deep --timestamp --options runtime --sign "$DEEPCRATE_CODESIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
fi

echo "Creating distributable archives..."
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_BUNDLE" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if [[ -n "${DEEPCRATE_NOTARY_APPLE_ID:-}" && -n "${DEEPCRATE_NOTARY_APP_PASSWORD:-}" && -n "${DEEPCRATE_NOTARY_TEAM_ID:-}" ]]; then
  require_cmd xcrun
  if [[ -z "${DEEPCRATE_CODESIGN_IDENTITY:-}" ]]; then
    echo "Notarization requested, but DEEPCRATE_CODESIGN_IDENTITY is not set." >&2
    exit 1
  fi
  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$DEEPCRATE_NOTARY_APPLE_ID" \
    --password "$DEEPCRATE_NOTARY_APP_PASSWORD" \
    --team-id "$DEEPCRATE_NOTARY_TEAM_ID" \
    --wait
  xcrun stapler staple "$DMG_PATH"
fi

echo "Done."
echo "App: $APP_BUNDLE"
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
