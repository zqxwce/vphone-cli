import Foundation

// MARK: - IM4P

/// A parsed IM4P (Image4 Payload) firmware container.
public struct IM4P: Sendable {
    /// Raw DER-encoded IM4P bytes.
    public let data: Data

    /// Parse an IM4P from raw bytes.
    /// - Throws: ``Img4Error`` if the data is not a valid IM4P.
    public init(_ data: Data) throws {
        guard Self.isValid(data) else {
            throw Img4Error.invalidFormat("not a valid IM4P")
        }
        self.data = data
    }

    /// Parse an IM4P from file.
    public init(contentsOf url: URL) throws {
        try self.init(Data(contentsOf: url))
    }

    /// 4-character type code (e.g. "rkrn", "rdsk", "dtre").
    public var fourcc: String {
        guard let element = try? DERElement.parse(data),
              let child = try? element.child(at: 1),
              let s = try? child.stringValue()
        else { return "" }
        return s
    }

    /// Description metadata string.
    public var description: String {
        guard let element = try? DERElement.parse(data),
              let child = try? element.child(at: 2),
              let s = try? child.stringValue()
        else { return "" }
        return s
    }

    /// Whether this IM4P contains a KBAG (is encrypted).
    public var isEncrypted: Bool {
        guard let element = try? DERElement.parse(data),
              let children = try? element.children()
        else { return false }
        // IM4P: [0]=type, [1]=fourcc, [2]=desc, [3]=payload, [4]=kbag (optional)
        return children.count >= 5 && children[4].tag == DERTag.octetString
    }

    /// Extract the decompressed payload data.
    /// - Parameters:
    ///   - iv: Decryption IV (hex string), or nil for unencrypted.
    ///   - key: Decryption key (hex string), or nil for unencrypted.
    /// - Returns: Decompressed payload bytes.
    public func payload(iv: String? = nil, key: String? = nil) throws -> Data {
        let element = try DERElement.parse(data)
        let children = try element.children()
        guard children.count >= 4 else {
            throw Img4Error.extractionFailed("malformed IM4P structure")
        }

        var payloadData = children[3].value

        // Decrypt if keys provided
        if let iv, let key {
            payloadData = try Img4Crypto.aesDecrypt(payloadData, ivHex: iv, keyHex: key)
        }

        // Check for compression
        if LZSSDecompressor.isLZSS(payloadData) {
            return try LZSSDecompressor.decompress(payloadData)
        }

        // Check for bvx2 (LZFSE) - indicated by compression info in element [5] or [4]
        if let uncompressedSize = extractBvx2UncompressedSize(children: children) {
            return try LZFSEDecompressor.decompress(payloadData, expectedSize: uncompressedSize)
        }

        return payloadData
    }

    /// Create a new IM4P with a different fourcc tag.
    public func renamed(to newFourcc: String) throws -> IM4P {
        let element = try DERElement.parse(data)
        let children = try element.children()
        guard children.count >= 4 else {
            throw Img4Error.operationFailed("malformed IM4P structure")
        }

        // Rebuild with new fourcc
        var elements: [Data] = [
            DERBuilder.ia5String("IM4P"),
            DERBuilder.ia5String(newFourcc),
        ]
        // Keep original description and all remaining elements
        for i in 2 ..< children.count {
            elements.append(children[i].raw)
        }

        let newData = DERBuilder.sequence(elements)
        return try IM4P(newData)
    }

    /// Create a new IM4P container from raw payload data.
    /// - Parameters:
    ///   - fourcc: 4-character type code.
    ///   - description: Metadata description (must be non-empty for valid IM4P).
    ///   - payload: Raw payload bytes.
    ///   - compression: Compression type ("lzss", "lzfse") or nil for uncompressed.
    public init(fourcc: String, description: String, payload: Data, compression: String? = nil) throws {
        var payloadData = payload

        if let compression {
            switch compression.lowercased() {
            case "lzss":
                payloadData = try LZSSCompressor.compress(payload)
            case "lzfse":
                let compressed = try LZFSEDecompressor.compress(payload)
                payloadData = compressed
                // For LZFSE we need to add compression info element
                let compressionInfo = DERBuilder.sequence([
                    DERBuilder.integer(1), // version
                    DERBuilder.integer(UInt64(payload.count)), // uncompressed size
                ])
                let built = DERBuilder.sequence([
                    DERBuilder.ia5String("IM4P"),
                    DERBuilder.ia5String(fourcc),
                    DERBuilder.ia5String(description),
                    DERBuilder.octetString(payloadData),
                    compressionInfo,
                ])
                self.data = built
                return
            default:
                throw Img4Error.operationFailed("unsupported compression: \(compression)")
            }
        }

        let built = DERBuilder.sequence([
            DERBuilder.ia5String("IM4P"),
            DERBuilder.ia5String(fourcc),
            DERBuilder.ia5String(description),
            DERBuilder.octetString(payloadData),
        ])
        self.data = built
    }

    // MARK: - Private

    static func isValid(_ data: Data) -> Bool {
        guard let element = try? DERElement.parse(data),
              element.tag == DERTag.sequence,
              let children = try? element.children(),
              children.count >= 4,
              let typeStr = try? children[0].stringValue(),
              typeStr == "IM4P",
              let _ = try? children[1].stringValue(), // fourcc
              let _ = try? children[2].stringValue() // description
        else { return false }
        return true
    }

    /// Extract bvx2/LZFSE uncompressed size from IM4P compression info.
    private func extractBvx2UncompressedSize(children: [DERElement]) -> Int? {
        // Compression info can be at index 4 or 5
        for i in 4 ..< children.count {
            let child = children[i]
            if child.tag == DERTag.sequence {
                guard let seqChildren = try? child.children(),
                      seqChildren.count >= 2
                else { continue }
                let version = seqChildren[0].integerValue()
                guard version == 1 else { continue }
                let uncompSize = seqChildren[1].integerValue()
                if uncompSize > 0 { return Int(uncompSize) }
            }
        }
        return nil
    }
}

// MARK: - IM4M

/// A parsed IM4M (Image4 Manifest) container.
public struct IM4M: Sendable {
    /// Raw DER-encoded IM4M bytes.
    public let data: Data

    /// Parse an IM4M from raw bytes.
    public init(_ data: Data) throws {
        guard Self.isValid(data) else {
            throw Img4Error.invalidFormat("not a valid IM4M")
        }
        self.data = data
    }

    /// Parse an IM4M from file.
    public init(contentsOf url: URL) throws {
        try self.init(Data(contentsOf: url))
    }

    /// Validate the IM4M signature.
    public var isSignatureValid: Bool {
        Img4SignatureVerifier.verifyIM4MSignature(data)
    }

    static func isValid(_ data: Data) -> Bool {
        guard let element = try? DERElement.parse(data),
              element.tag == DERTag.sequence,
              let children = try? element.children(),
              children.count >= 2,
              let typeStr = try? children[0].stringValue(),
              typeStr == "IM4M"
        else { return false }
        return true
    }
}

// MARK: - IMG4

/// A parsed IMG4 (Image4) signed firmware container (IM4P + IM4M).
public struct IMG4: Sendable {
    /// Raw DER-encoded IMG4 bytes.
    public let data: Data

    /// Parse an IMG4 from raw bytes.
    public init(_ data: Data) throws {
        guard Self.isValid(data) else {
            throw Img4Error.invalidFormat("not a valid IMG4")
        }
        self.data = data
    }

    /// Parse an IMG4 from file.
    public init(contentsOf url: URL) throws {
        try self.init(Data(contentsOf: url))
    }

    /// Build an IMG4 container from IM4P and optional IM4M.
    public init(im4p: IM4P, im4m: IM4M? = nil) throws {
        var elements: [Data] = [
            DERBuilder.ia5String("IMG4"),
            im4p.data,
        ]
        if let im4m {
            // IM4M is wrapped in a context-specific [0] tag
            elements.append(DERBuilder.contextTag(0, content: im4m.data))
        }
        self.data = DERBuilder.sequence(elements)
    }

    /// Extract the IM4P component.
    public func im4p() throws -> IM4P {
        let element = try DERElement.parse(data)
        let children = try element.children()
        // children[0] = IA5String "IMG4"
        // children[1] = SEQUENCE (IM4P) - but it might be a bare IM4P sequence
        guard children.count >= 2 else {
            throw Img4Error.extractionFailed("IMG4 does not contain IM4P")
        }

        // The IM4P is at index 1
        let im4pElement = children[1]
        return try IM4P(im4pElement.raw)
    }

    /// Extract the IM4M component.
    public func im4m() throws -> IM4M {
        let element = try DERElement.parse(data)
        let children = try element.children()

        // Find the context-specific [0] tag containing IM4M
        for child in children {
            // Context-specific constructed tag [0] = 0xA0
            if child.tag == 0xA0 {
                // The IM4M is the content inside this context tag
                let innerElement = try DERElement.parse(child.value)
                return try IM4M(innerElement.raw)
            }
        }

        throw Img4Error.extractionFailed("IMG4 does not contain IM4M")
    }

    static func isValid(_ data: Data) -> Bool {
        guard let element = try? DERElement.parse(data),
              element.tag == DERTag.sequence,
              let children = try? element.children(),
              children.count >= 2,
              let typeStr = try? children[0].stringValue(),
              typeStr == "IMG4"
        else { return false }
        return true
    }
}

// MARK: - Utility

/// Detect the container type of raw firmware data.
public enum Img4ContainerType: Sendable, Equatable {
    case img4
    case im4p
    case im4m
    case unknown
}

/// Detect the container type of raw data.
public func img4DetectType(_ data: Data) -> Img4ContainerType {
    if IMG4.isValid(data) { return .img4 }
    if IM4P.isValid(data) { return .im4p }
    if IM4M.isValid(data) { return .im4m }
    return .unknown
}

/// Get the library version string.
public func img4Version() -> String {
    "img4tool-swift 1.0.0"
}

// MARK: - Errors

public enum Img4Error: Error, Sendable, CustomStringConvertible {
    case invalidFormat(String)
    case extractionFailed(String)
    case operationFailed(String)

    public var description: String {
        switch self {
        case .invalidFormat(let msg): "Img4Error.invalidFormat: \(msg)"
        case .extractionFailed(let msg): "Img4Error.extractionFailed: \(msg)"
        case .operationFailed(let msg): "Img4Error.operationFailed: \(msg)"
        }
    }
}
