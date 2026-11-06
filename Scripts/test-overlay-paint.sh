#!/bin/bash
# Renders the hint overlay off-screen and compares an incremental (dirty-rect)
# frame against a full repaint, pixel for pixel. Run this after any change to
# HintOverlayView drawing or invalidation, and on each macOS release, since
# AppKit's compositing costs are what make typing feel fast or sluggish.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orbit-overlay-tests.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

swiftc \
  -parse-as-library \
  -module-cache-path "$TEST_ROOT/module-cache" \
  "$REPO_ROOT/Sources/Eclick/SystemCommand.swift" \
  "$REPO_ROOT/Sources/Eclick/Core.swift" \
  "$REPO_ROOT/Sources/Eclick/PageScroller.swift" \
  "$REPO_ROOT/Sources/Eclick/Permissions.swift" \
  "$REPO_ROOT/Sources/Eclick/Preferences.swift" \
  "$REPO_ROOT/Sources/Eclick/Overlay.swift" \
  "$REPO_ROOT/Tests/OverlayPaintTests/main.swift" \
  -o "$TEST_ROOT/OverlayPaintTests"

"$TEST_ROOT/OverlayPaintTests"
