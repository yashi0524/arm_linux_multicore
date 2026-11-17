# arm_linux_multicore — multicore Linux boot + ftrace

Minimal mainline Linux 6.8.12, built from scratch (kernel +
boot-wrapper-aarch64 + busybox squashfs rootfs) and booted SMP on two
Arm FVPs, either directly via boot-wrapper or through the standard
firmware stack (TF-A + UEFI/EDK2). Once up, the kernel's own `function` ftrace tracer is driven
across every online CPU. Sibling of
[`../arm_bare_metal_multi`](../arm_bare_metal_multi) (bare-metal PSCI
CPU_ON). That project debugs boot from *outside* via Iris; this one
exercises the kernel's own tracing from *inside* a running kernel.

## Quick start

```bash
source script/0_env_var_setup.sh
make base                       # first time: kernel + TF-A + EDK2 builds, ~15-30+ min
script/1_run_base_ftrace.sh     # 2-core boot via TF-A + UEFI + ftrace test, ~1 min, exit 0 = PASS
BOOT=bwa script/1_run_base_ftrace.sh   # same test booted via boot-wrapper, ~30 s
```
On Base RevC, **TF-A + UEFI is the default boot** (`make base` /
`make run-base` / `make run-base-debug`). The original boot-wrapper flow
is still available as `make base-bwa` / `make run-base-bwa` /
`make run-base-bwa-debug`.

## Targets

| | Foundation Platform | Base RevC, boot-wrapper | Base RevC, UEFI (**default**) |
|---|---|---|---|
| Make targets | `make` / `make run` | `make base-bwa` / `make run-base-bwa` / `make run-base-bwa-debug` | `make base` / `make run-base` / `make run-base-debug` |
| Test script | — | `BOOT=bwa script/1_run_base_ftrace.sh` | `script/1_run_base_ftrace.sh` |
| Firmware | boot-wrapper | boot-wrapper | TF-A v2.15 (BL1/BL2/BL31) + EDK2 (BL33) |
| Cores | 4 (`--cores=4`) | 2 (`cluster0.NUM_CORES=2`) | 2 |
| GIC | GICv2 (`--no-gicv3`) | GICv3 + ITS (`--enable-gicv3` boot-wrapper) | GICv3 + ITS (TF-A) |
| PSCI | boot-wrapper v0.1 | boot-wrapper v0.1 | TF-A BL31 v1.1 |
| DTB | FVP-shipped `foundation-platform.dts` | `dts/fvp-base-revc-2core.dts` (trimmed upstream) | same, passed as `dtb=` to the EFI stub |
| Kernel entry | raw `Image` | raw `Image` | `Image` as an EFI app (EFI stub) |
| Iris debug | no | yes (`run-base-bwa-debug`, port 7100) | `run-base-debug`, port 7100 (wired up, not yet exercised) |
| SMP boot | verified (4 CPUs) | verified (2 CPUs) | verified (2 CPUs) |
| ftrace capture | 0 entries, by hand over UART (see below); not re-run with `ftrace_test.sh` | **PASS on both CPUs** (2026-11-16, re-checked 2026-11-17) | **PASS on both CPUs** (2026-11-17) |

Kernel `Image` and rootfs are shared by all targets.

## Files

| Path | What |
|---|---|
| `Makefile` | all build + run targets; comments carry the root-cause notes |
| `dts/fvp-base-revc-2core.dts` | Base RevC dts trimmed to cpu@0 + cpu@100; built inside the kernel tree (needs kbuild's cpp include paths) |
| `rootfs/init` | PID 1: mounts proc/sys/debugfs, runs `/ftrace_test.sh`, then `exec /bin/sh` |
| `rootfs/ftrace_test.sh` | non-interactive ftrace capture on every online CPU; prints `FTRACE_CPU<n> entries=… overrun=…`, `FTRACE_RESULT PASS\|FAIL`, `FTRACE_DONE` |
| `script/0_env_var_setup.sh` | PATH for both FVPs, ipython3, no-root dtc/flex/bison |
| `script/1_run_base_ftrace.sh` | regression run of the Base RevC 2-core target: `BOOT=uefi` (default) or `BOOT=bwa` |
| `doc/run_base_2core_ftrace.log` | reference log from a passing boot-wrapper run |
| `doc/run_uefi_2core_ftrace.log` | reference log from a passing UEFI run (ANSI escapes stripped) |

## Base Platform RevC, 2 cores, boot-wrapper (verified 2026-11-16)

This was the original Base RevC boot. It is now the non-default
`*-bwa` targets; the default is the UEFI flow (see "UEFI boot flow"
below).

### Running the test

```bash
[BOOT=uefi|bwa] script/1_run_base_ftrace.sh [log_file] [timeout_s]
# defaults: BOOT=uefi, build/run_base_ftrace.log (run_base_bwa_ftrace.log for bwa), 1200 s
```
With `BOOT=bwa`, the script runs `make base-bwa`, then `make run-base-bwa` with
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

For an interactive session, use plain `make run-base-bwa` (no
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

### Base Platform RevC + Iris (`make run-base-bwa-debug`, `make run-base-debug`)

Same model and args plus `-I --iris-port 7100`. With `-I` and no `-R`,
the model does **not** run until a client drives it: `model.run()` on an
async connection, or `cpu.step()` on a synchronous one. Connection
helpers and the `ipython3` setup are shared with
[`../arm_bare_metal_multi`](../arm_bare_metal_multi) (`script/Iris_connect.py`,
`doc/how_to_debug.md`). Foundation Platform has no Iris server.
`make run-base-debug` adds the same Iris flags to the UEFI flow; that
combination has not been exercised yet.

## Boot flow (Base RevC, 2 cores, boot-wrapper: `run-base-bwa`)

FVP reset → boot-wrapper (EL3) → Linux (EL2) → PSCI `CPU_ON` for CPU1 →
`/init` → `ftrace_test.sh`. Line numbers refer to
`doc/run_base_2core_ftrace.log`. Foundation follows the same flow, with
GICv2 and its shipped dtb.

### 0. Image layout (`build/bwa-base2/model.lds`)

`linux-system.axf` is a single ELF:

| Address | Section | Contents |
|---|---|---|
| `0x8000_0000` | `.boot` | boot-wrapper code, PSCI vectors, stacks (`_start` = ELF entry) |
| `0x8000_fff8` | `.mbox` | spin mailbox (unused with PSCI) |
| `0x8020_0000` | `.kernel` | raw `arch/arm64/boot/Image` (`entrypoint`) |
| `0x8800_0000` | `.dtb` | `fdt.dtb`: our dts + `/chosen` cmdline + boot-wrapper's psci node |

The rootfs is not in the ELF: `build/rootfs.squashfs` is attached as a
virtio-blk device (`/dev/vda`). The dts's `/memreserve/ 0x80000000
0x10000` keeps Linux off boot-wrapper's code, mailbox, and PSCI
`branch_table`.

### 1. FVP reset

- `-a linux-system.axf` loads the ELF. Every powered core starts at
  `_start` in **EL3**.
- `pctl.startup=0.0.*.*` powers **both** cores at reset (needed in step 2).
- `bp.refcounter.non_arch_start_at_default=1` starts the system counter
  (needed in step 3).

### 2. boot-wrapper, all CPUs (`arch/aarch64/boot.S`, `common/init.c`)

1. `_start`: if `CurrentEL` is EL3, it sets `SCTLR_EL3`, then goes to
   `reset_common`.
2. `reset_common`: `find_logical_id()` maps MPIDR through
   `CPU_IDS=0x0,0x100` (from the dtb at build time, `NR_CPUS=2`). An
   unknown MPIDR is parked with `b .`. Each CPU gets its own stack.
3. `cpu_init_bootwrapper()`:
   - CPU0 only: UART init, the `Boot-wrapper v0.2` banner, the memory
     layout print, and `init_platform()`.
   - CPUs then run `cpu_init_self()` / `cpu_init_arch()` **one at a time,
     in order** (a `cpu_next` counter with `wfe`/`sev`):
     - `SCR_EL3` (NS, HCE, RW, feature enables)
     - `CPTR_EL3` and `MDCR_EL3` traps opened, SVE/SME vector lengths set
     - `CNTFRQ` = 100 MHz
     - GICv3 secure init (CPU0 also does the distributor and all
       redistributors, interrupts put in Group1NS)
     - `VBAR_EL3 = psci_vectors`
   - CPU0 waits for `cpu_next == NR_CPUS`, then prints `All CPUs
     initialized. Entering kernel...`. **If a dtb CPU is not powered,
     CPU0 hangs here**, right after `CPU0: (MPIDR ...) initializing...`.
4. `start_bootmethod` → `psci_first_spin()` → `first_spin()` in
   `common/boot.c`:
   - **CPU0**: `jump_kernel(0x80200000, x0=&dtb)` sets `SCTLR_EL1/EL2`
     and `SPSR=EL2h`, then `eret`s to the kernel at **EL2**. This follows
     the arm64 boot protocol: x0 = dtb, x1–x3 = 0, MMU off.
   - **CPU1**: sets `branch_table[1] = PSCI_ADDR_INVALID`, then loops in
     `spin()` (`wfe` + poll) until an address appears.

### 3. Linux on CPU0 (log lines 22–110)

- `Booting Linux on physical CPU 0x0`, then earlycon on the PL011 at
  `0x1c090000`.
- `efi: UEFI not found.`: no firmware tables, so the kernel uses the
  dtb (see "Relation to UEFI" below).
- `psci: Using PSCI v0.1 Function IDs from DT`. The dts says
  `arm,psci-0.2`, but boot-wrapper replaces the node with its own v0.1
  one (`cpu_on = 0xc4000003`, `method = smc`). Only `CPU_ON` and
  `CPU_OFF` are implemented.
- VHE is detected (the kernel runs at EL2). GICv3 and the ITS tables are
  set up. ITS init is where boot hangs when the system counter isn't
  running (`__delay` never expires).

### 4. Secondary bring-up (log lines 111–118)

1. `smp: Bringing up secondary CPUs`: the kernel issues `SMC
   PSCI_CPU_ON(mpidr=0x100, entry=secondary_entry)`.
2. The SMC traps to EL3 `psci_vectors` (`smc_entry64`) → `psci_call()` →
   `psci_cpu_on()`. That writes the entry address into `branch_table[1]`
   under a bakery lock, then returns with `eret`.
3. CPU1 wakes in `spin()`, sees the address, and calls `jump_kernel()`,
   which `eret`s it to EL2 at the kernel's secondary entry.
4. The log shows `CPU1: Booted secondary processor 0x100`, `smp: Brought
   up 1 node, 2 CPUs`, and `CPU: All CPU(s) started at EL2`.

### 5. Rootfs and userspace (log lines 274 onward)

- The cmdline `root=/dev/vda rootfstype=squashfs ro init=/init` mounts
  the virtio-blk squashfs. `Run /init as init process` appears at about
  9.8 s.
- `rootfs/init` (PID 1) mounts proc, sysfs and debugfs, then runs
  `/ftrace_test.sh`. That script runs the `function` tracer with work
  pinned to each CPU via `taskset`, and prints `FTRACE_CPU<n>`,
  `FTRACE_RESULT`, and `FTRACE_DONE`.
- `FTRACE_DONE` matches `shutdown_tag`, so the model exits (in
  `1_run_base_ftrace.sh`). Interactively, `/init` ends with `exec
  /bin/sh` on UART0 (`nc localhost 5000`).

### Relation to UEFI

**None at runtime. This boot does not use UEFI.** boot-wrapper takes the
place of the whole usual firmware stack, TF-A (BL1/BL2/BL31) plus
UEFI/EDK2 or U-Boot. It enters the kernel's raw `Image` directly via the
arm64 boot protocol, and hardware is described by the **dtb**, not
ACPI.

- The kernel is built with `CONFIG_EFI=y` / `CONFIG_EFI_STUB=y`
  (defconfig). The EFI stub is only used when firmware loads the Image
  as a PE/COFF EFI application. Here it is entered at its raw entry
  point, so the stub is skipped. The kernel finds no EFI system table
  and logs `efi: UEFI not found.` (line 27) and `EFI services will not
  be available.` (line 110).
- What a UEFI boot would provide and this one does not:
  - EFI runtime services (RTC, variables, `reboot`/`poweroff` via
    ResetSystem)
  - a memory map from firmware (here it comes from the dtb `memory`
    node)
  - a KASLR seed (hence `KASLR disabled due to lack of seed`)
  - ACPI tables (`CONFIG_ACPI` is disabled anyway)
- The PSCI provider is boot-wrapper at EL3, not TF-A BL31. That's why
  only v0.1 `CPU_ON`/`CPU_OFF` exist, and why the counter must be started
  by a model parameter.
- The default `base` / `run-base` targets build and boot exactly that firmware
  flow: TF-A (BL1→BL2→BL31) → EDK2 (BL33) → the kernel as an EFI app.
  See "UEFI boot flow" below.

## UEFI boot flow (Base RevC default: `run-base`, verified 2026-11-17)

```bash
make base                                            # TF-A + EDK2 + build/uefi/
script/1_run_base_ftrace.sh [log_file] [timeout_s]   # defaults: build/run_base_ftrace.log, 1200
```
Same board, kernel `Image`, dtb and rootfs as `run-base-bwa`. The only
difference is that boot-wrapper is replaced by the standard Arm firmware
stack. Wall time is about 55 s;
roughly 25 s of that is firmware, including the Shell's 5 s
`startup.nsh` countdown. Line numbers below refer to
`doc/run_uefi_2core_ftrace.log`.

```
FVP reset (cpu0 only, EL3)
 └─ TF-A BL1  (secure flash, bp.secureflashloader = bl1.bin)
     └─ BL2   (loaded from FIP in NOR flash0, bp.flashloader0 = fip.bin)
         └─ BL31 (EL3 runtime: PSCI v1.1, GICv3 secure init, counter start)
             └─ BL33 = EDK2 FVP_AARCH64_EFI.fd  (NS-EL2)
                 └─ BDS → UEFI Shell (fallback boot option)
                     └─ startup.nsh on SemihostFs (build/uefi/)
                         └─ Image dtb=… console=…  (kernel EFI stub)
                             └─ ExitBootServices → Linux at EL2
                                 └─ PSCI CPU_ON (SMC → BL31) for CPU1
```

### Build pieces (`Makefile`, "UEFI" sections)

| Piece | Source | Output |
|---|---|---|
| EDK2 | `tianocore/edk2` + `edk2-platforms`, pinned master SHAs (`EDK2_SHA`, `EDK2_PLAT_SHA`) | `build/Build/ArmVExpress-FVP-AArch64/RELEASE_GCC/FV/FVP_AARCH64_EFI.fd` |
| TF-A | `v2.15.0`, `PLAT=fvp FVP_CLUSTER_COUNT=1 FVP_MAX_CPUS_PER_CLUSTER=2 CTX_INCLUDE_AARCH32_REGS=0 BL33=<EDK2 fd>` | `build/tf-a/build/fvp/release/{bl1,fip}.bin` |
| Semihosting dir | `Image`, `fvp-base-revc-2core.dtb`, generated `startup.nsh` | `build/uefi/` |

EDK2 build-time host tools (`uuid-dev`, `iasl`) come from
`~/.local/uefi-tools` (see `script/0_env_var_setup.sh`).

### Stages

1. **TF-A (log lines 23–31).** BL1 → BL2 → BL31. (One earlier run,
   before the PCD fix below, showed the TF-A banner twice, i.e. one warm
   reset before EDK2's banner. The passing run shows it once; the cause
   was not root-caused.) BL31 stays resident at EL3
   as the PSCI provider and starts the system counter, so no
   `refcounter` or `pctl.startup` model parameters are needed.
2. **EDK2 / BDS (line 34).** `Press ESCAPE for boot options`, then the
   BDS boot timeout expires. No device has a bootable ESP (the virtio
   disk is a raw squashfs), so BDS boots the embedded UEFI Shell as its
   fallback.
3. **Shell (lines 34–59).** After a 5 s countdown, the Shell runs
   `startup.nsh` from EDK2's SemihostFs, which exposes the model's
   `semihosting-cwd` (`build/uefi/`).
4. **EFI stub (lines 61–64).** `Image` is a PE/COFF EFI application
   (`CONFIG_EFI_STUB=y`). The stub loads the dtb named by `dtb=` from
   the same volume (`Using DTB from command line`), builds the memory
   map, calls `ExitBootServices`, and enters the kernel at EL2.
5. **Linux.** Compared with the boot-wrapper flow:
   - `efi: EFI v2.7 by EDK II` instead of `UEFI not found`. EFI runtime
     services are mapped (`Remapping and enabling EFI services`), and
     `rtc-efi` registers as `rtc0`.
   - `psci: PSCIv1.1 detected in firmware` (TF-A) instead of
     boot-wrapper's v0.1 `CPU_ON`/`CPU_OFF` only.
   - `efi: ACPI 2.0=…` is published by EDK2 but ignored
     (`CONFIG_ACPI` off). Hardware still comes from our dtb.
   - `KASLR disabled due to lack of seed` / `EFI_RNG_PROTOCOL
     unavailable`: the FVP EDK2 build has no RNG protocol.
   - `Unknown kernel command line parameters "dtb=…"` is harmless. The
     stub consumes `dtb=`, and the kernel just passes it on to userspace.
6. **SMP + userspace.** CPU1 is brought up by `PSCI CPU_ON` → BL31,
   which powers it on through the FVP power controller (line 179). After
   that, the `/init` → `ftrace_test.sh` flow is the same as for
   `run-base`.

### Required settings (root-caused live)

- **`PcdUefiShellDefaultBootEnable=TRUE`** (EDK2 `build --pcd`). ArmPkg's
  `PlatformBootManagerLib` registers the Shell as an *inactive* boot
  option (hotkey `s` only). Without this PCD, BDS finds nothing to boot,
  drops to the setup front page ("Device Manager / Boot Manager / …"),
  and `startup.nsh` never runs.
- **`CTX_INCLUDE_AARCH32_REGS=0`** (TF-A). With `cluster0.has_arm_v9-0=1`,
  EL1 is AArch64-only. With the default of 1, BL1 prints `EL1 supports
  AArch64-only…` and reset-loops forever.
- **`FVP_CLUSTER_COUNT=1 FVP_MAX_CPUS_PER_CLUSTER=2`** (TF-A) matches
  the model's `cluster0.NUM_CORES=2 cluster1.NUM_CORES=0` and our dts.
- **No `-a`, no `pctl.startup`, no `refcounter` param** (model). BL1 is
  the reset vector, TF-A expects only cpu0 at reset, and TF-A starts the
  counter itself.
- `sh: 1: xterm: not found` in the log is harmless. The FVP tries to
  open terminal windows for UART1–3.

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
checks that both files exist when it runs. `make base-bwa` builds the Base
RevC dtb (inside the kernel tree) and `build/bwa-base2` (a local clone of
`build/bwa`, no second network fetch) instead. `make base` builds the
same dtb plus EDK2 and TF-A (see "UEFI boot flow").

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
- Running `make run-base-bwa` backgrounded, without a terminal, the model
  exited on its own ("Simulation stopped by user") shortly after the
  shell prompt. `1_run_base_ftrace.sh` doesn't depend on this, since it
  stops via `shutdown_tag`. Under a real terminal, use `make run-base-bwa`.
