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

    /// Unsliced vmaddr of
    /// `VzCore::Hardware::Usb::usb_device_service_has_isochronous_endpoints(Base::IoService const&)`
    /// in Virtualization.framework (arm64e). Resolved from the framework's
    /// LC_SYMTAB local-symbol entry
    /// `__ZN6VzCore8Hardware3Usb44usb_device_service_has_isochronous_endpointsERKN4Base9IoServiceE`
    /// in the macOS 27.0 (Virtualization 304.0.1) dyld shared cache. The check
    /// still gates the passthrough config validation path (two callers on 27.0).
    /// macOS 26.x used 0x22cff2a00; re-reveal via LC_SYMTAB on each major OS
    /// bump (procedure in research/virtualization_framework_27_vs_2651.md). The
    /// `isoCheckExpectedPrologue` guard below refuses to patch unless the live
    /// bytes match, so a stale address after an OS update fails safe instead of
    /// corrupting the shared framework image.
    private static let isoCheckVmaddr: UInt = 0x222f720cc

    /// First 3 instruction words of the unpatched iso-check function on 27.0
    /// (`pacibsp` / `sub sp, sp, #0x70` / `stp x22, x21, [sp, #0x40]`). The patch
    /// only proceeds if the live bytes match — version drift then fails safe.
    private static let isoCheckExpectedPrologue: [UInt32] = [0xd503237f, 0xd101c3ff, 0xa90457f6]

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

        // Fail-safe: only patch if the live bytes match the known iso-check
        // prologue. Guards against a stale isoCheckVmaddr after an OS update
        // writing the stub into the wrong place (which would corrupt the shared
        // framework image). Reading r-x framework text directly is fine.
        guard let probe = UnsafePointer<UInt32>(bitPattern: target) else {
            print("[vz-patch] iso-check target address invalid — skipping")
            return
        }
        let live = (0..<isoCheckExpectedPrologue.count).map { probe[$0] }
        if live != isoCheckExpectedPrologue {
            let hex = live.map { String(format: "0x%08x", $0) }.joined(separator: " ")
            print("[vz-patch] iso-check prologue mismatch (got \(hex)) — skipping (address stale for this build?)")
            return
        }

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
