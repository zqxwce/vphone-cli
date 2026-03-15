import Foundation

enum VPhoneError: Error, CustomStringConvertible {
    case hardwareModelNotSupported
    case romNotFound(String)
    case diskNotFound(String)
    case invalidKernelDebugPort(Int)
    case manifestLoadFailed(path: String, underlying: Error)
    case manifestParseFailed(path: String, underlying: Error)
    case manifestWriteFailed(path: String, underlying: Error)

    var description: String {
        switch self {
        case .hardwareModelNotSupported:
            """
            PV=3 hardware model not supported. Check:
              1. macOS >= 15.0 (Sequoia)
              2. Signed with com.apple.private.virtualization + \
            com.apple.private.virtualization.security-research
              3. SIP/AMFI disabled
            """
        case let .romNotFound(p):
            "ROM not found: \(p)"
        case let .diskNotFound(p):
            "Disk image not found: \(p)"
        case let .invalidKernelDebugPort(port):
            "Invalid kernel debug port: \(port) (expected 6000...65535)"
        case let .manifestLoadFailed(path: path, underlying: _):
            "Failed to load manifest from \(path)"
        case let .manifestParseFailed(path: path, underlying: _):
            "Failed to parse manifest at \(path)"
        case let .manifestWriteFailed(path: path, underlying: _):
            "Failed to write manifest to \(path)"
        }
    }
}
