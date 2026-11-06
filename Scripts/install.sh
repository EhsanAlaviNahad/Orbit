#!/bin/bash

set -euo pipefail

REPO_URL="${ORBIT_REPO_URL:-https://github.com/EhsanAlaviNahad/Orbit.git}"
REF="${ORBIT_REF:-main}"

say() { printf '%s\n' "$*"; }
die() { printf 'Orbit install failed: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required. Install the Command Line Tools with: xcode-select --install"
command -v swift >/dev/null 2>&1 || die "the Swift toolchain is required. Install it with: xcode-select --install"

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[[ "${MACOS_MAJOR:-0}" -ge 27 ]] || die "Orbit requires macOS 27 or newer (found ${MACOS_MAJOR:-unknown})."

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orbit-install.XXXXXX")"
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

say "Downloading Orbit…"
git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$WORK_DIR/Orbit"

say "Building and installing to ~/Applications/Orbit.app…"
"$WORK_DIR/Orbit/Scripts/install-app.sh"

say ""
say "Done. Launch Orbit with:  open ~/Applications/Orbit.app"
say "Then press Command-E in any app. Grant Accessibility in System Settings if prompted."
