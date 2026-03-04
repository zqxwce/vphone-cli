"""Mixin: KernelJBPatchMacMountMixin."""

from .kernel_jb_base import ARM64_OP_IMM, asm


class KernelJBPatchMacMountMixin:
    def patch_mac_mount(self):
        """Bypass MAC mount check in ___mac_mount-like flow.

        Old kernels may expose ___mac_mount/__mac_mount symbols directly.
        Stripped kernels are resolved via mount_common() call graph.
        We patch the conditional deny branch (`cbnz w0, ...`) rather than
        NOP'ing the BL itself, to avoid stale register state forcing errors.
        """
        self._log("\n[JB] ___mac_mount: bypass deny branch")

        # Try symbol first
        foff = self._resolve_symbol("___mac_mount")
        if foff < 0:
            foff = self._resolve_symbol("__mac_mount")
        strict = False
        if foff < 0:
            strict = True
            # Find via 'mount_common()' string → function area
            str_off = self.find_string(b"mount_common()")
            if str_off >= 0:
                refs = self.find_string_refs(str_off, *self.kern_text)
                if refs:
                    mount_common_func = self.find_function_start(refs[0][0])
                    if mount_common_func >= 0:
                        mc_end = self._find_func_end(mount_common_func, 0x2000)
                        for off in range(mount_common_func, mc_end, 4):
                            target = self._is_bl(off)
                            if (
                                target >= 0
                                and self.kern_text[0] <= target < self.kern_text[1]
                            ):
                                te = self._find_func_end(target, 0x1000)
                                site = self._find_mac_deny_site(
                                    target, te, require_error_return=True
                                )
                                if site:
                                    foff = target
                                    break

        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x1000)
        site = self._find_mac_deny_site(
            foff,
            func_end,
            require_error_return=strict,
        )
        if not site and strict:
            # Last-resort in stripped builds: still require the BL+CBNZ(w0) shape.
            site = self._find_mac_deny_site(foff, func_end, require_error_return=False)
        if not site:
            self._log("  [-] patch sites not found")
            return False

        bl_off, cb_off = site
        nop_patch = asm("nop")
        self._assert_patch_decode(nop_patch, "nop")
        self.emit(cb_off, nop_patch, "NOP [___mac_mount deny branch]")

        # Legacy companion tweak, kept for older layouts where x8 carries policy state.
        for off2 in range(bl_off + 8, min(bl_off + 0x60, func_end), 4):
            d2 = self._disas_at(off2)
            if not d2:
                continue
            if d2[0].mnemonic == "mov" and d2[0].op_str.startswith("x8,"):
                if d2[0].op_str != "x8, xzr":
                    mov_patch = asm("mov x8, xzr")
                    self._assert_patch_decode(mov_patch, "mov", "x8, xzr")
                    self.emit(off2, mov_patch, "mov x8,xzr [___mac_mount]")
                break
        return True

    def _find_mac_deny_site(self, start, end, require_error_return):
        for off in range(start, end - 8, 4):
            d0 = self._disas_at(off)
            if not d0 or d0[0].mnemonic != "bl":
                continue
            d1 = self._disas_at(off + 4)
            if not d1 or d1[0].mnemonic != "cbnz":
                continue
            if not d1[0].op_str.replace(" ", "").startswith("w0,"):
                continue
            if require_error_return:
                branch_target = self._branch_target(off + 4)
                if branch_target is None or not (off < branch_target < end):
                    continue
                if not self._looks_like_error_return(branch_target):
                    continue
            return (off, off + 4)
        return None

    def _branch_target(self, off):
        d = self._disas_at(off)
        if not d:
            return None
        for op in reversed(d[0].operands):
            if op.type == ARM64_OP_IMM:
                return op.imm
        return None

    def _looks_like_error_return(self, target):
        d = self._disas_at(target)
        if not d or d[0].mnemonic != "mov":
            return False
        op = d[0].op_str.replace(" ", "")
        if op.startswith("w0,#") and op != "w0,#0":
            return True
        if op.startswith("x0,#") and op != "x0,#0":
            return True
        return False

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
