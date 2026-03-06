#!/bin/zsh
# ramdisk_send.sh — Send signed ramdisk components to device via irecovery.
#
# Usage: ./ramdisk_send.sh [ramdisk_dir]
#
# Expects device in DFU mode. Loads iBSS/iBEC, then boots with
# SPTM, TXM, trustcache, ramdisk, device tree, SEP, and kernel.
set -euo pipefail

IRECOVERY="${IRECOVERY:-irecovery}"
IRECOVERY_ECID="${IRECOVERY_ECID:-}"
RAMDISK_DIR="${1:-Ramdisk}"

IRECOVERY_ARGS=()
if [[ -n "$IRECOVERY_ECID" ]]; then
    IRECOVERY_ECID="${IRECOVERY_ECID#0x}"
    IRECOVERY_ECID="${IRECOVERY_ECID#0X}"
    [[ "$IRECOVERY_ECID" =~ ^[0-9A-Fa-f]{1,16}$ ]] || {
        echo "[-] Invalid IRECOVERY_ECID: ${IRECOVERY_ECID}"
        exit 1
    }
    IRECOVERY_ECID="0x${IRECOVERY_ECID:u}"
    IRECOVERY_ARGS=(-i "$IRECOVERY_ECID")
    echo "[*] Using ECID selector for irecovery: ${IRECOVERY_ECID}"
fi

irecovery_cmd() {
    "$IRECOVERY" "${IRECOVERY_ARGS[@]}" "$@"
}

if [[ ! -d "$RAMDISK_DIR" ]]; then
    echo "[-] Ramdisk directory not found: $RAMDISK_DIR"
    echo "    Run 'make ramdisk_build' first."
    exit 1
fi

echo "[*] Sending ramdisk from $RAMDISK_DIR ..."

KERNEL_IMG="$RAMDISK_DIR/krnl.img4"
if [[ -f "$RAMDISK_DIR/krnl.ramdisk.img4" ]]; then
    KERNEL_IMG="$RAMDISK_DIR/krnl.ramdisk.img4"
    echo "  [*] Using ramdisk kernel variant: $(basename "$KERNEL_IMG")"
fi
[[ -f "$KERNEL_IMG" ]] || {
    echo "[-] Kernel image not found: $KERNEL_IMG"
    exit 1
}

# 1. Load iBSS + iBEC (DFU → recovery)
echo "  [1/8] Loading iBSS..."
irecovery_cmd -f "$RAMDISK_DIR/iBSS.vresearch101.RELEASE.img4"

echo "  [2/8] Loading iBEC..."
irecovery_cmd -f "$RAMDISK_DIR/iBEC.vresearch101.RELEASE.img4"
irecovery_cmd -c go

sleep 1

# 2. Load SPTM
echo "  [3/8] Loading SPTM..."
irecovery_cmd -f "$RAMDISK_DIR/sptm.vresearch1.release.img4"
irecovery_cmd -c firmware

# 3. Load TXM
echo "  [4/8] Loading TXM..."
irecovery_cmd -f "$RAMDISK_DIR/txm.img4"
irecovery_cmd -c firmware

# 4. Load trustcache
echo "  [5/8] Loading trustcache..."
irecovery_cmd -f "$RAMDISK_DIR/trustcache.img4"
irecovery_cmd -c firmware

# 5. Load ramdisk
echo "  [6/8] Loading ramdisk..."
irecovery_cmd -f "$RAMDISK_DIR/ramdisk.img4"
sleep 2
irecovery_cmd -c ramdisk

# 6. Load device tree
echo "  [7/8] Loading device tree..."
irecovery_cmd -f "$RAMDISK_DIR/DeviceTree.vphone600ap.img4"
irecovery_cmd -c devicetree

# 7. Load SEP
echo "  [8/8] Loading SEP..."
irecovery_cmd -f "$RAMDISK_DIR/sep-firmware.vresearch101.RELEASE.img4"
irecovery_cmd -c firmware

# 8. Load kernel and boot
echo "  [*] Booting kernel..."
irecovery_cmd -f "$KERNEL_IMG"
irecovery_cmd -c bootx

echo "[+] Boot sequence complete. Device should be booting into ramdisk."
