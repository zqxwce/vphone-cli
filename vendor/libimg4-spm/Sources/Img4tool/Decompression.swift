import Foundation
import Compression

// MARK: - LZSS Decompression

/// complzss header layout (376 bytes total):
///   [0..7]   signature "complzss"
///   [8..11]  adler32 checksum (big-endian)
///   [12..15] uncompressed size (big-endian)
///   [16..19] compressed size (big-endian)
///   [20..23] unknown (always 1)
///   [24..375] padding
///   [376..]  compressed data
enum LZSSDecompressor {
    private static let headerSize = 376
    private static let signature = "complzss"

    // Ring buffer parameters matching Apple's implementation
    private static let ringBufferSize = 4096 // N
    private static let maxMatchLength = 18   // F
    private static let matchThreshold = 2    // THRESHOLD

    static func isLZSS(_ data: Data) -> Bool {
        guard data.count > headerSize else { return false }
        let sig = data.prefix(8)
        return sig == Data(signature.utf8)
    }

    static func decompress(_ data: Data) throws -> Data {
        guard isLZSS(data) else {
            throw Img4Error.extractionFailed("not LZSS compressed data")
        }

        let uncompressedSize = data.withUnsafeBytes { buf -> UInt32 in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return UInt32(ptr[12]) << 24 | UInt32(ptr[13]) << 16 |
                   UInt32(ptr[14]) << 8 | UInt32(ptr[15])
        }

        let compressedData = data.dropFirst(headerSize)
        return try decompressRaw(compressedData, expectedSize: Int(uncompressedSize))
    }

    private static func decompressRaw(_ src: Data, expectedSize: Int) throws -> Data {
        var output = Data(capacity: expectedSize)

        // Ring buffer initialized to spaces (0x20) as per original LZSS
        var ringBuffer = [UInt8](repeating: 0x20, count: ringBufferSize)
        var ringPos = ringBufferSize - maxMatchLength

        var srcIndex = src.startIndex

        while srcIndex < src.endIndex, output.count < expectedSize {
            // Read flags byte - each bit controls one of 8 following operations
            let flags = src[srcIndex]
            srcIndex += 1

            for bit in 0 ..< 8 {
                guard srcIndex < src.endIndex, output.count < expectedSize else { break }

                if flags & (1 << bit) != 0 {
                    // Literal byte
                    let byte = src[srcIndex]
                    srcIndex += 1
                    output.append(byte)
                    ringBuffer[ringPos] = byte
                    ringPos = (ringPos + 1) & (ringBufferSize - 1)
                } else {
                    // Back-reference: 2 bytes encode position and length
                    guard srcIndex + 1 < src.endIndex else { break }
                    let lo = Int(src[srcIndex])
                    let hi = Int(src[srcIndex + 1])
                    srcIndex += 2

                    let matchPos = lo | ((hi & 0xF0) << 4)
                    let matchLen = (hi & 0x0F) + matchThreshold + 1

                    for i in 0 ..< matchLen {
                        guard output.count < expectedSize else { break }
                        let byte = ringBuffer[(matchPos + i) & (ringBufferSize - 1)]
                        output.append(byte)
                        ringBuffer[ringPos] = byte
                        ringPos = (ringPos + 1) & (ringBufferSize - 1)
                    }
                }
            }
        }

        return output
    }
}

// MARK: - LZSS Compression

enum LZSSCompressor {
    private static let ringBufferSize = 4096
    private static let maxMatchLength = 18
    private static let matchThreshold = 2

    static func compress(_ data: Data) throws -> Data {
        let compressed = compressRaw(data)

        // Build complzss header
        var header = Data(capacity: 376)
        header.append(contentsOf: "complzss".utf8)

        // adler32
        let checksum = adler32(data)
        header.append(contentsOf: withUnsafeBytes(of: checksum.bigEndian) { Data($0) })

        // uncompressed size
        let uncompSize = UInt32(data.count).bigEndian
        header.append(contentsOf: withUnsafeBytes(of: uncompSize) { Data($0) })

        // compressed size
        let compSize = UInt32(compressed.count).bigEndian
        header.append(contentsOf: withUnsafeBytes(of: compSize) { Data($0) })

        // unknown field (1)
        let one = UInt32(1).bigEndian
        header.append(contentsOf: withUnsafeBytes(of: one) { Data($0) })

        // Pad to 376 bytes
        header.append(Data(repeating: 0, count: 376 - header.count))

        return header + compressed
    }

    private static func compressRaw(_ src: Data) -> Data {
        guard !src.isEmpty else { return Data() }

        var output = Data()
        var srcPos = 0
        let srcBytes = Array(src)
        let srcLen = srcBytes.count

        while srcPos < srcLen {
            var flagByte: UInt8 = 0
            let flagPos = output.count
            output.append(0) // placeholder for flag byte

            for bit in 0 ..< 8 {
                guard srcPos < srcLen else { break }

                // Simple greedy search for matches in the lookback window
                var bestLen = 0
                var bestPos = 0

                let maxLookback = min(srcPos, ringBufferSize)
                let maxLen = min(maxMatchLength, srcLen - srcPos)

                if maxLen > matchThreshold {
                    for offset in 1 ... maxLookback {
                        var len = 0
                        while len < maxLen,
                              srcBytes[srcPos + len] == srcBytes[srcPos - offset + len]
                        {
                            len += 1
                        }
                        if len > bestLen {
                            bestLen = len
                            bestPos = (ringBufferSize - maxMatchLength + srcPos - offset) & (ringBufferSize - 1)
                        }
                    }
                }

                if bestLen > matchThreshold {
                    // Back-reference
                    let encodedLen = bestLen - matchThreshold - 1
                    let lo = UInt8(bestPos & 0xFF)
                    let hi = UInt8(((bestPos >> 4) & 0xF0) | (encodedLen & 0x0F))
                    output.append(lo)
                    output.append(hi)
                    srcPos += bestLen
                } else {
                    // Literal
                    flagByte |= (1 << bit)
                    output.append(srcBytes[srcPos])
                    srcPos += 1
                }
            }

            output[flagPos] = flagByte
        }

        return output
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let mod: UInt32 = 65521
        for byte in data {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }
        return (b << 16) | a
    }
}

// MARK: - LZFSE Decompression (via system Compression framework)

enum LZFSEDecompressor {
    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: expectedSize)
        let decompressedSize = output.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                compression_decode_buffer(
                    outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    expectedSize,
                    inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decompressedSize > 0 else {
            throw Img4Error.extractionFailed("LZFSE decompression failed")
        }
        output.count = decompressedSize
        return output
    }

    static func compress(_ data: Data) throws -> Data {
        // Worst case: compressed could be slightly larger than input
        let bufferSize = max(data.count + 1024, 4096)
        var output = Data(count: bufferSize)
        let compressedSize = output.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                compression_encode_buffer(
                    outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    bufferSize,
                    inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard compressedSize > 0 else {
            throw Img4Error.operationFailed("LZFSE compression failed")
        }
        output.count = compressedSize
        return output
    }
}
