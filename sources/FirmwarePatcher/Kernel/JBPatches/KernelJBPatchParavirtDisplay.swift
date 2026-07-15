// KernelJBPatchParavirtDisplay.swift — JB kernel patch: publish the VM's single
// AppleParavirtDisplay as the primary/main display.
//
// iOS 27 refactored FrontBoard (FBSDisplayMonitor) to REQUIRE a designated main
// display: `-[FBSDisplayMonitor _initWithDisplays:mainDisplay:bookendObserver:transformer:]`
// hard-asserts `mainDisplay != nil`, and the new `isMainDisplay:` flag is threaded
// through display construction. (Groundwork for multi-display/foldable hardware.)
//
// The VZ paravirt display is published generic: `AppleParavirtDisplay` sets its IOKit
// "primary" property from a per-display field that is 0, so CoreDisplay/FrontBoard
// never sees a built-in/primary display → mainDisplay stays nil → SpringBoard
// crash-loops ("failed to initialize mainDisplay source -> mainDisplay=(null)") →
// black screen. iOS 26.x had no main-display requirement, so the same VM booted fine.
//
// Force the published value to 1. In AppleParavirtDisplay the property is set via
// IOKit `setProperty("primary", value, 32)`; the value is loaded into w2 by a
// `ldr w2,[xN,#imm]` immediately before the call. Rewrite that load to `mov w2,#1`
// so the sole display is always published primary=1.
//
// Anchor (structural, no hardcoded offsets): the exact "primary\0" cstring xref
// whose call site is the `setProperty(key, value, numberOfBits=32)` form — an
// `add xN,xN,#<primary>` followed within a few insns by `mov w3,#0x20` then a
// `blraa` — distinguishing it from the sibling getProperty("primary") ref. From
// that ADRP, the nearest preceding `ldr w2,[…]` is the value load to rewrite.
//
// Safe for iOS 26.x too: a single display legitimately IS the primary display, so
// forcing primary=1 matches reality; 26.x simply didn't require it.

import Foundation

extension KernelJBPatcher {
    @discardableResult
    func patchParavirtDisplayPrimary() -> Bool {
        log("\n[JB] AppleParavirtDisplay 'primary' -> 1 (publish VM display as main; iOS 27 FBSDisplayMonitor)")

        guard let (ks, ke) = kernTextRange else {
            log("  [-] no kernel text range")
            return false
        }

        // ADRP+ADD refs to the exact "primary\0" cstring within kext __TEXT_EXEC.
        let refs = findStringRefs(in: (start: ks, end: ke), string: "primary")
        guard !refs.isEmpty else {
            log("  [-] no refs to \"primary\" cstring")
            return false
        }

        var hits: [Int] = []
        for (adrpOff, addOff) in refs {
            // Confirm the setProperty(key, value, numberOfBits=32) shape: after the
            // ADD that completes the "primary" pointer, a `mov w3,#0x20` then a
            // `blraa`. Skips the sibling getProperty("primary") reference.
            var sawBits = false
            var sawCall = false
            var o = addOff + 4
            var steps = 0
            while steps < 8, o + 4 <= ke {
                guard let ins = disasAt(o) else { break }
                if ins.mnemonic == "mov",
                   ins.operandString.contains("w3"),
                   ins.operandString.contains("0x20") {
                    sawBits = true
                }
                if ins.mnemonic == "blraa" {
                    sawCall = true
                    break
                }
                o += 4
                steps += 1
            }
            guard sawBits, sawCall else { continue }

            // The setProperty value lives in w2, loaded just before the ADRP via
            // `ldr w2,[xN,#imm]` (the per-display primary flag == 0). Find it.
            var l = adrpOff - 4
            var back = 0
            while back < 12, l >= ks {
                if let ins = disasAt(l),
                   ins.mnemonic == "ldr",
                   ins.operandString.hasPrefix("w2,") {
                    hits.append(l)
                    break
                }
                l -= 4
                back += 1
            }
        }

        guard hits.count == 1 else {
            log("  [-] paravirt-display primary value-load not found uniquely (found \(hits.count))")
            return false
        }

        let ldrOff = hits[0]
        guard let movBytes = ARM64Encoder.encodeMovzW(rd: 2, imm16: 1) else {
            log("  [-] failed to encode mov w2,#1")
            return false
        }

        let va = fileOffsetToVA(ldrOff)
        emit(
            ldrOff,
            movBytes,
            patchID: "paravirt_display_primary",
            virtualAddress: va,
            description: "ldr w2,[primary flag] -> mov w2,#1 [publish VM display as primary/main for iOS 27]"
        )
        return true
    }
}
