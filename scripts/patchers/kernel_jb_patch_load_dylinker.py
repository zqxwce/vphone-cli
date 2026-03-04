"""Mixin: KernelJBPatchLoadDylinkerMixin."""


class KernelJBPatchLoadDylinkerMixin:
    def patch_load_dylinker(self):
        """Bypass load_dylinker policy gate in the dyld path.

        Strict selector:
        1. Anchor function by '/usr/lib/dyld' string reference.
        2. Inside that function, find BL <check>; CBZ W0, <allow>.
        3. Replace BL with unconditional B to <allow>.
        """
        self._log("\n[JB] _load_dylinker: skip dyld policy check")

        # Try symbol first
        foff = self._resolve_symbol("_load_dylinker")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_bl_cbz_gate(foff, func_end)
            if result:
                bl_off, allow_target = result
                b_bytes = self._encode_b(bl_off, allow_target)
                if b_bytes:
                    self.emit(
                        bl_off,
                        b_bytes,
                        f"b #0x{allow_target - bl_off:X} [_load_dylinker]",
                    )
                    return True

        # Fallback: strict dyld-anchor function profile.
        str_off = self.find_string(b"/usr/lib/dyld")
        if str_off < 0:
            self._log("  [-] '/usr/lib/dyld' string not found")
            return False

        kstart, kend = self._get_kernel_text_range()
        refs = self.find_string_refs(str_off, kstart, kend)
        if not refs:
            refs = self.find_string_refs(str_off)
        if not refs:
            self._log("  [-] no code refs to '/usr/lib/dyld'")
            return False

        for adrp_off, _, _ in refs:
            func_start = self.find_function_start(adrp_off)
            if func_start < 0:
                continue
            func_end = self._find_func_end(func_start, 0x1200)
            result = self._find_bl_cbz_gate(func_start, func_end)
            if not result:
                continue
            bl_off, allow_target = result
            b_bytes = self._encode_b(bl_off, allow_target)
            if not b_bytes:
                continue
            self._log(
                f"  [+] dyld anchor func at 0x{func_start:X}, "
                f"patch BL at 0x{bl_off:X}"
            )
            self.emit(
                bl_off,
                b_bytes,
                f"b #0x{allow_target - bl_off:X} [_load_dylinker policy bypass]",
            )
            return True

        self._log("  [-] dyld policy gate not found")
        return False

    def _find_bl_cbz_gate(self, start, end):
        """Find BL <check>; CBZ W0,<allow>; MOV W0,#2 gate and return (bl_off, allow_target)."""
        for off in range(start, end - 8, 4):
            d0 = self._disas_at(off)
            d1 = self._disas_at(off + 4)
            d2 = self._disas_at(off + 8)
            if not d0 or not d1:
                continue
            i0 = d0[0]
            i1 = d1[0]
            if i0.mnemonic != "bl" or i1.mnemonic != "cbz":
                continue
            if not i1.op_str.startswith("w0, "):
                continue
            if len(i1.operands) < 2:
                continue
            allow_target = i1.operands[-1].imm

            # Keep selector strict: deny path usually sets errno=2 right after CBZ.
            if d2 and d2[0].mnemonic == "mov" and d2[0].op_str.startswith("w0, #2"):
                return off, allow_target
        return None
