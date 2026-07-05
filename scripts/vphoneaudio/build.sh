#!/bin/zsh
set -euo pipefail
cd "${0:a:h}"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang -arch arm64e -dynamiclib -fobjc-arc \
  -isysroot "$SDK" -mios-version-min=26.0 \
  -I../vphoned \
  -install_name /var/jb/usr/lib/libvphoneaudio.dylib \
  -framework Foundation \
  -Wl,-undefined,dynamic_lookup \
  -o libvphoneaudio.dylib libvphoneaudio.m
ldid -S./entitlements.plist libvphoneaudio.dylib
echo "built libvphoneaudio.dylib"
