// KernelJBPatchMacMount.swift — JB kernel patch: MAC mount bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Apply the upstream twin bypasses in the mount-role wrapper.
    ///
    /// Patches two sites in the wrapper that decides whether execution can
    /// continue into `mount_common()`:
    ///   - `tbnz wFlags, #5, deny` → NOP
    ///   - `ldrb w8, [xTmp, #1]`   → `mov x8, xzr`
    ///
    /// Runtime design:
    ///   1. Recover `mount_common` from the `"mount_common()"` string.
    ///   2. Scan a bounded neighborhood for local callers.
    ///   3. Select the unique caller containing both upstream gates.
    @discardableResult
    func patchMacMount() -> Bool {
        log("\n[JB] ___mac_mount: upstream twin bypass")

        guard let strOff = buffer.findString("mount_common()") else {
            log("  [-] mount_common anchor function not found")
            return false
        }
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty, let mountCommon = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] mount_common anchor function not found")
            return false
        }

        // Scan +/-0x5000 of mount_common for callers in code ranges
        let searchStart = max(codeRanges.first?.start ?? 0, mountCommon - 0x5000)
        let searchEnd = min(codeRanges.first?.end ?? buffer.count, mountCommon + 0x5000)

        var candidates: [Int: (Int, Int)] = [:] // caller → (flagGate, stateGate)
        var off = searchStart
        while off < searchEnd {
            guard let blTarget = decodeBLat(off), blTarget == mountCommon else { off += 4; continue }
            guard let caller = findFunctionStart(off), caller != mountCommon,
                  candidates[caller] == nil
            else { off += 4; continue }
            let callerEnd = findFuncEnd(caller, maxSize: 0x1200)
            if let sites = matchUpstreamMountWrapper(start: caller, end: callerEnd, mountCommon: mountCommon) {
                candidates[caller] = sites
            }
            off += 4
        }

        guard candidates.count == 1 else {
            log("  [-] expected 1 upstream mac_mount candidate, found \(candidates.count)")
            return false
        }

        let (branchOff, movOff) = candidates.values.first!
        let va1 = fileOffsetToVA(branchOff)
        let va2 = fileOffsetToVA(movOff)
        emit(branchOff, ARM64.nop,
             patchID: "kernelcache_jb.mac_mount.flag_gate",
             virtualAddress: va1,
             description: "NOP [___mac_mount upstream flag gate]")
        emit(movOff, ARM64.movX8Xzr,
             patchID: "kernelcache_jb.mac_mount.state_clear",
             virtualAddress: va2,
             description: "mov x8,xzr [___mac_mount upstream state clear]")
        return true
    }

    // MARK: - Private helpers

    private func matchUpstreamMountWrapper(start: Int, end: Int, mountCommon: Int) -> (Int, Int)? {
        // Collect all BL-to-mount_common call sites
        var callSites: [Int] = []
        for off in stride(from: start, to: end, by: 4) {
            if decodeBLat(off) == mountCommon { callSites.append(off) }
        }
        guard !callSites.isEmpty else { return nil }

        guard let flagGate = findFlagGate(start: start, end: end) else { return nil }
        guard let stateGate = findStateGate(start: start, end: end, callSites: callSites) else { return nil }
        return (flagGate, stateGate)
    }

    /// Find a unique `tbnz wN, #5, <deny>` where deny-block starts with `mov w?, #1`.
    private func findFlagGate(start: Int, end: Int) -> Int? {
        var hits: [Int] = []
        var off = start
        while off + 4 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first else { off += 4; continue }
            guard insn.mnemonic == "tbnz",
                  let ops = insn.aarch64?.operands, ops.count == 3,
                  ops[0].type == AARCH64_OP_REG,
                  ops[1].type == AARCH64_OP_IMM, ops[1].imm == 5,
                  ops[2].type == AARCH64_OP_IMM
            else { off += 4; continue }

            // Check register is a w-register
            let regName = insn.operandString.components(separatedBy: ",").first?
                .trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
            guard regName.hasPrefix("w") else { off += 4; continue }

            let target = Int(ops[2].imm)
            guard target >= start, target < end else { off += 4; continue }

            // Target must start with `mov w?, #1`
            let targetInsns = disasm.disassemble(in: buffer.data, at: target, count: 1)
            guard let tInsn = targetInsns.first,
                  tInsn.mnemonic == "mov",
                  let tOps = tInsn.aarch64?.operands, tOps.count == 2,
                  tOps[0].type == AARCH64_OP_REG,
                  tOps[1].type == AARCH64_OP_IMM, tOps[1].imm == 1
            else { off += 4; continue }
            let tRegName = tInsn.operandString.components(separatedBy: ",").first?
                .trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
            guard tRegName.hasPrefix("w") else { off += 4; continue }

            hits.append(off)
            off += 4
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Find `add x?, x?, #0x70 / ldrb w8, [x?, #1] / tbz w8, #6, <near call>`
    private func findStateGate(start: Int, end: Int, callSites: [Int]) -> Int? {
        var hits: [Int] = []
        var off = start
        while off + 8 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 3)
            guard insns.count >= 3 else { off += 4; continue }
            let addInsn = insns[0], ldrInsn = insns[1], tbzInsn = insns[2]

            // add xD, xS, #0x70
            guard addInsn.mnemonic == "add",
                  let addOps = addInsn.aarch64?.operands, addOps.count == 3,
                  addOps[0].type == AARCH64_OP_REG,
                  addOps[1].type == AARCH64_OP_REG,
                  addOps[2].type == AARCH64_OP_IMM, addOps[2].imm == 0x70
            else { off += 4; continue }
            let addDst = addOps[0].reg
            let addDstName = addInsn.operandString.components(separatedBy: ",").first?
                .trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
            guard addDstName.hasPrefix("x") else { off += 4; continue }

            // ldrb w8, [xDst, #1]
            guard ldrInsn.mnemonic == "ldrb",
                  let ldrOps = ldrInsn.aarch64?.operands, ldrOps.count >= 2,
                  ldrOps[0].type == AARCH64_OP_REG,
                  ldrOps[1].type == AARCH64_OP_MEM,
                  ldrOps[1].mem.base == addDst,
                  ldrOps[1].mem.disp == 1
            else { off += 4; continue }
            let ldrDstReg = ldrOps[0].reg
            let ldrDstName = ldrInsn.operandString.components(separatedBy: ",").first?
                .trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
            guard ldrDstName.hasPrefix("w") else { off += 4; continue }

            // tbz wLdr, #6, <target near a call>
            guard tbzInsn.mnemonic == "tbz",
                  let tbzOps = tbzInsn.aarch64?.operands, tbzOps.count == 3,
                  tbzOps[0].type == AARCH64_OP_REG, tbzOps[0].reg == ldrDstReg,
                  tbzOps[1].type == AARCH64_OP_IMM, tbzOps[1].imm == 6,
                  tbzOps[2].type == AARCH64_OP_IMM
            else { off += 4; continue }
            let tbzTarget = Int(tbzOps[2].imm)
            guard callSites.contains(where: { tbzTarget <= $0 && $0 <= tbzTarget + 0x80 }) else {
                off += 4; continue
            }

            hits.append(Int(ldrInsn.address))
            off += 4
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Decode a BL instruction at `off`, returning the target file offset or nil.
    private func decodeBLat(_ off: Int) -> Int? {
        guard off + 4 <= buffer.count else { return nil }
        let insn = buffer.readU32(at: off)
        guard insn >> 26 == 0b100101 else { return nil }
        let imm26 = insn & 0x03FF_FFFF
        let signedImm = Int32(bitPattern: imm26 << 6) >> 6
        return off + Int(signedImm) * 4
    }
}
