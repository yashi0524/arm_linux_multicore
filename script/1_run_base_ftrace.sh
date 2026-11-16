#!/bin/bash
# 2-core Base Platform RevC boot + ftrace regression test.
#
# Builds what's missing (make base), boots `make run-base`; the model
# shuts itself down after rootfs/ftrace_test.sh prints its result.
# Exit code: 0 = PASS, 1 = FAIL, 2 = no result (timeout/panic).
#
# Usage (from the project root or anywhere):
#   script/1_run_base_ftrace.sh [log_file] [timeout_s]
# Defaults: build/run_base_ftrace.log, 900 s.

PROJ=$(cd "$(dirname "$0")/.." && pwd)
LOG=${1:-$PROJ/build/run_base_ftrace.log}
TMO=${2:-900}

source "$PROJ/script/0_env_var_setup.sh"
cd "$PROJ" || exit 2

make base || exit 2

# shutdown_tag: the model exits as soon as ftrace_test.sh prints
# FTRACE_DONE (after its result line). `timeout` is only the fallback for
# a hang or panic. stdin from <(sleep) stays open so the model isn't fed
# EOF (a process substitution, not a pipe: bash doesn't wait on it).
timeout "$TMO" make run-base \
    BASE_EXTRA="-C bp.pl011_uart0.shutdown_tag=FTRACE_DONE" \
    < <(sleep "$TMO") > "$LOG" 2>&1
result=$(grep -o 'FTRACE_RESULT [A-Z]*' "$LOG" | head -1)

echo "--- boot ---"
grep -E 'smp: Brought up|SMP: Total|All CPU\(s\) started|Kernel panic' "$LOG"
echo "--- ftrace ---"
grep -E '^FTRACE_CPU' "$LOG"
echo "${result:-FTRACE_RESULT NONE (timeout or panic)}"
echo "log: $LOG"

case "$result" in
    "FTRACE_RESULT PASS") exit 0 ;;
    "FTRACE_RESULT FAIL") exit 1 ;;
    *)                    exit 2 ;;
esac
