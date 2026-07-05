# USB Audio Class passthrough — virtual UAC device on host, VZ passthrough into iOS VM

Status (2026-06-03 — **dead end**): the synthetic-USB-device + VZ-passthrough approach is blocked by two walls in VZ. The infrastructure all works in isolation (synthetic device enumerates, descriptors parse, passthrough config object can be created), but VZ rejects the attach.

**Wall 1 — iso endpoints rejected at validate time:**
`config.validate()` returns `VZErrorDomain` code -6 with `"A USB passthrough device with isochronous endpoints is not supported."` The check is `VzCore::Hardware::Usb::usb_device_service_has_isochronous_endpoints` — scans the IOService descriptor tree for iso endpoints and rejects.

**Workaround attempted:** skip `config.usbControllers = [xhci-with-our-device]`, instead pass an empty `VZXHCIControllerConfiguration` and hot-plug attach via `vm.usbControllers[0].attachDevice:completionHandler:` after VM start. This bypasses validate-time iso check.

**Wall 2 — IOServiceAuthorize on hot-plug attach:**
The hot-plug path returns `VZErrorDomain` code -7 `"IOServiceAuthorize failed."` Our own pre-call to `IOServiceAuthorize(svc, kIOServiceInteractionAllowed)` returns `kIOReturnBadMessageID` (0xE00002C6) — meaning the `com.apple.iokit.IOServiceAuthorizeAgent` XPC service rejects the request or replies with non-matching status.

Tested with HID-keyboard descriptors (no iso endpoints, no audio class). Same `IOReturnBadMessageID` result. **The rejection is not iso-specific** — IOServiceAuthorize rejects any synthetic device backed by AppleUSBUserHCI. The agent likely scans the parent class hierarchy and refuses synthetic controllers.

The `IOServiceAuthorize` disassembly in IOKit (extracted from DSC) shows the agent path: connect to `com.apple.iokit.IOServiceAuthorizeAgent` over XPC, send the service's registry entry ID with options, expect a status reply that matches an expected value. Our synthetic device gets rejected at the agent layer.

**Implication:** `_VZIOUSBHostPassthroughDeviceConfiguration` is intended for user-attached physical USB devices that the console user can authorize via a GUI prompt (the agent presumably also enforces parent-class-must-be-real-PCI-controller). Synthetic devices on `AppleUSBUserHCI` do not satisfy this gate.

The VZ private `_VZUSBPassthroughDeviceConfiguration` (the AAUSBAccessory path) might bypass this — but requires constructing an `AAUSBAccessory` from `AccessoryAuthentication.framework`, which is MFi-authentication-backed.

## Extension entitlements probed (2026-06-03 follow-up)

VZ's umbrella binary contains a list of private "extension" entitlement strings (file offsets ~22.8M):

```
com.apple.virtualization.extension.audio-output
com.apple.virtualization.extension.audio-input
com.apple.virtualization.extension.usb-hci
com.apple.virtualization.extension.usb-device-passthrough
com.apple.virtualization.extension.io-surface
com.apple.virtualization.extension.paravirtualized-graphics
com.apple.virtualization.extension.bridged-networking
com.apple.virtualization.extension.bifrost-pci-device.local
com.apple.virtualization.extension.bifrost-pci-device.unix
com.apple.virtualization.extension.aes
com.apple.virtualization.extension.fp
com.apple.virtualization.extension.avp.rtc
com.apple.virtualization.extension.videotoolbox
com.apple.virtualization.extension.biometrics
com.apple.virtualization.extension.strong-identity
com.apple.virtualization.extension.disk-images-2.amber-plugin
com.apple.virtualization.extension.disk-images-2.julio-test-plugin
com.apple.virtualization.extension.internal.rosetta
```

Tested with `com.apple.virtualization.extension.{usb-device-passthrough, usb-hci, audio-input, audio-output}` added to vphone-cli — no change. Both the iso-validate check and the IOServiceAuthorize gate still fire. These entitlements gate WHO is allowed to use the existing public/private VZ APIs (and probably exist for Apple-internal use of those APIs from secondary processes). They do NOT make the existing APIs accept synthetic devices on `AppleUSBUserHCI`.

VZ's audio-class inventory is exclusively VirtIO sound: `VZAudioDeviceConfiguration` (and the VirtIO subclass), `VZAudioInputStreamSource`, `VZAudioOutputStreamSink`, `VZHostAudioInputStreamSource`, `VZHostAudioOutputStreamSink`, `_VZAudioDevice`. There is no `_VZUSBAudio*` class — VZ does not internally emulate USB audio. So the audio extension entitlements don't unlock a new audio device path either.

## Why this approach

The virtio-sound work (see `virtio_sound_bridge.md`) hit an architectural wall: iOS audio is gated by AVAudioSession + audiomxd's MX layer, which sits above HAL. The virtio sound HAL plugin loaded fine but never reached AVAudioSession-aware clients because the iOS audio stack treats HAL devices as a registration source the MX layer mostly ignores.

USB audio is a different code path. iOS knows how to handle USB Audio Class devices because every USB-C headphone/DAC is a UAC device, and iOS's USB audio driver wires those into the MX layer automatically. If we make a synthetic USB UAC device on the host and pass it through to the iOS VM via VZ, iOS should treat it exactly like a plugged-in DAC.

## Architecture

```
                                  macOS host
+--------------------------------------------------------------+
|  vphone-cli (host process)                                   |
|  ┌────────────────────────────────────────────────────────┐  |
|  │  SyntheticUSBDevice (UAC1)                             │  |
|  │   ├─ IOUSBHostControllerInterface (kernel UC)          │  |
|  │   ├─ UAC1 descriptors                                  │  |
|  │   ├─ iso IN  → reads from CoreAudio mic                │  |
|  │   └─ iso OUT → writes to CoreAudio speaker             │  |
|  └────────────────────────────────────────────────────────┘  |
|         │                                                    |
|         ▼ kernel registers synthetic device                  |
|  ┌────────────────────────────────────────────────────────┐  |
|  │  AppleUSBUserHCI@81000000                              │  |
|  │   └─ "vphone Synthetic USB POC@81100000"               │  |
|  │      locationID 0x81100000 (IOUSBHostDevice)           │  |
|  └────────────────────────────────────────────────────────┘  |
|         │                                                    |
|         ▼ VZ passthrough by locationID                       |
|  ┌────────────────────────────────────────────────────────┐  |
|  │  _VZIOUSBHostPassthroughDeviceConfiguration            │  |
|  │   added to VZXHCIControllerConfiguration.usbDevices    │  |
|  └────────────────────────────────────────────────────────┘  |
+--------------------------------------------------------------+
                            │ VZ XHCI bus
                            ▼
+--------------------------------------------------------------+
|  iOS VM                                                      |
|  ┌────────────────────────────────────────────────────────┐  |
|  │  IOUSBHostFamily (in guest) → matches class 0x01       │  |
|  │   └─ IOUSBAudio (or equivalent) attaches               │  |
|  │      └─ AVAudioSession picks up device automatically   │  |
|  └────────────────────────────────────────────────────────┘  |
+--------------------------------------------------------------+
```

## Foundation: synthetic USB device on macOS host

### Required entitlement

`com.apple.developer.usb.host-controller-interface`

Accepted by AMFI as long as the binary is signed with this entitlement. The vphone development environment has `amfidont -v -S --path /Users/user/dev/vphone-cli/` so locally-signed binaries with arbitrary entitlements run.

### Kernel side

`AppleUSBUserHCI.kext` (com.apple.driver.usb.AppleUSBUserHCI) is loaded in stock macOS 15+. Its IORegistry presence:

```
+-o AppleUSBUserHCI@80000000  <class AppleUSBUserHCI, id 0x10006a428>      ← used by VZ already (iPhone-as-USB)
  +-o iPhone Research Environment Virtual Machine@80100000
+-o AppleUSBUserHCI@81000000  <class AppleUSBUserHCI, id 0x10006a67b>      ← our POC's controller
  +-o vphone Synthetic USB POC@81100000
```

Each `IOUSBHostControllerInterface` instantiation creates a new AppleUSBUserHCI service at a fresh @XX000000 locationID.

### POC structure

`scripts/usbaudio/`:
- `Package.swift`: SwiftPM, links IOUSBHost + IOKit
- `usbaudio.entitlements`: host-controller-interface + get-task-allow
- `Sources/usbaudio-poc/SyntheticIOUSBDevice.swift`: JJTech0130 gist (https://gist.github.com/JJTech0130/fae6b6ee6ae4232172a9188fb199d5d9), unchanged
- `Sources/usbaudio-poc/main.swift`: HID-keyboard descriptors as a smoke test
- `build.sh`: swift build + codesign

POC output (verified 2026-06-03):
```
[SyntheticIOUSBDevice] Controller created — UUID: 3656E1FB-...
[SyntheticIOUSBDevice] CMD IOUSBHostCIMessageTypeControllerPowerOn
[SyntheticIOUSBDevice] CMD IOUSBHostCIMessageTypeControllerStart
[SyntheticIOUSBDevice] CMD IOUSBHostCIMessageTypePortPowerOn
[SyntheticIOUSBDevice] Port 1: device connected (full-speed)
[SyntheticIOUSBDevice] CMD IOUSBHostCIMessageTypeDeviceCreate
[SyntheticIOUSBDevice] Device at address 1
[SyntheticIOUSBDevice] SETUP bmRT=0x80 bReq=0x06 wVal=0x0100 ...   # GET_DESCRIPTOR Device
[SyntheticIOUSBDevice] SETUP bmRT=0x80 bReq=0x06 wVal=0x0200 ...   # GET_DESCRIPTOR Config
[SyntheticIOUSBDevice] SETUP bmRT=0x00 bReq=0x09 wVal=0x0001 ...   # SET_CONFIGURATION
```

IORegistry properties showed `idVendor=0x05AC idProduct=0x0710 kUSBCurrentConfiguration=1` — full enumeration cycle complete.

## VZ passthrough APIs (private, macOS 15+)

Extracted from `Virtualization.framework` (DSC `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e`).

### `_VZIOUSBHostPassthroughDeviceConfiguration`

Designed for passing through any host USB device by IOService reference or locationID. **This is what we use for our synthetic UAC device.**

```objc
@interface _VZIOUSBHostPassthroughDeviceConfiguration : NSObject
    <_VZVirtualMachineConfigurationEncodable,
     _VZUSBDeviceConfigurationInternal,
     _VZUSBDeviceConfigurationSignature,
     NSCopying,
     VZUSBDeviceConfiguration>

+ (id)fromLocationID:(unsigned int)id error:(id *)error;
- (id)initWithService:(unsigned int)service error:(id *)error;

@property (copy) NSUUID *uuid;
@property (readonly, nonatomic) NSData *signature;
@end
```

Wire-up:
```swift
let cfg = Dynamic._VZIOUSBHostPassthroughDeviceConfiguration
    .fromLocationID(locationID, error: nil)            // ← unsigned int locationID

let xhci = VZXHCIControllerConfiguration()
xhci.usbDevices = [cfg]
vmConfig.usbControllers = [xhci]
```

### `_VZUSBPassthroughDeviceConfiguration` (NOT what we want)

Designed for `AAUSBAccessory` objects — the AccessoryAuthentication-framework MFi flow. Wrong entry point for our synthetic device.

### Public API surface (macOS 15+)

```objc
@interface VZUSBControllerConfiguration : NSObject
@property NSArray<id<VZUSBDeviceConfiguration>> *usbDevices;
@end

@interface VZXHCIControllerConfiguration : VZUSBControllerConfiguration
- (instancetype)init;
@end

@protocol VZUSBDeviceConfiguration <NSObject>
@property NSUUID *uuid;
@end

@interface VZUSBMassStorageDeviceConfiguration : NSObject <VZUSBDeviceConfiguration>
// Only public concrete device type. Private subclasses: _VZIOUSBHostPassthroughDeviceConfiguration,
// _VZUSBKeyboardConfiguration, _VZUSBMouseConfiguration, _VZUSBTouchScreenConfiguration, etc.
@end
```

`VZVirtualMachineConfiguration` has `usbControllers : NSArray<VZUSBControllerConfiguration*>` (added macOS 15).

## How to get locationID at runtime

`IOUSBHostControllerInterface` does not expose its assigned locationID directly. Three options:

1. **Iterate IORegistry post-instantiation**: walk `AppleUSBUserHCI` services, find the one matching our `IOUSBHostControllerInterface.uuid` (the controller exposes its UUID; the matching IOService entry likely has a matching property). Need to verify the property name on the IOService side.

2. **Use IOService matching dictionary** for our class+VID:PID after `start()`. Faster.

3. **Walk the controller's children**: each AppleUSBUserHCI has exactly one IOUSBHostDevice child at locationID = controller_loc + 0x100000. Our POC saw `@81000000 → @81100000`. The mapping is deterministic.

Option 2 is simplest. Pseudo-code:
```swift
let matching = IOServiceMatching("IOUSBHostDevice")
matching[kUSBVendorID] = 0x05AC
matching[kUSBProductID] = 0x0710
let iter = IOServiceGetMatchingServices(...)
let svc = IOIteratorNext(iter)                       // io_service_t (unsigned int)
let cfg = Dynamic._VZIOUSBHostPassthroughDeviceConfiguration
    .initWithService(svc, error: nil)
```

## USB Audio Class 1.0 device design

UAC1 (USB Class Code 0x01) is the right target for full-speed (12 Mbps). UAC2 needs high-speed and is more complex; iOS supports both but UAC1 is simpler.

### Descriptor topology

A minimum dual-direction UAC1 device has:

```
Device descriptor (class 0xFF/00/00 — defined by interface, since multiple)
└─ Configuration descriptor (wTotalLength ~ 250+)
   ├─ IAD (Interface Association Descriptor) covering all audio interfaces
   │
   ├─ Interface 0 — AudioControl (class 0x01, subclass 0x01)
   │  └─ Class-specific AC descriptors:
   │     ├─ Header descriptor
   │     ├─ Input Terminal (microphone)       — for mic IN
   │     ├─ Output Terminal (USB streaming)   — for mic IN
   │     ├─ Input Terminal (USB streaming)    — for speaker OUT
   │     └─ Output Terminal (speaker)         — for speaker OUT
   │
   ├─ Interface 1 — AudioStreaming (mic IN), AlternateSetting 0 (no streaming)
   ├─ Interface 1 — AudioStreaming (mic IN), AlternateSetting 1 (active)
   │  ├─ Class-specific AS general descriptor
   │  ├─ Format Type I PCM descriptor (48 kHz, 16-bit, 2 ch)
   │  └─ Isochronous IN endpoint (EP 0x81)
   │
   ├─ Interface 2 — AudioStreaming (speaker OUT), AlternateSetting 0 (no streaming)
   └─ Interface 2 — AudioStreaming (speaker OUT), AlternateSetting 1 (active)
      ├─ Class-specific AS general descriptor
      ├─ Format Type I PCM descriptor (48 kHz, 16-bit, 2 ch)
      └─ Isochronous OUT endpoint (EP 0x02)
```

### Endpoint changes in SyntheticIOUSBDevice

The base class assumes:
- EP 0x81 is interrupt IN
- HID class requests (0xA1) for GET_REPORT

For UAC1 we need:
- EP 0x81: isochronous IN (mic data flowing host→VM)
- EP 0x02: isochronous OUT (speaker data flowing VM→host)
- UAC class requests: SET_CUR/GET_CUR/GET_MIN/GET_MAX (volume, mute, sample rate)

The `handleNormalTransfer` function in `SyntheticIOUSBDevice.swift` needs:
- Endpoint-direction dispatch: 0x81 → fill from mic, 0x02 → drain to speaker
- Isochronous packets are large (~192 bytes per 1ms frame at 48k/16/2)

### CoreAudio bridging

On the host, the device should:
- Open a default-input AUHAL unit, feed mic samples into EP 0x81 transfer buffers
- Open a default-output AUHAL unit, drain EP 0x02 transfer buffers to speaker

This is the inverse of what VirtIO sound's VZHostAudioInputStreamSource does (which feeds the guest's virtio device from host mic) — same bytes, different transport.

## Open questions for the next iteration

1. **Does iOS's USB audio driver attach to a UAC1 device on a VZ-virtual XHCI bus?** Should be yes (it's the standard USB audio class) but needs verification once the device shows up in the VM's USB tree.

2. **Latency**: Isochronous transfers at 1ms frame intervals = ~1ms host-to-VM. CoreAudio bridging adds buffering. Total round-trip likely 5–20 ms. Acceptable for a research tool.

3. **48 kHz vs 44.1 kHz**: iOS prefers 48 kHz. Use 48k.

4. **Headphone or built-in?**: User has an external speaker on the Mac. Use the system default output (already set to external speaker per user instruction) — that's what `kAudioObjectPropertyDefaultOutputDevice` resolves to.

## Integration in vphone-cli (done 2026-06-03)

Files added / changed:

- `sources/vphone.entitlements` — added `com.apple.developer.usb.host-controller-interface`.
- `sources/vphone-cli/VPhoneSyntheticUSBDevice.swift` — JJTech base class with the new `deviceINData(endpoint:maxLength:)` and `deviceOUTData(endpoint:data:)` overrides so iso-EP traffic dispatches by endpoint direction (not hardcoded to EP 0x81).
- `sources/vphone-cli/VPhoneUSBAudioDescriptors.swift` — UAC1 stereo / 48 kHz / 16-bit duplex descriptors. AC header `bLength=10` (NOT 9 — the 1+1+1+2+2+1+2 layout caught me on first attempt) and `wTotalLength` accounts for both `baInterfaceNr` entries.
- `sources/vphone-cli/VPhoneUSBAudioDevice.swift` — `VPhoneUSBAudioDevice` orchestrator + `SyntheticUACDevice` subclass. Mic IN returns silence; speaker OUT discards data (CoreAudio bridging in next task).
- `sources/vphone-cli/VPhoneVirtualMachine.swift` — `init()` creates the synthetic device, polls IORegistry for `IOUSBHostDevice` matching our VID:PID, reads `locationID`, calls `+[_VZIOUSBHostPassthroughDeviceConfiguration fromLocationID:error:]` via the obj-c runtime, wraps in a `VZXHCIControllerConfiguration`, and assigns `config.usbControllers = [xhci]`. VirtIO sound config preserved (no regression; both paths configured).
- `sources/vphone-cli/VPhoneError.swift` — two new error cases for setup failure paths.

Build/sign:

- `make build` and `make bundle` succeed; entitlement embedded in `.build/vphone-cli.app/Contents/MacOS/vphone-cli`. Verified with `codesign -d --entitlements -`.

Failure-safe design: any failure in the USB audio setup (controller alloc, IOService timeout, passthrough config creation, validation rejection) is caught and logged; vphone-cli continues without USB audio. No regression vs the previous build.

## Open verification

End-to-end testing requires a fresh VM (the user said they'd rebuild one) — the prior virtio-sound / audiomxd surgery may have left the existing image in an inconsistent state. Once a fresh VM boots with the updated binary, check:

1. `ioreg` on host shows our synthetic device under AppleUSBUserHCI (already confirmed in POC).
2. iOS VM's `ioreg` (via SSH) shows a USB audio device under the virtual XHCI.
3. iOS detects an external audio output in **Settings → Sound** or via AVAudioSession's `availableInputs`/`outputs`.
4. (After CoreAudio bridge) actual audio routes through.

## Re-entry plan

When picking up this work:

1. `/Users/user/dev/vphone-cli/scripts/usbaudio/` still has the standalone POC. Useful for iterating on descriptors / endpoint handling outside the vphone-cli build.

2. The vphone-cli build is the production wiring. The synthetic device lifecycle is tied to `VPhoneVirtualMachine` — created in init, lives for the VM's lifetime, cleaned up by process exit (no explicit teardown on `guestDidStop` yet — acceptable since process exits).

3. The next concrete task is the CoreAudio bridge (`SyntheticUACDevice.deviceINData` and `deviceOUTData` overrides):
   - Mic IN: AUHAL input unit reading default-input (Mac mic) → ring buffer → drained by `deviceINData(endpoint: 0x81, …)`.
   - Speaker OUT: `deviceOUTData(endpoint: 0x02, …)` → ring buffer → AUHAL output unit writing to default-output (external speaker per user's environment).
   - Sample rate conversion if iOS picks an alt setting at a non-48k rate (it should pick 48k since that's the only freq we expose).

4. Pristine VM required — the prior virtio-sound and audiomxd-patching experiments may have left state on the older VM image.
