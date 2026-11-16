#!/bin/busybox sh
# Non-interactive ftrace capture across every online CPU.
# Runs from /init so nothing goes through the PL011 input FIFO, which
# overruns under scripted input (see doc/README.md).
# Prints per-CPU entry counts as "FTRACE_CPU<n> entries=<e> overrun=<o>"
# and a final "FTRACE_RESULT PASS|FAIL" line for log grepping, then
# "FTRACE_DONE" (script/1_run_base_ftrace.sh sets it as the model's
# shutdown_tag, so the simulation exits right here in test mode).
BB=/bin/busybox
T=/sys/kernel/debug/tracing
NCPU=$($BB nproc)

echo "=== ftrace_test: $NCPU CPUs ==="
echo 0 > $T/tracing_on
echo nop > $T/current_tracer
echo 256 > $T/buffer_size_kb          # per CPU; keep the readout small
echo > $T/trace                       # clear all per-CPU buffers
echo function > $T/current_tracer
echo "current_tracer=$($BB cat $T/current_tracer)"

echo 1 > $T/tracing_on
# Pin a short burst of syscall-heavy work to each CPU in turn.
c=0
while [ $c -lt $NCPU ]; do
    $BB taskset -c $c $BB sh -c 'i=0; while [ $i -lt 50 ]; do /bin/busybox cat /proc/version >/dev/null; i=$((i+1)); done' &
    c=$((c+1))
done
wait
echo 0 > $T/tracing_on

pass=1
c=0
while [ $c -lt $NCPU ]; do
    S=$T/per_cpu/cpu$c/stats
    e=$($BB grep '^entries:' $S | $BB awk '{print $2}')
    o=$($BB grep '^overrun:' $S | $BB awk '{print $2}')
    echo "FTRACE_CPU$c entries=$e overrun=$o"
    [ "${e:-0}" -gt 0 ] || pass=0
    c=$((c+1))
done

echo "--- sample: first 3 entries per CPU ---"
c=0
while [ $c -lt $NCPU ]; do
    $BB grep -v '^#' $T/per_cpu/cpu$c/trace | $BB head -3
    c=$((c+1))
done

echo nop > $T/current_tracer
if [ $pass -eq 1 ]; then echo "FTRACE_RESULT PASS"; else echo "FTRACE_RESULT FAIL"; fi
echo "FTRACE_DONE"
