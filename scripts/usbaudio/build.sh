#!/usr/bin/env zsh
set -euo pipefail

HERE="${0:a:h}"
cd "$HERE"

BIN_NAME="usbaudio-poc"
ENTITLEMENTS="$HERE/usbaudio.entitlements"
BUILD_DIR="$HERE/.build/arm64-apple-macosx/debug"

echo "[build] swift build"
swift build --triple arm64-apple-macosx

EXE="$BUILD_DIR/$BIN_NAME"
[ -f "$EXE" ] || { echo "[build] missing $EXE"; exit 1; }

echo "[build] codesign with entitlements"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$EXE"

echo "[build] verify"
codesign -d --entitlements - "$EXE" 2>&1 | grep -E "(host-controller|get-task)"

echo "[build] binary at $EXE"
echo "[build] run:   sudo $EXE     # uncertain whether root is required — try without first"
