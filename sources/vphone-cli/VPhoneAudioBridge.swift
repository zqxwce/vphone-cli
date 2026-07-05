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

    // Playback (RX → speaker) engine, see Task 1.3.
    fileprivate var playbackEngine: AVAudioEngine?
    fileprivate var playbackSource: AVAudioSourceNode?

    // Capture (mic → TX) engine, see Task 1.4.
    fileprivate var captureEngine: AVAudioEngine?

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
                    self.startPlayback()
                    self.startCapture()
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

// MARK: - Ring Buffer

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

// MARK: - Playback (RX PCM → Mac speakers)

extension VPhoneAudioBridge {
    // Immutable Sendable value — nonisolated so the nonisolated render/tap
    // factories below can read it off the main actor.
    nonisolated static let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true)!

    // Build the source node in a NONISOLATED context. AVFAudio invokes the render
    // block on the realtime `com.apple.audio.IOThread.client`; if the closure
    // inherits @MainActor isolation (which it does when formed inside this
    // @MainActor class), Swift inserts an executor-isolation check that traps
    // (EXC_BREAKPOINT) the moment it runs off the main actor. Forming it here
    // keeps it nonisolated. It captures only `ring` (@unchecked Sendable).
    nonisolated private static func makePlaybackSource(ring: VPhoneAudioRing) -> AVAudioSourceNode {
        AVAudioSourceNode(format: wireFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let bytes = Int(frameCount) * 2 * 2
            let pcm = ring.readPadded(frames: Int(frameCount))   // zero-fills on underrun
            pcm.withUnsafeBytes { raw in
                if let dst = abl[0].mData { memcpy(dst, raw.baseAddress!, min(bytes, Int(abl[0].mDataByteSize))) }
            }
            return noErr
        }
    }

    func startPlayback() {
        guard playbackEngine == nil else { return }
        let engine = AVAudioEngine()
        let src = Self.makePlaybackSource(ring: playbackRing)
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: Self.wireFormat)
        do { try engine.start(); playbackEngine = engine; playbackSource = src
             print("[audio] playback engine started") }
        catch { print("[audio] playback start failed: \(error)") }
    }

    func stopPlayback() { playbackEngine?.stop(); playbackEngine = nil; playbackSource = nil }
}

// MARK: - Capture (Mac mic → TX)

extension VPhoneAudioBridge {
    // Install the input tap in a NONISOLATED context for the same reason as the
    // playback source node — AVFAudio calls the tap block on a realtime thread,
    // and a @MainActor-isolated closure would trap there. Returns false if the
    // host has no usable input (no converter), so the caller can skip start.
    nonisolated private static func installCaptureTap(on engine: AVAudioEngine, ring: VPhoneAudioRing) -> Bool {
        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        guard inFmt.channelCount > 0, let conv = AVAudioConverter(from: inFmt, to: wireFormat) else {
            print("[audio] capture: no converter"); return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { buf, _ in
            let outCap = AVAudioFrameCount(Double(buf.frameLength) * 48000 / inFmt.sampleRate) + 16
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: outCap) else { return }
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in status.pointee = .haveData; return buf }
            guard err == nil, let ch = outBuf.int16ChannelData else { return }
            let bytes = Int(outBuf.frameLength) * 2 * 2
            ring.write(Data(bytes: ch[0], count: bytes))
        }
        return true
    }

    func startCapture() {
        guard captureEngine == nil else { return }
        let engine = AVAudioEngine()
        guard Self.installCaptureTap(on: engine, ring: captureRing) else { return }
        do { try engine.start(); captureEngine = engine; print("[audio] capture engine started") }
        catch { print("[audio] capture start failed: \(error)") }
    }

    func stopCapture() { captureEngine?.inputNode.removeTap(onBus: 0); captureEngine?.stop(); captureEngine = nil }
}
