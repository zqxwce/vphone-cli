import AppKit
import ArgumentParser
import Foundation

do {
    let command = try VPhoneCLI.parseAsRoot()

    switch command {
    case let boot as VPhoneBootCLI:
        let app = NSApplication.shared
        let delegate = VPhoneAppDelegate(cli: boot)
        app.delegate = delegate
        app.run()

    case var patch as PatchFirmwareCLI:
        try patch.run()

    case var patch as PatchComponentCLI:
        try patch.run()

    default:
        break
    }
} catch {
    VPhoneCLI.exit(withError: error)
}
