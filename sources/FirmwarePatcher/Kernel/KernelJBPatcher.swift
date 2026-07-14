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
