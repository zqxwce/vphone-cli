// KernelJBPatcher.swift — JB kernel patcher orchestrator.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

/// JB kernel patcher: 84 patches across 3 groups.
///
/// Group A: Core gate-bypass methods (5 patches)
/// Group B: Pattern/string anchored methods (16 patches)
/// Group C: Shellcode/trampoline heavy methods (4 patches)
public final class KernelJBPatcher: KernelJBPatcherBase, Patcher {
    public let component = "kernelcache_jb"

    /// Gates the iOS-27-only kernel patches. These target an iOS-27 userland running
    /// on the 26.4 kernel; on a 26.x base they are unnecessary and some are actively
    /// harmful (e.g. the IOMFB SwapEnd size gate would reject 26.x's native 0x588 swap
    /// struct → dead display, the 26.5 regression). The pipeline sets this from the
    /// iPhone base ProductVersion (false for 18.x/26.x → byte-identical to pre-branch);
    /// standalone patch-component defaults it true so the dev tool exercises the full
    /// set (override with --target-os).
    public var applyIOS27 = false

    public func findAll() throws -> [PatchRecord] {
        try parseMachO()
        buildADRPIndex()
        buildBLIndex()
        buildSymbolTable()
        findPanic()

        // Group A
        patchAmfiCdhashInTrustcache()
        patchTaskConversionEvalInternal()
        patchSandboxHooksExtended()
        patchIoucFailedMacf()
        // iOS 27 userland on the 26.4 kernel: the IOKit user-client open path's
        // Sandbox gate (separate from the MACF gate above) spuriously denies the
        // render server (backboardd) its IOMobileFramebuffer/IOSurface/HID user
        // clients → no present (no Apple logo) + nil main display (SpringBoard
        // crash-loop). Bypass it, mirroring the MACF gate. No-op where the gate
        // already allows (native 26.x userlands).
        patchIoucFailedSandbox()

        // Group B
        patchPostValidationAdditional()
        patchProcSecurityPolicy()
        patchProcPidinfo()
        patchConvertPortToMap()
        patchBsdInitAuth()
        patchDounmount()
        patchIoSecureBsdRoot()
        patchLoadDylinker()
        patchMacMount()
        patchNvramVerifyPermission()
        patchSharedRegionMap()
        patchSpawnValidatePersona()
        patchTaskForPid()
        patchThidShouldCrash()
        patchVmFaultEnterPrepare()
        patchVmMapProtect()

        // Group C
        patchCredLabelUpdateExecve()
        patchHookCredLabelUpdateExecve()
        patchKcall10()
        patchSyscallmaskApplyToProc()

        // Neutralize the exec-time ip_mac_return SECURITY_POLICY kill so a userland
        // newer than the kernel (iOS 27 on the 26.4 kernel) can launch: AMFI's exec
        // hooks reject the newer binaries' validation category → ip_mac_return != 0 →
        // core daemons (backboardd, cfprefsd, ...) die at exec → boot deadlock.
        // No-op-in-effect for version-matched userlands (ip_mac_return == 0 there).
        patchExecSecurityPolicyKill()

        // DISABLED (kept off): these three were an earlier, WRONG theory that the
        // iOS-27 black screen was an IOMFB SwapEnd size/struct ABI issue. Root
        // cause is actually the IOUC *sandbox* gate denying backboardd the
        // framebuffer — fixed by patchIoucFailedSandbox() above. Leave these off:
        //  - patchParavirtDisplayPrimary sets the display's "primary" property=1,
        //    which iOS 27 turns into the device NAME suffix ("primary-1"), which
        //    then fails the render server's exact name match → HARMFUL.
        //  - the SwapEnd patches target a present path iOS 27 never takes (method
        //    5 is never called) and would break 26.x's native 0x588 SwapEnd.
        //
        // Publish the VM's single paravirt display as primary=1 so iOS 27's
        // FBSDisplayMonitor finds a main display (else SpringBoard crash-loops on a
        // nil mainDisplay assertion → black screen). Harmless for iOS 26.x bases.
        // patchParavirtDisplayPrimary()

        // Accept iOS 27's native 0x6e0 IOMFBSwapRec (variable-size dispatch)
        // instead of truncating userland to 0x588 (which misaligns 27's layout).
        // Paired with leaving iOS 27 userland at native size (cfw_install gate).
        // patchIomfbSwapEndVariableSize()
        // The handler has a SECOND internal exact-size gate (cmp w2,#0x588) beyond
        // the dispatch check; retarget it to iOS 27's 0x6e0 so the native struct
        // reaches the real swap processing.
        // patchIomfbSwapEndHandlerSize()

        return patches
    }

    public func apply() throws -> Int {
        let records = try (patches.isEmpty ? findAll() : patches)
        for record in records {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
        return records.count
    }
}
