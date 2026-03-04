"""Mixin: KernelJBPatchDounmountMixin."""

from .kernel_jb_base import asm


class KernelJBPatchDounmountMixin:
    def patch_dounmount(self):
        """NOP a MAC check in _dounmount (strict matching only).
        Pattern: mov w1,#0; mov x2,#0; bl TARGET (MAC policy check pattern).
        """
        self._log("\n[JB] _dounmount: strict MAC check NOP")

        # Try symbol first
        foff = self._resolve_symbol("_dounmount")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x1000)
            result = self._find_mac_check_bl(foff, func_end)
            if result:
                nop_patch = asm("nop")
                self._assert_patch_decode(nop_patch, "nop")
                self.emit(result, nop_patch, "NOP [_dounmount MAC check]")
                return True

        # String anchor: resolve the actual dounmount function and patch in-function only.
        # We intentionally avoid broad scan fallbacks to prevent false-positive patching.
        str_off = self.find_string(b"dounmount:")
        if str_off >= 0:
            refs = self.find_string_refs(str_off)
            for adrp_off, _, _ in refs:
                caller = self.find_function_start(adrp_off)
                if caller < 0:
                    continue
                caller_end = self._find_func_end(caller, 0x2000)
                result = self._find_mac_check_bl(caller, caller_end)
                if result:
                    nop_patch = asm("nop")
                    self._assert_patch_decode(nop_patch, "nop")
                    self.emit(result, nop_patch, "NOP [_dounmount MAC check]")
                    return True

        self._log("  [-] patch site not found (unsafe fallback disabled)")
        return False

    def _find_mac_check_bl(self, start, end):
        """Find mov w1,#0; mov x2,#0; bl TARGET pattern. Returns BL offset or None."""
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic != "mov" or i1.mnemonic != "mov" or i2.mnemonic != "bl":
                continue
            # Check: mov w1, #0; mov x2, #0
            if "w1" in i0.op_str and "#0" in i0.op_str:
                if "x2" in i1.op_str and "#0" in i1.op_str:
                    return off + 8
            # Also match: mov x2, #0; mov w1, #0
            if "x2" in i0.op_str and "#0" in i0.op_str:
                if "w1" in i1.op_str and "#0" in i1.op_str:
                    return off + 8
        return None

    def _assert_patch_decode(self, patch_bytes, expect_mnemonic, expect_op_str=None):
        insns = self._disas_n(patch_bytes, 0, 1)
        assert insns, "capstone decode failed for patch bytes"
        ins = insns[0]
        assert ins.mnemonic == expect_mnemonic, (
            f"patch decode mismatch: expected {expect_mnemonic}, got {ins.mnemonic}"
        )
        if expect_op_str is not None:
            assert ins.op_str == expect_op_str, (
                f"patch decode mismatch: expected op_str '{expect_op_str}', "
                f"got '{ins.op_str}'"
            )
