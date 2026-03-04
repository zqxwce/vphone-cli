"""Mixin: KernelJBPatchCredLabelMixin."""

from .kernel_jb_base import asm, _rd32


class KernelJBPatchCredLabelMixin:
    _RET_INSNS = (0xD65F0FFF, 0xD65F0BFF, 0xD65F03C0)

    def _is_cred_label_execve_candidate(self, func_off, anchor_refs):
        """Validate candidate function shape for _cred_label_update_execve."""
        func_end = self._find_func_end(func_off, 0x1000)
        if func_end - func_off < 0x200:
            return False, 0, func_end

        anchor_hits = sum(1 for r in anchor_refs if func_off <= r < func_end)
        if anchor_hits == 0:
            return False, 0, func_end

        has_arg9_load = False
        has_flags_load = False
        has_flags_store = False

        for off in range(func_off, func_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            op = i.op_str.replace(" ", "")
            if i.mnemonic == "ldr" and op.startswith("x26,[x29"):
                has_arg9_load = True
                break

        for off in range(func_off, func_end, 4):
            d = self._disas_at(off)
            if not d:
                continue
            i = d[0]
            op = i.op_str.replace(" ", "")
            if i.mnemonic == "ldr" and op.startswith("w") and ",[x26" in op:
                has_flags_load = True
            elif i.mnemonic == "str" and op.startswith("w") and ",[x26" in op:
                has_flags_store = True
            if has_flags_load and has_flags_store:
                break

        ok = has_arg9_load and has_flags_load and has_flags_store
        score = anchor_hits * 10 + (1 if has_arg9_load else 0) + (1 if has_flags_load else 0) + (1 if has_flags_store else 0)
        return ok, score, func_end

    def _find_cred_label_execve_func(self):
        """Locate _cred_label_update_execve by AMFI kill-path string cluster."""
        anchor_strings = (
            b"AMFI: hook..execve() killing",
            b"Attempt to execute completely unsigned code",
            b"Attempt to execute a Legacy VPN Plugin",
            b"dyld signature cannot be verified",
        )

        anchor_refs = set()
        candidates = set()
        s, e = self.amfi_text

        for anchor in anchor_strings:
            str_off = self.find_string(anchor)
            if str_off < 0:
                continue
            refs = self.find_string_refs(str_off, s, e)
            if not refs:
                refs = self.find_string_refs(str_off)
            for adrp_off, _, _ in refs:
                anchor_refs.add(adrp_off)
                func_off = self.find_function_start(adrp_off)
                if func_off >= 0 and s <= func_off < e:
                    candidates.add(func_off)

        best_func = -1
        best_score = -1
        for func_off in sorted(candidates):
            ok, score, _ = self._is_cred_label_execve_candidate(func_off, anchor_refs)
            if ok and score > best_score:
                best_score = score
                best_func = func_off

        return best_func

    def _find_cred_label_return_site(self, func_off):
        """Pick a return site with full epilogue restore (SP/frame restored)."""
        func_end = self._find_func_end(func_off, 0x1000)
        fallback = -1
        for off in range(func_end - 4, func_off, -4):
            val = _rd32(self.raw, off)
            if val not in self._RET_INSNS:
                continue
            if fallback < 0:
                fallback = off

            saw_add_sp = False
            saw_ldp_fp = False
            for prev in range(max(func_off, off - 0x24), off, 4):
                d = self._disas_at(prev)
                if not d:
                    continue
                i = d[0]
                op = i.op_str.replace(" ", "")
                if i.mnemonic == "add" and op.startswith("sp,sp,#"):
                    saw_add_sp = True
                elif i.mnemonic == "ldp" and op.startswith("x29,x30,[sp"):
                    saw_ldp_fp = True

            if saw_add_sp and saw_ldp_fp:
                return off

        return fallback

    def patch_cred_label_update_execve(self):
        """Redirect _cred_label_update_execve to shellcode that sets cs_flags.

        Shellcode: LDR x0,[sp,#8]; LDR w1,[x0]; ORR w1,w1,#0x4000000;
                   ORR w1,w1,#0xF; AND w1,w1,#0xFFFFC0FF; STR w1,[x0];
                   MOV x0,xzr; RETAB
        """
        self._log("\n[JB] _cred_label_update_execve: shellcode (cs_flags)")

        func_off = -1

        # Try symbol first, but still validate shape.
        for sym, off in self.symbols.items():
            if "cred_label_update_execve" in sym and "hook" not in sym:
                ok, _, _ = self._is_cred_label_execve_candidate(off, set([off]))
                if ok:
                    func_off = off
                break

        if func_off < 0:
            func_off = self._find_cred_label_execve_func()

        if func_off < 0:
            self._log("  [-] function not found, skipping shellcode patch")
            return False

        # Find code cave
        cave = self._find_code_cave(32)  # 8 instructions = 32 bytes
        if cave < 0:
            self._log("  [-] no code cave found for shellcode")
            return False

        # Assemble shellcode
        shellcode = (
            asm("ldr x0, [sp, #8]")  # load cred pointer
            + asm("ldr w1, [x0]")  # load cs_flags
            + asm("orr w1, w1, #0x4000000")  # set CS_PLATFORM_BINARY
            + asm(
                "orr w1, w1, #0xF"
            )  # set CS_VALID|CS_ADHOC|CS_GET_TASK_ALLOW|CS_INSTALLER
            + bytes(
                [0x21, 0x64, 0x12, 0x12]
            )  # AND w1, w1, #0xFFFFC0FF (clear CS_HARD|CS_KILL etc)
            + asm("str w1, [x0]")  # store back
            + asm("mov x0, xzr")  # return 0
            + bytes([0xFF, 0x0F, 0x5F, 0xD6])  # RETAB
        )

        ret_off = self._find_cred_label_return_site(func_off)
        if ret_off < 0:
            self._log("  [-] function return not found")
            return False

        # Write shellcode to cave
        for i in range(0, len(shellcode), 4):
            self.emit(
                cave + i,
                shellcode[i : i + 4],
                f"shellcode+{i} [_cred_label_update_execve]",
            )

        # Branch from function return to cave
        b_bytes = self._encode_b(ret_off, cave)
        if b_bytes:
            self.emit(
                ret_off, b_bytes, f"b cave [_cred_label_update_execve -> 0x{cave:X}]"
            )
        else:
            self._log("  [-] branch to cave out of range")
            return False

        return True
