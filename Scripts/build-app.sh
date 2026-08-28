#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Orbit"
BUILD_ROOT="$REPO_ROOT/.build"
SWIFT_BUILD_ROOT="$BUILD_ROOT/swiftpm"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
INFO_PLIST="$REPO_ROOT/Resources/Info.plist"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-module-cache"

swift build \
  --disable-sandbox \
  --scratch-path "$SWIFT_BUILD_ROOT" \
  --package-path "$REPO_ROOT" \
  --configuration release \
  --arch arm64 \
  -debug-info-format none \
  --product "$APP_NAME"

BIN_DIR="$(swift build \
  --disable-sandbox \
  --scratch-path "$SWIFT_BUILD_ROOT" \
  --package-path "$REPO_ROOT" \
  --configuration release \
  --arch arm64 \
  --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Release executable not found: $EXECUTABLE" >&2
  exit 1
fi

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Info.plist not found: $INFO_PLIST" >&2
  exit 1
fi

EXPECTED_BUNDLE="$REPO_ROOT/.build/Orbit.app"
if [[ "$APP_BUNDLE" != "$EXPECTED_BUNDLE" ]]; then
  echo "Refusing to replace unexpected bundle path: $APP_BUNDLE" >&2
  exit 1
fi

rm -rf -- "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
chmod 755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

codesign \
  --force \
  --sign - \
  --timestamp=none \
  --requirements '=designated => identifier "com.ehsanalavinahad.eclick" and info[EclickSigningMarker] = "F14A184E-BC4A-4E78-AE83-EC617B748E54"' \
  "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
