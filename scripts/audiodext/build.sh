#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun -sdk driverkit --show-sdk-path)
DK="$SDK/System/DriverKit"
FWK="$DK/System/Library/Frameworks"
DKH="$FWK/DriverKit.framework/Headers"
ADKH="$FWK/AudioDriverKit.framework/Headers"
ARCH="${ARCH:-arm64e}"
TRIPLE="$ARCH-apple-driverkit"
NAME=com.apple.vphone.audiodext
BUNDLE=VPhoneAudio.dext

echo "SDK=$SDK"
echo "iig=$(xcrun -sdk driverkit -f iig)"

rm -rf inc *.iig.cpp *.iig.o VPhoneAudio.o "$NAME"
mkdir -p inc/VPhoneAudio

echo "=== iig (device + driver) ==="
for cls in VPhoneAudioDevice VPhoneAudio; do
  xcrun -sdk driverkit iig \
    --def "$cls.iig" \
    --header "inc/VPhoneAudio/$cls.h" \
    --impl "$cls.iig.cpp" \
    --framework-name VPhoneAudio \
    --deployment-target 25.5 \
    -- -I"$DKH" -I"$ADKH" -F"$FWK" -x c++ -std=gnu++17 -D__IIG=1
done

FLAGS=(-target "$TRIPLE" -std=gnu++17 -fno-exceptions -fno-rtti -I. -Iinc -I"$DKH" -I"$ADKH" -F"$FWK")
echo "=== compile ==="
xcrun -sdk driverkit clang++ "${FLAGS[@]}" -c VPhoneAudioDevice.iig.cpp -o VPhoneAudioDevice.iig.o
xcrun -sdk driverkit clang++ "${FLAGS[@]}" -c VPhoneAudio.iig.cpp -o VPhoneAudio.iig.o
xcrun -sdk driverkit clang++ "${FLAGS[@]}" -c VPhoneAudio.cpp -o VPhoneAudio.o
echo "=== link ==="
xcrun -sdk driverkit clang++ -target "$TRIPLE" -F"$FWK" \
    -framework DriverKit -framework AudioDriverKit \
    VPhoneAudioDevice.iig.o VPhoneAudio.iig.o VPhoneAudio.o -o "$NAME"

echo "=== assemble bundle ==="
rm -rf "$BUNDLE"; mkdir "$BUNDLE"
cp "$NAME" "$BUNDLE/$NAME"
cp Info.plist "$BUNDLE/Info.plist"
echo "=== sign ==="
codesign --force --sign - --entitlements vphoneaudio.entitlements --generate-entitlement-der "$BUNDLE" 2>&1 || \
  ldid -Svphoneaudio.entitlements "$BUNDLE/$NAME"
echo "=== done: $(file "$NAME" | head -1) ==="
lipo -info "$NAME" 2>/dev/null || true
