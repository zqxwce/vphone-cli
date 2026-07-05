#!/bin/zsh
# Build the custom VirtualAudio AudioServerPlugIn for iOS (arm64e) and assemble
# the flat .plugin bundle audiomxd loads from /System/Library/Audio/Plug-Ins/HAL/.
# Deploy is via ramdisk RW surgery (sealed System volume) — see the JB ramdisk skill.
set -euo pipefail
cd "${0:a:h}"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=VirtualAudio.plugin
rm -rf "$OUT"; mkdir -p "$OUT"

xcrun -sdk iphoneos clang -arch arm64e -bundle -fobjc-arc \
  -isysroot "$SDK" -mios-version-min=26.0 \
  -Ivendor \
  -framework CoreFoundation -framework CoreAudio -framework AudioToolbox \
  -o "$OUT/vphone_vaudio" vphone_vaudio.c

cp Info.plist "$OUT/Info.plist"
ldid -S "$OUT/vphone_vaudio"
echo "built $OUT (bundle id com.apple.audio.CoreAudio.VirtualAudio)"
