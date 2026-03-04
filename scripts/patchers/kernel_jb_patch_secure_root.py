"""Mixin: KernelJBPatchSecureRootMixin."""

from .kernel_jb_base import ARM64_OP_IMM, asm


class KernelJBPatchSecureRootMixin:
    def patch_io_secure_bsd_root(self):
        """Skip security check in _IOSecureBSDRoot.
        Prefer symbol. On stripped kernels, resolve a function that references both
        "SecureRoot" and "SecureRootName" and patch a strict policy branch site.
        """
        self._log("\n[JB] _IOSecureBSDRoot: skip check")

        # Try symbol first
        foff = self._resolve_symbol("_IOSecureBSDRoot")
        if foff < 0:
            foff = self._find_secure_root_function()
        if foff < 0:
            self._log("  [-] function not found")
            return False

        func_end = self._find_func_end(foff, 0x1200)
        site = self._find_secure_root_branch_site(foff, func_end)
        if not site:
            self._log("  [-] secure-root policy branch not found")
            return False

        off, target = site
        b_bytes = self._compile_branch_checked(off, target)
        self.emit(off, b_bytes, f"b #0x{target - off:X} [_IOSecureBSDRoot]")
        return True

    def _find_secure_root_function(self):
        funcs_with_name = self._functions_referencing_string(b"SecureRootName")
        if not funcs_with_name:
            return -1

        funcs_with_root = self._functions_referencing_string(b"SecureRoot")
        common = funcs_with_name & funcs_with_root
        if not common:
            # Fail closed: a plain SecureRootName-only function is often setup/epilogue code.
            return -1

        # Deterministic pick: lowest function offset among common candidates.
        return min(common)

    def _functions_referencing_string(self, needle):
        func_starts = set()
        for str_off in self._all_cstring_offsets(needle):
            refs = self.find_string_refs(str_off, *self.kern_text)
            for adrp_off, _, _ in refs:
                fn = self.find_function_start(adrp_off)
                if fn >= 0:
                    func_starts.add(fn)
        return func_starts

    def _all_cstring_offsets(self, needle):
        if isinstance(needle, str):
            needle = needle.encode()
        out = []
        start = 0
        while True:
            pos = self.raw.find(needle, start)
            if pos < 0:
                break
            cstr = pos
            while cstr > 0 and self.raw[cstr - 1] != 0:
                cstr -= 1
            cend = self.raw.find(b"\x00", cstr)
            if cend > cstr and self.raw[cstr:cend] == needle:
                out.append(cstr)
            start = pos + 1
        return sorted(set(out))

    def _find_secure_root_branch_site(self, func_start, func_end):
        # Strict selection:
        #  - forward conditional branch
        #  - on w0
        #  - immediately after BL (typical compare/callback check)
        #  - not in epilogue guard area (AUTIBSP/TBZ+BRK integrity checks)
        for off in range(func_start, func_end - 4, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            if i.mnemonic not in ("cbnz", "cbz"):
                continue
            if not i.op_str.replace(" ", "").startswith("w0,"):
                continue

            prev = self._disas_at(off - 4)
            if not prev or not prev[0].mnemonic.startswith("bl"):
                continue

            target = None
            for op in reversed(i.operands):
                if op.type == ARM64_OP_IMM:
                    target = op.imm
                    break
            if not target or not (off < target < func_end):
                continue

            if self._looks_like_epilogue_guard(off, target, func_end):
                continue

            return (off, target)

        return None

    def _looks_like_epilogue_guard(self, off, target, func_end):
        if off >= func_end - 0x40 or target >= func_end - 0x20:
            return True
        for probe in range(max(target - 4, 0), min(target + 0x14, func_end), 4):
            d = self._disas_at(probe)
            if d and d[0].mnemonic == "brk":
                return True
        for probe in range(max(off - 0x10, 0), off + 4, 4):
            d = self._disas_at(probe)
            if d and d[0].mnemonic == "autibsp":
                return True
        return False

    def _compile_branch_checked(self, off, target):
        delta = target - off
        b_bytes = asm(f"b #{delta}")
        insns = self._disas_n(b_bytes, 0, 1)
        assert insns, "capstone decode failed for secure-root branch patch"
        ins = insns[0]
        assert ins.mnemonic == "b", (
            f"secure-root branch decode mismatch: expected 'b', got '{ins.mnemonic}'"
        )
        got_target = None
        for op in reversed(ins.operands):
            if op.type == ARM64_OP_IMM:
                got_target = op.imm
                break
        assert got_target == delta, (
            "secure-root branch target mismatch: "
            f"expected delta 0x{delta:X}, got 0x{(got_target or -1):X}"
        )
        return b_bytes
