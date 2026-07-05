# vphone audio session 2026-06-04 — what was tried, what stuck, what to try next

Standalone summary so the next iteration can pick up clean. Full
investigation log is in `virtio_sound_bridge.md` (1799 lines).

## Goal

Make audio playback work inside the vphone iOS 26.5 guest. The
host-side VirtIO sound device is configured correctly, the in-kernel
`AppleVirtIOSound` matches and the user client is open, but the
client-side audio stack (AVAudioSession / AVAudioEngine / AVAudioPlayer
/ AudioQueue) doesn't see the device and AVAudioEngine.start fails.

## What we proved

### 1. The architectural gap

macOS has both `coreaudiod` AND `audiomxd`; iOS has only
`audiomxd`. macOS's HAL→Fig bridge runs through `coreaudiod`,
which iOS doesn't have. There is no iOS-equivalent of
`_MXSystemAudio_macOSAddEndpointToContext` — every per-device add /
pick / activate function in `MediaExperience.framework` is
`_macOS*`-prefixed and only reachable from the macOS code path.

This is documented fully in `virtio_sound_bridge.md` Session 2026-06-04
parts 4 and 5.

### 2. HAL plugin publication works

The ported `AppleVirtIOSound.driver` HAL plugin is loaded by audiomxd
and registers an `AVIODevice` instance:

```
[AVIOPlugin addAudioDevice:] self=0xc12dcb560 device=0xc13328280
  deviceName = "Apple Virtual Sound Device"
```

Verified live in audiomxd via `route_probe.dylib`'s ObjC swizzle.

Class hierarchy: `AVIOPlugin: ASDPlugin`, `AVIODevice: ASDAudioDevice`
(the ASD-side iOS-native classes). So the publish path through
`[ASDPlugin audioDevices]` IS populated. But this list is not read by
the AVAudioSession server-side path on iOS.

### 3. Client-side AVAudioSession route advertising

`route_probe.dylib` (`/Users/user/.claude/jobs/4084a958/route_probe.m`)
when injected into a client process makes `AVAudioSession.currentRoute`
report our virtual audio device:

```
inputs=1 outputs=1
output[0]: <AVAudioSessionPortDescription:
              type = USBAudio;
              name = Apple Virtual Sound Device;
              UID = com.vphone.virtio.audio>
```

Mechanism: swizzles `-[AVAudioSessionRouteDescription initWithRawDescription:owningSession:]`
and substitutes a fabricated `NSDictionary` rawDescription when the
server reply is nil.

Plus it swizzles:
- `-[AVAudioSession sampleRate]` → 44100 when reported as 0
- `-[AVAudioSession outputNumberOfChannels]` → 2 when reported as 0
- `-[AVAudioSession inputNumberOfChannels]` → 1 when reported as 0
- `-[AVAudioSession IOBufferDuration]` → 0.005 when reported as 0
- `-[AVAudioIONode outputFormatForBus:]` → 2ch 44100Hz Float32 when reported as 0ch 0Hz
- `-[AVAudioIONode inputFormatForBus:]` → 1ch 44100Hz Float32

### 4. The audiomxd-side hooks (deployed but don't propagate)

`route_inject.dylib` (`/Users/user/.claude/jobs/4084a958/route_inject.m`)
runs inside audiomxd:
- Swizzles `-[MXEndpointDescriptorCache copyRouteDescriptorsForEndpoints:]`
  to append a synthetic descriptor — fires reliably (verified in
  `/tmp/route_inject.log` on VM)
- Swizzles `+[ATAudioSessionUtils getRouteDescriptionFromAVASRouteDescription:]`
  — never invoked (this is a client-side conversion, doesn't fire in audiomxd)

The injection is loaded by `route_probe.dylib`'s constructor via
`dlopen("/var/root/route_inject.dylib")` so we don't need to re-patch
audiomxd's LC_LOAD_DYLIB chain.

### 5. The DSC patch infrastructure works on iOS 26.5

`scripts/patchers/cfw_patch_audio_remoteio.py` — 23 byte-patches to
`dyld_shared_cache_arm64e.19` inside the SystemOS Cryptex:

- 6 NOPs on format-validation branches in `RemoteIOClient::ConnectToDevice` and `RemoteIOClient::IONodeClient::ConnectToDevice` (AudioToolbox)
- 3 NOPs on cbnz checks after wrap-error helper in `AVAudioEngineGraph::Initialize` (AVFAudio)
- 3 `mov x21, x0 → mov x21, #0` (force return value to zero)
- 3 `mov x6, x20 → mov x6, #0` (NULL outError**)
- 3 `mov w5, #-0x2a7b → mov w5, #0` (zero the error code passed to helper)
- 5 `mov w_, #-0x2a63 → mov w_, #0` at every -10851 emit site
- 1 `mov w20, #-0x2a7b → mov w20, #0` at the IONodeClient -10875 site

The patcher uses `cfw_dsc_chunks.DSCChunks.write_at_vma` and
`cfw_dsc_codesign.reattest_modified_pages` — same primitives as the
existing EXP variant patches. Page-hash reattest writes 5 new SHA-256
slot hashes in chunk19; TXM accepts; VM boots normally.

Deployment iteration loop:
- Pristine chunk19 copied from `_extracted/`
- `patch_audio_remoteio_in_dsc(work_dir)` mutates the chunk
- `make boot_dfu` + `make ramdisk_send`
- `pymobiledevice3 usbmux forward 2222 22`
- `/sbin/mount_apfs -o rw /dev/disk2s1 /mnt2`
- `cat patched_chunk19 > /mnt2/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e.19`
- `sync && umount /mnt2`
- Kill DFU, `make boot`
- Verify via `nc -z $ip 22222` + `rpcclient -f probe.py`

(Note: on this iPhone17,3 VM the system volume is `/dev/disk2s1`,
NOT `/dev/disk1s1` as the skill's default suggests.)

### Iteration count

Roughly 5 patch-deploy-boot cycles, each ~90s. The DSC patch IS live —
bytes on disk match the patched chunk, page hashes match, TXM accepts.
Verified by reading bytes from the live chunk via `dd` and comparing.

## What still fails

`AVAudioEngine.startAndReturnError:` returns NSError code `-10875`
(`kAudioUnitErr_FailedInitialization`) AFTER all 23 patches.

Same code, every iteration. So the `-10875` we observe is being
generated from somewhere our scans didn't catch — possibly:
- A different framework (we scanned AudioToolbox + AVFAudio + CoreAudio)
- A runtime-loaded constant rather than a `mov w_, #0x2a7a` immediate
- A sub-call that returns -10875 directly and propagates

lldb can't single-step engine.start because the audio thread watchdog
SIGABRTs any paused process. That blocks the obvious diagnostic.

## Files this session produced

**In the repo:**
- `scripts/patchers/cfw_patch_audio_remoteio.py` — NEW, 23 patches catalogued
- `research/audio/virtio_sound_bridge.md` — EXTENDED, full investigation log
- `research/audio/SESSION_2026-06-04_SUMMARY.md` — this file

**In the per-session job dir (`/Users/user/.claude/jobs/4084a958/`):**
- `route_probe.m` + `route_probe.dylib` — client-side AVAudioSession hooks
- `route_inject.m` + `route_inject.dylib` — audiomxd-side cache hooks
- `hal_hook.m` + `hal_hook.h` — CoreAudio HAL inline hook (failed: iOS
  DSC code can't be mprotect'd writable; kept for reference)
- `audiomxd.patched` + `audiomxd.patched3` — audiomxd with LC_LOAD_DYLIB to /var/root/route_probe.dylib (deployed earlier via prior session ramdisk surgery)
- `audiomxd_ent.plist` — copy of audiomxd's entitlements for re-signing
- `patched_chunks/dyld_shared_cache_arm64e.19` — last patched chunk applied

**On the live VM:**
- `/var/root/route_probe.dylib` — last build
- `/var/root/route_inject.dylib` — last build
- `/var/root/dyld_shared_cache_arm64e.19.bak` — pristine chunk19 backup
- `/usr/libexec/audiomxd` — patched, contains LC_LOAD_DYLIB /var/root/route_probe.dylib
- `/System/Cryptexes/OS/.../dyld_shared_cache_arm64e.19` — currently has the 23 patches applied

## What to try next (carry-forward ideas)

1. **Find the actual -10875 source.** Likely candidates not yet scanned:
   - `libsystem_*.dylib` (AudioComponentInstance / AURemoteIO helpers)
   - `AudioToolbox` sub-frameworks
   - A function that loads the error code from a const table (`ldr w_, [pc, +offset]`) rather than `mov`-immediate
   - Try `ipsw dyld macho ... --strings | grep -i kAudioUnit` and follow xrefs

2. **Use os_log to instrument** rather than lldb. iOS doesn't ship the
   `log` CLI on the device but you can patch a single point in
   AVAudioEngineGraph::Initialize to call a logger you control,
   capturing call chain via tail-return paths.

3. **Look at what AVAudioEngineGraph::Initialize calls that could
   return -10875.** Walk every `bl` in that function and resolve
   each callee, looking for ones that internally return -10875 from a
   non-immediate-load source (likely a CMBaseObject / AudioUnit
   property check).

4. **Different approach entirely: AudioQueue / AudioServicesPlaySystemSound.**
   These are simpler than AVAudioEngine. If they work without
   triggering the same -10875 path, the device may be playable through
   them even with the engine broken.

5. **mediaserverd-equivalent.** macOS's chain is
   coreaudiod → audiomxd → AVAudioSession. iOS collapses
   coreaudiod into audiomxd. Possibly the missing piece is a separate
   "device server" that needs to spawn under launchd to publish
   devices to clients. None of the existing audio daemons (audioaccessoryd,
   audioclocksyncd, audioanalyticsd) reference MXRegisterEndpointManager.

6. **Disable the audio watchdog** so lldb single-stepping engine.start
   doesn't SIGABRT. Check
   `defaults read /Library/Preferences/com.apple.coreaudio` for
   knobs, or sysctl `kern.coreaudio.*`.

## How to resume

If you wipe the VM and start fresh:
- The patcher module survives in the repo (git unchanged, in untracked dir)
- The `route_probe.dylib` source survives in `$CLAUDE_JOB_DIR/`
- The deployed VM-side files (`/var/root/route_*.dylib`,
  `/usr/libexec/audiomxd` patched, DSC chunk19 patched) DON'T survive a
  clean reinstall — would need to redeploy via the same workflow

If you want to roll back the DSC patch on the current VM without a
reinstall:
1. Boot ramdisk again (`make boot_dfu` + `make ramdisk_send`)
2. `mount_apfs -o rw /dev/disk2s1 /mnt2`
3. `cp /mnt2/var/root/dyld_shared_cache_arm64e.19.bak /mnt2/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e.19`
4. `sync; umount /mnt2`
5. Kill DFU, `make boot`

The backup at `/var/root/dyld_shared_cache_arm64e.19.bak` is the
pristine chunk (verified hash matches the original IPSW).
