# Design — vphone guest audio via vsock side-channel (Approach A)

Status: **design, approved direction (2026-06-23)**. Scope: EXP variant only,
full duplex (output proven first, then mic input). Supersedes the "loads but no
audio" dead-end documented in `virtio_sound_bridge.md` /
`SESSION_2026-06-04_SUMMARY.md` by changing the byte-delivery strategy.

## Goal

Make audio audible end-to-end on the vphone iOS guest:

- **Output:** app audio in the guest → Mac speakers.
- **Input:** Mac microphone → guest apps.

EXP-variant-only. Other variants (Regular/Dev/JB) are deliberately unaffected.

## The gap this design closes (established, not assumed)

All claims below are from the prior investigation log; line refs are
`research/audio/virtio_sound_bridge.md` unless noted.

1. iOS has **no `coreaudiod`**; `audiomxd` absorbs its role. There is no
   `com.apple.audio.audiohald` mach service and `audiomxd` does not link
   `CoreAudio.framework`. (`:1290-1331`, `:1449-1457`)
2. The ported `AppleVirtIOSound.driver` HAL plugin **loads in `audiomxd`** and
   publishes its device, but only in-process: `[plugin audioDevices].count == 1`
   while `AudioObjectGetPropertyDataSize(kAudioHardwarePropertyDevices) == 0` for
   every client. (`:928-929`, `:972-975`)
3. iOS routes app audio through **Fig endpoints**, not HAL devices.
   `AURemoteIOServer` (hosted in `audiomxd`, `:1360`) renders to the **current
   route's Fig endpoint**, populated only by `FigEndpointManager`s registered via
   `MXRegisterEndpointManager`. In this VM nothing registers an audio endpoint
   (no speaker/BT/AirPlay/USB hardware), so the route list is legitimately empty.
   (`:693`, `:1471-1494`, `:991-993`)
4. Therefore `AVAudioEngine.start` fails `-10851` / `-10875`: the IO unit has no
   output endpoint to bind. The 23-site DSC NOP campaign
   (`scripts/patchers/cfw_patch_audio_remoteio.py`) and the client-side
   route-faking (`route_probe.dylib`) are **cosmetic** — `currentRoute` reports a
   device but no data path exists. (`:1600-1718`, `:1780-1787`)

**Unavoidable core (any approach):** register a renderable audio endpoint inside
`audiomxd` so `AURemoteIOServer` has somewhere to render and the engine starts.
This design then delivers the rendered bytes to the host over **vsock** rather
than depending on the unproven virtio userland transport.

## Why vsock (Approach A) over native virtio (Approach B)

- The virtio kernel driver binds (`AppleVirtIOSound`, PCI `1AF4:0019`) and the
  `AppleVirtIOSoundUserClient` opens with a valid IOConnect handle, but **no
  session ever pushed samples through it** — the userland transport is unproven
  (`:1227`, probe v13 at `:310-334`).
- vsock is fully under our control on both ends, reuses proven infra (the
  `audiomxd` dylib-injection path from `route_probe.dylib`, and the host/guest
  vsock model already used by `vphoned`), and is independent of the virtio feed.
- Native virtio (Approach B) is a clean **later upgrade**: once the endpoint +
  engine work under A, swap the byte sink from vsock to the
  `AppleVirtIOSoundUserClient` and audio exits via `VZHostAudioOutputStreamSink`
  (`sources/vphone-cli/VPhoneVirtualMachine.swift:170-177`), no vsock. Out of
  scope for this design.

## Architecture / data flow

```
OUTPUT (guest → Mac speakers)
  app → AVAudioEngine → client AURemoteIO ──XPC──▶ audiomxd AURemoteIOServer
        renders mixed PCM to current-route endpoint
            │
            ▼  [libvphoneaudio.dylib, injected in audiomxd]
        endpoint/HAL IO callback copies PCM
            │
            ▼  framed PCM over vsock (dedicated audio port)
        VPhoneAudioBridge (host, in vphone-cli)
            │
            ▼  Mac CoreAudio (AVAudioEngine/AudioQueue → default output)
        Mac speakers

INPUT (Mac mic → guest)  — reverse
  Mac mic → VPhoneAudioBridge capture (CoreAudio)
            │ framed PCM over vsock
            ▼  [libvphoneaudio.dylib] feeds the endpoint input callback
        audiomxd AURemoteIOServer input → client AURemoteIO → app inputNode
```

## Components

### 1. Guest: `libvphoneaudio.dylib` (injected into `audiomxd`)

- **Endpoint registration** — register a duplex audio endpoint so the route is
  non-empty and `AURemoteIOServer` will render to/from it. *Mechanism is the
  Phase 0 unknown* (see below): preferred = reuse an existing Apple
  endpoint-manager class; fallback = minimal PAC-signed `CMBaseObject`
  `FigEndpointManager` (`:1085-1121`). Endpoint advertised as `AudioRouteName =
  "USB"` (no `Virtual`/`VirtIO` route name exists; USB is the closest match,
  `:985`).
- **Clocking/backing** — prefer backing the endpoint with the already-loaded
  `AppleVirtIOSound` HAL device (valid streams + hardware clock from the virtio
  device) so timing is real; the HAL plugin is our code and re-signable. If
  Phase 0 shows the HAL device cannot back a Fig endpoint, use a software clock.
- **Byte tap/inject** — in the endpoint (or HAL) IO callback: copy output PCM to
  the vsock TX queue; pull input PCM from the vsock RX queue into the input
  callback.
- **Transport** — open a vsock connection to the host on a **dedicated audio
  port** (not `vphoned`'s 1337) to keep continuous PCM off the control channel.
  Guest listens, host connects (matches the `vphoned`/`VPhoneControl` model).
- **Safety** — audio is non-critical: any failure (registration, vsock, format)
  logs and degrades to silence; it must **never** crash or hang `audiomxd`
  (launchd-respawn loops would harm the VM).

### 2. Guest sandbox consideration (transport fallback)

`audiomxd` runs under a sandbox (some `/var/root` writes blocked; `/tmp` ok,
`:836`). If the profile denies `AF_VSOCK`, fall back to a local hop:
`libvphoneaudio.dylib` → `vphoned` (unix socket / shared ring in `/tmp`) →
`vphoned` relays over its existing vsock. Primary path is direct vsock from
`audiomxd`; the relay is the documented fallback. Resolve in Phase 0/1.

### 3. Host: `VPhoneAudioBridge.swift` (new, in `sources/vphone-cli/`)

- Connects to the guest audio vsock port (auto-reconnect, like `VPhoneControl`).
- **Output:** receive framed PCM → play via Mac CoreAudio to default output.
- **Input:** capture Mac default input → send framed PCM to guest.
- **Format:** fixed **48 kHz, stereo, interleaved Int16** to start; the host
  converts to/from the Mac device format. Renegotiation deferred.
- Gated by a CLI flag / menu toggle; off unless the EXP guest side is present.

### 4. vsock audio protocol (dedicated port)

Minimal streaming frame, distinct from `vphoned`'s length-prefixed JSON:

```
struct AudioFrameHeader {            // little-endian, fixed size
    u32 magic;                       // 'VPAU'
    u8  direction;                   // 0 = guest→host (out), 1 = host→guest (in)
    u8  format;                      // 0 = Int16 interleaved
    u16 channels;                    // 2
    u32 sampleRate;                  // 48000
    u32 frameCount;                  // samples per channel in this packet
    u64 hostTimeNs;                  // capture/render timestamp for jitter mgmt
}
// followed by frameCount * channels * sizeof(Int16) PCM bytes
```

Small packets (~5–10 ms, 240–480 frames) for low latency; host keeps a small
jitter buffer.

### 5. EXP variant wiring

- Deploy `libvphoneaudio.dylib` and inject it into `/usr/libexec/audiomxd` at
  first boot, mirroring `libcamfix`/`libvcamcaptured`
  (`cfw_install_exp.sh` JB-5 block, `:620-652`), via `insert_dylib --inplace`
  + `ldid` re-sign (`:831`) over the ramdisk RW path.
- Confirm Regular/Dev/JB variants do not receive the dylib (EXP-only).
- **Update `research/0_binary_patch_comparison.md`** with the new patch
  (mandated by CLAUDE.md for any new patch).

## Phase 0 — resolve the two load-bearing unknowns (spike, before building)

On-device RE via `rpcclient`/`lldb` (skills: `vphone-rpcclient-introspection`,
`ios-debugserver-over-ssh`):

- **U1 — endpoint-manager reuse.** Is there an instantiable Apple
  `FigEndpointManager` class (the one `usbaudiodxpc`/built-in audio uses) we can
  construct + feed our descriptor, avoiding the PAC-signed `CMBaseObject` build?
  Outcome decides Phase 1 cost.
- **U2 — sufficiency.** After an endpoint is registered (even a stub), does
  `AVAudioEngine.start` succeed and does `AURemoteIOServer` issue IO callbacks?
  Confirms endpoint registration is the true (and only) missing gate.

Exit criteria: a concrete registration mechanism chosen, and proof that
`engine.start` succeeds once it runs.

## Phased plan

- **Phase 0** — spike U1 + U2 (above).
- **Phase 1** — `libvphoneaudio.dylib`: register endpoint + output IO tap →
  vsock; `VPhoneAudioBridge` host playback. **Milestone: a guest tone is audible
  on the Mac.**
- **Phase 2** — add mic input (host capture → vsock → guest input callback).
  Full duplex.
- **Phase 3** — wire into EXP (`cfw_install_exp.sh` first-boot inject; EXP-only;
  update `0_binary_patch_comparison.md`); verify other variants unaffected.
- **Phase 4 (out of scope)** — native virtio upgrade (Approach B): retarget the
  byte sink to `AppleVirtIOSoundUserClient`; drop vsock for output.

## Error handling

- vsock connect fail / disconnect → guest retries; host auto-reconnects.
- Endpoint registration fail → log, no audio, **do not** crash `audiomxd`.
- Format mismatch → fixed wire format; host converts to/from Mac device format.
- Underrun/overrun → small host jitter buffer; drop/zero-fill rather than block
  the audio IO thread.

## Verification

- **Phase 0:** `rpcclient` confirms chosen registration mechanism;
  `engine.start` returns success (no `-10851`/`-10875`).
- **Phase 1:** guest plays a known tone (test app or `AVAudioEngine` source);
  host logs received frame counts and emits on Mac speakers; confirm by
  recording the Mac output and checking the tone frequency.
- **Phase 2:** drive Mac mic with a known signal; guest records and we verify
  level/frequency.
- **Phase 3:** clean EXP boot, audio works after first-boot inject; Regular/Dev/
  JB boots show no audio dylib and unchanged behavior.

## Risks / open questions

- `audiomxd` sandbox may deny `AF_VSOCK` → `vphoned` relay fallback (Component 2).
- If U1 fails (no reusable manager), Phase 1 absorbs the PAC `CMBaseObject` build
  (multi-day, `:1117-1121`).
- Endpoint registration could expose a second gate beyond engine start (e.g.
  audiomxd validating the endpoint's IO before issuing callbacks) — U2 surfaces
  this early.
- Latency for interactive use is unmeasured; target < ~50 ms round path,
  acceptable for a research instrument.
```
