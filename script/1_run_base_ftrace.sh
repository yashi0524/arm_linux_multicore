#!/bin/bash
# 2-core Base Platform RevC boot + ftrace regression test.
#
# BOOT=uefi (default): make base / make run-base
#   TF-A BL1 -> BL2 -> BL31 -> EDK2 (BL33) -> UEFI Shell -> startup.nsh
#   -> kernel EFI stub -> Linux
# BOOT=bwa: make base-bwa / make run-base-bwa
#   boot-wrapper (EL3) -> Linux
# Builds what's missing, boots; the model shuts itself down after
# rootfs/ftrace_test.sh prints its result.
# Exit code: 0 = PASS, 1 = FAIL, 2 = no result (timeout/panic).
#
# Usage (from the project root or anywhere):
#   [BOOT=uefi|bwa] script/1_run_base_ftrace.sh [log_file] [timeout_s]
# Defaults: build/run_base_ftrace.log (run_base_bwa_ftrace.log for bwa), 1200 s.

PROJ=$(cd "$(dirname "$0")/.." && pwd)
BOOT=${BOOT:-uefi}
case "$BOOT" in
    uefi) SUFFIX=""     ;;
    bwa)  SUFFIX="-bwa" ;;
    *)    echo "BOOT must be uefi or bwa (got '$BOOT')" >&2; exit 2 ;;
esac
LOG=${1:-$PROJ/build/run_base${SUFFIX/-/_}_ftrace.log}
TMO=${2:-1200}

source "$PROJ/script/0_env_var_setup.sh"
cd "$PROJ" || exit 2

make "base$SUFFIX" || exit 2

# shutdown_tag: the model exits as soon as ftrace_test.sh prints
# FTRACE_DONE (after its result line). `timeout` is only the fallback for
# a hang or panic. stdin from <(sleep) stays open so the model isn't fed
# EOF (a process substitution, not a pipe: bash doesn't wait on it).
timeout "$TMO" make "run-base$SUFFIX" \
    BASE_EXTRA="-C bp.pl011_uart0.shutdown_tag=FTRACE_DONE" \
    < <(sleep "$TMO") > "$LOG" 2>&1
result=$(grep -ao 'FTRACE_RESULT [A-Z]*' "$LOG" | head -1)

echo "--- firmware (BOOT=$BOOT) ---"
grep -aE 'BL31: v|Boot-wrapper v|startup.nsh: launching|EFI stub: Booting Linux' "$LOG" | tr -d '\r'
echo "--- boot ---"
grep -aE 'efi: EFI v|efi: UEFI not found|psci: PSCIv|psci: Using PSCI v0.1|smp: Brought up|SMP: Total|All CPU\(s\) started|Kernel panic' "$LOG"
echo "--- ftrace ---"
grep -aE '^FTRACE_CPU' "$LOG"
echo "${result:-FTRACE_RESULT NONE (timeout or panic)}"
echo "log: $LOG"

case "$result" in
    "FTRACE_RESULT PASS") exit 0 ;;
    "FTRACE_RESULT FAIL") exit 1 ;;
    *)                    exit 2 ;;
esac
