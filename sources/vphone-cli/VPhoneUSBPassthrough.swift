import AppKit
import Dynamic
import Foundation
import IOKit
import IOKit.usb
import Virtualization

// MARK: - Host USB Device Record

struct VPhoneHostUSBDevice: Hashable {
    let locationID: UInt32
    let vendorID: UInt16
    let productID: UInt16
    let vendorName: String?
    let productName: String?

    var displayName: String {
        let vid = String(format: "%04x", vendorID)
        let pid = String(format: "%04x", productID)
        let loc = String(format: "%08x", locationID)
        let name: String = {
            switch (vendorName, productName) {
            case let (v?, p?): return "\(v) \(p)"
            case (_, let p?): return p
            case (let v?, _): return v
            default: return "USB device"
            }
        }()
        return "\(name) [\(vid):\(pid) @ 0x\(loc)]"
    }
}

// MARK: - Controller delegate stub
//
// VZUSBController has a private `setDelegate:`. On macOS 27.0 there is no formal
// delegate protocol — the framework messages the delegate via untyped
// selectors. We implement the ones it sends so attach/detach lifecycle and
// hotplug failures surface. UTM sets a delegate before attach; we mirror that —
// the framework may use the presence of a delegate as part of its flow.
@objc final class VPhoneUSBControllerDelegate: NSObject {
    @objc(usbController:passthroughDeviceWillDisconnect:)
    func passthroughDeviceWillDisconnect(_ controller: AnyObject, device: AnyObject) {
        // Framework callback when a passthrough device is unplugged on the host.
        print("[usb] passthroughDeviceWillDisconnect — host device went away")
    }

    // 27.0 renamed the did-disconnect selector (was
    // `usbController:passthroughDeviceDidDisconnect:` on 26.x).
    @objc(usbController:usbPassthroughDeviceDidDisconnect:)
    func usbPassthroughDeviceDidDisconnect(_ controller: AnyObject, device: AnyObject) {
        print("[usb] usbPassthroughDeviceDidDisconnect")
    }

    // 27.0 hotplug failure callbacks — surface attach/detach errors that
    // otherwise stay inside the framework's hub plumbing.
    @objc(usbController:hub:passthroughDevice:didFailToAttachWithError:)
    func didFailToAttach(_ controller: AnyObject, hub: AnyObject, device: AnyObject, error: NSError) {
        print("[usb] didFailToAttach: domain=\(error.domain) code=\(error.code) \(error.localizedDescription)")
    }

    @objc(usbController:hub:passthroughDevice:didFailToDetachWithError:)
    func didFailToDetach(_ controller: AnyObject, hub: AnyObject, device: AnyObject, error: NSError) {
        print("[usb] didFailToDetach: domain=\(error.domain) code=\(error.code) \(error.localizedDescription)")
    }
}

// MARK: - USB Passthrough Controller

/// Host-side controller for live USB passthrough to the running VZ guest.
///
/// Mirrors UTM PR #7635 — enumerates host devices via IOKit (`IOUSBDevice`),
/// builds `_VZIOUSBHostPassthroughDeviceConfiguration` via the private
/// `-initWithService:error:` initializer (NOT `+fromLocationID:error:`),
/// instantiates the matching live `_VZIOUSBHostPassthroughDevice`, and attaches
/// it to the live `VZUSBController` exposed at `vm.usbControllers[0]`.
@MainActor
final class VPhoneUSBPassthrough {
    private weak var vm: VZVirtualMachine?
    private var attached: [UInt32: any VZUSBDevice] = [:]
    private let controllerDelegate = VPhoneUSBControllerDelegate()
    private var delegateInstalled = false

    init(vm: VZVirtualMachine) {
        self.vm = vm
        VPhoneVZPatches.disableIsochronousEndpointCheck()
    }

    var controller: VZUSBController? {
        vm?.usbControllers.first
    }

    // MARK: Enumeration

    /// Snapshot of every IOUSBDevice the host can currently see.
    func enumerate() -> [VPhoneHostUSBDevice] {
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else { return [] }
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var out: [VPhoneHostUSBDevice] = []
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            if let dev = Self.read(service: service) {
                out.append(dev)
            }
        }
        out.sort { $0.locationID < $1.locationID }
        return out
    }

    private static func read(service: io_service_t) -> VPhoneHostUSBDevice? {
        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &propsUnmanaged, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let props = propsUnmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        guard
            let loc = (props["locationID"] as? NSNumber)?.uint32Value,
            let vid = (props["idVendor"] as? NSNumber)?.uint16Value,
            let pid = (props["idProduct"] as? NSNumber)?.uint16Value
        else { return nil }

        return VPhoneHostUSBDevice(
            locationID: loc,
            vendorID: vid,
            productID: pid,
            vendorName: props["USB Vendor Name"] as? String,
            productName: props["USB Product Name"] as? String
        )
    }

    /// Walk IOKit again and return a +1-retained io_service_t whose locationID matches.
    /// Caller must IOObjectRelease the returned value.
    private static func resolveService(forLocationID wanted: UInt32) -> io_service_t {
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else { return 0 }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iter) }

        while case let service = IOIteratorNext(iter), service != 0 {
            var locUnm: Unmanaged<CFTypeRef>?
            // Targeted property read — cheaper than CreateCFProperties.
            if let propRaw = IORegistryEntryCreateCFProperty(
                service, "locationID" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber {
                if propRaw.uint32Value == wanted {
                    return service // +1 retained — caller owns
                }
            }
            _ = locUnm
            IOObjectRelease(service)
        }
        return 0
    }

    // MARK: Attach / Detach state

    func isAttached(locationID: UInt32) -> Bool {
        attached[locationID] != nil
    }

    // MARK: Attach

    func attach(locationID: UInt32, completion: @escaping @MainActor (Error?) -> Void) {
        guard let controller else {
            completion(VPhoneUSBPassthroughError.noController)
            return
        }
        if attached[locationID] != nil {
            completion(VPhoneUSBPassthroughError.alreadyAttached)
            return
        }

        // Install delegate once — UTM does this before attach. The framework may
        // require a delegate to authorize the passthrough.
        installControllerDelegateIfNeeded(on: controller)

        let service = Self.resolveService(forLocationID: locationID)
        guard service != 0 else {
            completion(VPhoneUSBPassthroughError.serviceNotFound(locationID))
            return
        }
        defer { IOObjectRelease(service) }

        let cfgResult = Self.makeConfiguration(ioService: service)
        switch cfgResult {
        case let .failure(err):
            completion(err)
            return
        case let .success(cfg):
            let deviceObj: AnyObject
            switch Self.makeDevice(configuration: cfg) {
            case let .failure(err):
                completion(err)
                return
            case let .success(obj):
                deviceObj = obj
            }
            guard let usbDevice = deviceObj as? (any VZUSBDevice) else {
                completion(VPhoneUSBPassthroughError.deviceNotConforming)
                return
            }
            controller.attach(device: usbDevice) { err in
                if let nserr = err as NSError? {
                    print("[usb] controller.attach: domain=\(nserr.domain) code=\(nserr.code) userInfo=\(nserr.userInfo)")
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        if err == nil {
                            self?.attached[locationID] = usbDevice
                        }
                        completion(err)
                    }
                }
            }
        }
    }

    // MARK: Detach

    func detach(locationID: UInt32, completion: @escaping @MainActor (Error?) -> Void) {
        guard let controller else {
            completion(VPhoneUSBPassthroughError.noController)
            return
        }
        guard let device = attached[locationID] else {
            completion(VPhoneUSBPassthroughError.notAttached)
            return
        }
        controller.detach(device: device) { err in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if err == nil {
                        self?.attached.removeValue(forKey: locationID)
                    }
                    completion(err)
                }
            }
        }
    }

    // MARK: - Private VZ class wiring

    /// Install our delegate object on the live VZUSBController via the private
    /// `setDelegate:` selector. UTM does this before attach.
    private func installControllerDelegateIfNeeded(on controller: VZUSBController) {
        if delegateInstalled { return }
        let sel = NSSelectorFromString("setDelegate:")
        guard let method = class_getInstanceMethod(VZUSBController.self, sel) else {
            print("[usb] VZUSBController.setDelegate: missing — skipping delegate install")
            return
        }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        fn(controller, sel, controllerDelegate)
        delegateInstalled = true
        print("[usb] installed VZUSBController delegate")
    }

    /// Calls `[[_VZIOUSBHostPassthroughDeviceConfiguration alloc] initWithService:error:]`.
    /// UTM's PR #7635 uses this initializer rather than `+fromLocationID:error:`.
    private static func makeConfiguration(ioService: io_service_t) -> Result<AnyObject, Error> {
        guard let cls: AnyClass = NSClassFromString("_VZIOUSBHostPassthroughDeviceConfiguration")
        else {
            return .failure(VPhoneUSBPassthroughError.privateClassMissing(
                "_VZIOUSBHostPassthroughDeviceConfiguration"))
        }
        let initSel = NSSelectorFromString("initWithService:error:")
        guard let initMethod = class_getInstanceMethod(cls, initSel) else {
            return .failure(VPhoneUSBPassthroughError.privateSelectorMissing(
                "-initWithService:error:"))
        }

        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else {
            return .failure(VPhoneUSBPassthroughError.privateSelectorMissing("+alloc"))
        }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let allocFn = unsafeBitCast(method_getImplementation(allocMethod), to: AllocFn.self)
        guard let allocated = allocFn(cls, allocSel) else {
            return .failure(VPhoneUSBPassthroughError.configCreationFailed)
        }

        typealias InitFn = @convention(c) (
            Unmanaged<AnyObject>, Selector, io_service_t, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> Unmanaged<AnyObject>?
        let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self)

        var err: NSError? = nil
        guard let unmanagedCfg = initFn(allocated, initSel, ioService, &err) else {
            if let e = err {
                print("[usb] initWithService:error: domain=\(e.domain) code=\(e.code) userInfo=\(e.userInfo)")
            }
            return .failure(err ?? VPhoneUSBPassthroughError.configCreationFailed)
        }
        return .success(unmanagedCfg.takeRetainedValue())
    }

    /// Calls `[[_VZIOUSBHostPassthroughDevice alloc] initWithConfiguration:error:]`.
    private static func makeDevice(configuration: AnyObject) -> Result<AnyObject, Error> {
        guard let cls: AnyClass = NSClassFromString("_VZIOUSBHostPassthroughDevice") else {
            return .failure(VPhoneUSBPassthroughError.privateClassMissing(
                "_VZIOUSBHostPassthroughDevice"))
        }
        let initSel = NSSelectorFromString("initWithConfiguration:error:")
        guard let initMethod = class_getInstanceMethod(cls, initSel) else {
            return .failure(VPhoneUSBPassthroughError.privateSelectorMissing(
                "-initWithConfiguration:error:"))
        }

        let allocSel = NSSelectorFromString("alloc")
        guard let allocMethod = class_getClassMethod(cls, allocSel) else {
            return .failure(VPhoneUSBPassthroughError.privateSelectorMissing("+alloc"))
        }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let allocFn = unsafeBitCast(method_getImplementation(allocMethod), to: AllocFn.self)
        guard let allocated = allocFn(cls, allocSel) else {
            return .failure(VPhoneUSBPassthroughError.deviceConstructionFailed)
        }

        typealias InitFn = @convention(c) (
            Unmanaged<AnyObject>, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> Unmanaged<AnyObject>?
        let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self)

        var err: NSError? = nil
        guard let unmanagedResult = initFn(allocated, initSel, configuration, &err) else {
            if let e = err {
                print("[usb] initWithConfiguration:error: domain=\(e.domain) code=\(e.code) userInfo=\(e.userInfo)")
            }
            return .failure(err ?? VPhoneUSBPassthroughError.deviceConstructionFailed)
        }
        return .success(unmanagedResult.takeRetainedValue())
    }
}

// MARK: - Errors

enum VPhoneUSBPassthroughError: LocalizedError {
    case noController
    case alreadyAttached
    case notAttached
    case privateClassMissing(String)
    case privateSelectorMissing(String)
    case configCreationFailed
    case deviceConstructionFailed
    case deviceNotConforming
    case serviceNotFound(UInt32)

    var errorDescription: String? {
        switch self {
        case .noController: return "vm.usbControllers is empty — XHCI not wired into VM config"
        case .alreadyAttached: return "device already attached"
        case .notAttached: return "device is not attached"
        case let .privateClassMissing(name): return "private VZ class missing: \(name)"
        case let .privateSelectorMissing(name): return "private VZ selector missing: \(name)"
        case .configCreationFailed: return "configuration creation failed"
        case .deviceConstructionFailed: return "_VZIOUSBHostPassthroughDevice init failed"
        case .deviceNotConforming: return "constructed object does not conform to VZUSBDevice"
        case let .serviceNotFound(loc): return "no IOUSBDevice found for locationID 0x\(String(loc, radix: 16))"
        }
    }
}
