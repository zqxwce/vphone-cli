"""Mixin: KernelJBPatchSharedRegionMixin."""

from .kernel_jb_base import ARM64_OP_IMM, ARM64_OP_REG, CMP_X0_X0


class KernelJBPatchSharedRegionMixin:
    def patch_shared_region_map(self):
        """Force shared region check: cmp x0,x0.
        Anchor: '/private/preboot/Cryptexes' string → call-site fail target
        → CMP+B.NE to same fail label.
        """
        self._log("\n[JB] _shared_region_map_and_slide_setup: cmp x0,x0")

        # Try symbol first
        foff = self._resolve_symbol("_shared_region_map_and_slide_setup")
        if foff < 0:
            foff = self._find_func_by_string(
                b"/private/preboot/Cryptexes", self.kern_text
            )
        if foff < 0:
            foff = self._find_func_by_string(b"/private/preboot/Cryptexes")
        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x2000)
        str_off = self.find_string(b"/private/preboot/Cryptexes")
        refs = self.find_string_refs(str_off, foff, func_end) if str_off >= 0 else []

        # Prefer: BL ... ; CBNZ W0, fail  and then CMP reg,reg ; B.NE fail.
        for adrp_off, _, _ in refs:
            fail_target = self._find_fail_target_after_ref(adrp_off, func_end)
            if fail_target is None:
                continue
            patch_off = self._find_cmp_bne_to_target(
                adrp_off, min(func_end, adrp_off + 0x140), fail_target
            )
            if patch_off is None:
                continue
            self.emit(
                patch_off, CMP_X0_X0, "cmp x0,x0 [_shared_region_map_and_slide_setup]"
            )
            return True

        # Fallback: strict in-function scan for CMP reg,reg + B.NE, skipping
        # stack canary compares against qword_FFFFFE00097BB000.
        for off in range(foff, func_end - 4, 4):
            d = self._disas_at(off, 2)
            if len(d) < 2:
                continue
            i0, i1 = d[0], d[1]
            if i0.mnemonic != "cmp" or i1.mnemonic != "b.ne":
                continue
            ops = i0.operands
            if len(ops) < 2:
                continue
            if ops[0].type == ARM64_OP_REG and ops[1].type == ARM64_OP_REG:
                if self._is_probable_stack_canary_cmp(off):
                    continue
                self.emit(
                    off, CMP_X0_X0, "cmp x0,x0 [_shared_region_map_and_slide_setup]"
                )
                return True

        self._log("  [-] CMP+B.NE pattern not found")
        return False

    def _find_fail_target_after_ref(self, ref_off, func_end):
        """Find CBNZ W0,<target> following the Cryptexes call site."""
        for off in range(ref_off, min(func_end - 4, ref_off + 0x60), 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "cbnz":
                continue
            i = d[0]
            if not i.op_str.startswith("w0, "):
                continue
            if len(i.operands) >= 2 and i.operands[-1].type == ARM64_OP_IMM:
                return i.operands[-1].imm
        return None

    def _find_cmp_bne_to_target(self, start, end, target):
        """Find CMP reg,reg; B.NE <target> in range."""
        for off in range(start, end - 4, 4):
            d = self._disas_at(off, 2)
            if len(d) < 2:
                continue
            i0, i1 = d[0], d[1]
            if i0.mnemonic != "cmp" or i1.mnemonic != "b.ne":
                continue
            ops = i0.operands
            if len(ops) < 2:
                continue
            if ops[0].type != ARM64_OP_REG or ops[1].type != ARM64_OP_REG:
                continue
            if len(i1.operands) < 1 or i1.operands[-1].type != ARM64_OP_IMM:
                continue
            if i1.operands[-1].imm != target:
                continue
            if self._is_probable_stack_canary_cmp(off):
                continue
            return off
        return None

    def _is_probable_stack_canary_cmp(self, cmp_off):
        """Heuristic: skip stack canary compare blocks near epilogue."""
        for lookback in range(cmp_off - 0x10, cmp_off, 4):
            if lookback < 0:
                continue
            d = self._disas_at(lookback)
            if not d:
                continue
            i = d[0]
            if i.mnemonic != "ldr":
                continue
            if "qword_FFFFFE00097BB000" in i.op_str:
                return True
        return False
