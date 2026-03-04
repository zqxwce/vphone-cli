#!/usr/bin/env zsh
set -euo pipefail

# Fast test a single kernel JB patch.
# Restores base kernel backup, applies one patch, rebuilds ramdisk, boots.
#
# Usage: ./testing_do_patch.sh <patch_name>
#    or: make testing_do_patch PATCH=patch_vm_fault_enter_prepare

# ─── Track child PIDs for cleanup ───────────────────────────────────
typeset -a CHILD_PIDS=()

cleanup() {
    echo "\n[patch] cleaning up..."
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "[patch] killing PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    exit 0
}

trap cleanup EXIT INT TERM

PROJECT_DIR="$(cd "$(dirname "${0:a:h}")" && pwd)"
cd "$PROJECT_DIR"

PATCH_NAME="${1:-}"
if [[ -z "$PATCH_NAME" ]]; then
    echo "Usage: $0 <patch_name>"
    echo "  e.g. $0 patch_vm_fault_enter_prepare"
    exit 1
fi

VM_DIR="${VM_DIR:-vm}"

# ─── Kill existing vphone-cli ──────────────────────────────────────
echo "[patch] killing existing vphone-cli..."
pkill -9 vphone-cli 2>/dev/null || true
sleep 1

# ─── Restore kernel + apply single patch ───────────────────────────
echo "[patch] restoring base kernel + applying: $PATCH_NAME"
make testing_kernel_patch PATCH="$PATCH_NAME"

# ─── Rebuild ramdisk ────────────────────────────────────────────────
echo "[patch] testing_ramdisk_build..."
make testing_ramdisk_build

# ─── Send ramdisk in background ────────────────────────────────────
echo "[patch] testing_ramdisk_send (background)..."
make testing_ramdisk_send &
CHILD_PIDS+=($!)

# ─── Boot DFU ──────────────────────────────────────────────────────
echo "[patch] boot_dfu..."
make boot_dfu &
CHILD_PIDS+=($!)

echo "[patch] waiting for boot_dfu (PID ${CHILD_PIDS[-1]})..."
wait "${CHILD_PIDS[-1]}" 2>/dev/null || true
