// KernelJBPatchProcSecurity.swift — JB: stub _proc_security_policy with mov x0,#0; ret.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.
//
// Reveal: find _proc_info by `sub wN,wM,#1 ; cmp wN,#0x21` switch pattern,
//   then identify _proc_security_policy among BL targets called 2+ times,
//   with function size in [0x40, 0x200].

import Foundation

extension KernelJBPatcher {
    /// Stub _proc_security_policy: mov x0,#0; ret.
    @discardableResult
    func patchProcSecurityPolicy() -> Bool {
        log("\n[JB] _proc_security_policy: mov x0,#0; ret")

        guard let (procInfoFunc, switchOff) = findProcInfoAnchor() else {
            log("  [-] _proc_info function not found")
            return false
        }

        let ksStart = codeRanges.first?.start ?? 0
        let ksEnd = codeRanges.first?.end ?? buffer.count

        let procInfoEnd = findFuncEnd(procInfoFunc, maxSize: 0x4000)
        log("  [+] _proc_info at 0x\(String(format: "%X", procInfoFunc)) (size 0x\(String(format: "%X", procInfoEnd - procInfoFunc)))")

        // Count BL targets after switch dispatch within _proc_info.
        var blTargetCounts: [Int: Int] = [:]
        for off in stride(from: switchOff, to: procInfoEnd, by: 4) {
            guard off + 4 <= buffer.count else { break }
            let insn = buffer.readU32(at: off)
            // BL: [31:26] = 0b100101
            guard insn >> 26 == 0b100101 else { continue }
            let imm26 = insn & 0x03FF_FFFF
            let signedImm = Int32(bitPattern: imm26 << 6) >> 6
            let target = off + Int(signedImm) * 4
            guard target >= ksStart, target < ksEnd else { continue }
            blTargetCounts[target, default: 0] += 1
        }

        guard !blTargetCounts.isEmpty else {
            log("  [-] no BL targets found in _proc_info switch cases")
            return false
        }

        // Sort by count descending, then by address ascending (to match Python
        // Counter.most_common() insertion-order tie-breaking from the forward scan).
        let sorted = blTargetCounts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }

        for (foff, count) in sorted {
            guard count >= 2 else { break }

            let funcEnd = findFuncEnd(foff, maxSize: 0x400)
            let funcSize = funcEnd - foff

            log("  [*] candidate 0x\(String(format: "%X", foff)): \(count) calls, size 0x\(String(format: "%X", funcSize))")

            if funcSize > 0x200 {
                log("  [-] skipped (too large, likely utility)")
                continue
            }
            if funcSize < 0x40 {
                log("  [-] skipped (too small)")
                continue
            }

            log("  [+] identified _proc_security_policy at 0x\(String(format: "%X", foff)) (\(count) calls, size 0x\(String(format: "%X", funcSize)))")
            emit(foff, ARM64.movX0_0,
                 patchID: "jb.proc_security_policy.mov_x0_0",
                 virtualAddress: fileOffsetToVA(foff),
                 description: "mov x0,#0 [_proc_security_policy]")
            emit(foff + 4, ARM64.ret,
                 patchID: "jb.proc_security_policy.ret",
                 virtualAddress: fileOffsetToVA(foff + 4),
                 description: "ret [_proc_security_policy]")
            return true
        }

        log("  [-] _proc_security_policy not identified among BL targets")
        return false
    }
}
