#!/usr/bin/env python3
"""
testing_c23_bisect.py — Bisect C23 shellcode to find which part causes PAC panic.

Usage:
    python3 testing_c23_bisect.py <vm_dir> <variant>

Variants (progressive complexity):
    A  — PACIBSP + save/restore regs + B hook+4  (stack frame, no calls)
    B  — A + mrs tpidr_el1 + vfs_context build   (register reads, no calls)
    C  — B + BL vnode_getattr                     (external function call)
    D  — C + ownership propagation (uid/gid/csflags writes)
    E  — full shellcode (same as kernel_jb_patch_hook_cred_label.py)

Each variant is strictly additive — if A boots, B adds only the next layer.
"""

import os
import shutil
import sys

from fw_patch import find_file, find_restore_dir, load_firmware, save_firmware
from patchers.kernel_jb import KernelJBPatcher
from patchers.kernel_jb_base import asm, _rd32, _rd64, NOP

PACIBSP = bytes([0x7F, 0x23, 0x03, 0xD5])


def build_variant(kp, variant, cave, orig_hook, vnode_getattr_off):
    """Build shellcode for the given variant, return list of 4-byte parts."""

    # Helper: encode BL/B
    def bl(src, dst):
        return kp._encode_bl(src, dst)

    def b(src, dst):
        return kp._encode_b(src, dst)

    # B resume always at the last slot
    # We'll pad all variants to 46 slots for consistency.
    #
    # Variant A: stack frame only
    # Variant B: + tpidr_el1 / vfs_context
    # Variant C: + BL vnode_getattr
    # Variant D: + ownership propagation
    # Variant E: full (same as production)

    parts = []

    if variant in ("A", "B", "C", "D", "E"):
        parts.append(PACIBSP)                        # 0: relocated from hook
        # In full shellcode, slot 1 is: cbz x3, #0xb0 → slot 45
        # For variant A, skip the cbz (just NOP), so we always enter the frame
        if variant == "A":
            parts.append(NOP)                        # 1
        else:
            parts.append(asm("cbz x3, #0xb0"))      # 1: if vp==NULL → slot 45
        parts.append(asm("sub sp, sp, #0x400"))      # 2
        parts.append(asm("stp x29, x30, [sp]"))      # 3
        parts.append(asm("stp x0, x1, [sp, #16]"))   # 4
        parts.append(asm("stp x2, x3, [sp, #32]"))   # 5
        parts.append(asm("stp x4, x5, [sp, #48]"))   # 6
        parts.append(asm("stp x6, x7, [sp, #64]"))   # 7

    if variant in ("B", "C", "D", "E"):
        # Build vfs_context
        parts.append(asm("mrs x8, tpidr_el1"))       # 8: current_thread
        parts.append(asm("stp x8, x0, [sp, #0x70]")) # 9: {thread, cred}
        parts.append(asm("add x2, sp, #0x70"))        # 10: ctx = &vfs_ctx
        # Setup vnode_getattr args
        parts.append(asm("ldr x0, [sp, #0x28]"))     # 11: x0 = vp (saved x3)
        parts.append(asm("add x1, sp, #0x80"))        # 12: x1 = &vattr
        parts.append(asm("mov w8, #0x380"))           # 13: vattr size
        parts.append(asm("stp xzr, x8, [x1]"))       # 14: init vattr
        parts.append(asm("stp xzr, xzr, [x1, #0x10]"))  # 15: init vattr+16
        parts.append(NOP)                             # 16
        parts.append(NOP)                             # 17
    elif variant == "A":
        # Pad slots 8-17 with NOP
        for _ in range(10):
            parts.append(NOP)

    if variant in ("C", "D", "E"):
        # BL vnode_getattr
        vnode_bl_off = cave + 18 * 4
        vnode_bl = bl(vnode_bl_off, vnode_getattr_off)
        if not vnode_bl:
            print("  [-] BL to vnode_getattr out of range")
            return None
        parts.append(vnode_bl)                        # 18: BL vnode_getattr
    elif variant in ("A", "B"):
        parts.append(NOP)                             # 18

    if variant in ("C", "D", "E"):
        # After BL, check result — jump to restore on error
        parts.append(asm("cbnz x0, #0x4c"))          # 19: error → slot 38
    elif variant in ("A", "B"):
        parts.append(NOP)                             # 19

    if variant in ("D", "E"):
        # Ownership propagation
        parts.append(asm("mov w2, #0"))               # 20: changed = 0
        parts.append(asm("ldr w8, [sp, #0xCC]"))      # 21: va_mode
        parts.append(bytes([0xA8, 0x00, 0x58, 0x36])) # 22: tbz w8,#11
        parts.append(asm("ldr w8, [sp, #0xC4]"))      # 23: va_uid
        parts.append(asm("ldr x0, [sp, #0x18]"))      # 24: new_cred
        parts.append(asm("str w8, [x0, #0x18]"))      # 25: cred->uid
        parts.append(asm("mov w2, #1"))               # 26: changed = 1
        parts.append(asm("ldr w8, [sp, #0xCC]"))      # 27: va_mode
        parts.append(bytes([0xA8, 0x00, 0x50, 0x36])) # 28: tbz w8,#10
        parts.append(asm("mov w2, #1"))               # 29: changed = 1
        parts.append(asm("ldr w8, [sp, #0xC8]"))      # 30: va_gid
        parts.append(asm("ldr x0, [sp, #0x18]"))      # 31: new_cred
        parts.append(asm("str w8, [x0, #0x28]"))      # 32: cred->gid
        parts.append(asm("cbz w2, #0x14"))            # 33: if !changed → slot 38
        parts.append(asm("ldr x0, [sp, #0x20]"))      # 34: proc
        parts.append(asm("ldr w8, [x0, #0x454]"))     # 35: p_csflags
        parts.append(asm("orr w8, w8, #0x100"))       # 36: CS_VALID
        parts.append(asm("str w8, [x0, #0x454]"))     # 37: store
    elif variant in ("A", "B", "C"):
        # Pad slots 20-37 with NOP
        for _ in range(18):
            parts.append(NOP)

    # Restore and resume — always present (slots 38-45)
    if variant in ("A", "B", "C", "D", "E"):
        parts.append(asm("ldp x0, x1, [sp, #16]"))   # 38
        parts.append(asm("ldp x2, x3, [sp, #32]"))   # 39
        parts.append(asm("ldp x4, x5, [sp, #48]"))   # 40
        parts.append(asm("ldp x6, x7, [sp, #64]"))   # 41
        parts.append(asm("ldp x29, x30, [sp]"))       # 42
        parts.append(asm("add sp, sp, #0x400"))        # 43
        parts.append(NOP)                              # 44

        # B hook+4
        b_resume_off = cave + 45 * 4
        b_resume = b(b_resume_off, orig_hook + 4)
        if not b_resume:
            print("  [-] B to hook+4 out of range")
            return None
        parts.append(b_resume)                         # 45

    assert len(parts) == 46, f"Expected 46 parts, got {len(parts)}"
    return parts


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <vm_dir> <variant>")
        print(f"  Variants: A B C D E")
        sys.exit(1)

    vm_dir = os.path.abspath(sys.argv[1])
    variant = sys.argv[2].upper()
    if variant not in ("A", "B", "C", "D", "E"):
        print(f"[-] Unknown variant: {variant}")
        sys.exit(1)

    restore_dir = find_restore_dir(vm_dir)
    if not restore_dir:
        print(f"[-] No *Restore* directory found in {vm_dir}")
        sys.exit(1)

    kernel_path = find_file(restore_dir, ["kernelcache.research.vphone600"], "kernelcache")
    backup_path = kernel_path + ".base_backup"

    if not os.path.exists(backup_path):
        print(f"[-] No backup found: {backup_path}")
        sys.exit(1)

    # Restore from backup
    shutil.copy2(backup_path, kernel_path)
    print(f"[*] Restored kernel from backup")

    # Load
    im4p, data, was_im4p, original_raw = load_firmware(kernel_path)
    print(f"[*] Loaded: {len(data)} bytes")

    kp = KernelJBPatcher(data)

    # ── Find vnode_getattr ──
    vnode_getattr_off = kp._resolve_symbol("_vnode_getattr")
    if vnode_getattr_off < 0:
        vnode_getattr_off = kp._find_vnode_getattr_via_string()
    if vnode_getattr_off < 0:
        print("[-] vnode_getattr not found")
        sys.exit(1)
    print(f"[+] vnode_getattr at 0x{vnode_getattr_off:X}")

    # ── Find sandbox ops table ──
    ops_table = kp._find_sandbox_ops_table_via_conf()
    if ops_table is None:
        print("[-] sandbox ops table not found")
        sys.exit(1)

    # ── Find hook (largest in ops[0:30]) ──
    hook_index = -1
    orig_hook = -1
    best_size = 0
    for idx in range(0, 30):
        entry = kp._read_ops_entry(ops_table, idx)
        if entry is None or entry <= 0:
            continue
        if not any(s <= entry < e for s, e in kp.code_ranges):
            continue
        fend = kp._find_func_end(entry, 0x2000)
        fsize = fend - entry
        if fsize > best_size:
            best_size = fsize
            hook_index = idx
            orig_hook = entry

    if hook_index < 0 or best_size < 1000:
        print(f"[-] hook not found (best: idx={hook_index}, size={best_size})")
        sys.exit(1)
    print(f"[+] hook at ops[{hook_index}] = 0x{orig_hook:X} ({best_size} bytes)")

    # Verify PACIBSP
    first_insn = data[orig_hook:orig_hook + 4]
    if first_insn != PACIBSP:
        print(f"[-] first insn not PACIBSP (got 0x{_rd32(data, orig_hook):08X})")
        sys.exit(1)

    # ── Find code cave (200 bytes) ──
    cave = kp._find_code_cave(200)
    if cave < 0:
        print("[-] no code cave found")
        sys.exit(1)
    print(f"[+] code cave at 0x{cave:X}")

    # ── Build variant shellcode ──
    print(f"\n[*] Building variant {variant}")
    parts = build_variant(kp, variant, cave, orig_hook, vnode_getattr_off)
    if parts is None:
        sys.exit(1)

    # Write shellcode to data
    for i, part in enumerate(parts):
        off = cave + i * 4
        data[off:off + 4] = part

    # Patch function entry: PACIBSP → B cave
    b_to_cave = kp._encode_b(orig_hook, cave)
    if not b_to_cave:
        print("[-] B to cave out of range")
        sys.exit(1)
    data[orig_hook:orig_hook + 4] = b_to_cave

    print(f"[+] Variant {variant}: {len(parts)} instructions written to cave")
    print(f"[+] Trampoline: B 0x{cave:X} at 0x{orig_hook:X}")

    # Save
    save_firmware(kernel_path, im4p, data, was_im4p, original_raw)
    print(f"[+] Saved: {kernel_path}")


if __name__ == "__main__":
    main()
