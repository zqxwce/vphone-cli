import Foundation

// MARK: - ASN.1 DER Parser

/// A zero-copy view into a DER-encoded ASN.1 element.
struct DERElement: Sendable {
    /// The raw bytes of the entire element (tag + length + value).
    let raw: Data
    /// Byte offset where the value (payload) starts within `raw`.
    let valueOffset: Int
    /// Length of the value portion.
    let valueLength: Int

    /// The tag byte.
    var tag: UInt8 { raw[raw.startIndex] }

    /// Whether this element is constructed (SEQUENCE, SET, etc.).
    var isConstructed: Bool { (tag & 0x20) != 0 }

    /// The tag class (universal, application, context-specific, private).
    var tagClass: UInt8 { tag >> 6 }

    /// The tag number (lower 5 bits).
    var tagNumber: UInt8 { tag & 0x1F }

    /// The value bytes.
    var value: Data {
        raw[raw.startIndex + valueOffset ..< raw.startIndex + valueOffset + valueLength]
    }

    /// Total size of this element.
    var totalSize: Int { valueOffset + valueLength }

    /// Parse a DER element from the start of `data`.
    /// Returns the parsed element or throws if malformed.
    static func parse(_ data: Data) throws -> DERElement {
        guard data.count >= 2 else {
            throw DERError.truncated
        }

        let startIndex = data.startIndex
        var offset = 1 // skip tag byte

        // Parse length
        let firstLenByte = data[startIndex + offset]
        offset += 1

        let length: Int
        if firstLenByte < 0x80 {
            length = Int(firstLenByte)
        } else if firstLenByte == 0x80 {
            throw DERError.indefiniteLengthNotSupported
        } else {
            let numLenBytes = Int(firstLenByte & 0x7F)
            guard numLenBytes <= 4, data.count >= offset + numLenBytes else {
                throw DERError.truncated
            }
            var len = 0
            for i in 0 ..< numLenBytes {
                len = (len << 8) | Int(data[startIndex + offset + i])
            }
            offset += numLenBytes
            length = len
        }

        guard data.count >= offset + length else {
            throw DERError.truncated
        }

        let totalSize = offset + length
        return DERElement(
            raw: data[startIndex ..< startIndex + totalSize],
            valueOffset: offset,
            valueLength: length
        )
    }

    /// Iterate over child elements (only valid for constructed elements).
    func children() throws -> [DERElement] {
        var result: [DERElement] = []
        var remaining = value
        while !remaining.isEmpty {
            let child = try DERElement.parse(remaining)
            result.append(child)
            remaining = remaining.dropFirst(child.totalSize)
        }
        return result
    }

    /// Get child element at index.
    func child(at index: Int) throws -> DERElement {
        let kids = try children()
        guard index < kids.count else {
            throw DERError.indexOutOfBounds(index, kids.count)
        }
        return kids[index]
    }

    /// Read value as a UTF-8 / IA5 string.
    func stringValue() throws -> String {
        guard let s = String(data: value, encoding: .utf8) else {
            throw DERError.invalidString
        }
        return s
    }

    /// Read value as an integer (big-endian).
    func integerValue() -> UInt64 {
        var result: UInt64 = 0
        for byte in value {
            result = (result << 8) | UInt64(byte)
        }
        return result
    }
}

// MARK: - DER Builder

enum DERBuilder {
    static func sequence(_ elements: [Data]) -> Data {
        let content = elements.reduce(Data()) { $0 + $1 }
        return Data([0x30]) + encodeLength(content.count) + content
    }

    static func ia5String(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        return Data([0x16]) + encodeLength(bytes.count) + Data(bytes)
    }

    static func octetString(_ d: Data) -> Data {
        Data([0x04]) + encodeLength(d.count) + d
    }

    static func integer(_ value: UInt64) -> Data {
        if value == 0 {
            return Data([0x02, 0x01, 0x00])
        }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        // Add leading zero if high bit set (to keep it positive)
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return Data([0x02]) + encodeLength(bytes.count) + Data(bytes)
    }

    /// Context-specific constructed tag [tagNum] wrapping content.
    static func contextTag(_ tagNum: UInt8, constructed: Bool = true, content: Data) -> Data {
        let classBits: UInt8 = 0x80 // context-specific
        let constructedBit: UInt8 = constructed ? 0x20 : 0x00
        let tag = classBits | constructedBit | (tagNum & 0x1F)
        return Data([tag]) + encodeLength(content.count) + content
    }

    static func encodeLength(_ len: Int) -> Data {
        if len < 0x80 {
            return Data([UInt8(len)])
        } else if len < 0x100 {
            return Data([0x81, UInt8(len)])
        } else if len < 0x10000 {
            return Data([0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
        } else if len < 0x1000000 {
            return Data([0x83, UInt8(len >> 16), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        } else {
            return Data([0x84, UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        }
    }
}

// MARK: - DER Tag Constants

enum DERTag {
    static let sequence: UInt8 = 0x30
    static let set: UInt8 = 0x31
    static let integer: UInt8 = 0x02
    static let octetString: UInt8 = 0x04
    static let ia5String: UInt8 = 0x16
    static let utf8String: UInt8 = 0x0C
    static let boolean: UInt8 = 0x01
}

// MARK: - Errors

enum DERError: Error, Sendable {
    case truncated
    case indefiniteLengthNotSupported
    case indexOutOfBounds(Int, Int)
    case invalidString
    case invalidStructure(String)
}
