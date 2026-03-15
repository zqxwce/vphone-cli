// KernelJBPatchVmProtect.swift — JB kernel patch: VM map protect bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Skip the vm_map_protect write-downgrade gate.
    ///
    /// Source-backed anchor: recover the function from the in-kernel
    /// `vm_map_protect(` panic string, then find the unique local block matching:
    ///
    ///     mov wMask, #6
    ///     bics wzr, wMask, wProt
    ///     b.ne skip
    ///     tbnz wEntryFlags, #22, skip
    ///     ...
    ///     and wProt, wProt, #~VM_PROT_WRITE
    ///
    /// Rewriting `b.ne` to unconditional `b` always skips the downgrade block.
    @discardableResult
    func patchVmMapProtect() -> Bool {
        log("\n[JB] _vm_map_protect: skip write-downgrade gate")

        // Find function via "vm_map_protect(" string
        guard let strOff = buffer.findString("vm_map_protect(") else {
            log("  [-] kernel-text 'vm_map_protect(' anchor not found")
            return false
        }
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty, let funcStart = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] kernel-text 'vm_map_protect(' anchor not found")
            return false
        }
        let funcEnd = findFuncEnd(funcStart, maxSize: 0x2000)

        guard let gate = findWriteDowngradeGate(start: funcStart, end: funcEnd) else {
            log("  [-] vm_map_protect write-downgrade gate not found")
            return false
        }

        let (brOff, target) = gate
        guard let bBytes = encodeB(from: brOff, to: target) else {
            log("  [-] branch rewrite out of range")
            return false
        }

        let va = fileOffsetToVA(brOff)
        let delta = target - brOff
        emit(brOff, bBytes,
             patchID: "kernelcache_jb.vm_map_protect",
             virtualAddress: va,
             description: "b #0x\(String(format: "%X", delta)) [_vm_map_protect]")
        return true
    }

    // MARK: - Private helpers

    /// Find the `b.ne` instruction address and its target in the write-downgrade block.
    private func findWriteDowngradeGate(start: Int, end: Int) -> (brOff: Int, target: Int)? {
        let wZrReg: aarch64_reg = AARCH64_REG_WZR

        var hits: [(Int, Int)] = []
        var off = start
        while off + 0x10 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 4)
            guard insns.count >= 4 else { off += 4; continue }
            let movMask = insns[0], bicsInsn = insns[1], bneInsn = insns[2], tbnzInsn = insns[3]

            // mov wMask, #6
            guard movMask.mnemonic == "mov",
                  let movOps = movMask.aarch64?.operands, movOps.count == 2,
                  movOps[0].type == AARCH64_OP_REG,
                  movOps[1].type == AARCH64_OP_IMM, movOps[1].imm == 6
            else { off += 4; continue }
            let maskReg = movOps[0].reg

            // bics wzr, wMask, wProt
            guard bicsInsn.mnemonic == "bics",
                  let bicsOps = bicsInsn.aarch64?.operands, bicsOps.count == 3,
                  bicsOps[0].type == AARCH64_OP_REG, bicsOps[0].reg == wZrReg,
                  bicsOps[1].type == AARCH64_OP_REG, bicsOps[1].reg == maskReg,
                  bicsOps[2].type == AARCH64_OP_REG
            else { off += 4; continue }
            let protReg = bicsOps[2].reg

            // b.ne <skip>
            guard bneInsn.mnemonic == "b.ne",
                  let bneOps = bneInsn.aarch64?.operands, bneOps.count == 1,
                  bneOps[0].type == AARCH64_OP_IMM
            else { off += 4; continue }
            let skipTarget = Int(bneOps[0].imm)
            guard skipTarget > Int(bneInsn.address) else { off += 4; continue }

            // tbnz wEntryFlags, #22, <skip>
            guard tbnzInsn.mnemonic == "tbnz",
                  let tbnzOps = tbnzInsn.aarch64?.operands, tbnzOps.count == 3,
                  tbnzOps[0].type == AARCH64_OP_REG,
                  tbnzOps[1].type == AARCH64_OP_IMM, tbnzOps[1].imm == 22,
                  tbnzOps[2].type == AARCH64_OP_IMM, Int(tbnzOps[2].imm) == skipTarget
            else { off += 4; continue }

            // Verify there's an `and wProt, wProt, #~2` between tbnz+4 and target
            let searchStart = Int(tbnzInsn.address) + 4
            let searchEnd = min(skipTarget, end)
            guard findWriteClearBetween(start: searchStart, end: searchEnd, protReg: protReg) != nil
            else { off += 4; continue }

            // bneInsn.address is a virtual-like address (== file offset here)
            let bneFileOff = Int(bneInsn.address)
            hits.append((bneFileOff, skipTarget))
            off += 4
        }

        return hits.count == 1 ? hits[0] : nil
    }

    /// Scan [start, end) for `and wProt, wProt, #imm` where imm clears bit 1 (VM_PROT_WRITE).
    private func findWriteClearBetween(start: Int, end: Int, protReg: aarch64_reg) -> Int? {
        var off = start
        while off < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first else { off += 4; continue }
            if insn.mnemonic == "and",
               let ops = insn.aarch64?.operands, ops.count == 3,
               ops[0].type == AARCH64_OP_REG, ops[0].reg == protReg,
               ops[1].type == AARCH64_OP_REG, ops[1].reg == protReg,
               ops[2].type == AARCH64_OP_IMM
            {
                let imm = UInt32(bitPattern: Int32(truncatingIfNeeded: ops[2].imm)) & 0xFFFF_FFFF
                // Clears bit 1 (VM_PROT_WRITE=2), keeps bit 0 (VM_PROT_READ=1)
                if (imm & 0x7) == 0x3 {
                    return off
                }
            }
            off += 4
        }
        return nil
    }
}
