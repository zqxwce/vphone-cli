// halpoke.c — minimal CoreAudio HAL client. One AudioObjectGetPropertyDataSize
// call connects to the HAL server (audiomxd), which makes launchd launch
// audiomxd on-demand. Used during the boot-stall to give `debugserver
// --waitfor=audiomxd` a spawn to catch.
#include <CoreAudio/AudioHardware.h>   // vendored (iOS SDK lacks it)
#include <stdio.h>
int main(void) {
    AudioObjectPropertyAddress a = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 sz = 0;
    OSStatus rc = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    printf("halpoke: rc=%d deviceListBytes=%u\n", (int)rc, (unsigned)sz);
    return 0;
}
