// Validate VZ accepts a synthetic USB device by locationID.
//
// Usage:
//   1. Start usbaudio-poc — it parks a synthetic USB device on AppleUSBUserHCI.
//   2. `ioreg -p IOUSB` → find the locationID (e.g. 0x81100000).
//   3. Run:  vz-validate 0x81100000
//
// Success: prints "cfg created" + uses VZVirtualMachineConfiguration.validate
// to confirm a VZ config with our device as a passthrough is internally consistent.

import Foundation
import Virtualization
import ObjectiveC.runtime

setbuf(stdout, nil)

guard CommandLine.arguments.count == 2 else {
    print("usage: vz-validate <locationID-hex-or-decimal>")
    exit(2)
}

let locArg = CommandLine.arguments[1]
let locationID: UInt32
if locArg.hasPrefix("0x") || locArg.hasPrefix("0X") {
    guard let v = UInt32(locArg.dropFirst(2), radix: 16) else { print("bad locationID"); exit(2) }
    locationID = v
} else {
    guard let v = UInt32(locArg) else { print("bad locationID"); exit(2) }
    locationID = v
}
print("[validate] locationID = 0x\(String(locationID, radix: 16))")

guard let cls: AnyClass = NSClassFromString("_VZIOUSBHostPassthroughDeviceConfiguration") else {
    print("[validate] FATAL: _VZIOUSBHostPassthroughDeviceConfiguration not found in runtime")
    exit(1)
}
print("[validate] class found: \(cls)")

let sel = NSSelectorFromString("fromLocationID:error:")
guard let m = class_getClassMethod(cls, sel) else {
    print("[validate] FATAL: +fromLocationID:error: not found")
    exit(1)
}
let imp = method_getImplementation(m)
typealias FromLocFn = @convention(c) (AnyClass, Selector, UInt32, UnsafeMutablePointer<Optional<NSError>>) -> AnyObject?
let fn = unsafeBitCast(imp, to: FromLocFn.self)

var err: NSError? = nil
let configObj = fn(cls, sel, locationID, &err)
if let e = err {
    print("[validate] fromLocationID error: \(e)")
}
guard let config = configObj else {
    print("[validate] FAILED to create passthrough config")
    exit(1)
}
print("[validate] cfg created: \(config)")

// Cast through NSObject so Swift accepts it as a VZUSBDeviceConfiguration.
guard let usbDev = config as? VZUSBDeviceConfiguration else {
    print("[validate] FAILED: cfg does not conform to VZUSBDeviceConfiguration")
    exit(1)
}

// Build a minimal VZ config with our device behind an XHCI controller.
let xhci = VZXHCIControllerConfiguration()
xhci.usbDevices = [usbDev]

let vmCfg = VZVirtualMachineConfiguration()
vmCfg.cpuCount = 1
vmCfg.memorySize = 256 * 1024 * 1024
vmCfg.usbControllers = [xhci]

do {
    try vmCfg.validate()
    print("[validate] VZ config validates ✓")
} catch {
    // Expected: there's no bootloader/disk; we only care that the USB section is OK.
    let ns = error as NSError
    print("[validate] vmCfg.validate() returned: \(ns)")
    if ns.localizedDescription.lowercased().contains("usb") {
        print("[validate] ✗ USB-related validation error — passthrough config not accepted")
        exit(1)
    }
    print("[validate] ✓ error unrelated to USB — passthrough config accepted")
}
