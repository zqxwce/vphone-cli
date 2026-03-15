import Img4tool
import Foundation

@main
enum Img4CLI {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: img4cli <command> [options]")
            print()
            print("Commands:")
            print("  info <file>              Show container type and metadata")
            print("  extract <file> <output>  Extract payload to raw file")
            print("  create <fourcc> <raw> <output> [--lzss|--lzfse]")
            print("                           Create IM4P from raw payload")
            print("  rename <file> <fourcc> <output>")
            print("                           Rename IM4P fourcc tag")
            print("  version                  Show img4tool version")
            return
        }

        let command = args[1]

        switch command {
        case "version":
            print(img4Version())

        case "info":
            guard args.count >= 3 else {
                print("Usage: img4cli info <file>")
                return
            }
            try cmdInfo(path: args[2])

        case "extract":
            guard args.count >= 4 else {
                print("Usage: img4cli extract <file> <output>")
                return
            }
            try cmdExtract(path: args[2], output: args[3])

        case "create":
            guard args.count >= 5 else {
                print("Usage: img4cli create <fourcc> <raw> <output> [--lzss|--lzfse]")
                return
            }
            let compression: String? = args.count > 5 ? String(args[5].dropFirst(2)) : nil
            try cmdCreate(fourcc: args[2], rawPath: args[3], output: args[4], compression: compression)

        case "rename":
            guard args.count >= 5 else {
                print("Usage: img4cli rename <file> <fourcc> <output>")
                return
            }
            try cmdRename(path: args[2], fourcc: args[3], output: args[4])

        default:
            print("Unknown command: \(command)")
        }
    }

    static func cmdInfo(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let type = img4DetectType(data)

        print("File: \(path)")
        print("Size: \(data.count) bytes")
        print("Type: \(type)")

        switch type {
        case .im4p:
            let im4p = try IM4P(data)
            print("Fourcc: \(im4p.fourcc)")
            print("Description: \(im4p.description)")
            print("Encrypted: \(im4p.isEncrypted)")
            if !im4p.isEncrypted {
                let payload = try im4p.payload()
                print("Payload size: \(payload.count) bytes")
                // Show first 16 bytes as hex
                let preview = payload.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("Payload head: \(preview)")
            }

        case .img4:
            let img4 = try IMG4(data)
            print("--- IM4P ---")
            if let im4p = try? img4.im4p() {
                print("  Fourcc: \(im4p.fourcc)")
                print("  Description: \(im4p.description)")
                print("  Encrypted: \(im4p.isEncrypted)")
                if !im4p.isEncrypted {
                    if let payload = try? im4p.payload() {
                        print("  Payload size: \(payload.count) bytes")
                    }
                }
            }
            print("--- IM4M ---")
            if let im4m = try? img4.im4m() {
                print("  Size: \(im4m.data.count) bytes")
                print("  Signature valid: \(im4m.isSignatureValid)")
            } else {
                print("  (not present)")
            }

        case .im4m:
            let im4m = try IM4M(data)
            print("Signature valid: \(im4m.isSignatureValid)")

        case .unknown:
            // Check if it's raw Mach-O
            if data.count >= 4 {
                let magic = data.prefix(4)
                if magic == Data([0xcf, 0xfa, 0xed, 0xfe]) {
                    print("Detected: raw Mach-O (64-bit)")
                } else if magic == Data([0xce, 0xfa, 0xed, 0xfe]) {
                    print("Detected: raw Mach-O (32-bit)")
                } else {
                    let hex = magic.map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("Magic: \(hex)")
                }
            }
        }
    }

    static func cmdExtract(path: String, output: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let type = img4DetectType(data)

        let payload: Data
        switch type {
        case .im4p:
            let im4p = try IM4P(data)
            payload = try im4p.payload()
            print("Extracted IM4P payload (\(im4p.fourcc)): \(payload.count) bytes")

        case .img4:
            let img4 = try IMG4(data)
            let im4p = try img4.im4p()
            payload = try im4p.payload()
            print("Extracted IMG4→IM4P payload (\(im4p.fourcc)): \(payload.count) bytes")

        default:
            print("Not an IM4P or IMG4 container")
            return
        }

        try payload.write(to: URL(fileURLWithPath: output))
        print("Written to: \(output)")
    }

    static func cmdCreate(fourcc: String, rawPath: String, output: String, compression: String?) throws {
        let raw = try Data(contentsOf: URL(fileURLWithPath: rawPath))
        let im4p = try IM4P(fourcc: fourcc, description: fourcc, payload: raw, compression: compression)
        try im4p.data.write(to: URL(fileURLWithPath: output))
        print("Created IM4P (\(fourcc)): \(im4p.data.count) bytes")
        if let c = compression { print("Compression: \(c)") }
        print("Written to: \(output)")
    }

    static func cmdRename(path: String, fourcc: String, output: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let im4p = try IM4P(data)
        let renamed = try im4p.renamed(to: fourcc)
        try renamed.data.write(to: URL(fileURLWithPath: output))
        print("Renamed \(im4p.fourcc) → \(fourcc): \(renamed.data.count) bytes")
        print("Written to: \(output)")
    }
}
