#!/bin/bash
# Measures the real cost of an Orbit hint scan on the currently installed macOS
# build: accessibility traversal, completeness, and the OCR supplement. Run this
# after each macOS release, since accessibility and ScreenCaptureKit costs are
# what make hint activation feel fast or sluggish.
#
# Requires the calling process to hold Accessibility (and Screen Recording for
# the OCR path) permission, the same as Orbit.app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orbit-bench.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

swiftc \
  -O \
  -module-cache-path "$WORK_DIR/module-cache" \
  "$REPO_ROOT/Sources/Eclick/Core.swift" \
  "$REPO_ROOT/Sources/Eclick/Permissions.swift" \
  "$REPO_ROOT/Sources/Eclick/AccessibilityModeLease.swift" \
  "$REPO_ROOT/Sources/Eclick/Scanner.swift" \
  "$REPO_ROOT/Tests/ScanBench/main.swift" \
  -o "$WORK_DIR/ScanBench"

"$WORK_DIR/ScanBench" "${@:-com.apple.finder}"
