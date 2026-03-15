// KernelJBPatchSpawnPersona.swift — JB kernel patch: Spawn validate persona bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// NOP the upstream dual-CBZ bypass in the persona helper.
    ///
    /// 1. Recover the outer spawn policy function from
    ///    `com.apple.private.spawn-panic-crash-behavior`.
    /// 2. Enumerate its local BL callees.
    /// 3. Choose the unique small callee whose local CFG matches:
    ///    `ldr [arg,#8] ; cbz deny ; ldr [arg,#0xc] ; cbz deny`.
    /// 4. NOP both `cbz` guards.
    @discardableResult
    func patchSpawnValidatePersona() -> Bool {
        log("\n[JB] _spawn_validate_persona: upstream dual-CBZ bypass")

        guard let strOff = buffer.findString("com.apple.private.spawn-panic-crash-behavior") else {
            log("  [-] spawn entitlement anchor not found")
            return false
        }
        let refs = findStringRefs(strOff)
        guard !refs.isEmpty, let anchorFunc = findFunctionStart(refs[0].adrpOff) else {
            log("  [-] spawn entitlement anchor not found")
            return false
        }
        let anchorEnd = findFuncEnd(anchorFunc, maxSize: 0x4000)

        guard let sites = findUpstreamPersonaCbzSites(anchorStart: anchorFunc, anchorEnd: anchorEnd) else {
            log("  [-] upstream persona helper not found from string anchor")
            return false
        }

        let (firstCbz, secondCbz) = sites
        let va1 = fileOffsetToVA(firstCbz)
        let va2 = fileOffsetToVA(secondCbz)
        emit(firstCbz, ARM64.nop,
             patchID: "kernelcache_jb.spawn_validate_persona.cbz1",
             virtualAddress: va1,
             description: "NOP [_spawn_validate_persona pid-slot guard]")
        emit(secondCbz, ARM64.nop,
             patchID: "kernelcache_jb.spawn_validate_persona.cbz2",
             virtualAddress: va2,
             description: "NOP [_spawn_validate_persona persona-slot guard]")
        return true
    }

    // MARK: - Private helpers

    private func findUpstreamPersonaCbzSites(anchorStart: Int, anchorEnd: Int) -> (Int, Int)? {
        var matches: [(Int, Int)] = []
        var seen = Set<Int>()

        for off in stride(from: anchorStart, to: anchorEnd, by: 4) {
            guard let blTarget = decodeBL(at: off), !seen.contains(blTarget) else { continue }
            guard jbIsInCodeRange(blTarget) else { continue }
            seen.insert(blTarget)
            let callee_end = findFuncEnd(blTarget, maxSize: 0x400)
            if let sites = matchPersonaHelper(start: blTarget, end: callee_end) {
                matches.append(sites)
            }
        }

        if matches.count == 1 { return matches[0] }
        if !matches.isEmpty {
            let list = matches.map { String(format: "0x%X/0x%X", $0.0, $0.1) }.joined(separator: ", ")
            log("  [-] ambiguous persona helper candidates: \(list)")
        }
        return nil
    }

    /// Match the upstream shape:
    ///   ldr wA, [x0, #8]
    ///   cbz wA, deny
    ///   ldr wB, [x0, #0xc]
    ///   cbz wB, deny
    ///   mov x?, #0
    ///   ldr x?, [x?, #0x490]
    private func matchPersonaHelper(start: Int, end: Int) -> (Int, Int)? {
        var hits: [(Int, Int)] = []
        var off = start
        while off + 0x14 < end {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 6)
            guard insns.count >= 6 else { off += 4; continue }
            let i0 = insns[0], i1 = insns[1], i2 = insns[2]
            let i3 = insns[3], i4 = insns[4], i5 = insns[5]

            // ldr wA, [base, #8]
            guard isLdrMem(i0, disp: 8) else { off += 4; continue }
            guard let i0ops = i0.aarch64?.operands, i0ops.count >= 2 else { off += 4; continue }
            let loadedReg0 = i0ops[0].reg
            let baseReg = i0ops[1].mem.base

            // cbz wA, deny
            guard isCbzWSameReg(i1, reg: loadedReg0) else { off += 4; continue }

            // ldr wB, [base, #0xc]
            guard isLdrMemSameBase(i2, base: baseReg, disp: 0xC) else { off += 4; continue }
            guard let i2ops = i2.aarch64?.operands, i2ops.count >= 1 else { off += 4; continue }
            let loadedReg2 = i2ops[0].reg

            // cbz wB, deny (same deny target)
            guard isCbzWSameReg(i3, reg: loadedReg2) else { off += 4; continue }
            guard let i1ops = i1.aarch64?.operands, i1ops.count == 2,
                  let i3ops = i3.aarch64?.operands, i3ops.count == 2,
                  i1ops[1].type == AARCH64_OP_IMM, i3ops[1].type == AARCH64_OP_IMM,
                  i1ops[1].imm == i3ops[1].imm
            else { off += 4; continue }
            let denyTarget = Int(i1ops[1].imm)

            // Deny block must look like `mov w0, #1`
            guard looksLikeErrnoReturn(target: denyTarget, value: 1) else { off += 4; continue }

            // mov x?, #0
            guard isMovXImmZero(i4) else { off += 4; continue }

            // ldr x?, [x?, #0x490]
            guard isLdrMem(i5, disp: 0x490) else { off += 4; continue }

            hits.append((Int(i1.address), Int(i3.address)))
            off += 4
        }

        return hits.count == 1 ? hits[0] : nil
    }

    private func isLdrMem(_ insn: Instruction, disp: Int32) -> Bool {
        guard insn.mnemonic == "ldr",
              let ops = insn.aarch64?.operands, ops.count >= 2,
              ops[0].type == AARCH64_OP_REG,
              ops[1].type == AARCH64_OP_MEM,
              ops[1].mem.disp == disp
        else { return false }
        return true
    }

    private func isLdrMemSameBase(_ insn: Instruction, base: aarch64_reg, disp: Int32) -> Bool {
        guard isLdrMem(insn, disp: disp),
              let ops = insn.aarch64?.operands, ops.count >= 2,
              ops[1].mem.base == base
        else { return false }
        return true
    }

    private func isCbzWSameReg(_ insn: Instruction, reg: aarch64_reg) -> Bool {
        guard insn.mnemonic == "cbz",
              let ops = insn.aarch64?.operands, ops.count == 2,
              ops[0].type == AARCH64_OP_REG, ops[0].reg == reg,
              ops[1].type == AARCH64_OP_IMM
        else { return false }
        // Must be a w-register
        let name = insn.operandString.components(separatedBy: ",").first?
            .trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
        return name.hasPrefix("w")
    }

    private func isMovXImmZero(_ insn: Instruction) -> Bool {
        guard insn.mnemonic == "mov",
              let ops = insn.aarch64?.operands, ops.count == 2,
              ops[0].type == AARCH64_OP_REG,
              ops[1].type == AARCH64_OP_IMM, ops[1].imm == 0
        else { return false }
        let name = insn.operandString.components(separatedBy: ",").first?
            .trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
        return name.hasPrefix("x")
    }

    private func looksLikeErrnoReturn(target: Int, value: Int64) -> Bool {
        guard target >= 0, target + 4 <= buffer.count else { return false }
        let insns = disasm.disassemble(in: buffer.data, at: target, count: 1)
        guard let insn = insns.first else { return false }
        return isMovWImmValue(insn, imm: value)
    }

    private func isMovWImmValue(_ insn: Instruction, imm: Int64) -> Bool {
        guard insn.mnemonic == "mov",
              let ops = insn.aarch64?.operands, ops.count == 2,
              ops[0].type == AARCH64_OP_REG,
              ops[1].type == AARCH64_OP_IMM, ops[1].imm == imm
        else { return false }
        let name = insn.operandString.components(separatedBy: ",").first?
            .trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
        return name.hasPrefix("w")
    }

    // MARK: - Instruction decode helpers

    /// Decode a BL instruction at `off`, returning the target file offset or nil.
    private func decodeBL(at off: Int) -> Int? {
        guard off + 4 <= buffer.count else { return nil }
        let insn = buffer.readU32(at: off)
        guard insn >> 26 == 0b100101 else { return nil }
        let imm26 = insn & 0x03FF_FFFF
        let signedImm = Int32(bitPattern: imm26 << 6) >> 6
        return off + Int(signedImm) * 4
    }
}
