import Darwin
import Foundation
import MachO

/// In-process byte patches to Virtualization.framework.
///
/// VZ refuses to instantiate `_VZIOUSBHostPassthroughDeviceConfiguration` for
/// devices with isochronous endpoints (audio class, video class, MIDI). The
/// check is performed by `usb_device_service_has_isochronous_endpoints` in the
/// framework — a C++ free function called from
/// `-[_VZIOUSBHostPassthroughDeviceConfiguration _validateWithError:]`. The
/// validate method is not on the class's ObjC method list, so it can't be
/// swizzled. We patch the function body in our process-local copy of the
/// framework instead, using a copy-on-write page replacement so other
/// processes' VZ instances are unaffected.
///
/// Caveat: bypassing the guard does not give VZ the capability to actually
/// transport isochronous transfers — guest enumeration may succeed but data
/// flow may not. Useful for research and to see how far the device gets.
enum VPhoneVZPatches {
    private static let frameworkPath =
        "/System/Library/Frameworks/Virtualization.framework/Versions/A/Virtualization"

    /// Unsliced vmaddr of `usb_device_service_has_isochronous_endpoints` in
    /// Virtualization.framework (arm64e, macOS 26.x). Verified by disassembly.
    private static let isoCheckVmaddr: UInt = 0x22cff2a00

    // Idempotency flag. Called only from @MainActor contexts; concurrency-safe in practice.
    nonisolated(unsafe) private static var didPatchIsoCheck = false

    /// Replace the iso-endpoint check with a stub that always returns 0x100
    /// (= "descriptor read succeeded, no isochronous endpoint found").
    /// Safe to call multiple times; the patch is applied at most once.
    static func disableIsochronousEndpointCheck() {
        if didPatchIsoCheck { return }

        var slide: Int = 0
        var found = false
        for i in 0..<_dyld_image_count() {
            guard let cname = _dyld_get_image_name(i) else { continue }
            if String(cString: cname) == frameworkPath {
                slide = _dyld_get_image_vmaddr_slide(i)
                found = true
                break
            }
        }
        guard found else {
            print("[vz-patch] Virtualization.framework not loaded — skipping iso patch")
            return
        }

        let target = isoCheckVmaddr &+ UInt(bitPattern: slide)
        print("[vz-patch] iso-check fn @ 0x\(String(target, radix: 16)) (slide=0x\(String(slide, radix: 16)))")

        // ARM64e replacement (12 bytes, preserves PAC/BTI safety):
        //   pacibsp           0xd503237f  ; sign LR (BTI landing pad equivalent)
        //   mov   w0, #0x100  0x52802000  ; return 0x100 — "no iso found"
        //   retab             0xd65f0fff  ; authenticate + return
        let instrs: [UInt32] = [0xd503237f, 0x52802000, 0xd65f0fff]

        // Apple Silicon page size is 16KB; macOS x86_64 is 4KB. Use 16KB as
        // an over-aligned, conservative bound that works on both.
        let pageSize: UInt = 16 * 1024
        let pageMask = pageSize &- 1
        let pageStart = target & ~pageMask
        let pageEnd = (target &+ UInt(instrs.count * 4) &+ pageMask) & ~pageMask
        let size = mach_vm_size_t(pageEnd - pageStart)

        // VM_PROT_COPY (0x10) makes the kernel create a copy-on-write private
        // page so our write doesn't affect the shared framework image.
        let VM_PROT_COPY: vm_prot_t = 0x10
        let rwc: vm_prot_t = VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
        let kr1 = mach_vm_protect(mach_task_self_, mach_vm_address_t(pageStart), size, 0, rwc)
        guard kr1 == KERN_SUCCESS else {
            print("[vz-patch] mach_vm_protect(RW|COPY) failed: kr=\(kr1) \(String(cString: mach_error_string(kr1)))")
            return
        }

        instrs.withUnsafeBufferPointer { buf in
            _ = memcpy(UnsafeMutableRawPointer(bitPattern: target), buf.baseAddress, buf.count * MemoryLayout<UInt32>.size)
        }

        let rx: vm_prot_t = VM_PROT_READ | VM_PROT_EXECUTE
        let kr2 = mach_vm_protect(mach_task_self_, mach_vm_address_t(pageStart), size, 0, rx)
        if kr2 != KERN_SUCCESS {
            print("[vz-patch] mach_vm_protect(RX) restore failed: kr=\(kr2) — page remains writable")
        }

        // Verify
        let ptr = UnsafePointer<UInt32>(bitPattern: target)!
        let actual = (0..<instrs.count).map { ptr[$0] }
        if actual == instrs {
            print("[vz-patch] iso-check disabled in-process (overwrote 12 bytes)")
            didPatchIsoCheck = true
        } else {
            let hex = actual.map { String(format: "0x%08x", $0) }.joined(separator: " ")
            print("[vz-patch] verify FAILED — bytes at target: \(hex)")
        }
    }
}
