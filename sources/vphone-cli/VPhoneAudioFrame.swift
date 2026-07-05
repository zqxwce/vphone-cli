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

extension VPhoneAudioFrame {
    static func selfTest() -> Bool {
        let f = VPhoneAudioFrame(direction: 0, sampleRate: 48000, channels: 2,
                                 frameCount: 480, hostTimeNs: 123, pcm: Data(count: 1920))
        guard let h = decodeHeader(f.encoded()) else { return false }
        return h.sampleRate == 48000 && h.channels == 2 && h.frameCount == 480 && h.direction == 0
    }
}
