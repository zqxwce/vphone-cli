// KernelJBPatchProcPidinfo.swift — JB: NOP the two pid-0 guards in proc_pidinfo.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal: shared _proc_info switch-table anchor → function prologue (first 0x80 bytes) →
//   precise 4-insn pattern: ldr x0,[x0,#0x18] ; cbz x0,fail ; bl ... ; cbz/cbnz wN,fail.
// Patch: NOP the two cbz/cbnz guards (instructions at +4 and +12 of the pattern).

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Bypass the two early pid-0/proc-null guards in proc_pidinfo.
    @discardableResult
    func patchProcPidinfo() -> Bool {
        log("\n[JB] _proc_pidinfo: NOP pid-0 guard (2 sites)")

        guard let (procInfoFunc, _) = findProcInfoAnchor() else {
            log("  [-] _proc_info function not found")
            return false
        }

        var firstGuard: Int?
        var secondGuard: Int?

        let prologueEnd = min(procInfoFunc + 0x80, buffer.count)
        var off = procInfoFunc
        while off + 16 <= prologueEnd {
            defer { off += 4 }

            let insns = disasm.disassemble(in: buffer.data, at: off, count: 4)
            guard insns.count >= 4 else { continue }
            let i0 = insns[0], i1 = insns[1], i2 = insns[2], i3 = insns[3]

            // Pattern: ldr x0, [x0, #0x18]
            guard i0.mnemonic == "ldr",
                  i0.operandString.hasPrefix("x0, [x0, #0x18]") else { continue }
            // cbz x0, <label>
            guard i1.mnemonic == "cbz",
                  i1.operandString.hasPrefix("x0, ") else { continue }
            // bl <target>
            guard i2.mnemonic == "bl" else { continue }
            // cbz/cbnz wN, <label>
            guard i3.mnemonic == "cbz" || i3.mnemonic == "cbnz",
                  i3.operandString.hasPrefix("w") else { continue }

            firstGuard = off + 4 // cbz x0
            secondGuard = off + 12 // cbz/cbnz wN
            break
        }

        guard let guardA = firstGuard, let guardB = secondGuard else {
            log("  [-] precise proc_pidinfo guard pair not found")
            return false
        }

        emit(guardA, ARM64.nop,
             patchID: "jb.proc_pidinfo.nop_guard_a",
             virtualAddress: fileOffsetToVA(guardA),
             description: "NOP [_proc_pidinfo pid-0 guard A]")
        emit(guardB, ARM64.nop,
             patchID: "jb.proc_pidinfo.nop_guard_b",
             virtualAddress: fileOffsetToVA(guardB),
             description: "NOP [_proc_pidinfo pid-0 guard B]")
        return true
    }
}
