#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/eclick-tests.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

swiftc \
  -parse-as-library \
  -module-cache-path "$TEST_ROOT/module-cache" \
  "$REPO_ROOT/Sources/Eclick/Core.swift" \
  "$REPO_ROOT/Tests/CoreSelfTests/main.swift" \
  -o "$TEST_ROOT/EclickCoreTests"

"$TEST_ROOT/EclickCoreTests"
