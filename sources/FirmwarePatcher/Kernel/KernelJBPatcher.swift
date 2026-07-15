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

        // Force the sandbox exec-time container-manager upcall onto its success path.
        // iOS 27 deleted the kernel-side containermanagerd upcall (no HOST_CONTAINERD_PORT
        // / CM_KERN_* in the stock 27 kernel), so on the 26.4 kernel the upcall fails for
        // every 27 platform app → they are autoboxed into `temporary-sandbox`, which denies
        // backboard.display.services → Campo (wallpaper) crash-loops, + intelligencetasksd/
        // feedbackd. Flip the `cbz w0,<success>` guard to `b <success>` so a failed upcall
        // takes the success path instead of autobox/kill. No-op-in-effect for version-matched
        // userlands (there the upcall succeeds, so cbz already branches to <success>).
        patchContainerManagerUpcall()

        // DISABLED (kept off): patchParavirtDisplayPrimary was a wrong theory —
        // setting the display's "primary" property=1 makes iOS 27 append it as the
        // device NAME suffix ("primary-1"), which then fails the render server's
        // exact name match → HARMFUL. The nil-mainDisplay crash it targeted is
        // actually fixed by patchIoucFailedSandbox() above.
        // patchParavirtDisplayPrimary()

        // iOS 27 VZ-view (host paravirt-GPU scanout) fix — kernel half of the
        // "force the kern present path" pair:
        //
        // The 26.4 kernel's paravirt GPU only scans a frame out to the host when
        // the guest presents via the IOMFB userclient SwapEnd (external method 5).
        // iOS 27 defaults the paravirt display's present to IOMFB's parallel
        // `_virt_*` path (an in-process callback that never enters the userclient),
        // so the paravirt GPU never scans out → host VZ window is black (the guest
        // still composites; visible over in-guest TrollVNC). cfw_patch_iomfb_force_kern
        // (userland half) retargets IOMFB's public `_IOMobileFramebufferSwap*`
        // trampolines to `_kern_Swap*`, forcing present back onto method 5. But
        // iOS 27's native SwapEnd struct is 0x6e0 bytes (26.x sent 0x588), and the
        // 26.4 userclient exact-checks 0x588 in TWO places, so method 5 would return
        // kIOReturnBadArgument. These two patches relax both size gates to accept
        // 27's 0x6e0 (its IOMFBSwapRec prefix matches 26.x, so the paravirt swap
        // handler reads valid fields):
        //  1. dispatch-table checkStructureInputSize 0x588 → variable
        patchIomfbSwapEndVariableSize()
        //  2. the handler's internal `cmp w2,#0x588` gate → 0x6e0
        patchIomfbSwapEndHandlerSize()

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
