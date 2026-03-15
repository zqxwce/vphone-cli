// KernelJBPatchSecureRoot.swift — JB: force SecureRootName policy to return success.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal: find functions referencing both "SecureRootName" and "SecureRoot" strings →
//   locate the final CSEL that selects between wzr (success) and kIOReturnNotPrivileged →
//   verify context: TST+LDRB at [x19,#0x11A] before, STRB+CSET+CMP w0,#0 further back.
// Patch: replace CSEL with MOV <dest>, #0.

import Capstone
import Foundation

extension KernelJBPatcher {
    /// Offset of the SecureRoot match flag inside the dispatch struct.
    private static let secureRootMatchOffset: Int = 0x11A

    /// Force SecureRootName policy return to success in _IOSecureBSDRoot.
    @discardableResult
    func patchIoSecureBsdRoot() -> Bool {
        log("\n[JB] _IOSecureBSDRoot: force SecureRootName success")

        let candidates = findSecureRootFunctions()
        guard !candidates.isEmpty else {
            log("  [-] secure-root dispatch function not found")
            return false
        }

        for funcStart in candidates.sorted() {
            let funcEnd = findFuncEnd(funcStart, maxSize: 0x1200)
            guard let (off, destReg) = findSecureRootReturnSite(funcStart: funcStart, funcEnd: funcEnd) else {
                continue
            }

            // Encode mov <destReg>, #0  (always a 32-bit W register)
            guard let patchBytes = encodeMovWReg0(destReg) else { continue }

            emit(off, patchBytes,
                 patchID: "jb.io_secure_bsd_root.zero_return",
                 virtualAddress: fileOffsetToVA(off),
                 description: "mov \(destReg), #0 [_IOSecureBSDRoot SecureRootName allow]")
            return true
        }

        log("  [-] SecureRootName deny-return site not found")
        return false
    }

    // MARK: - Private helpers

    /// Find all functions that reference both "SecureRootName" and "SecureRoot".
    private func findSecureRootFunctions() -> Set<Int> {
        let withName = functionsReferencingString("SecureRootName")
        let withRoot = functionsReferencingString("SecureRoot")
        let common = withName.intersection(withRoot)
        return common.isEmpty ? withName : common
    }

    /// Find all function starts that reference `needle` via ADRP+ADD.
    private func functionsReferencingString(_ needle: String) -> Set<Int> {
        var result = Set<Int>()
        // Scan all occurrences of the needle in the buffer.
        guard let encoded = needle.data(using: .utf8) else { return result }
        var searchFrom = 0
        while searchFrom < buffer.count {
            guard let range = buffer.data.range(of: encoded, in: searchFrom ..< buffer.count) else { break }
            let pos = range.lowerBound
            // Find null-terminated C string boundary.
            var cstrStart = pos
            while cstrStart > 0, buffer.data[cstrStart - 1] != 0 {
                cstrStart -= 1
            }
            var cstrEnd = pos
            while cstrEnd < buffer.count, buffer.data[cstrEnd] != 0 {
                cstrEnd += 1
            }
            // Only accept if the C string equals the needle exactly.
            if buffer.data[cstrStart ..< cstrEnd] == encoded {
                let refs = findStringRefs(cstrStart)
                for (adrpOff, _) in refs {
                    if let fn = findFunctionStart(adrpOff) {
                        result.insert(fn)
                    }
                }
            }
            searchFrom = pos + 1
        }
        return result
    }

    /// Scan [funcStart, funcEnd) for the CSEL that is the SecureRootName deny/allow selector.
    /// Returns (offset, destRegName) on success.
    private func findSecureRootReturnSite(funcStart: Int, funcEnd: Int) -> (Int, String)? {
        for off in stride(from: funcStart, to: funcEnd - 4, by: 4) {
            let insns = disasm.disassemble(in: buffer.data, at: off, count: 1)
            guard let insn = insns.first, insn.mnemonic == "csel" else { continue }
            guard let detail = insn.aarch64, detail.operands.count >= 3 else { continue }

            let destOp = detail.operands[0]
            let zeroSrcOp = detail.operands[1]
            let errSrcOp = detail.operands[2]

            guard destOp.type == AARCH64_OP_REG,
                  zeroSrcOp.type == AARCH64_OP_REG,
                  errSrcOp.type == AARCH64_OP_REG else { continue }

            let destName = disasm.registerName(UInt32(destOp.reg.rawValue)) ?? ""
            let zeroName = disasm.registerName(UInt32(zeroSrcOp.reg.rawValue)) ?? ""
            let errName = disasm.registerName(UInt32(errSrcOp.reg.rawValue)) ?? ""

            // Must be: csel wX, wzr, wErr, ne
            guard destName.hasPrefix("w") else { continue }
            guard zeroName == "wzr" || zeroName == "xzr" else { continue }

            // Last operand string should contain "ne"
            let opStr = insn.operandString.replacingOccurrences(of: " ", with: "")
            guard opStr.hasSuffix(",ne") || opStr.hasSuffix("ne") else { continue }

            // Verify return context: TST + LDRB [x19, #0x11A] walking back.
            guard hasSecureRootReturnContext(off: off, funcStart: funcStart, errRegName: errName) else { continue }
            // Verify compare context: STRB + CSET + CMP w0,#0 walking back.
            guard hasSecureRootCompareContext(off: off, funcStart: funcStart) else { continue }

            return (off, destName)
        }
        return nil
    }

    /// Walk backward from `off` to verify the flag-load and error-build context.
    private func hasSecureRootReturnContext(off: Int, funcStart: Int, errRegName: String) -> Bool {
        var sawFlagLoad = false
        var sawFlagTest = false
        var sawErrBuild = false
        let lookbackStart = max(funcStart, off - 0x40)

        var probe = off - 4
        while probe >= lookbackStart {
            defer { probe -= 4 }
            let insns = disasm.disassemble(in: buffer.data, at: probe, count: 1)
            guard let ins = insns.first else { continue }
            let ops = ins.operandString.replacingOccurrences(of: " ", with: "")

            if !sawFlagTest, ins.mnemonic == "tst", ops.hasSuffix("#1") {
                sawFlagTest = true
                continue
            }

            if sawFlagTest, !sawFlagLoad, ins.mnemonic == "ldrb",
               ops.contains("[x19,#0x\(String(format: "%x", Self.secureRootMatchOffset))]")
            {
                sawFlagLoad = true
                continue
            }

            if ins.mnemonic == "mov" || ins.mnemonic == "movk" || ins.mnemonic == "sub",
               writesRegister(ins, regName: errRegName)
            {
                sawErrBuild = true
            }
        }

        return sawFlagLoad && sawFlagTest && sawErrBuild
    }

    /// Walk backward from `off` to verify the match-store + cset,eq + cmp w0,#0 context.
    private func hasSecureRootCompareContext(off: Int, funcStart: Int) -> Bool {
        var sawMatchStore = false
        var sawCsetEq = false
        var sawCmpW0Zero = false
        let lookbackStart = max(funcStart, off - 0xA0)

        var probe = off - 4
        while probe >= lookbackStart {
            defer { probe -= 4 }
            let insns = disasm.disassemble(in: buffer.data, at: probe, count: 1)
            guard let ins = insns.first else { continue }
            let ops = ins.operandString.replacingOccurrences(of: " ", with: "")

            if !sawMatchStore, ins.mnemonic == "strb",
               ops.contains("[x19,#0x\(String(format: "%x", Self.secureRootMatchOffset))]")
            {
                sawMatchStore = true
                continue
            }

            if sawMatchStore, !sawCsetEq, ins.mnemonic == "cset", ops.hasSuffix(",eq") {
                sawCsetEq = true
                continue
            }

            if sawMatchStore, sawCsetEq, !sawCmpW0Zero, ins.mnemonic == "cmp",
               ops.hasPrefix("w0,#0")
            {
                sawCmpW0Zero = true
                break
            }
        }

        return sawMatchStore && sawCsetEq && sawCmpW0Zero
    }

    /// Return true if the instruction writes to `regName` as its first operand.
    private func writesRegister(_ ins: Instruction, regName: String) -> Bool {
        guard let detail = ins.aarch64, !detail.operands.isEmpty else { return false }
        let first = detail.operands[0]
        guard first.type == AARCH64_OP_REG else { return false }
        return (disasm.registerName(UInt32(first.reg.rawValue)) ?? "") == regName
    }

    /// Encode `mov <wReg>, #0` (MOVZ Wd, #0). E.g. "w22" → MOVZ W22, #0.
    private func encodeMovWReg0(_ regName: String) -> Data? {
        guard regName.hasPrefix("w"), let numStr = regName.dropFirst().isEmpty ? nil : String(regName.dropFirst()),
              let rd = UInt32(numStr), rd < 32 else { return nil }
        // MOVZ Wd, #0 = 0x52800000 | rd
        let insn: UInt32 = 0x5280_0000 | rd
        return ARM64.encodeU32(insn)
    }
}
