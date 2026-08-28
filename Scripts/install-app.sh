#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="$REPO_ROOT/.build/Orbit.app"
APPLICATIONS_DIR="${HOME}/Applications"
DESTINATION="$APPLICATIONS_DIR/Orbit.app"
LEGACY_DESTINATION="$APPLICATIONS_DIR/Eclick.app"

"$SCRIPT_DIR/build-app.sh"
mkdir -p "$APPLICATIONS_DIR"

EXPECTED_DESTINATION="$HOME/Applications/Orbit.app"
if [[ "$DESTINATION" != "$EXPECTED_DESTINATION" ]]; then
  echo "Refusing unexpected install destination: $DESTINATION" >&2
  exit 1
fi

if [[ -e "$DESTINATION" ]]; then
  rm -rf -- "$DESTINATION"
fi
ditto "$SOURCE_APP" "$DESTINATION"

if [[ -d "$LEGACY_DESTINATION" ]]; then
  LEGACY_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$LEGACY_BUNDLE_ID" == "com.ehsanalavinahad.eclick" ]]; then
    rm -rf -- "$LEGACY_DESTINATION"
    echo "Removed legacy $LEGACY_DESTINATION"
  else
    echo "Left unexpected legacy app untouched: $LEGACY_DESTINATION" >&2
  fi
fi

echo "Installed $DESTINATION"
echo "Launch with: open '$DESTINATION'"
