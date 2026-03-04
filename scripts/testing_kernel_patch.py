#!/usr/bin/env python3
"""
testing_kernel_patch.py — Restore base kernel backup and apply a single JB patch.

Usage:
    python3 testing_kernel_patch.py <vm_directory> <patch_name> [patch_name2 ...]

Example:
    python3 testing_kernel_patch.py vm patch_vm_fault_enter_prepare
    python3 testing_kernel_patch.py vm patch_mac_mount patch_dounmount
"""

import os
import shutil
import sys

from fw_patch import find_file, find_restore_dir, load_firmware, save_firmware
from patchers.kernel_jb import KernelJBPatcher


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <vm_dir> <patch_name> [patch_name2 ...]")
        sys.exit(1)

    vm_dir = os.path.abspath(sys.argv[1])
    patch_names = sys.argv[2:]

    restore_dir = find_restore_dir(vm_dir)
    if not restore_dir:
        print(f"[-] No *Restore* directory found in {vm_dir}")
        sys.exit(1)

    kernel_path = find_file(restore_dir, ["kernelcache.research.vphone600"], "kernelcache")
    backup_path = kernel_path + ".base_backup"

    if not os.path.exists(backup_path):
        print(f"[-] No backup found: {backup_path}")
        print(f"    Run 'make testing_do_save' first.")
        sys.exit(1)

    # Restore from backup
    shutil.copy2(backup_path, kernel_path)
    print(f"[*] Restored kernel from backup ({os.path.getsize(backup_path)} bytes)")

    # Load the kernel
    im4p, data, was_im4p, original_raw = load_firmware(kernel_path)
    fmt = "IM4P" if was_im4p else "raw"
    print(f"[*] Loaded: {fmt}, {len(data)} bytes")

    # Create patcher (inherits from KernelJBPatcherBase which inherits from KernelPatcher)
    kp = KernelJBPatcher(data)

    # Apply each requested patch
    applied = 0
    for patch_name in patch_names:
        method = getattr(kp, patch_name, None)
        if method is None:
            print(f"[-] Unknown patch: {patch_name}")
            print(f"    Available patches:")
            for name in sorted(dir(kp)):
                if name.startswith("patch_") and callable(getattr(kp, name)):
                    print(f"      {name}")
            sys.exit(1)

        print(f"\n[*] Applying: {patch_name}")
        method()

    # Apply the collected patches
    for off, patch_bytes, _ in kp.patches:
        data[off : off + len(patch_bytes)] = patch_bytes
        applied += 1

    print(f"\n[+] {applied} patch(es) applied from {len(patch_names)} method(s)")

    # Save
    save_firmware(kernel_path, im4p, data, was_im4p, original_raw)
    print(f"[+] Saved: {kernel_path}")


if __name__ == "__main__":
    main()
