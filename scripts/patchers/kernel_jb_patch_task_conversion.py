"""Mixin: KernelJBPatchTaskConversionMixin."""

import os

from .kernel_jb_base import (
    ARM64_OP_REG,
    ARM64_OP_MEM,
    ARM64_REG_X0,
    ARM64_REG_X1,
    ARM64_REG_W0,
    CMP_XZR_XZR,
    asm,
    struct,
    _rd32,
)


def _u32(insn):
    return struct.unpack("<I", asm(insn))[0]


def _derive_mask_and_value(insns):
    vals = [_u32(i) for i in insns]
    mask = 0xFFFFFFFF
    for v in vals[1:]:
        mask &= ~(vals[0] ^ v)
    value = vals[0] & mask
    return mask, value


def _field_mask(total_bits=32, variable_fields=()):
    mask = (1 << total_bits) - 1
    for start, width in variable_fields:
        mask &= ~(((1 << width) - 1) << start)
    return mask & ((1 << total_bits) - 1)


class KernelJBPatchTaskConversionMixin:
    _ALLOW_SLOW_FALLBACK = (
        os.environ.get("VPHONE_TASK_CONV_ALLOW_SLOW_FALLBACK", "").strip() == "1"
    )

    # Build all matcher constants from keystone-assembled instruction bytes.
    # No hardcoded opcode constants.
    _CMP_XN_X0_MASK, _CMP_XN_X0_VAL = _derive_mask_and_value(
        ("cmp x0, x0", "cmp x1, x0", "cmp x30, x0")
    )
    _CMP_XN_X1_MASK, _CMP_XN_X1_VAL = _derive_mask_and_value(
        ("cmp x0, x1", "cmp x1, x1", "cmp x30, x1")
    )
    _BEQ_MASK = _field_mask(variable_fields=((5, 19),))
    _BEQ_VAL = _u32("b.eq #0x100") & _BEQ_MASK
    _LDR_X_UNSIGNED_MASK = _field_mask(variable_fields=((0, 5), (5, 5), (10, 12)))
    _LDR_X_UNSIGNED_VAL = _u32("ldr x0, [x0]") & _LDR_X_UNSIGNED_MASK
    _ADRP_MASK = 0x9F000000
    _ADRP_VAL = 0x90000000
    _BL_MASK = 0xFC000000
    _BL_VAL = 0x94000000
    _CBZ_W_MASK = 0x7F000000
    _CBZ_W_VAL = 0x34000000
    _CBNZ_W_VAL = 0x35000000
    _MOV_X19_X0 = _u32("mov x19, x0")
    _MOV_X0_X1 = _u32("mov x0, x1")

    def patch_task_conversion_eval_internal(self):
        """Allow task conversion: cmp Xn,x0 -> cmp xzr,xzr at unique guard site."""
        self._log("\n[JB] task_conversion_eval_internal: cmp xzr,xzr")

        ks, ke = self.kern_text
        candidates = self._collect_candidates_fast(ks, ke)
        # Fail-closed by default. Slow fallback can be explicitly enabled for
        # manual triage on unknown kernels.
        if len(candidates) != 1 and self._ALLOW_SLOW_FALLBACK:
            self._log(
                "  [!] fast matcher non-unique, trying slow fallback "
                "(VPHONE_TASK_CONV_ALLOW_SLOW_FALLBACK=1)"
            )
            candidates = self._collect_candidates_slow(ks, ke)

        if len(candidates) != 1:
            msg = (
                "  [-] expected 1 task-conversion guard site, found "
                f"{len(candidates)}"
            )
            if not self._ALLOW_SLOW_FALLBACK:
                msg += " (slow fallback disabled)"
            self._log(msg)
            return False

        self.emit(
            candidates[0], CMP_XZR_XZR, "cmp xzr,xzr [_task_conversion_eval_internal]"
        )
        return True

    @staticmethod
    def _decode_b_cond_target(off, insn):
        imm19 = (insn >> 5) & 0x7FFFF
        if imm19 & (1 << 18):
            imm19 -= 1 << 19
        return off + imm19 * 4

    def _is_candidate_context_safe(self, off, cmp_reg):
        # Require ADRP + LDR preamble for the same register.
        p2 = _rd32(self.raw, off - 8)
        if (p2 & self._ADRP_MASK) != self._ADRP_VAL:
            return False
        if (p2 & 0x1F) != cmp_reg:
            return False

        # Require the known post-compare sequence shape.
        if _rd32(self.raw, off + 16) != self._MOV_X19_X0:
            return False
        if _rd32(self.raw, off + 20) != self._MOV_X0_X1:
            return False

        i6 = _rd32(self.raw, off + 24)
        if (i6 & self._BL_MASK) != self._BL_VAL:
            return False

        i7 = _rd32(self.raw, off + 28)
        op = i7 & self._CBZ_W_MASK
        if op not in (self._CBZ_W_VAL, self._CBNZ_W_VAL):
            return False
        if (i7 & 0x1F) != 0:  # require w0
            return False

        # Both b.eq targets must be forward and nearby in the same routine.
        t1 = self._decode_b_cond_target(off + 4, _rd32(self.raw, off + 4))
        t2 = self._decode_b_cond_target(off + 12, _rd32(self.raw, off + 12))
        if t1 <= off or t2 <= off:
            return False
        if (t1 - off) > 0x200 or (t2 - off) > 0x200:
            return False
        return True

    def _collect_candidates_fast(self, start, end):
        cache = getattr(self, "_jb_scan_cache", None)
        key = ("task_conversion_fast", start, end)
        if cache is not None:
            cached = cache.get(key)
            if cached is not None:
                return cached

        out = []
        for off in range(start + 8, end - 28, 4):
            i0 = _rd32(self.raw, off)
            if (i0 & self._CMP_XN_X0_MASK) != self._CMP_XN_X0_VAL:
                continue
            cmp_reg = (i0 >> 5) & 0x1F

            p = _rd32(self.raw, off - 4)
            if (p & self._LDR_X_UNSIGNED_MASK) != self._LDR_X_UNSIGNED_VAL:
                continue
            p_rt = p & 0x1F
            p_rn = (p >> 5) & 0x1F
            if p_rt != cmp_reg or p_rn != cmp_reg:
                continue

            i1 = _rd32(self.raw, off + 4)
            if (i1 & self._BEQ_MASK) != self._BEQ_VAL:
                continue

            i2 = _rd32(self.raw, off + 8)
            if (i2 & self._CMP_XN_X1_MASK) != self._CMP_XN_X1_VAL:
                continue
            if ((i2 >> 5) & 0x1F) != cmp_reg:
                continue

            i3 = _rd32(self.raw, off + 12)
            if (i3 & self._BEQ_MASK) != self._BEQ_VAL:
                continue

            if not self._is_candidate_context_safe(off, cmp_reg):
                continue

            out.append(off)
        if cache is not None:
            cache[key] = out
        return out

    def _collect_candidates_slow(self, start, end):
        cache = getattr(self, "_jb_scan_cache", None)
        key = ("task_conversion_slow", start, end)
        if cache is not None:
            cached = cache.get(key)
            if cached is not None:
                return cached

        out = []
        for off in range(start + 4, end - 12, 4):
            d0 = self._disas_at(off)
            if not d0:
                continue
            i0 = d0[0]
            if i0.mnemonic != "cmp" or len(i0.operands) < 2:
                continue
            a0, a1 = i0.operands[0], i0.operands[1]
            if not (a0.type == ARM64_OP_REG and a1.type == ARM64_OP_REG):
                continue
            if a1.reg != ARM64_REG_X0:
                continue
            cmp_reg = a0.reg

            dp = self._disas_at(off - 4)
            d1 = self._disas_at(off + 4)
            d2 = self._disas_at(off + 8)
            d3 = self._disas_at(off + 12)
            if not dp or not d1 or not d2 or not d3:
                continue
            p = dp[0]
            i1, i2, i3 = d1[0], d2[0], d3[0]

            if p.mnemonic != "ldr" or len(p.operands) < 2:
                continue
            p0, p1 = p.operands[0], p.operands[1]
            if p0.type != ARM64_OP_REG or p0.reg != cmp_reg:
                continue
            if p1.type != ARM64_OP_MEM:
                continue
            if p1.mem.base != cmp_reg:
                continue

            if i1.mnemonic != "b.eq":
                continue
            if i2.mnemonic != "cmp" or len(i2.operands) < 2:
                continue
            j0, j1 = i2.operands[0], i2.operands[1]
            if not (j0.type == ARM64_OP_REG and j1.type == ARM64_OP_REG):
                continue
            if not (j0.reg == cmp_reg and j1.reg == ARM64_REG_X1):
                continue
            if i3.mnemonic != "b.eq":
                continue

            out.append(off)
        if cache is not None:
            cache[key] = out
        return out
