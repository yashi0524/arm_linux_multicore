#!/bin/bash

if [ -z "$PATH_BACK" ]; then
    export PATH_BACK="$PATH"
fi

# Foundation Platform — `make run` (no Iris available on this FVP)
export PATH=$HOME/work/0_simulator/arm_fvp/Foundation_Platform_11.32_19/bin:$PATH_BACK

# Base Platform RevC — `make run-base` / `make run-base-debug` (Iris server)
export PATH=$HOME/work/0_simulator/arm_fvp/Base_RevC_AEMvA_11.32_19/bin:$PATH

# ipython3 for interactive iris.debug sessions — same no-root install as
# ../../arm_bare_metal_multi/script/0_env_var_setup.sh
export PATH=$HOME/.local/ipython-tools/usr/bin:$PATH
export PYTHONPATH=$HOME/.local/ipython-tools/usr/lib/python3/dist-packages:$PYTHONPATH

# dtc, flex, bison — not preinstalled on this host, no root/sudo available.
# Installed the same no-root way as ipython3 (see ../../arm_bare_metal_multi):
# apt-get download + dpkg-deb -x into a user-local prefix.
export PATH=$HOME/.local/dtc-tools/usr/bin:$HOME/.local/kbuild-tools/usr/bin:$PATH
export LD_LIBRARY_PATH=$HOME/.local/dtc-tools/usr/lib/aarch64-linux-gnu:$LD_LIBRARY_PATH
# bison's data files aren't relocatable via PATH alone — it hardcodes
# /usr/share/bison; this env var is bison's own escape hatch (verified
# needed: without it, "cannot open m4sugar.m4" during kbuild's kconfig step).
export BISON_PKGDATADIR=$HOME/.local/kbuild-tools/usr/share/bison
