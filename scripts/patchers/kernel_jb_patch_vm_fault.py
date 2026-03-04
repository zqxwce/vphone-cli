"""Mixin: KernelJBPatchVmFaultMixin."""

from .kernel_jb_base import NOP


class KernelJBPatchVmFaultMixin:
    def patch_vm_fault_enter_prepare(self):
        """NOP a PMAP check in _vm_fault_enter_prepare.
        Strict mode:
        - Resolve vm_fault_enter_prepare function via symbol/string anchor.
        - In-function only (no global fallback scan).
        - Require a unique BL site with post-call flag test shape.
        """
        self._log("\n[JB] _vm_fault_enter_prepare: NOP")

        # Try symbol first
        foff = self._resolve_symbol("_vm_fault_enter_prepare")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_bl_tbz_pmap(foff, func_end)
            if result:
                self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
                return True

        # String anchor: all refs to "vm_fault_enter_prepare"
        str_off = self.find_string(b"vm_fault_enter_prepare")
        candidate_sites = set()
        if str_off >= 0:
            refs = self.find_string_refs(str_off, *self.kern_text)
            funcs = sorted(
                {
                    self.find_function_start(adrp_off)
                    for adrp_off, _, _ in refs
                    if self.find_function_start(adrp_off) >= 0
                }
            )
            for func_start in funcs:
                func_end = self._find_func_end(func_start, 0x4000)
                result = self._find_bl_tbz_pmap(func_start, func_end)
                if result is not None:
                    candidate_sites.add(result)

        if len(candidate_sites) == 1:
            result = next(iter(candidate_sites))
            self.emit(result, NOP, "NOP [_vm_fault_enter_prepare]")
            return True
        if len(candidate_sites) > 1:
            self._log(
                "  [-] ambiguous vm_fault_enter_prepare candidates: "
                + ", ".join(f"0x{x:X}" for x in sorted(candidate_sites))
            )
            return False

        self._log("  [-] patch site not found")
        return False

    def _find_bl_tbz_pmap(self, start, end):
        """Find strict BL site used by vm_fault_enter_prepare guard path.

        Expected local shape:
          BL target(rare)
          LDRB wN, [xM, #0x2c]
          ... TBZ/TBNZ wN, #bit, <forward>
        Returns BL offset when the match is unique inside [start, end).
        """
        hits = []
        scan_start = max(start + 0x80, start)
        for off in range(scan_start, end - 0x10, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "bl":
                continue
            bl_target = d0[0].operands[0].imm
            n_callers = len(self.bl_callers.get(bl_target, []))
            if n_callers >= 20:
                continue

            d1 = self._disas_at(off + 4)
            if not d1 or d1[0].mnemonic != "ldrb":
                continue
            op1 = d1[0].op_str
            if "#0x2c" not in op1 or not op1.startswith("w"):
                continue

            reg = op1.split(",", 1)[0].strip()
            matched = False
            for delta in (8, 12, 16):
                d2 = self._disas_at(off + delta)
                if not d2:
                    continue
                i2 = d2[0]
                if i2.mnemonic not in ("tbz", "tbnz"):
                    continue
                if not i2.op_str.startswith(f"{reg},"):
                    continue
                matched = True
                break
            if matched:
                hits.append(off)

        if len(hits) == 1:
            return hits[0]
        return None
