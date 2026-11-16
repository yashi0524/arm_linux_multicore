# arm_linux_multicore — multicore Linux boot + ftrace

Minimal mainline Linux 6.8.12, built from scratch (kernel +
boot-wrapper-aarch64 + busybox squashfs rootfs) and booted SMP on two
Arm FVPs. Once up, the kernel's own `function` ftrace tracer is driven
across every online CPU. Sibling of
[`../arm_bare_metal_multi`](../arm_bare_metal_multi) (bare-metal PSCI
CPU_ON). That project debugs boot from *outside* via Iris; this one
exercises the kernel's own tracing from *inside* a running kernel.

## Quick start

```bash
source script/0_env_var_setup.sh
make base                       # first time: kernel build ~15-30+ min
script/1_run_base_ftrace.sh     # 2-core boot + ftrace test, ~30 s, exit 0 = PASS
```

## Targets

| | Foundation Platform | Base Platform RevC |
|---|---|---|
| Make targets | `make` / `make run` | `make base` / `make run-base` / `make run-base-debug` |
| Cores | 4 (`--cores=4`) | 2 (`cluster0.NUM_CORES=2`) |
| GIC | GICv2 (`--no-gicv3`) | GICv3 + ITS (`--enable-gicv3` boot-wrapper) |
| DTB | FVP-shipped `foundation-platform.dts` | `dts/fvp-base-revc-2core.dts` (trimmed upstream) |
| boot-wrapper build | `build/bwa` | `build/bwa-base2` |
| Iris debug | no | yes (`run-base-debug`, port 7100) |
| SMP boot | verified (4 CPUs) | verified (2 CPUs) |
| ftrace capture | 0 entries, by hand over UART (see below); not re-run with `ftrace_test.sh` | **PASS on both CPUs** (2026-11-16) |

Kernel `Image` and rootfs are shared by both targets.

## Files

| Path | What |
|---|---|
| `Makefile` | all build + run targets; comments carry the root-cause notes |
| `dts/fvp-base-revc-2core.dts` | Base RevC dts trimmed to cpu@0 + cpu@100; built inside the kernel tree (needs kbuild's cpp include paths) |
| `rootfs/init` | PID 1: mounts proc/sys/debugfs, runs `/ftrace_test.sh`, then `exec /bin/sh` |
| `rootfs/ftrace_test.sh` | non-interactive ftrace capture on every online CPU; prints `FTRACE_CPU<n> entries=… overrun=…`, `FTRACE_RESULT PASS\|FAIL`, `FTRACE_DONE` |
| `script/0_env_var_setup.sh` | PATH for both FVPs, ipython3, no-root dtc/flex/bison |
| `script/1_run_base_ftrace.sh` | regression run of the Base RevC 2-core target (see below) |
| `doc/run_base_2core_ftrace.log` | reference log from a passing run |

## Base Platform RevC, 2 cores (verified 2026-11-16)

### Running the test

```bash
script/1_run_base_ftrace.sh [log_file] [timeout_s]   # defaults: build/run_base_ftrace.log, 900
```
The script runs `make base`, then `make run-base` with
`BASE_EXTRA="-C bp.pl011_uart0.shutdown_tag=FTRACE_DONE"`, so the model
exits by itself once the test prints its last line. It then prints a
summary and exits **0 = PASS, 1 = FAIL, 2 = no result** (timeout or
panic). Wall time on this host is about 26 s. Reference output:
```
--- boot ---
[    0.029730] smp: Brought up 1 node, 2 CPUs
[    0.029991] SMP: Total of 2 processors activated.
[    0.030063] CPU: All CPU(s) started at EL2
--- ftrace ---
FTRACE_CPU0 entries=9340 overrun=871595
FTRACE_CPU1 entries=9389 overrun=872610
FTRACE_RESULT PASS
```
The log also shows per-CPU sample entries with the `[000]` / `[001]`
CPU column. Large `overrun` counts are expected: the 256 KB/CPU ring
buffer wraps under an unfiltered `function` tracer. Raise
`buffer_size_kb` or set `set_ftrace_filter` in `ftrace_test.sh` to keep
everything.

For an interactive session, use plain `make run-base` (no
`shutdown_tag`). After the test it drops to the `~ #` shell, reachable
on `nc localhost 5000`.

### Model parameters that are required (root-caused live)

- `bp.refcounter.non_arch_start_at_default=1` starts the system counter.
  That's normally TF-A's job, and boot-wrapper doesn't do it. Without it
  `CNTPCT_EL0` stays 0 and Linux hangs forever in GIC ITS init
  (`its_wait_for_range_completion` → `__delay` never times out).
- `pctl.startup=0.0.*.*` powers **both** cluster0 cores at reset (the
  default is cpu0 only). boot-wrapper's cpu0 waits for every dtb CPU to
  check in before entering the kernel. Without it the boot hangs right
  after `CPU0: (MPIDR ...) initializing...`.
- `cluster0.NUM_CORES=2 cluster1.NUM_CORES=0` trims the model to match
  the dtb's 2 CPUs. boot-wrapper's `NR_CPUS` / `CPU_IDS` come from the
  dtb (`-DCPU_IDS=0x0,0x100 -DNR_CPUS=2` in its build).
- `bp.pl011_uart0.unbuffered_output=1` is needed for logging, not for
  boot. Without it the model block-buffers UART output when stdout is a
  file, so a redirected log only fills in when the model exits.

### Base Platform RevC + Iris (`make run-base-debug`)

Same model and args plus `-I --iris-port 7100`. With `-I` and no `-R`,
the model does **not** run until a client drives it: `model.run()` on an
async connection, or `cpu.step()` on a synchronous one. Connection
helpers and the `ipython3` setup are shared with
[`../arm_bare_metal_multi`](../arm_bare_metal_multi) (`script/Iris_connect.py`,
`doc/how_to_debug.md`). Foundation Platform has no Iris server.

## Foundation Platform, 4 cores

`make run`. Verified from the kernel's boot log: `CPU1/2/3: Booted
secondary processor`, `smp: Brought up 1 node, 4 CPUs`, `CPU: All CPU(s)
started at EL2`.

### ftrace history: the PL011 input overrun

Before `ftrace_test.sh` existed, the capture was driven over the UART0
socket (`nc localhost 5000`) and **consistently came back empty**
(`entries-in-buffer/entries-written: 0/0`), even though
`CONFIG_FUNCTION_TRACER`/`CONFIG_DYNAMIC_FTRACE` are set. The emulated
PL011's input FIFO overruns under scripted input:
```
ttyAMA ttyAMA0: 1 input overrun(s)
ttyAMA ttyAMA0: 3 input overrun(s)
```
Commands piped through `nc`, even paced at 20 ms/char, lost characters
mid-command (`tracing_on` → `trcig_n`, `echo function` → `unction`).

**Resolution:** `rootfs/ftrace_test.sh` now runs from `/init`, so no
console input is involved, and it captures on every CPU on Base RevC.
That supports the overrun theory. The same rootfs also runs on
Foundation, but `make run` has **not yet been re-checked** with it.

Known quirk: the first line typed right after the boot banner races
BusyBox's cursor-position query (`ESC[6n`) and loses its leading
characters. It only affects the first command.

## Setup

No root/sudo on this host. `dtc`, `flex`, and `bison` (needed for
`make defconfig` and device-tree compilation) aren't preinstalled. They
were added the same no-root way as `arm_bare_metal_multi`'s `ipython3`:
`apt-get download` + `dpkg-deb -x` into a user-local prefix, all wired
into `script/0_env_var_setup.sh`. That includes `BISON_PKGDATADIR`:
bison hardcodes `/usr/share/bison`, and without the variable kbuild's
kconfig step fails with `cannot open m4sugar.m4`.

`make` (= `make all`, Foundation) builds, in order: the dtb, the kernel
(downloaded + configured + compiled; the slow step, not rebuilt once
`arch/arm64/boot/Image` exists), `boot-wrapper-aarch64` (cloned,
`autoreconf`'d, configured against the built Image and dtb), and the
rootfs. Ordering matters for correctness: boot-wrapper's `configure`
checks that both files exist when it runs. `make base` builds the Base
RevC dtb (inside the kernel tree) and `build/bwa-base2` (a local clone of
`build/bwa`, no second network fetch) instead.

`rootfs/bin/busybox` isn't tracked in git. `make` copies it from the
host's `/usr/bin/busybox`, so the host needs Ubuntu's `busybox-static`
package (a static aarch64 binary that runs as-is in the rootfs).

`make clean` removes the fast-to-rebuild bits (dtbs, rootfs,
boot-wrapper binaries). `make distclean` also removes the ~140 MB kernel
source tree.

## Notes / gotchas (verified, not assumed)

- The core count at launch must match the dtb's CPU nodes, on both
  boards (`--cores=4` on Foundation; `NUM_CORES` + `pctl.startup` on Base
  RevC). A mismatch hangs secondary bring-up, because boot-wrapper brings
  up exactly the CPUs the dtb describes.
- `rootfs/`'s empty mountpoint directories (`proc/`, `sys/`, `dev/`,
  `etc/`, `sbin/`) are tracked via `.gitkeep`. Losing them silently
  breaks `/init`'s `mount` calls (`mount: mounting proc on /proc failed`).
- `rootfs/init` ends with `exec /bin/sh`. A script that returns as PID 1
  triggers `Kernel panic: Attempted to kill init!`.
- `/init` calls applets as `/bin/busybox <applet>` where no symlink
  exists. `rootfs/bin` only has symlinks for cat, echo, grep, ls, mkdir,
  mount, nproc, sh, tail, taskset, uname, and wait.
- The host's Ubuntu kernel config is NOT usable on this board. It hangs
  at `NET: Registered PF_PACKET protocol family` because ACPI/PCI/bus
  drivers probe hardware the model doesn't implement.
- Running `make run-base` backgrounded, without a terminal, the model
  exited on its own ("Simulation stopped by user") shortly after the
  shell prompt. `1_run_base_ftrace.sh` doesn't depend on this, since it
  stops via `shutdown_tag`. Under a real terminal, use `make run-base`.
