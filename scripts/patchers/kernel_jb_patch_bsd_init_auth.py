"""Mixin: KernelJBPatchBsdInitAuthMixin."""

from .kernel_jb_base import MOV_X0_0, _rd32


class KernelJBPatchBsdInitAuthMixin:
    # ldr x0, [xN, #0x2b8]  (ignore xN/Rn)
    _LDR_X0_2B8_MASK = 0xFFFFFC1F
    _LDR_X0_2B8_VAL = 0xF9415C00
    # cbz {w0|x0}, <label> (mask drops sf bit)
    _CBZ_X0_MASK = 0x7F00001F
    _CBZ_X0_VAL = 0x34000000

    def patch_bsd_init_auth(self):
        """Bypass rootvp authentication check in _bsd_init.
        Pattern: ldr x0, [xN, #0x2b8]; cbz x0, ...; bl AUTH_FUNC
        Replace the BL with mov x0, #0.
        """
        self._log("\n[JB] _bsd_init: mov x0,#0 (auth bypass)")

        # Try symbol first
        foff = self._resolve_symbol("_bsd_init")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x2000)
            result = self._find_auth_bl(foff, func_end)
            if result:
                self.emit(result, MOV_X0_0, "mov x0,#0 [_bsd_init auth]")
                return True

        # Pattern search: ldr x0, [xN, #0x2b8]; cbz x0; bl
        ks, ke = self.kern_text
        rootvp_func = self._func_for_rootvp_anchor()
        if rootvp_func is None:
            self._log("  [-] rootvp anchor function not found")
            return False

        # Fast path: scan a narrow window around rootvp/bsd_init region first.
        near_start = max(ks, rootvp_func - 0x200000)
        near_end = min(ke, rootvp_func + 0x400000)
        candidates = self._collect_auth_bl_candidates(near_start, near_end)
        if not candidates:
            # Fallback to full kernel text only when needed.
            candidates = self._collect_auth_bl_candidates(ks, ke)

        if not candidates:
            self._log("  [-] ldr+cbz+bl pattern not found")
            return False

        bl_off = self._select_bsd_init_auth_candidate(candidates, rootvp_func)
        if bl_off is None:
            self._log("  [-] no safe _bsd_init auth candidate (fail-closed)")
            return False

        self._log(f"  [+] auth BL at 0x{bl_off:X} (strict candidate)")
        self.emit(bl_off, MOV_X0_0, "mov x0,#0 [_bsd_init auth]")
        return True

    def _find_auth_bl(self, start, end):
        """Find ldr x0,[xN,#0x2b8]; cbz x0; bl pattern. Returns BL offset."""
        cands = self._collect_auth_bl_candidates(start, end)
        if cands:
            return cands[0]

        # Fallback for unexpected instruction variants.
        for off in range(start, end - 8, 4):
            d = self._disas_at(off, 3)
            if len(d) < 3:
                continue
            i0, i1, i2 = d[0], d[1], d[2]
            if i0.mnemonic == "ldr" and i1.mnemonic == "cbz" and i2.mnemonic == "bl":
                if i0.op_str.startswith("x0,") and "#0x2b8" in i0.op_str:
                    if i1.op_str.startswith("x0,"):
                        return off + 8
        return None

    def _collect_auth_bl_candidates(self, start, end):
        """Fast matcher using raw instruction masks (no capstone in hot loop)."""
        out = []
        limit = min(end - 8, self.size - 8)
        for off in range(max(start, 0), limit, 4):
            i0 = _rd32(self.raw, off)
            if (i0 & self._LDR_X0_2B8_MASK) != self._LDR_X0_2B8_VAL:
                continue

            i1 = _rd32(self.raw, off + 4)
            if (i1 & self._CBZ_X0_MASK) != self._CBZ_X0_VAL:
                continue

            i2 = _rd32(self.raw, off + 8)
            if (i2 & 0xFC000000) != 0x94000000:  # BL imm26
                continue

            out.append(off + 8)
        return out

    def _select_bsd_init_auth_candidate(self, candidates, rootvp_func):
        """Select a safe candidate in core kernel code.

        Heuristics (strict, fail-closed):
        - Stay near the core bsd_init region (anchored by rootvp panic string xref).
        - Require function context to reference `/dev/null` (boot-path fingerprint).
        - Prefer lower-caller-count function entries.
        """
        # Keep candidates in the same broad kernel neighborhood.
        core_limit = rootvp_func + 0x400000
        nearby = [off for off in candidates if off < core_limit]
        if not nearby:
            return None

        ranked = []
        for bl_off in nearby:
            fn = self.find_function_start(bl_off)
            if fn < 0:
                continue
            fn_end = self._find_func_end(fn, 0x4000)
            if not self._function_has_string(fn, fn_end, b"/dev/null"):
                continue
            callers = len(self.bl_callers.get(fn, []))
            ranked.append((callers, bl_off, fn))

        if not ranked:
            return None

        ranked.sort()
        best_callers, best_off, _ = ranked[0]
        # Ambiguous: multiple same-rank hits.
        same = [item for item in ranked if item[0] == best_callers]
        if len(same) > 1:
            return None
        return best_off

    def _func_for_rootvp_anchor(self):
        needle = b"rootvp not authenticated after mounting @%s:%d"
        str_off = self.find_string(needle)
        if str_off < 0:
            return None
        refs = self.find_string_refs(str_off, *self.kern_text)
        if not refs:
            return None
        fn = self.find_function_start(refs[0][0])
        return fn if fn >= 0 else None

    def _function_has_string(self, func_start, func_end, needle):
        str_off = self.find_string(needle)
        if str_off < 0:
            return False
        refs = self.find_string_refs(str_off, *self.kern_text)
        for adrp_off, _, _ in refs:
            if func_start <= adrp_off < func_end:
                return True
        return False
