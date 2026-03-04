#!/usr/bin/env zsh
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# testing_batch.sh — Batch-test kernel JB patches one at a time.
#
# Prerequisite: run `make testing_do_save` first to create base backup.
#
# For each patch:
#   1. Restore base kernel + apply single patch
#   2. Build ramdisk
#   3. Boot DFU (vphone-cli --no-graphics --dfu)
#   4. Send boot chain via irecovery
#   5. Wait up to 2 minutes, watching for panic
#   6. Save output → testing_results/<patch_name>.log
#   7. Kill everything, move to next patch
#
# Usage:
#   ./testing_batch.sh                          # test all uncommented B/C patches
#   ./testing_batch.sh patch_mac_mount patch_dounmount  # test specific patches
# ═══════════════════════════════════════════════════════════════════

PROJECT_DIR="$(cd "$(dirname "${0:a:h}")" && pwd)"
cd "$PROJECT_DIR"

VM_DIR="$PROJECT_DIR/${VM_DIR:-vm}"
RESULTS_DIR="$PROJECT_DIR/testing_results"
TIMEOUT_SECS=120  # 2 minutes

BINARY="$PROJECT_DIR/.build/release/vphone-cli"
IRECOVERY="$PROJECT_DIR/.limd/bin/irecovery"
PYTHON="$PROJECT_DIR/.venv/bin/python3"

mkdir -p "$RESULTS_DIR"

# ─── Default patch list (all B + C patches) ────────────────────────
ALL_PATCHES=(
    patch_post_validation_additional        # B5
    patch_proc_security_policy              # B6
    patch_proc_pidinfo                      # B7
    patch_convert_port_to_map               # B8
    patch_vm_fault_enter_prepare            # B9
    patch_vm_map_protect                    # B10
    patch_mac_mount                         # B11
    patch_dounmount                         # B12
    patch_bsd_init_auth                     # B13
    patch_spawn_validate_persona            # B14
    patch_task_for_pid                      # B15
    patch_load_dylinker                     # B16
    patch_shared_region_map                 # B17
    patch_nvram_verify_permission           # B18
    patch_io_secure_bsd_root                # B19
    patch_thid_should_crash                 # B20
    patch_cred_label_update_execve          # C21
    patch_syscallmask_apply_to_proc         # C22
    patch_hook_cred_label_update_execve     # C23
    patch_kcall10                           # C24
)

# Use args if provided, otherwise test all
if (( $# > 0 )); then
    PATCHES=("$@")
else
    PATCHES=("${ALL_PATCHES[@]}")
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  Batch kernel JB patch tester"
echo "  Testing ${#PATCHES[@]} patch(es), ${TIMEOUT_SECS}s timeout each"
echo "  Results → $RESULTS_DIR/"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── Verify backup exists ──────────────────────────────────────────
RESTORE_DIR=$(find "$VM_DIR" -maxdepth 1 -type d -name '*Restore*' | head -1)
KERNEL_BACKUP=$(find "$RESTORE_DIR" -name 'kernelcache.research.vphone600.base_backup' 2>/dev/null | head -1)
if [[ -z "$KERNEL_BACKUP" ]]; then
    echo "[-] No kernel backup found. Run 'make testing_do_save' first."
    exit 1
fi
echo "[*] Kernel backup: $KERNEL_BACKUP"
echo ""

# ─── Summary file ──────────────────────────────────────────────────
SUMMARY="$RESULTS_DIR/_summary.txt"
echo "Batch test run: $(date)" > "$SUMMARY"
echo "Timeout: ${TIMEOUT_SECS}s" >> "$SUMMARY"
echo "─────────────────────────────────────────" >> "$SUMMARY"

# ─── Test each patch ───────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0
TOTAL=${#PATCHES[@]}

for i in {1..$TOTAL}; do
    PATCH="${PATCHES[$i]}"
    LOG="$RESULTS_DIR/${PATCH}.log"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  [$i/$TOTAL] Testing: $PATCH"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Clean up any prior vphone-cli
    pkill -9 vphone-cli 2>/dev/null || true
    sleep 1

    # Header in log
    {
        echo "Patch: $PATCH"
        echo "Date: $(date)"
        echo "Timeout: ${TIMEOUT_SECS}s"
        echo "══════════════════════════════════════════"
    } > "$LOG"

    # Step 1: Restore kernel + apply patch
    echo "  [1/4] Patching kernel..."
    {
        echo ""
        echo "── kernel patch ──"
        "$PYTHON" "$PROJECT_DIR/scripts/testing_kernel_patch.py" "$VM_DIR" "$PATCH" 2>&1
    } >> "$LOG" 2>&1

    PATCH_EXIT=$?
    if (( PATCH_EXIT != 0 )); then
        echo "  [-] Patch failed (exit $PATCH_EXIT) — skipping"
        echo "$PATCH  ERROR  patch_failed" >> "$SUMMARY"
        ERROR_COUNT=$(( ERROR_COUNT + 1 ))
        continue
    fi

    # Step 2: Build ramdisk
    echo "  [2/4] Building ramdisk..."
    {
        echo ""
        echo "── ramdisk build ──"
        make -C "$PROJECT_DIR" testing_ramdisk_build VM_DIR="$VM_DIR" 2>&1
    } >> "$LOG" 2>&1

    # Step 3: Boot DFU (capture output)
    echo "  [3/4] Booting DFU..."
    {
        echo ""
        echo "── boot output ──"
    } >> "$LOG"

    # Start vphone-cli in background, capturing output
    "$BINARY" \
        --rom "$VM_DIR/AVPBooter.vresearch1.bin" \
        --disk "$VM_DIR/Disk.img" \
        --nvram "$VM_DIR/nvram.bin" \
        --machine-id "$VM_DIR/machineIdentifier.bin" \
        --cpu 8 --memory 8192 \
        --sep-rom "$VM_DIR/AVPSEPBooter.vresearch1.bin" \
        --sep-storage "$VM_DIR/SEPStorage" \
        --no-graphics --dfu \
        >> "$LOG" 2>&1 &
    VM_PID=$!

    # Step 4: Send boot chain
    echo "  [4/4] Sending boot chain..."
    {
        echo ""
        echo "── ramdisk send ──"
        make -C "$PROJECT_DIR" testing_ramdisk_send VM_DIR="$VM_DIR" 2>&1
    } >> "$LOG" 2>&1 || true

    # ─── Monitor for panic or timeout ──────────────────────────────
    echo "  [*] Monitoring for ${TIMEOUT_SECS}s (panic or timeout)..."

    RESULT="TIMEOUT"
    START_TIME=$SECONDS

    while (( SECONDS - START_TIME < TIMEOUT_SECS )); do
        # Check if VM died
        if ! kill -0 "$VM_PID" 2>/dev/null; then
            RESULT="VM_DIED"
            break
        fi

        # Check log for panic
        if grep -qi 'panic' "$LOG" 2>/dev/null; then
            # Give a few more seconds for full panic log to flush
            sleep 5
            RESULT="PANIC"
            break
        fi

        sleep 3
    done

    ELAPSED=$(( SECONDS - START_TIME ))

    # Kill VM
    kill -9 "$VM_PID" 2>/dev/null || true
    wait "$VM_PID" 2>/dev/null || true
    # Also kill any orphaned vphone-cli
    pkill -9 vphone-cli 2>/dev/null || true

    # Append result to log
    {
        echo ""
        echo "══════════════════════════════════════════"
        echo "RESULT: $RESULT"
        echo "ELAPSED: ${ELAPSED}s"
    } >> "$LOG"

    # Record
    case "$RESULT" in
        PANIC)
            echo "  [X] PANIC after ${ELAPSED}s → $LOG"
            echo "$PATCH  PANIC  ${ELAPSED}s" >> "$SUMMARY"
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            ;;
        VM_DIED)
            echo "  [X] VM died after ${ELAPSED}s → $LOG"
            echo "$PATCH  VM_DIED  ${ELAPSED}s" >> "$SUMMARY"
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            ;;
        TIMEOUT)
            echo "  [+] No panic in ${TIMEOUT_SECS}s (likely OK) → $LOG"
            echo "$PATCH  OK  ${TIMEOUT_SECS}s" >> "$SUMMARY"
            PASS_COUNT=$(( PASS_COUNT + 1 ))
            ;;
    esac

    echo ""
    sleep 2
done

# ─── Final summary ─────────────────────────────────────────────────
{
    echo ""
    echo "═══════════════════════════════════════════"
    echo "TOTAL: $TOTAL  PASS: $PASS_COUNT  FAIL: $FAIL_COUNT  ERROR: $ERROR_COUNT"
} >> "$SUMMARY"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  DONE — $TOTAL tested: $PASS_COUNT pass, $FAIL_COUNT fail, $ERROR_COUNT error"
echo "  Summary: $SUMMARY"
echo "  Logs:    $RESULTS_DIR/<patch_name>.log"
echo "═══════════════════════════════════════════════════════════════"
cat "$SUMMARY"
