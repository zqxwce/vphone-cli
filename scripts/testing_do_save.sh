#!/usr/bin/env zsh
set -euo pipefail

# Save a base-patched kernel for fast per-patch testing.
# Run once, then use testing_do_patch.sh <patch_name> to test individual patches.

PROJECT_DIR="$(cd "$(dirname "${0:a:h}")" && pwd)"
cd "$PROJECT_DIR"

VM_DIR="${VM_DIR:-vm}"

# ─── Kill existing vphone-cli ──────────────────────────────────────
echo "[save] killing existing vphone-cli..."
pkill -9 vphone-cli 2>/dev/null || true
sleep 1

# ─── Full pipeline with base patches only ──────────────────────────
echo "[save] fw_prepare..."
make fw_prepare

echo "[save] fw_patch_jb..."
make fw_patch_jb

# ─── Find and save kernelcache backup ──────────────────────────────
RESTORE_DIR=$(find "$VM_DIR" -maxdepth 1 -type d -name '*Restore*' | head -1)
KERNEL_PATH=$(find "$RESTORE_DIR" -name 'kernelcache.research.vphone600' | head -1)

if [[ -z "$KERNEL_PATH" ]]; then
    echo "[-] kernelcache not found in $RESTORE_DIR"
    exit 1
fi

BACKUP_PATH="${KERNEL_PATH}.base_backup"
cp "$KERNEL_PATH" "$BACKUP_PATH"
echo "[save] kernel backup saved: $BACKUP_PATH ($(wc -c < "$BACKUP_PATH") bytes)"
echo "[save] done. Now use: make testing_do_patch PATCH=<name>"
echo ""
echo "Available patch names:"
echo "  patch_post_validation_additional        (B5)"
echo "  patch_proc_security_policy              (B6)"
echo "  patch_proc_pidinfo                      (B7)"
echo "  patch_convert_port_to_map               (B8)"
echo "  patch_vm_fault_enter_prepare            (B9)"
echo "  patch_vm_map_protect                    (B10)"
echo "  patch_mac_mount                         (B11)"
echo "  patch_dounmount                         (B12)"
echo "  patch_bsd_init_auth                     (B13)"
echo "  patch_spawn_validate_persona            (B14)"
echo "  patch_task_for_pid                      (B15)"
echo "  patch_load_dylinker                     (B16)"
echo "  patch_shared_region_map                 (B17)"
echo "  patch_nvram_verify_permission           (B18)"
echo "  patch_io_secure_bsd_root                (B19)"
echo "  patch_thid_should_crash                 (B20)"
echo "  patch_cred_label_update_execve          (C21)"
echo "  patch_syscallmask_apply_to_proc         (C22)"
echo "  patch_hook_cred_label_update_execve     (C23)"
echo "  patch_kcall10                           (C24)"
