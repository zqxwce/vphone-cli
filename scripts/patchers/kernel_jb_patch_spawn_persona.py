"""Mixin: KernelJBPatchSpawnPersonaMixin."""

from .kernel_jb_base import ARM64_OP_IMM, NOP


class KernelJBPatchSpawnPersonaMixin:
    def patch_spawn_validate_persona(self):
        """NOP persona validation: LDR + TBNZ sites.
        Pattern: ldr wN, [xN, #0x600] (unique struct offset) followed by
        cbz wN then tbnz wN, #1 — NOP both the LDR and the TBNZ.
        """
        self._log("\n[JB] _spawn_validate_persona: NOP (2 sites)")

        # Try symbol first
        foff = self._resolve_symbol("_spawn_validate_persona")
        if foff >= 0:
            func_end = self._find_func_end(foff, 0x800)
            result = self._find_persona_pattern(foff, func_end)
            if result:
                self.emit(result[0], NOP, "NOP [_spawn_validate_persona LDR]")
                self.emit(result[1], NOP, "NOP [_spawn_validate_persona TBNZ]")
                return True

        anchor_func = self._find_spawn_anchor_func()
        if anchor_func < 0:
            self._log("  [-] spawn anchor function not found")
            return False
        anchor_end = self._find_func_end(anchor_func, 0x4000)

        # Legacy pattern, but restricted to spawn anchor function only.
        result = self._find_persona_pattern(anchor_func, anchor_end)
        if result:
            self.emit(result[0], NOP, "NOP [_spawn_validate_persona LDR]")
            self.emit(result[1], NOP, "NOP [_spawn_validate_persona TBNZ]")
            return True

        # Newer layout: `ldr x?, [x?, #0x2b8] ; ldrh wN, [sp, #imm] ; tbz wN,#1,target`
        # -> force skip of validation block by rewriting TBZ/TBNZ to unconditional branch.
        gate = self._find_persona_gate_branch(anchor_func, anchor_end)
        if gate:
            br_off, target = gate
            b_bytes = self._encode_b(br_off, target)
            if b_bytes:
                self.emit(
                    br_off,
                    b_bytes,
                    f"b #0x{target - br_off:X} [_spawn_validate_persona gate]",
                )
                return True

        self._log("  [-] pattern not found in spawn anchor (fail-closed)")
        return False

    def _find_persona_pattern(self, start, end):
        """Find ldr wN,[xN,#0x600] + tbnz wN,#1 pattern. Returns (ldr_off, tbnz_off)."""
        for off in range(start, end - 0x30, 4):
            d = self._disas_at(off)
            if not d or d[0].mnemonic != "ldr":
                continue
            if "#0x600" not in d[0].op_str or not d[0].op_str.startswith("w"):
                continue
            for delta in range(4, 0x30, 4):
                d2 = self._disas_at(off + delta)
                if d2 and d2[0].mnemonic == "tbnz" and "#1" in d2[0].op_str:
                    if d2[0].op_str.startswith("w"):
                        return (off, off + delta)
        return None

    def _find_spawn_anchor_func(self):
        primary = self._find_func_by_string(
            b"com.apple.private.spawn-panic-crash-behavior", self.kern_text
        )
        if primary >= 0:
            return primary
        return self._find_func_by_string(
            b"com.apple.private.spawn-subsystem-root", self.kern_text
        )

    def _find_persona_gate_branch(self, start, end):
        hits = []
        for off in range(start, end - 8, 4):
            d0 = self._disas_at(off)
            d1 = self._disas_at(off + 4)
            d2 = self._disas_at(off + 8)
            if not d0 or not d1 or not d2:
                continue
            i0, i1, i2 = d0[0], d1[0], d2[0]
            if i0.mnemonic != "ldr" or "#0x2b8" not in i0.op_str:
                continue
            if not i0.op_str.startswith("x"):
                continue
            if i1.mnemonic != "ldrh" or not i1.op_str.startswith("w"):
                continue
            reg = i1.op_str.split(",", 1)[0].strip()
            if i2.mnemonic not in ("tbz", "tbnz"):
                continue
            if not i2.op_str.startswith(f"{reg},"):
                continue
            if "#1" not in i2.op_str:
                continue

            target = None
            for op in reversed(i2.operands):
                if op.type == ARM64_OP_IMM:
                    target = op.imm
                    break
            if target is None or not (off + 8 < target < end):
                continue
            hits.append((off + 8, target))

        if len(hits) == 1:
            return hits[0]
        return None
