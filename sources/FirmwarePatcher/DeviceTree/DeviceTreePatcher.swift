// DeviceTreePatcher.swift — DeviceTree payload patcher.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy:
//   1. Parse the flat device tree binary into a node/property tree.
//   2. Apply a fixed set of property patches (serial-number, home-button-type,
//      artwork-device-subtype, island-notch-location).
//   3. Serialize the modified tree back to flat binary.

import Foundation

/// Patcher for DeviceTree payloads.
public final class DeviceTreePatcher: Patcher {
    public let component = "devicetree"
    public let verbose: Bool

    let buffer: BinaryBuffer
    var patches: [PatchRecord] = []
    var rebuiltData: Data?

    // MARK: - Patch Definitions

    /// A single property patch specification.
    struct PropertyPatch {
        let nodePath: [String]
        let property: String
        let length: Int
        let flags: UInt16
        let value: PropertyValue
        let patchID: String
        let description: String
    }

    /// The value to write into a device tree property.
    enum PropertyValue {
        case string(String)
        case integer(UInt64)
    }

    /// Fixed set of device tree patches, matching scripts/dtree.py PATCHES.
    static let propertyPatches: [PropertyPatch] = [
        PropertyPatch(
            nodePath: ["device-tree"],
            property: "serial-number",
            length: 12,
            flags: 0,
            value: .string("vphone-1337"),
            patchID: "devicetree.serial_number",
            description: "Set serial number to vphone-1337"
        ),
        PropertyPatch(
            nodePath: ["device-tree", "buttons"],
            property: "home-button-type",
            length: 4,
            flags: 0,
            value: .integer(2),
            patchID: "devicetree.home_button_type",
            description: "Set home button type to 2"
        ),
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "artwork-device-subtype",
            length: 4,
            flags: 0,
            value: .integer(2556),
            patchID: "devicetree.artwork_device_subtype",
            description: "Set artwork device subtype to 2556"
        ),
        PropertyPatch(
            nodePath: ["device-tree", "product"],
            property: "island-notch-location",
            length: 4,
            flags: 0,
            value: .integer(144),
            patchID: "devicetree.island_notch_location",
            description: "Set island notch location to 144"
        ),
    ]

    // MARK: - Device Tree Structures

    /// A single property in a device tree node.
    final class DTProperty {
        var name: String
        var length: Int
        var flags: UInt16
        var value: Data
        /// File offset of the property value within the flat binary.
        let valueOffset: Int

        init(name: String, length: Int, flags: UInt16, value: Data, valueOffset: Int) {
            self.name = name
            self.length = length
            self.flags = flags
            self.value = value
            self.valueOffset = valueOffset
        }
    }

    /// A node in the device tree containing properties and child nodes.
    final class DTNode {
        var properties: [DTProperty] = []
        var children: [DTNode] = []
    }

    // MARK: - Init

    public init(data: Data, verbose: Bool = true) {
        buffer = BinaryBuffer(data)
        self.verbose = verbose
    }

    // MARK: - Patcher

    public func findAll() throws -> [PatchRecord] {
        patches = []
        rebuiltData = nil
        let root = try parsePayload(buffer.data)
        try applyPatches(root: root)
        rebuiltData = serializePayload(root)
        return patches
    }

    @discardableResult
    public func apply() throws -> Int {
        if patches.isEmpty, rebuiltData == nil {
            let _ = try findAll()
        }
        if let rebuiltData {
            buffer.data = rebuiltData
        } else {
            for record in patches {
                buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
            }
        }
        if verbose, !patches.isEmpty {
            print("\n  [\(patches.count) DeviceTree patch(es) applied]")
        }
        return patches.count
    }

    public var patchedData: Data {
        rebuiltData ?? buffer.data
    }

    // MARK: - Parsing

    /// Align a value up to the next 4-byte boundary.
    private static func align4(_ n: Int) -> Int {
        (n + 3) & ~3
    }

    /// Decode a null-terminated C string from raw bytes.
    private static func decodeCString(_ data: Data) -> String {
        if let nullIndex = data.firstIndex(of: 0) {
            let slice = data[data.startIndex ..< nullIndex]
            return String(bytes: slice, encoding: .utf8) ?? ""
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Parse a device tree node from the flat binary at the given offset.
    /// Returns the parsed node and the offset past the end of the node.
    private func parseNode(_ blob: Data, offset: Int) throws -> (DTNode, Int) {
        guard offset + 8 <= blob.count else {
            throw PatcherError.invalidFormat("DeviceTree: truncated node header at offset \(offset)")
        }

        let nProps = blob.loadLE(UInt32.self, at: offset)
        let nChildren = blob.loadLE(UInt32.self, at: offset + 4)
        var pos = offset + 8

        let node = DTNode()

        for _ in 0 ..< nProps {
            guard pos + 36 <= blob.count else {
                throw PatcherError.invalidFormat("DeviceTree: truncated property header at offset \(pos)")
            }

            let nameData = blob[blob.startIndex.advanced(by: pos) ..< blob.startIndex.advanced(by: pos + 32)]
            let name = Self.decodeCString(Data(nameData))
            let length = Int(blob.loadLE(UInt16.self, at: pos + 32))
            let flags = blob.loadLE(UInt16.self, at: pos + 34)
            pos += 36

            guard pos + length <= blob.count else {
                throw PatcherError.invalidFormat("DeviceTree: truncated property value '\(name)' at offset \(pos)")
            }

            let value = Data(blob[blob.startIndex.advanced(by: pos) ..< blob.startIndex.advanced(by: pos + length)])
            let valueOffset = pos
            pos += Self.align4(length)

            node.properties.append(DTProperty(
                name: name, length: length, flags: flags,
                value: value, valueOffset: valueOffset
            ))
        }

        for _ in 0 ..< nChildren {
            let (child, nextPos) = try parseNode(blob, offset: pos)
            node.children.append(child)
            pos = nextPos
        }

        return (node, pos)
    }

    /// Parse the entire device tree payload.
    private func parsePayload(_ blob: Data) throws -> DTNode {
        let (root, end) = try parseNode(blob, offset: 0)
        guard end == blob.count else {
            throw PatcherError.invalidFormat(
                "DeviceTree: unexpected trailing bytes (\(blob.count - end) extra)"
            )
        }
        return root
    }

    private func serializeNode(_ node: DTNode) -> Data {
        var out = Data()
        out.append(contentsOf: withUnsafeBytes(of: UInt32(node.properties.count).littleEndian) { Data($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt32(node.children.count).littleEndian) { Data($0) })

        for prop in node.properties {
            var name = Data(prop.name.utf8)
            if name.count >= 32 {
                name = Data(name.prefix(31))
            }
            name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
            out.append(name)

            out.append(contentsOf: withUnsafeBytes(of: UInt16(prop.length).littleEndian) { Data($0) })
            out.append(contentsOf: withUnsafeBytes(of: prop.flags.littleEndian) { Data($0) })
            out.append(prop.value)

            let pad = Self.align4(prop.length) - prop.length
            if pad > 0 {
                out.append(Data(repeating: 0, count: pad))
            }
        }

        for child in node.children {
            out.append(serializeNode(child))
        }
        return out
    }

    private func serializePayload(_ root: DTNode) -> Data {
        serializeNode(root)
    }

    // MARK: - Node Navigation

    /// Get the "name" property value from a node.
    private func nodeName(_ node: DTNode) -> String {
        for prop in node.properties {
            if prop.name == "name" {
                return Self.decodeCString(prop.value)
            }
        }
        return ""
    }

    /// Find a direct child node by name.
    private func findChild(_ node: DTNode, name: String) throws -> DTNode {
        for child in node.children {
            if nodeName(child) == name {
                return child
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: missing child node '\(name)'")
    }

    /// Resolve a node path like ["device-tree", "buttons"] from the root.
    private func resolveNode(_ root: DTNode, path: [String]) throws -> DTNode {
        guard !path.isEmpty, path[0] == "device-tree" else {
            throw PatcherError.patchSiteNotFound("DeviceTree: invalid node path \(path)")
        }
        var node = root
        for name in path.dropFirst() {
            node = try findChild(node, name: name)
        }
        return node
    }

    /// Find a property by name within a node.
    private func findProperty(_ node: DTNode, name: String) throws -> DTProperty {
        for prop in node.properties {
            if prop.name == name {
                return prop
            }
        }
        throw PatcherError.patchSiteNotFound("DeviceTree: missing property '\(name)'")
    }

    // MARK: - Value Encoding

    /// Encode a string value with null termination, padded/truncated to a fixed length.
    private static func encodeFixedString(_ text: String, length: Int) -> Data {
        var raw = Data(text.utf8)
        raw.append(0) // null terminator
        if raw.count > length {
            return Data(raw.prefix(length))
        }
        raw.append(contentsOf: [UInt8](repeating: 0, count: length - raw.count))
        return raw
    }

    /// Encode an integer value as little-endian bytes.
    private static func encodeInteger(_ value: UInt64, length: Int) throws -> Data {
        var data = Data(count: length)
        switch length {
        case 1:
            data[0] = UInt8(value & 0xFF)
        case 2:
            let v = UInt16(value & 0xFFFF)
            data.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, as: UInt16.self) }
        case 4:
            let v = UInt32(value & 0xFFFF_FFFF)
            data.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, as: UInt32.self) }
        case 8:
            data.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, as: UInt64.self) }
        default:
            throw PatcherError.invalidFormat("DeviceTree: unsupported integer length \(length)")
        }
        return data
    }

    // MARK: - Patch Application

    /// Apply all property patches and record each change.
    private func applyPatches(root: DTNode) throws {
        for patch in Self.propertyPatches {
            let node = try resolveNode(root, path: patch.nodePath)
            let prop = try findProperty(node, name: patch.property)

            let originalBytes = Data(prop.value.prefix(patch.length))

            let newValue: Data = switch patch.value {
            case let .string(s):
                Self.encodeFixedString(s, length: patch.length)
            case let .integer(v):
                try Self.encodeInteger(v, length: patch.length)
            }

            prop.length = patch.length
            prop.flags = patch.flags
            prop.value = newValue

            let record = PatchRecord(
                patchID: patch.patchID,
                component: component,
                fileOffset: prop.valueOffset,
                virtualAddress: nil,
                originalBytes: originalBytes,
                patchedBytes: newValue,
                description: patch.description
            )
            patches.append(record)

            if verbose {
                print(String(format: "  0x%06X: %@ → %@  [%@]",
                             prop.valueOffset,
                             originalBytes.hex,
                             newValue.hex,
                             patch.patchID))
            }
        }
    }
}
