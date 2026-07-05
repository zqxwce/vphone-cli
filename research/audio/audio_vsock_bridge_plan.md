# Guest Audio via vsock Side-Channel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make guest iOS audio audible on the Mac (full duplex) by registering an audio endpoint inside `audiomxd` and tunnelling rendered PCM over a dedicated vsock port to a host-side CoreAudio bridge.

**Architecture:** Guest dylib injected into `audiomxd` registers a routable audio endpoint (so `AURemoteIOServer` will render/capture) and pumps PCM over vsock port **1339** to/from a new host-side `VPhoneAudioBridge` that plays to / captures from the Mac's default audio device. EXP-variant only.

**Tech Stack:** Swift 6.0 (host, `Virtualization` + `AVFoundation`), C/Objective-C (guest dylib, iOS arm64e SDK + `ldid`), vsock (`AF_VSOCK`), existing DSC/ramdisk deploy tooling.

**Design spec:** `research/audio/audio_vsock_bridge_design.md`. Background/evidence: `research/audio/virtio_sound_bridge.md`, `research/audio/SESSION_2026-06-04_SUMMARY.md`.

## Global Constraints

- Build the host binary with `make build` — never `swift build` alone (entitlements; CLAUDE.md "Build & Sign").
- The executable target has **no XCTest** (SwiftPM can't unit-test executables). Host-Swift tasks verify via `make build` + runtime observation; guest/RE tasks verify on-device (rpcclient / ssh / logs / audible check). This matches existing practice (`VPhoneCameraServer`, `vphoned`, firmware gates) — do **not** fabricate an executable test target.
- vsock ports in use: **1337** = vphoned, **1338** = camera. Audio uses **1339**. Do not reuse 1337/1338.
- Wire format is fixed: **48000 Hz, 2 channels, Int16 interleaved, little-endian**. Host converts to/from the Mac device format; guest converts to/from `audiomxd`'s format.
- The guest dylib must **never crash or hang `audiomxd`** — every failure path (registration, vsock, format) logs and degrades to silence. `audiomxd` respawns under launchd; a crash loop harms the VM.
- EXP variant only. Regular/Dev/JB must not receive the dylib and must behave unchanged.
- Kernel/DSC patchers (if any are added): no hardcoded offsets/addresses/instruction bytes; derive from Capstone, assemble via Keystone helpers (CLAUDE.md "Kernel patcher guardrails").
- Any new firmware patch must be recorded in `research/0_binary_patch_comparison.md` (CLAUDE.md).
- Commit only when the user asks; on `main`, branch first.

---

## Verification model (read before starting)

Each task ends with a concrete, observable check:
- **Host-Swift tasks:** `make build` succeeds, then a runtime check (loopback connect, logged frame counts, audible output).
- **Guest dylib tasks:** build + `ldid` sign, inject into `audiomxd`, deploy via the ramdisk RW path (`ios-jb-ramdisk-rw-surgery` / `vphone-dsc-chunk-ramdisk-deploy` skills), then observe `/tmp` logs + on-device probes (`vphone-rpcclient-introspection`, `ios-debugserver-over-ssh`).
- **The single irreducible unknown** — the exact endpoint-registration call — is resolved in **Phase 0** and written back into Task 2.4 before that task is coded. This is a deliberate spike→fill-in, not a placeholder.

---

## Phase 0 — Spike: resolve the two load-bearing unknowns

A booted EXP VM with `rpcserver_ios` is required. Skills: `vphone-rpcclient-introspection`, `vphone-vm-ssh-and-controlmaster`, `ios-debugserver-over-ssh`.

### Task 0.1: U1 — find a reusable endpoint-manager construction path

**Files:**
- Create: `research/audio/spike_endpoint_manager.py` (rpcclient script, throwaway-but-kept)

**Interfaces:**
- Produces: a written decision in `audio_vsock_bridge_design.md` ("Phase 0 results" section) — either `REUSE: <class> <selector(s)>` or `BUILD: CMBaseObject` — plus the concrete registration call signature.

- [ ] **Step 1: Enumerate candidate endpoint-manager classes live**

Run via `rpcclient -f research/audio/spike_endpoint_manager.py <vm-ip>` (port 5910). Script body:

```python
# List ObjC classes in MediaExperience / CoreMedia / AVRouting whose name
# hints at endpoint management, and resolve MXRegisterEndpointManager.
import re
for img in p.images:
    if any(s in img.name for s in ("MediaExperience", "CoreMedia", "AVRouting")):
        for cls in p.objc_get_classes_in_image(img):  # see rpcclient-introspection skill
            if re.search(r"(EndpointManager|FigEndpoint|RouteDiscovery)", cls):
                print(cls)
print("MXRegisterEndpointManager =", hex(p.symbols.MXRegisterEndpointManager))
```

Expected: a list including the BT/AirPlay/USB endpoint-manager classes referenced in `virtio_sound_bridge.md:987, 1494`.

- [ ] **Step 2: For each candidate, check whether it is instantiable without PAC-signed vtable surgery**

For each class, probe a no-arg or simple `+sharedManager`/`+new` constructor and whether `FigEndpointManagerGetCMBaseObject` returns non-NULL on the instance (the gate at `virtio_sound_bridge.md:1037-1058`). Log results.

Expected outcome: either a class whose instance already has a valid CMBaseObject (→ `REUSE`), or none (→ `BUILD`, accept the multi-day CMBaseObject path at `:1085-1121`).

- [ ] **Step 3: Record the decision**

Append a "Phase 0 results" section to `audio_vsock_bridge_design.md` stating `REUSE`/`BUILD`, the class/selectors or the CMBaseObject plan, and the exact `MXRegisterEndpointManager` call shape. Commit if the user asks.

### Task 0.2: U2 — prove endpoint registration unblocks `AVAudioEngine.start`

**Files:**
- Create: `research/audio/spike_engine_start.py` (rpcclient script)

**Interfaces:**
- Consumes: the registration path from Task 0.1.
- Produces: a yes/no in the design doc: does `engine.start` return success once an endpoint is registered.

- [ ] **Step 1: Register a stub endpoint using the Task 0.1 path, in-process in rpcserver_ios**

If `REUSE`: instantiate the class, register via `MXRegisterEndpointManager`. If `BUILD`: defer U2 until Task 2.4 (the stub can't exist without the CMBaseObject), and instead set the gate to "validated during Task 2.4".

- [ ] **Step 2: Attempt engine start and read the error**

```python
eng = p.objc_get_class("AVAudioEngine").alloc().init()
out = eng.outputNode()
fmt = out.outputFormatForBus_(0)
print("out fmt:", fmt)
err = p.malloc(8)
ok = eng.startAndReturnError_(err)
print("start ok =", ok, "err =", p.symbol(err).item_size and "...")  # read NSError code
```

Expected (success criterion): `ok == 1` (or a *different* error than `-10851/-10875`, indicating the endpoint gate cleared). Record the result.

- [ ] **Step 3: Gate decision**

If registering an endpoint clears `-10851/-10875`, the approach is confirmed → proceed. If a new gate appears, document it in the design doc's risks and adjust Task 2.4 before coding it.

---

## Phase 1 — Host audio bridge (Swift, independent of Phase 0)

Buildable and verifiable immediately; does not depend on the spike. Models `VPhoneCameraServer` (host streaming vsock client) and `VPhoneControl` (framing helpers).

### Task 1.1: Audio wire-format frame (encode/decode)

**Files:**
- Create: `sources/vphone-cli/VPhoneAudioFrame.swift`

**Interfaces:**
- Produces:
  - `struct VPhoneAudioFrame { let direction: UInt8; let sampleRate: UInt32; let channels: UInt16; let frameCount: UInt32; let hostTimeNs: UInt64; let pcm: Data }`
  - `static func VPhoneAudioFrame.headerSize: Int` (= 24)
  - `func encoded() -> Data` (24-byte LE header + pcm)
  - `static func decodeHeader(_ d: Data) -> (sampleRate: UInt32, channels: UInt16, frameCount: UInt32, direction: UInt8, hostTimeNs: UInt64)?`

- [x] **Step 1: Write the type + encode/decode**

```swift
import Foundation

/// Fixed-format audio frame for the vsock audio side-channel (port 1339).
/// Header is 24 bytes, little-endian, followed by `frameCount*channels*2`
/// bytes of interleaved Int16 PCM. See research/audio/audio_vsock_bridge_design.md.
struct VPhoneAudioFrame {
    static let magic: UInt32 = 0x5650_4155  // 'VPAU'
    static let headerSize = 24
    static let formatInt16Interleaved: UInt8 = 0

    enum Direction: UInt8 { case guestToHost = 0; case hostToGuest = 1 }

    let direction: UInt8
    let sampleRate: UInt32
    let channels: UInt16
    let frameCount: UInt32
    let hostTimeNs: UInt64
    let pcm: Data

    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + pcm.count)
        func put<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        put(Self.magic)                 // 0..4
        out.append(direction)           // 4
        out.append(Self.formatInt16Interleaved)  // 5
        put(channels)                   // 6..8
        put(sampleRate)                 // 8..12
        put(frameCount)                 // 12..16
        put(hostTimeNs)                 // 16..24
        out.append(pcm)
        return out
    }

    static func decodeHeader(_ d: Data)
        -> (sampleRate: UInt32, channels: UInt16, frameCount: UInt32, direction: UInt8, hostTimeNs: UInt64)?
    {
        guard d.count >= headerSize else { return nil }
        func load<T: FixedWidthInteger>(_ off: Int, _ : T.Type) -> T {
            d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: T.self).littleEndian }
        }
        guard load(0, UInt32.self) == magic else { return nil }
        let direction: UInt8 = d[d.startIndex + 4]
        return (load(8, UInt32.self), load(6, UInt16.self), load(12, UInt32.self), direction, load(16, UInt64.self))
    }
}
```

- [x] **Step 2: Build**

Run: `make build`
Expected: build succeeds, no errors referencing `VPhoneAudioFrame`.

- [x] **Step 3: Add a runtime round-trip self-check behind a hidden flag**

In `VPhoneAudioFrame.swift`, add a `#if DEBUG`-free static `selfTest()` that encodes a known frame and asserts `decodeHeader` returns the same values; call it from the bridge's `init` log path (Task 1.2). (No XCTest target exists; this is the project-consistent way to verify pure logic at runtime.)

```swift
extension VPhoneAudioFrame {
    static func selfTest() -> Bool {
        let f = VPhoneAudioFrame(direction: 0, sampleRate: 48000, channels: 2,
                                 frameCount: 480, hostTimeNs: 123, pcm: Data(count: 1920))
        guard let h = decodeHeader(f.encoded()) else { return false }
        return h.sampleRate == 48000 && h.channels == 2 && h.frameCount == 480 && h.direction == 0
    }
}
```

- [ ] **Step 4: Commit** (if the user asks)

```bash
git add sources/vphone-cli/VPhoneAudioFrame.swift
git commit -m "feat(audio): add vsock audio frame wire format"
```

### Task 1.2: Host audio bridge — vsock connect + duplex transport

**Files:**
- Create: `sources/vphone-cli/VPhoneAudioBridge.swift`

**Interfaces:**
- Consumes: `VPhoneAudioFrame` (Task 1.1).
- Produces:
  - `@MainActor final class VPhoneAudioBridge`
  - `static let vsockPort: UInt32 = 1339`
  - `func connect(device: VZVirtioSocketDevice)`
  - `func disconnect()`
  - `var onConnectionStateChange: ((Bool) -> Void)?`
  - internal: `func enqueuePlayback(_ pcm: Data)` (fed by RX loop; consumed by Task 1.3), `func nextCaptureFrame() -> Data?` (produced by Task 1.4; sent by TX loop)

- [x] **Step 1: Write connect/reconnect + RX/TX loops** (mirrors `VPhoneCameraServer:54-205` and `VPhoneControl.readFully/writeFully`)

```swift
import AVFoundation
import Foundation
import Virtualization

/// Host-side audio bridge. Connects to the guest libvphoneaudio listener on
/// vsock port 1339 (1337=vphoned, 1338=camera). Receives guest output PCM and
/// plays it on the Mac (Task 1.3); captures the Mac mic and sends it to the
/// guest (Task 1.4). Fixed wire format: 48kHz, 2ch, Int16 interleaved.
@MainActor
final class VPhoneAudioBridge {
    nonisolated static let vsockPort: UInt32 = 1339
    nonisolated static let sampleRate: Double = 48000
    nonisolated static let channels: UInt32 = 2

    private(set) var isConnected = false
    var onConnectionStateChange: ((Bool) -> Void)?

    private var device: VZVirtioSocketDevice?
    private var connection: VZVirtioSocketConnection?
    private var connectionFD: Int32 = -1
    private var attemptToken: UInt64 = 0

    // Playback ring (RX → speaker) and capture ring (mic → TX), guarded by locks.
    let playbackRing = VPhoneAudioRing(capacityFrames: 48000)   // 1s @ 48k stereo
    let captureRing = VPhoneAudioRing(capacityFrames: 48000)

    private let rxQueue = DispatchQueue(label: "com.vphone.audio.rx", qos: .userInteractive)
    private let txQueue = DispatchQueue(label: "com.vphone.audio.tx", qos: .userInteractive)

    func connect(device: VZVirtioSocketDevice) {
        precondition(VPhoneAudioFrame.selfTest(), "audio frame self-test failed")
        self.device = device
        attemptConnect()
    }

    func disconnect() {
        if connectionFD >= 0 { close(connectionFD); connectionFD = -1 }
        connection = nil
        if isConnected { isConnected = false; onConnectionStateChange?(false) }
    }

    private func attemptConnect() {
        guard let device else { return }
        attemptToken &+= 1
        let token = attemptToken
        device.connect(toPort: Self.vsockPort) { [weak self] result in
            Task { @MainActor in
                guard let self, self.attemptToken == token else { return }
                switch result {
                case let .success(conn):
                    self.connection = conn
                    self.connectionFD = conn.fileDescriptor
                    self.isConnected = true
                    print("[audio] connected on vsock port \(Self.vsockPort)")
                    self.onConnectionStateChange?(true)
                    self.startRX(fd: conn.fileDescriptor, token: token)
                    self.startTX(fd: conn.fileDescriptor, token: token)
                case let .failure(error):
                    print("[audio] connect failed: \(error). Retrying in 3s.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.attemptToken == token else { return }
                            self.attemptConnect()
                        }
                    }
                }
            }
        }
    }

    private func handleDrop(fd: Int32) {
        Task { @MainActor in
            guard self.connectionFD == fd else { return }
            print("[audio] connection dropped; reconnecting")
            self.disconnect()
            self.attemptConnect()
        }
    }

    // RX: read frames from guest → playbackRing
    private func startRX(fd: Int32, token: UInt64) {
        let ring = playbackRing
        rxQueue.async { [weak self] in
            var header = [UInt8](repeating: 0, count: VPhoneAudioFrame.headerSize)
            while true {
                guard Self.readFully(fd: fd, &header, header.count) else { break }
                guard let h = VPhoneAudioFrame.decodeHeader(Data(header)) else { break }
                let payload = Int(h.frameCount) * Int(h.channels) * 2
                guard payload > 0, payload < 1 << 20 else { break }
                var pcm = [UInt8](repeating: 0, count: payload)
                guard Self.readFully(fd: fd, &pcm, payload) else { break }
                ring.write(Data(pcm))
            }
            self?.handleDrop(fd: fd)
        }
    }

    // TX: captureRing → frames to guest, paced 10ms
    private func startTX(fd: Int32, token: UInt64) {
        let ring = captureRing
        txQueue.async { [weak self] in
            let frameCount: UInt32 = 480  // 10ms @ 48k
            while true {
                guard let pcm = ring.readExactly(frames: Int(frameCount)) else {
                    usleep(2000); continue
                }
                let frame = VPhoneAudioFrame(direction: VPhoneAudioFrame.Direction.hostToGuest.rawValue,
                                             sampleRate: 48000, channels: 2,
                                             frameCount: frameCount, hostTimeNs: 0, pcm: pcm)
                let out = frame.encoded()
                let ok = out.withUnsafeBytes { Self.writeFully(fd: fd, $0.baseAddress!, out.count) }
                if !ok { break }
            }
            self?.handleDrop(fd: fd)
        }
    }

    nonisolated static func readFully(fd: Int32, _ buf: inout [UInt8], _ count: Int) -> Bool {
        buf.withUnsafeMutableBytes { raw in readFully(fd: fd, buf: raw.baseAddress!, count: count) }
    }
    nonisolated static func readFully(fd: Int32, buf: UnsafeMutableRawPointer, count: Int) -> Bool {
        var off = 0
        while off < count { let n = read(fd, buf + off, count - off); if n <= 0 { return false }; off += n }
        return true
    }
    nonisolated static func writeFully(fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Bool {
        var off = 0
        while off < count { let n = write(fd, buf + off, count - off); if n <= 0 { return false }; off += n }
        return true
    }
}
```

- [x] **Step 2: Write the lock-protected ring buffer**

Create the ring in the same file (or `VPhoneAudioRing.swift`):

```swift
/// Simple lock-protected byte ring for interleaved Int16 PCM.
final class VPhoneAudioRing: @unchecked Sendable {
    private let lock = NSLock()
    private var buf: Data
    private let cap: Int
    init(capacityFrames: Int) { cap = capacityFrames * 2 * 2; buf = Data(); buf.reserveCapacity(cap) }

    func write(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buf.append(d)
        if buf.count > cap { buf.removeFirst(buf.count - cap) }  // drop oldest on overflow
    }
    /// Returns exactly `frames*2ch*2B` bytes or nil if not enough buffered.
    func readExactly(frames: Int) -> Data? {
        let need = frames * 2 * 2
        lock.lock(); defer { lock.unlock() }
        guard buf.count >= need else { return nil }
        let out = buf.prefix(need); buf.removeFirst(need)
        return Data(out)
    }
    /// Drains up to `frames`, zero-filling the remainder (for the speaker render callback).
    func readPadded(frames: Int) -> Data {
        let need = frames * 2 * 2
        lock.lock(); defer { lock.unlock() }
        var out = Data(buf.prefix(need)); buf.removeFirst(min(need, buf.count))
        if out.count < need { out.append(Data(count: need - out.count)) }
        return out
    }
}
```

- [x] **Step 3: Build**

Run: `make build`
Expected: success.

- [ ] **Step 4: Commit** (if asked)

```bash
git add sources/vphone-cli/VPhoneAudioBridge.swift
git commit -m "feat(audio): host vsock audio bridge transport + ring buffer"
```

### Task 1.3: Host playback (RX PCM → Mac speakers)

**Files:**
- Modify: `sources/vphone-cli/VPhoneAudioBridge.swift`

**Interfaces:**
- Consumes: `playbackRing` (Task 1.2).
- Produces: `func startPlayback()`, `func stopPlayback()` on `VPhoneAudioBridge`.

- [x] **Step 1: Add an `AVAudioEngine` + `AVAudioSourceNode` pulling from `playbackRing`**

```swift
extension VPhoneAudioBridge {
    private static let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!

    func startPlayback() {
        guard playbackEngine == nil else { return }
        let engine = AVAudioEngine()
        let ring = playbackRing
        let src = AVAudioSourceNode(format: Self.wireFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let bytes = Int(frameCount) * 2 * 2
            let pcm = ring.readPadded(frames: Int(frameCount))   // zero-fills on underrun
            pcm.withUnsafeBytes { raw in
                if let dst = abl[0].mData { memcpy(dst, raw.baseAddress!, min(bytes, Int(abl[0].mDataByteSize))) }
            }
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: Self.wireFormat)
        do { try engine.start(); playbackEngine = engine; playbackSource = src
             print("[audio] playback engine started") }
        catch { print("[audio] playback start failed: \(error)") }
    }

    func stopPlayback() { playbackEngine?.stop(); playbackEngine = nil; playbackSource = nil }
}
```

Add stored properties `private var playbackEngine: AVAudioEngine?` and `private var playbackSource: AVAudioSourceNode?` to the class, and call `startPlayback()` at the end of the `.success` branch in `attemptConnect`.

- [x] **Step 2: Build**

Run: `make build` — expected success.

- [ ] **Step 3: Runtime loopback verification** — SKIPPED: requires a running VM (audible tone playback on the Mac). VM is rebooting/unavailable. Host build of the playback path verified; runtime audible check deferred.

Temporarily, in `startRX`, also `captureRing.write(Data(pcm))` is NOT used; instead write a 440 Hz Int16 tone generator into `playbackRing` from a debug timer (added behind a `--audio-selftest` path you remove after) and confirm the Mac plays a tone. Document the check in the commit message; remove the debug generator before Task 2.

- [ ] **Step 4: Commit** (if asked)

```bash
git add sources/vphone-cli/VPhoneAudioBridge.swift
git commit -m "feat(audio): host playback of guest PCM via AVAudioEngine"
```

### Task 1.4: Host capture (Mac mic → TX)

**Files:**
- Modify: `sources/vphone-cli/VPhoneAudioBridge.swift`

**Interfaces:**
- Consumes: `captureRing` (Task 1.2).
- Produces: `func startCapture()`, `func stopCapture()`.

- [x] **Step 1: Install an input tap, convert to wire format, write to `captureRing`**

```swift
extension VPhoneAudioBridge {
    func startCapture() {
        guard captureEngine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inFmt, to: Self.wireFormat) else {
            print("[audio] capture: no converter"); return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            guard let self else { return }
            let outCap = AVAudioFrameCount(Double(buf.frameLength) * 48000 / inFmt.sampleRate) + 16
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: Self.wireFormat, frameCapacity: outCap) else { return }
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in status.pointee = .haveData; return buf }
            guard err == nil, let ch = outBuf.int16ChannelData else { return }
            let bytes = Int(outBuf.frameLength) * 2 * 2
            let data = Data(bytes: ch[0], count: bytes)
            self.captureRing.write(data)
        }
        do { try engine.start(); captureEngine = engine; print("[audio] capture engine started") }
        catch { print("[audio] capture start failed: \(error)") }
    }

    func stopCapture() { captureEngine?.inputNode.removeTap(onBus: 0); captureEngine?.stop(); captureEngine = nil }
}
```

Add `private var captureEngine: AVAudioEngine?`; call `startCapture()` after `startPlayback()` in the connect success branch. (`wireFormat` interleaved Int16 stereo: `int16ChannelData[0]` holds the interleaved buffer.)

- [x] **Step 2: Build** — `make build`, expected success.

- [ ] **Step 3: Runtime check** — SKIPPED: requires running the app against the VM (`[audio] capture engine started` log + Mac mic-permission prompt fire only on a live connect). VM rebooting/unavailable. Host build verified.

- [ ] **Step 4: Commit** (if asked)

```bash
git add sources/vphone-cli/VPhoneAudioBridge.swift
git commit -m "feat(audio): host mic capture → vsock TX"
```

### Task 1.5: CLI flag + AppDelegate wiring (EXP-gated)

**Files:**
- Modify: `sources/vphone-cli/VPhoneCLI.swift:56-62` (add flag), `:89-112` (pass through)
- Modify: `sources/vphone-cli/VPhoneVirtualMachine.swift:24-40` (add `audio: Bool` to `Options`)
- Modify: `sources/vphone-cli/VPhoneAppDelegate.swift:92-97` (instantiate + connect)

**Interfaces:**
- Consumes: `VPhoneAudioBridge` (Task 1.2-1.4).
- Produces: `--audio` boot flag; `Options.audio`.

- [x] **Step 1: Add the flag to `VPhoneBootCLI`** (after `noVphoned`, `:56`)

```swift
    @Flag(name: .customLong("audio"), help: "Enable guest⇄host audio bridge (EXP variant only).")
    var audio: Bool = false
```

- [x] **Step 2: Add `audio` to `Options` and thread it through `resolveOptions()`**

In `VPhoneVirtualMachine.Options` add `var audio: Bool = false`. In `VPhoneCLI.resolveOptions()` return-list add `audio: self.audio`.

- [x] **Step 3: Instantiate + connect the bridge in `VPhoneAppDelegate`** (beside `camServer`, `:92-97`)

```swift
            // Audio bridge — EXP variant only, gated by --audio.
            if options.audio && options.variant == .exp {
                let audioBridge = VPhoneAudioBridge()
                self.audioBridge = audioBridge
                if let device = vm.virtualMachine.socketDevices.first as? VZVirtioSocketDevice {
                    audioBridge.connect(device: device)
                }
            } else if options.audio {
                print("[audio] --audio ignored: only supported on the EXP variant")
            }
```

Add `private var audioBridge: VPhoneAudioBridge?` near `:16` (beside `cameraServer`).

- [x] **Step 4: Build** — `make build` succeeded; `--audio` is registered (appears as `[--audio]` in ArgumentParser usage; help text `host audio bridge (EXP variant only).` embedded in binary). Note: `boot --help` produces no stdout under the non-interactive harness because the boot subcommand routes through the NSApplication GUI binary; the flag registration was confirmed via the usage line on the parse-error path instead.

- [ ] **Step 5: Commit** (if asked)

```bash
git add sources/vphone-cli/VPhoneCLI.swift sources/vphone-cli/VPhoneVirtualMachine.swift sources/vphone-cli/VPhoneAppDelegate.swift
git commit -m "feat(audio): --audio flag wires the bridge on EXP boots"
```

---

## Phase 2 — Guest dylib (`libvphoneaudio.dylib`) injected into `audiomxd`

Requires Phase 0 results for the registration call. Skills: `vphone-firmwarepatcher-jb-patch-recipe` (patterns), `ios-jb-ramdisk-rw-surgery`, `vphone-vm-ssh-and-controlmaster`.

### Task 2.1: dylib skeleton + build/sign/inject pipeline

**Files:**
- Create: `scripts/vphoneaudio/libvphoneaudio.m`
- Create: `scripts/vphoneaudio/build.sh`
- Create: `scripts/vphoneaudio/entitlements.plist`

**Interfaces:**
- Produces: a signed `libvphoneaudio.dylib` that loads in `audiomxd`, logs to `/tmp/vphoneaudio.log`, and does nothing else yet.

- [ ] **Step 1: Constructor-only dylib that proves it loads**

```objc
// libvphoneaudio.m — injected into /usr/libexec/audiomxd. Must NEVER crash the host.
#import <Foundation/Foundation.h>
#import <os/log.h>

static void vpa_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen("/tmp/vphoneaudio.log", "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

__attribute__((constructor))
static void vpa_init(void) {
    @try {
        vpa_log(@"[vphoneaudio] loaded in pid %d", getpid());
    } @catch (id e) { /* never propagate into audiomxd */ }
}
```

- [ ] **Step 2: build.sh (iOS arm64e SDK + ldid)** — mirrors `scripts/vphoned/Makefile` signing

```bash
#!/bin/zsh
set -euo pipefail
cd "${0:a:h}"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun -sdk iphoneos clang -arch arm64e -dynamiclib -fobjc-arc \
  -isysroot "$SDK" -mios-version-min=26.0 \
  -framework Foundation \
  -o libvphoneaudio.dylib libvphoneaudio.m
ldid -S./entitlements.plist libvphoneaudio.dylib
echo "built libvphoneaudio.dylib"
```

`entitlements.plist`: start empty (`<dict/>`); add `com.apple.private.virtio.sound.user-access` later only if Task 2.4 needs the userclient.

- [ ] **Step 3: Build it** — `zsh scripts/vphoneaudio/build.sh`; expected `built libvphoneaudio.dylib`.

- [ ] **Step 4: Inject into a live VM's audiomxd + verify load** (manual, EXP VM booted)

```bash
# On host: push dylib, then on device (root@22222) inject + resign audiomxd, reboot audiomxd.
# insert_dylib pattern from virtio_sound_bridge.md:831
scp -P 22222 scripts/vphoneaudio/libvphoneaudio.dylib root@$IP:/var/root/
ssh -p 22222 root@$IP '/var/root/insert_dylib --inplace --strip-codesig --all-yes \
  /var/root/libvphoneaudio.dylib /usr/libexec/audiomxd && \
  ldid -S/var/root/audiomxd_ent.plist -I/usr/libexec/audiomxd /usr/libexec/audiomxd && \
  kill $(pgrep audiomxd)'
sleep 2 && ssh -p 22222 root@$IP 'cat /tmp/vphoneaudio.log'
```

Expected: `[vphoneaudio] loaded in pid <n>` (n = new audiomxd pid). (Sealed-volume writes: use `ios-jb-ramdisk-rw-surgery` if `/usr/libexec` is not writable on the booted system.)

- [ ] **Step 5: Commit** (if asked)

```bash
git add scripts/vphoneaudio/
git commit -m "feat(audio): libvphoneaudio dylib skeleton + build/inject pipeline"
```

### Task 2.2: Guest vsock listener (port 1339) + framing

**Files:**
- Modify: `scripts/vphoneaudio/libvphoneaudio.m`

**Interfaces:**
- Consumes: nothing new.
- Produces: a background thread listening on vsock 1339, accepting one host connection, with `vpa_read_full` / `vpa_write_full` and the 24-byte frame header matching `VPhoneAudioFrame`.

- [ ] **Step 1: Add the AF_VSOCK listener** (mirrors `vphoned.m:485-517`)

```objc
#include <sys/socket.h>
#include <unistd.h>
#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#define VMADDR_CID_ANY 0xFFFFFFFF
#define VPA_PORT 1339
struct sockaddr_vm { unsigned char svm_len, svm_family; unsigned short svm_reserved1;
                     unsigned int svm_port, svm_cid; };

static int g_audio_fd = -1;

static int vpa_listen(void) {
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) { vpa_log(@"[vphoneaudio] socket() errno=%d", errno); return -1; }
    struct sockaddr_vm a = { sizeof(a), AF_VSOCK, 0, VPA_PORT, VMADDR_CID_ANY };
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) { vpa_log(@"[vphoneaudio] bind errno=%d", errno); close(s); return -1; }
    if (listen(s, 1) < 0) { vpa_log(@"[vphoneaudio] listen errno=%d", errno); close(s); return -1; }
    vpa_log(@"[vphoneaudio] listening on vsock %d", VPA_PORT);
    return s;
}

static BOOL vpa_read_full(int fd, void *buf, size_t n) {
    size_t off = 0; while (off < n) { ssize_t r = read(fd, (char *)buf + off, n - off); if (r <= 0) return NO; off += r; } return YES;
}
static BOOL vpa_write_full(int fd, const void *buf, size_t n) {
    size_t off = 0; while (off < n) { ssize_t w = write(fd, (const char *)buf + off, n - off); if (w <= 0) return NO; off += w; } return YES;
}
```

- [ ] **Step 2: Run the accept loop on a detached thread from the constructor**

In `vpa_init`, after logging, `dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATIVE,0), ^{ ... accept loop ... })`. The accept loop sets `g_audio_fd` and (Task 2.4) starts the pump; on disconnect it loops back to `accept`. Guard with `@try/@catch`.

- [ ] **Step 3: Build + inject + verify** — repeat Task 2.1 Step 3-4; then from host run `vphone-cli boot --variant exp --audio` and confirm `[audio] connected on vsock port 1339` (host log) **and** `[vphoneaudio] listening on vsock 1339` (guest `/tmp/vphoneaudio.log`).

- [ ] **Step 4: Commit** (if asked)

```bash
git add scripts/vphoneaudio/libvphoneaudio.m
git commit -m "feat(audio): guest vsock listener + framing on port 1339"
```

### Task 2.3: Loopback proof (no endpoint yet) — tone over the wire

**Files:**
- Modify: `scripts/vphoneaudio/libvphoneaudio.m` (temporary tone source, removed in Task 2.4)

**Interfaces:**
- Produces: confirmation that guest→host PCM transport + host playback work end-to-end, isolating the remaining risk to endpoint registration alone.

- [ ] **Step 1: After `accept`, push a 440 Hz Int16 tone** as `VPAU` frames (direction=0, 48k, 2ch, 480 frames) every 10 ms.

```objc
// generate 480-frame stereo Int16 sine packets, prefixed with the 24-byte header
// (magic 'VPAU'=0x56504155 LE, dir 0, fmt 0, ch 2, sr 48000, frameCount 480, ts 0)
```

- [ ] **Step 2: Boot EXP with `--audio`; confirm the Mac plays the 440 Hz tone.** This validates Tasks 1.1-1.3 + 2.1-2.2 against the real VM. Record the result; **remove the tone source** before Task 2.4.

- [ ] **Step 3: Commit** (if asked) the removal-ready state

```bash
git commit -am "test(audio): verified guest→host tone over vsock (loopback)"
```

### Task 2.4: Register the audio endpoint + tap output IO → vsock

**Files:**
- Modify: `scripts/vphoneaudio/libvphoneaudio.m`
- Modify: `research/audio/audio_vsock_bridge_design.md` (write back the Phase 0 mechanism before coding)

**Interfaces:**
- Consumes: Phase 0 decision (`REUSE` class+selectors, or `BUILD` CMBaseObject), `vpa_write_full`, `g_audio_fd`.
- Produces: a registered duplex endpoint; its output render path copies PCM to the vsock TX; `AVAudioEngine.start` in guest clients succeeds.

- [ ] **Step 1: Implement endpoint registration per Phase 0**

If `REUSE`: instantiate the class found in Task 0.1, populate its descriptor (`AudioRouteName = "USB"`, `virtio_sound_bridge.md:985`), and call `MXRegisterEndpointManager`. If `BUILD`: implement the minimal PAC-signed `CMBaseObject` `FigEndpointManager` per `virtio_sound_bridge.md:1095-1121` (vtable slot `+0x30` returns success; `CopyEndpointsForType` returns one endpoint). **Write the exact chosen code here from the Phase 0 result** — do not start this step until Task 0.1/0.2 are complete.

- [ ] **Step 2: Tap the output render**

Where the endpoint's output IO callback runs (HAL device IO if the endpoint is HAL-backed, else our endpoint's render block), copy the rendered Int16 stereo buffer into a `VPAU` frame and `vpa_write_full(g_audio_fd, ...)`. Convert from `audiomxd`'s render format to 48k/2ch/Int16 if needed. Never block the audio IO thread (drop if `g_audio_fd < 0`).

- [ ] **Step 3: Boot EXP with `--audio`, play audio in a guest app/test, confirm it comes out the Mac.** Verify `engine.start` no longer returns `-10851/-10875` (guest log / rpcclient). **Milestone: guest app audio is audible on the Mac.**

- [ ] **Step 4: Commit** (if asked)

```bash
git add scripts/vphoneaudio/libvphoneaudio.m research/audio/audio_vsock_bridge_design.md
git commit -m "feat(audio): register audiomxd endpoint + tap output to vsock"
```

### Task 2.5: Input path (vsock RX → endpoint input callback)

**Files:**
- Modify: `scripts/vphoneaudio/libvphoneaudio.m`

**Interfaces:**
- Consumes: the registered endpoint (Task 2.4), `vpa_read_full`.
- Produces: mic input into the guest; full duplex.

- [ ] **Step 1: RX thread reads `VPAU` frames (direction=1) into a guest-side ring; the endpoint's input callback drains it** (zero-fill on underrun). Reuse the framing from Task 2.2.

- [ ] **Step 2: Boot EXP with `--audio`; drive the Mac mic with a known signal; confirm a guest recording/level meter shows it.** (e.g. guest `AVAudioRecorder` or rpcclient level read.)

- [ ] **Step 3: Commit** (if asked)

```bash
git commit -am "feat(audio): full-duplex — host mic into guest via vsock"
```

---

## Phase 3 — EXP variant integration

### Task 3.1: Deploy + inject the dylib at first boot (EXP only)

**Files:**
- Modify: `scripts/cfw_install_exp.sh` (JB-5 block, `:620-652`)
- Reference: how `libcamfix`/`libvcamcaptured` are deployed (`:565-618`)

**Interfaces:**
- Produces: EXP installs put `libvphoneaudio.dylib` on the device and inject it into `/usr/libexec/audiomxd` (insert_dylib + re-sign), persisted across reboot.

- [ ] **Step 1: Add an EXP-only deploy+inject step** mirroring the camera dylib deploy: copy `libvphoneaudio.dylib` to the device, `insert_dylib --inplace` into audiomxd, `ldid` re-sign with audiomxd's entitlements. Guard the block so only the EXP path reaches it.

- [ ] **Step 2: Clean EXP install + boot; confirm** `/tmp/vphoneaudio.log` shows load on a fresh boot (no manual injection), and `vphone-cli boot --variant exp --audio` produces audio.

- [ ] **Step 3: Commit** (if asked)

```bash
git add scripts/cfw_install_exp.sh
git commit -m "feat(audio): EXP first-boot injection of libvphoneaudio into audiomxd"
```

### Task 3.2: Variant isolation + patch-comparison doc

**Files:**
- Modify: `research/0_binary_patch_comparison.md`

**Interfaces:** none (verification + docs).

- [ ] **Step 1: Add the audio dylib/injection to `0_binary_patch_comparison.md`** (mandated by CLAUDE.md), with the EXP-only scope and the audiomxd injection described.

- [ ] **Step 2: Verify Regular/Dev/JB are unaffected** — boot each, confirm no `/tmp/vphoneaudio.log`, no audiomxd modification, unchanged behavior. Confirm `--audio` is a no-op (with the warning) on non-EXP.

- [ ] **Step 3: Commit** (if asked)

```bash
git add research/0_binary_patch_comparison.md
git commit -m "docs(audio): record EXP audio bridge in binary patch comparison"
```

---

## Phase 4 — Native virtio upgrade (OUT OF SCOPE)

Documented for continuity, not implemented here: retarget Task 2.4's byte sink from vsock to the `AppleVirtIOSoundUserClient` so audio exits via the host's `VZHostAudioOutputStreamSink` (`VPhoneVirtualMachine.swift:170-177`), dropping the vsock output path. Pursue only after Phase 1-3 prove the endpoint + engine path. See `audio_vsock_bridge_design.md` "Why vsock".

---

## Self-review (against the spec)

- **Spec coverage:** gap analysis → Phase 0; endpoint registration → Task 2.4; vsock transport → Tasks 1.1-1.2, 2.2; host playback/capture → 1.3/1.4; guest dylib + sandbox load → 2.1; CLI/menu gate → 1.5 (CLI flag; a menu toggle is optional polish, not required by the spec's "CLI flag / menu toggle"); EXP wiring + doc → 3.1/3.2; native-virtio out of scope → Phase 4. ✓
- **Placeholder scan:** the only deferred concrete code is Task 2.4 Step 1, explicitly gated on the Phase 0 spike result and bounded to two known branches — a spike→fill-in, not a vague TODO. All host-Swift code is complete. ✓
- **Type consistency:** `VPhoneAudioFrame` header layout (24 B, `VPAU` magic, dir/fmt/ch/sr/frameCount/ts) is identical in Swift (Task 1.1) and C (Task 2.2); port `1339` used consistently; `playbackRing`/`captureRing` names consistent across 1.2-1.4. ✓
- **Risk carry-through:** `audiomxd` `AF_VSOCK` sandbox risk (spec Component 2) is exercised at Task 2.2 Step 3 — if `bind`/`socket` fails with the sandbox errno, switch to the `vphoned`-relay fallback before continuing. ✓
```
