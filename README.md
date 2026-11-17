# arm_linux_multicore

Mainline Linux 6.8.12 + boot-wrapper-aarch64 + busybox rootfs, booted SMP
on Arm FVPs (Foundation Platform 4-core, Base Platform RevC 2-core, the
latter also via TF-A + UEFI/EDK2), with
the kernel's `function` ftrace tracer captured on every CPU.

```bash
source script/0_env_var_setup.sh
make base                       # first time: kernel + TF-A + EDK2 builds, ~15-30+ min
script/1_run_base_ftrace.sh     # 2-core boot (TF-A -> UEFI -> EFI stub) + ftrace, exit 0 = PASS
BOOT=bwa script/1_run_base_ftrace.sh   # same test, booted via boot-wrapper instead
```

Full documentation: [doc/README.md](doc/README.md).
Build outputs (`build/`, kernel, dtb, axf, rootfs image, busybox) are not
tracked; `make` regenerates them.
