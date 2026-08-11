#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="$REPO_ROOT/.build/Eclick.app"
APPLICATIONS_DIR="${HOME}/Applications"
DESTINATION="$APPLICATIONS_DIR/Eclick.app"

"$SCRIPT_DIR/build-app.sh"
mkdir -p "$APPLICATIONS_DIR"

EXPECTED_DESTINATION="$HOME/Applications/Eclick.app"
if [[ "$DESTINATION" != "$EXPECTED_DESTINATION" ]]; then
  echo "Refusing unexpected install destination: $DESTINATION" >&2
  exit 1
fi

if [[ -e "$DESTINATION" ]]; then
  rm -rf -- "$DESTINATION"
fi
ditto "$SOURCE_APP" "$DESTINATION"

echo "Installed $DESTINATION"
echo "Launch with: open '$DESTINATION'"
