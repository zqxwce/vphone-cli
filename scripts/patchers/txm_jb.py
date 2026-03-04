#!/usr/bin/env python3
"""
txm_jb.py — Jailbreak extension patcher for TXM images.

Reuses shared TXM logic from txm_dev.py and adds the selector24 CodeSignature
hash-extraction bypass used only by the JB variant.
"""

from .txm_dev import TXMPatcher as TXMDevPatcher, _asm, _disasm_one


NOP = _asm("nop")


class TXMJBPatcher(TXMDevPatcher):
    """JB-only TXM patcher: selector24 CS hash-extraction bypass.

    Dev patches are applied separately by txm_dev.py; this class only
    adds the JB-exclusive selector24 extension.
    """

    def apply(self):
        self.find_all()
        for off, pb, _ in self.patches:
            self.data[off : off + len(pb)] = pb
        if self.verbose and self.patches:
            self._log(f"\n  [{len(self.patches)} TXM JB patches applied]")
        return len(self.patches)

    def find_all(self):
        self.patches = []
        self.patch_selector24_hash_extraction_nop()
        return self.patches

    def patch_selector24_hash_extraction_nop(self):
        """NOP hash-flags extraction setup/call in selector24 path."""
        for off in range(0, self.size - 4, 4):
            ins = _disasm_one(self.raw, off)
            if not (ins and ins.mnemonic == "mov" and ins.op_str == "w0, #0xa1"):
                continue

            func_start = self._find_func_start(off)
            if func_start is None:
                continue

            # Scan function for: LDR X1,[Xn,#0x38] / ADD X2,... / BL / LDP
            for scan in range(func_start, off, 4):
                i0 = _disasm_one(self.raw, scan)
                i1 = _disasm_one(self.raw, scan + 4)
                i2 = _disasm_one(self.raw, scan + 8)
                i3 = _disasm_one(self.raw, scan + 12)
                if not all((i0, i1, i2, i3)):
                    continue
                if not (
                    i0.mnemonic == "ldr"
                    and "x1," in i0.op_str
                    and "#0x38]" in i0.op_str
                ):
                    continue
                if not (i1.mnemonic == "add" and i1.op_str.startswith("x2,")):
                    continue
                if i2.mnemonic != "bl":
                    continue
                if i3.mnemonic != "ldp":
                    continue

                self.emit(scan, NOP, "selector24 CS: nop ldr x1,[xN,#0x38]")
                self.emit(scan + 8, NOP, "selector24 CS: nop bl hash_flags_extract")
                return True

        self._log("  [-] TXM JB: selector24 hash extraction site not found")
        return False
