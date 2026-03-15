// KernelJBPatchTaskConversion.swift — JB kernel patch: Task conversion eval bypass
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Strategy (fast raw scanner):
//   Locate the unique guard site in _task_conversion_eval_internal that performs:
//     ADRP Xn, <global>       ; [off - 8]  — loads global task-conversion table
//     LDR  Xn, [Xn]           ; [off - 4]  — dereferences it
//     CMP  Xn, X0             ; [off + 0]  — compare task pointer against X0
//     B.EQ <skip1>            ; [off + 4]
//     CMP  Xn, X1             ; [off + 8]  — compare against X1
//     B.EQ <skip2>            ; [off + 12]
//     MOV  X19, X0            ; [off + 16]
//     MOV  X0, X1             ; [off + 20]
//     BL   <callee>           ; [off + 24]
//     CBZ/CBNZ W0, ...        ; [off + 28]
//   Patch: replace CMP Xn, X0 with CMP XZR, XZR so the equality check always passes.

import Foundation

extension KernelJBPatcher {
    /// Task conversion eval bypass: patch the guard CMP to always be equal.
    @discardableResult
    func patchTaskConversionEvalInternal() -> Bool {
        log("\n[JB] task_conversion_eval_internal: cmp xzr,xzr")

        guard let range = kernTextRange ?? codeRanges.first.map({ ($0.start, $0.end) }) else {
            return false
        }
        let (ks, ke) = range

        let candidates = collectTaskConversionCandidates(start: ks, end: ke)

        guard candidates.count == 1 else {
            log("  [-] expected 1 task-conversion guard site, found \(candidates.count)")
            return false
        }

        let site = candidates[0]
        let va = fileOffsetToVA(site)
        emit(site, ARM64.cmpXzrXzr,
             patchID: "task_conversion_eval",
             virtualAddress: va,
             description: "cmp xzr,xzr [_task_conversion_eval_internal]")
        return true
    }

    // MARK: - Private scanner

    private func collectTaskConversionCandidates(start: Int, end: Int) -> [Int] {
        // Derived masks — no hardcoded opcode bytes:
        // CMP Xn, X0 = SUBS XZR, Xn, X0  → bits [31:21]=1110_1011_000, [20:16]=X0=00000,
        //   [15:10]=000000, [9:5]=Rn, [4:0]=11111(XZR)
        // Mask covers the fixed opcode and X0 operand; leaves Rn free.
        let cmpXnX0Mask: UInt32 = 0xFFFF_FC1F
        let cmpXnX0Val: UInt32 = 0xEB00_001F // cmp Xn, X0 — Rn wildcard

        // CMP Xn, X1 = SUBS XZR, Xn, X1  → Rm=X1=00001
        let cmpXnX1Mask: UInt32 = 0xFFFF_FC1F
        let cmpXnX1Val: UInt32 = 0xEB01_001F // cmp Xn, X1 — Rn wildcard

        // B.EQ #offset → bits[31:24]=0101_0100, bit[4]=0, bits[3:0]=0000 (EQ cond)
        let beqMask: UInt32 = 0xFF00_001F
        let beqVal: UInt32 = 0x5400_0000 // b.eq with any imm19

        // LDR Xd, [Xn] (unsigned offset, size=3):
        // bits [31:22] fixed = 0xF94 (size=11, V=0, opc=01, class=01);
        // bits [21:10] = imm12, bits [9:5] = Rn, bits [4:0] = Rt — all variable.
        let ldrXUnsignedMask: UInt32 = 0xFFC0_0000 // leaves imm12, Rn, Rt free
        let ldrXUnsignedVal: UInt32 = 0xF940_0000

        // ADRP: bit[31]=1, bits[28:24]=10000
        let adrpMask: UInt32 = 0x9F00_0000
        let adrpVal: UInt32 = 0x9000_0000

        // MOV X19, X0 = ORR X19, XZR, X0
        let movX19X0: UInt32 = 0xAA00_03F3
        // MOV X0, X1  = ORR X0, XZR, X1
        let movX0X1: UInt32 = 0xAA01_03E0

        // BL mask
        let blMask: UInt32 = 0xFC00_0000
        let blVal: UInt32 = 0x9400_0000

        // CBZ/CBNZ W (32-bit): bits[31]=0, bits[30:25]=011010 / 011011
        let cbzWMask: UInt32 = 0x7F00_0000
        let cbzWVal: UInt32 = 0x3400_0000 // CBZ  W
        let cbnzWVal: UInt32 = 0x3500_0000 // CBNZ W

        var out: [Int] = []

        var off = start + 8
        while off < end - 28 {
            defer { off += 4 }

            // [off]: CMP Xn, X0
            let i0 = buffer.readU32(at: off)
            guard (i0 & cmpXnX0Mask) == cmpXnX0Val else { continue }
            let cmpRn = (i0 >> 5) & 0x1F // the register being compared

            // [off - 4]: LDR Xn, [Xn] (load into cmpRn from cmpRn)
            let prev = buffer.readU32(at: off - 4)
            guard (prev & ldrXUnsignedMask) == ldrXUnsignedVal else { continue }
            let pRt = prev & 0x1F
            let pRn = (prev >> 5) & 0x1F
            guard pRt == cmpRn, pRn == cmpRn else { continue }

            // [off + 4]: B.EQ
            let i1 = buffer.readU32(at: off + 4)
            guard (i1 & beqMask) == beqVal else { continue }

            // [off + 8]: CMP Xn, X1 (same register)
            let i2 = buffer.readU32(at: off + 8)
            guard (i2 & cmpXnX1Mask) == cmpXnX1Val else { continue }
            guard ((i2 >> 5) & 0x1F) == cmpRn else { continue }

            // [off + 12]: B.EQ
            let i3 = buffer.readU32(at: off + 12)
            guard (i3 & beqMask) == beqVal else { continue }

            // Context safety: ADRP at [off - 8] for same register
            let p2 = buffer.readU32(at: off - 8)
            guard (p2 & adrpMask) == adrpVal else { continue }
            guard (p2 & 0x1F) == cmpRn else { continue }

            // [off + 16]: MOV X19, X0
            guard buffer.readU32(at: off + 16) == movX19X0 else { continue }

            // [off + 20]: MOV X0, X1
            guard buffer.readU32(at: off + 20) == movX0X1 else { continue }

            // [off + 24]: BL
            let i6 = buffer.readU32(at: off + 24)
            guard (i6 & blMask) == blVal else { continue }

            // [off + 28]: CBZ or CBNZ W0
            let i7 = buffer.readU32(at: off + 28)
            let op7 = i7 & cbzWMask
            guard op7 == cbzWVal || op7 == cbnzWVal else { continue }
            guard (i7 & 0x1F) == 0 else { continue } // must be W0

            // B.EQ targets must be forward and nearby (within same function)
            guard let t1 = decodeBEQTarget(insn: i1, at: off + 4) else { continue }
            guard let t2 = decodeBEQTarget(insn: i3, at: off + 12) else { continue }
            guard t1 > off, t2 > off else { continue }
            guard (t1 - off) <= 0x200, (t2 - off) <= 0x200 else { continue }

            out.append(off)
        }
        return out
    }

    /// Decode a B.cond target offset from an instruction at `pc`.
    private func decodeBEQTarget(insn: UInt32, at pc: Int) -> Int? {
        // B.cond: bits[31:24] = 0x54, bits[23:5] = imm19, bits[4] = 0, bits[3:0] = cond
        guard (insn & 0xFF00_001E) == 0x5400_0000 else { return nil }
        let imm19 = (insn >> 5) & 0x7FFFF
        // Sign-extend 19 bits
        let signedImm = Int32(bitPattern: imm19 << 13) >> 13
        return pc + Int(signedImm) * 4
    }
}
