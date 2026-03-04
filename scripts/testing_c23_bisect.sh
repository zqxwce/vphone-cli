#!/usr/bin/env zsh
set -euo pipefail

# Bisect C23 shellcode — restore, patch variant, rebuild ramdisk, boot.
#
# Usage: ./testing_c23_bisect.sh <variant>
#    or: make testing_c23_bisect_boot VARIANT=A
#
# Variants: A B C D E (see testing_c23_bisect.py)

typeset -a CHILD_PIDS=()

cleanup() {
    echo "\n[c23] cleaning up..."
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "[c23] killing PID $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    exit 0
}

trap cleanup EXIT INT TERM

PROJECT_DIR="$(cd "$(dirname "${0:a:h}")" && pwd)"
cd "$PROJECT_DIR"

VARIANT="${1:-}"
if [[ -z "$VARIANT" ]]; then
    echo "Usage: $0 <variant>"
    echo "  Variants: A B C D E"
    exit 1
fi

VM_DIR="${VM_DIR:-vm}"

echo "[c23] ═══════════════════════════════════════════"
echo "[c23] Bisect variant: $VARIANT"
echo "[c23] ═══════════════════════════════════════════"

# Kill existing
echo "[c23] killing existing vphone-cli..."
pkill -9 vphone-cli 2>/dev/null || true
sleep 1

# Restore + patch variant
echo "[c23] restoring base kernel + applying variant $VARIANT"
make testing_c23_bisect VARIANT="$VARIANT"

# Rebuild ramdisk
echo "[c23] testing_ramdisk_build..."
make testing_ramdisk_build

# Send ramdisk in background
echo "[c23] testing_ramdisk_send (background)..."
make testing_ramdisk_send &
CHILD_PIDS+=($!)

# Boot
echo "[c23] boot_dfu..."
make boot_dfu &
CHILD_PIDS+=($!)

echo "[c23] waiting for boot (PID ${CHILD_PIDS[-1]})..."
wait "${CHILD_PIDS[-1]}" 2>/dev/null || true
