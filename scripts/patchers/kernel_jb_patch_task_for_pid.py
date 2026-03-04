"""Mixin: KernelJBPatchTaskForPidMixin."""

from collections import Counter

from .kernel_jb_base import NOP, _rd32, _rd64


class KernelJBPatchTaskForPidMixin:
    def patch_task_for_pid(self):
        """NOP proc_ro security policy copy in _task_for_pid.

        Pattern: _task_for_pid is a Mach trap handler (0 BL callers) with:
          - 2x ldadda (proc reference counting)
          - 2x ldr wN,[xN,#0x490]; str wN,[xN,#0xc] (proc_ro security copy)
          - movk xN, #0xc8a2, lsl #48 (PAC discriminator)
          - BL to a non-panic function with >500 callers (proc_find etc.)
        NOP the second ldr wN,[xN,#0x490] (the target process security copy).
        """
        self._log("\n[JB] _task_for_pid: NOP")

        # Try symbol first
        foff = self._resolve_symbol("_task_for_pid")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x800)
            patch_off = self._find_second_ldr490(foff, func_end)
            if patch_off:
                self.emit(patch_off, NOP, "NOP [_task_for_pid proc_ro copy]")
                return True

        # Fast prefilter: locate functions containing >=2
        # ldr w?,[x?,#0x490] + str w?,[x?,#0xc] pairs.
        pair_candidates = self._find_funcs_with_ldr490_pairs()
        candidates = []
        for func_start, ldr490_offs in pair_candidates.items():
            if len(ldr490_offs) < 2:
                continue

            # Mach trap handlers are usually indirectly dispatched.
            if self.bl_callers.get(func_start, []):
                continue

            func_end = self._find_func_end(func_start, 0x1000)
            ldadda_count = 0
            has_movk_c8a2 = False
            has_high_caller_bl = False

            for o in range(func_start, func_end, 4):
                d = self._disas_at(o)
                if not d:
                    continue
                i = d[0]
                if i.mnemonic == "ldadda":
                    ldadda_count += 1
                elif i.mnemonic == "movk" and "#0xc8a2" in i.op_str:
                    has_movk_c8a2 = True
                elif i.mnemonic == "bl":
                    target = i.operands[0].imm
                    n_callers = len(self.bl_callers.get(target, []))
                    # >500 but <8000 excludes _panic (typically 8000+)
                    if 500 < n_callers < 8000:
                        has_high_caller_bl = True

            if ldadda_count >= 2 and has_movk_c8a2 and has_high_caller_bl:
                candidates.append((func_start, sorted(ldr490_offs)[1]))  # second pair

        if not candidates:
            self._log("  [-] function not found")
            return False

        # Trap handlers are usually referenced from data tables. Prefer
        # candidates with chained pointer refs from __DATA_CONST/__DATA.
        ranked = []
        for func_start, patch_off in candidates:
            data_refs = self._count_data_pointer_refs_to_function(func_start)
            ranked.append((data_refs, func_start, patch_off))

        with_data_refs = [item for item in ranked if item[0] > 0]
        pool = with_data_refs if with_data_refs else ranked
        pool.sort(reverse=True)

        # Reject ambiguous top score to avoid patching a wrong helper path.
        if len(pool) > 1 and pool[0][0] == pool[1][0]:
            self._log("  [-] ambiguous _task_for_pid candidates")
            for score, func_start, patch_off in pool[:5]:
                self._log(
                    f"      cand func=0x{func_start:X} patch=0x{patch_off:X} "
                    f"data_refs={score}"
                )
            return False

        score, func_start, patch_off = pool[0]
        self._log(
            f"  [+] _task_for_pid at 0x{func_start:X}, patch at 0x{patch_off:X} "
            f"(data_refs={score})"
        )
        self.emit(patch_off, NOP, "NOP [_task_for_pid proc_ro copy]")
        return True

    def _count_data_pointer_refs_to_function(self, target_off):
        """Count chained pointers in __DATA_CONST/__DATA resolving to target_off.

        Builds a one-time cache so candidate ranking stays fast.
        """
        if not hasattr(self, "_data_ptr_ref_counts_cache"):
            self._data_ptr_ref_counts_cache = self._build_data_pointer_ref_counts()
        return self._data_ptr_ref_counts_cache.get(target_off, 0)

    def _find_funcs_with_ldr490_pairs(self):
        """Return {func_start: [pair_off,...]} for ldr #0x490 + str #0xc pairs."""
        funcs = {}
        ks, ke = self.kern_text
        for off in range(ks, ke - 4, 4):
            ins = _rd32(self.raw, off)
            # LDR Wt, [Xn, #imm] (unsigned immediate)
            if (ins & 0xFFC00000) != 0xB9400000:
                continue
            if ((ins >> 10) & 0xFFF) != 0x124:  # 0x490 / 4
                continue

            nxt = _rd32(self.raw, off + 4)
            # STR Wt, [Xn, #imm] (unsigned immediate)
            if (nxt & 0xFFC00000) != 0xB9000000:
                continue
            if ((nxt >> 10) & 0xFFF) != 0x3:  # 0xC / 4
                continue

            func_start = self.find_function_start(off)
            if func_start < 0:
                continue
            funcs.setdefault(func_start, []).append(off)
        return funcs

    def _build_data_pointer_ref_counts(self):
        """Build target_off -> reference count for chained data pointers."""
        counts = Counter()
        for name, _, seg_foff, seg_fsize, _ in self.all_segments:
            if name not in ("__DATA_CONST", "__DATA") or seg_fsize <= 0:
                continue
            seg_end = seg_foff + seg_fsize
            for off in range(seg_foff, seg_end - 8, 8):
                val = _rd64(self.raw, off)
                target = self._decode_chained_ptr(val)
                if target >= 0:
                    counts[target] += 1
        return counts

    def _find_second_ldr490(self, start, end):
        """Find the second ldr wN,[xN,#0x490]+str wN,[xN,#0xc] in range."""
        count = 0
        for off in range(start, end - 4, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "ldr":
                continue
            if "#0x490" not in d[0].op_str or not d[0].op_str.startswith("w"):
                continue
            d2 = self._disas_at(off + 4)
            if (
                d2
                and d2[0].mnemonic == "str"
                and "#0xc" in d2[0].op_str
                and d2[0].op_str.startswith("w")
            ):
                count += 1
                if count == 2:
                    return off
        return None
