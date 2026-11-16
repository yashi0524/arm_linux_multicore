# Makefile — minimal multicore Linux boot + ftrace on Arm FVP
# Builds mainline Linux + boot-wrapper-aarch64 + a busybox rootfs from
# scratch, then boots all 4 cores on Foundation Platform and runs the
# kernel's `function` ftrace tracer across them. See doc/README.md.
#
# `source script/0_env_var_setup.sh` first — puts Foundation Platform,
# and the no-root-installed dtc/flex/bison, on PATH.
#
# Heavy, one-time steps (kernel source download + build, boot-wrapper
# clone + build) live under build/ and are NOT rebuilt once their target
# already exists — `make clean` only removes the fast-to-rebuild bits
# (dtb, rootfs squashfs, boot-wrapper binary); `make distclean` removes
# everything, including the ~140MB kernel source tree.

KERNEL_VER    := 6.8.12
BUILD_DIR     := build
KERNEL_TARBALL:= $(BUILD_DIR)/linux-$(KERNEL_VER).tar.xz
KERNEL_SRC    := $(BUILD_DIR)/linux-$(KERNEL_VER)
KERNEL_IMAGE  := $(KERNEL_SRC)/arch/arm64/boot/Image
DTB           := $(BUILD_DIR)/foundation-platform.dtb
BWA_DIR       := $(BUILD_DIR)/bwa
AXF           := $(BWA_DIR)/linux-system.axf
ROOTFS_SQFS   := $(BUILD_DIR)/rootfs.squashfs

FOUNDATION_HOME := $(HOME)/work/0_simulator/arm_fvp/Foundation_Platform_11.32_19
FOUNDATION_DTS  := $(FOUNDATION_HOME)/examples/foundation-platform.dts

# --- Base Platform RevC variant (run-base / run-base-debug) ---
# Same kernel Image and rootfs, different board: GICv3 (+ITS) instead of
# Foundation's GICv2, so it needs its own dtb and its own boot-wrapper
# build (--enable-gicv3). 2 cores — see dts/fvp-base-revc-2core.dts.
BASE_DTS_NAME := fvp-base-revc-2core
BASE_DTS_SRC  := dts/$(BASE_DTS_NAME).dts
BASE_DTS_DIR  := $(KERNEL_SRC)/arch/arm64/boot/dts/arm
BASE_DTB      := $(BASE_DTS_DIR)/$(BASE_DTS_NAME).dtb
BWA_BASE_DIR  := $(BUILD_DIR)/bwa-base2
BASE_AXF      := $(BWA_BASE_DIR)/linux-system.axf
IRIS_PORT     := 7100

all: $(AXF) $(ROOTFS_SQFS)

# Base RevC image is opt-in (not part of `all`): `make base`, or just
# `make run-base`, which builds it on demand.
base: $(BASE_AXF) $(ROOTFS_SQFS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# --- Device tree ---
# The FVP ships the matching source directly; only warns (cosmetic
# simple-bus/reg-property nits in the upstream dts), doesn't error.
$(DTB): | $(BUILD_DIR)
	dtc -I dts -O dtb -o $(DTB) $(FOUNDATION_DTS)

# --- Kernel ---
# NOT the host's Ubuntu distro kernel config — that one hangs at
# "NET: Registered PF_PACKET protocol family" on this board (ACPI/PCI/bus
# drivers probing hardware the model doesn't have). CONFIG_FTRACE +
# CONFIG_FUNCTION_TRACER are the point of this whole exercise.
$(KERNEL_TARBALL): | $(BUILD_DIR)
	curl -sL -o $(KERNEL_TARBALL) https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VER).tar.xz

$(KERNEL_SRC)/Makefile: $(KERNEL_TARBALL)
	tar -xf $(KERNEL_TARBALL) -C $(BUILD_DIR)
	touch $(KERNEL_SRC)/Makefile

$(KERNEL_IMAGE): $(KERNEL_SRC)/Makefile
	$(MAKE) -C $(KERNEL_SRC) ARCH=arm64 defconfig
	cd $(KERNEL_SRC) && scripts/config \
	  --disable CONFIG_ACPI --disable CONFIG_USB_SUPPORT \
	  --disable CONFIG_SOUND --disable CONFIG_DRM --disable CONFIG_PCI \
	  --disable CONFIG_WIRELESS --disable CONFIG_BT \
	  --disable CONFIG_SECURITY --disable CONFIG_SECURITY_APPARMOR \
	  --enable  CONFIG_VIRTIO_BLK --enable CONFIG_SQUASHFS \
	  --enable  CONFIG_SERIAL_AMBA_PL011_CONSOLE --enable CONFIG_DEBUG_FS \
	  --enable  CONFIG_FTRACE --enable CONFIG_FUNCTION_TRACER
	$(MAKE) -C $(KERNEL_SRC) ARCH=arm64 olddefconfig
	$(MAKE) -C $(KERNEL_SRC) ARCH=arm64 -j$$(nproc) Image

# --- boot-wrapper-aarch64 ---
# Foundation_Platform's --image= needs an ELF; a raw kernel Image isn't
# one. boot-wrapper wraps kernel+dtb into one, and is also what actually
# brings up the secondary cores (NR_CPUS baked in at its own build time —
# must match --cores= at launch, or CPU bring-up hangs).
$(BWA_DIR)/configure: | $(BUILD_DIR)
	git clone https://git.kernel.org/pub/scm/linux/kernel/git/mark/boot-wrapper-aarch64.git $(BWA_DIR)
	cd $(BWA_DIR) && autoreconf -i

$(AXF): $(BWA_DIR)/configure $(KERNEL_IMAGE) $(DTB)
	cd $(BWA_DIR) && ./configure --host=aarch64-linux-gnu \
	  --with-kernel-image=$(abspath $(KERNEL_IMAGE)) \
	  --with-dtb=$(abspath $(DTB)) \
	  --with-cmdline="console=ttyAMA0 earlycon=pl011,0x1c090000 root=/dev/vda rootfstype=squashfs ro init=/init"
	$(MAKE) -C $(BWA_DIR)

# --- Base RevC dtb + boot-wrapper ---
# The dts #includes the kernel's rtsm_ve-motherboard*.dtsi and
# dt-bindings headers, so it's copied into the kernel tree and built by
# kbuild (which runs cpp with the right include paths) rather than by a
# bare `dtc` like the Foundation dtb above.
$(BASE_DTB): $(BASE_DTS_SRC) $(KERNEL_SRC)/Makefile
	cp $(BASE_DTS_SRC) $(BASE_DTS_DIR)/
	$(MAKE) -C $(KERNEL_SRC) ARCH=arm64 arm/$(BASE_DTS_NAME).dtb

# Local clone of the already-cloned boot-wrapper (no second network fetch).
# boot-wrapper's NR_CPUS comes from the dtb's cpu nodes, and its cpu0 waits
# for ALL of them to pass through boot-wrapper before entering the kernel —
# hence pctl.startup in the run targets below.
$(BWA_BASE_DIR)/configure: $(BWA_DIR)/configure
	git clone -q $(BWA_DIR) $(BWA_BASE_DIR)
	cd $(BWA_BASE_DIR) && autoreconf -i

$(BASE_AXF): $(BWA_BASE_DIR)/configure $(KERNEL_IMAGE) $(BASE_DTB)
	cd $(BWA_BASE_DIR) && ./configure --host=aarch64-linux-gnu \
	  --with-kernel-image=$(abspath $(KERNEL_IMAGE)) \
	  --with-dtb=$(abspath $(BASE_DTB)) \
	  --with-cmdline="console=ttyAMA0 earlycon=pl011,0x1c090000 root=/dev/vda rootfstype=squashfs ro init=/init" \
	  --enable-gicv3
	$(MAKE) -C $(BWA_BASE_DIR)

# --- Rootfs ---
# busybox-static squashfs; rootfs/init mounts debugfs, runs
# rootfs/ftrace_test.sh (function-tracer capture on every online CPU,
# prints FTRACE_RESULT PASS|FAIL then FTRACE_DONE), then execs a real shell (see rootfs/init's
# comments for why the exec matters).
# busybox is not tracked in git (binary): copied from the host's
# busybox-static package (static aarch64, so it runs as-is in the rootfs).
rootfs/bin/busybox:
	cp /usr/bin/busybox $@

$(ROOTFS_SQFS): rootfs/init rootfs/ftrace_test.sh rootfs/bin/busybox | $(BUILD_DIR)
	mksquashfs rootfs/ $(ROOTFS_SQFS) -all-root -noappend

# --- Run ---
# --cores=4 must match boot-wrapper's --with-cpu-nr above.
run: $(AXF) $(ROOTFS_SQFS)
	Foundation_Platform --image=$(AXF) --cores=4 --no-gicv3 \
	  --block-device=$(ROOTFS_SQFS) --read-only --uart0-outfile=-

# --- Run under Base Platform RevC (2 cores) ---
# Needs FVP_Base_RevC-2xAEMvA on PATH (script/0_env_var_setup.sh).
# Two params are required here and both were root-caused live (see
# doc/README.md "Base Platform RevC + Iris"):
#   bp.refcounter.non_arch_start_at_default=1 — starts the system counter
#     (normally TF-A's job; boot-wrapper doesn't do it). Without it
#     CNTPCT_EL0 stays 0 and Linux hangs forever in GIC ITS init
#     (its_wait_for_range_completion -> __delay never times out).
#   pctl.startup=0.0.*.* — powers BOTH cluster0 cores at reset (default
#     is cpu0 only). boot-wrapper's cpu0 waits for every dtb CPU to check
#     in before entering the kernel; without this it hangs right after
#     "CPU0: (MPIDR ...) initializing...".
# NUM_CORES trims the model to match the dtb's 2 CPUs.
# Console: UART0 is echoed to stdout (out_file=-) and also served
# interactively on TCP port 5000 (`nc localhost 5000`), as with `run`.
# unbuffered_output=1: without it the model block-buffers UART output
# when stdout is a file, so a redirected log only fills in at exit.
BASE_FVP_ARGS = -a $(BASE_AXF) \
	  -C bp.secure_memory=0 \
	  -C bp.vis.disable_visualisation=1 \
	  -C bp.terminal_0.start_telnet=0 \
	  -C bp.pl011_uart0.out_file=- \
	  -C bp.pl011_uart0.unbuffered_output=1 \
	  -C bp.virtioblockdevice.image_path=$(ROOTFS_SQFS) \
	  -C bp.virtioblockdevice.read_only=1 \
	  -C bp.refcounter.non_arch_start_at_default=1 \
	  -C cluster0.NUM_CORES=2 -C cluster1.NUM_CORES=0 \
	  -C pctl.startup=0.0.*.* \
	  -C cluster0.has_arm_v9-0=1

# BASE_EXTRA: extra model args, e.g. script/1_run_base_ftrace.sh passes
#   -C bp.pl011_uart0.shutdown_tag=FTRACE_DONE  (model exits after the test)
run-base: $(BASE_AXF) $(ROOTFS_SQFS)
	FVP_Base_RevC-2xAEMvA $(BASE_FVP_ARGS) $(BASE_EXTRA)

# Same, plus an Iris debug server. With -I and no -R the model does NOT
# run until a client drives it — model.run() on an async connection, or
# cpu.step() on a synchronous one (see doc/README.md).
run-base-debug: $(BASE_AXF) $(ROOTFS_SQFS)
	FVP_Base_RevC-2xAEMvA $(BASE_FVP_ARGS) -I --iris-port $(IRIS_PORT)

clean:
	rm -f $(DTB) $(ROOTFS_SQFS) $(AXF) $(BASE_DTB) $(BASE_AXF)

distclean: clean
	rm -rf $(BUILD_DIR)

.PHONY: all base run run-base run-base-debug clean distclean
