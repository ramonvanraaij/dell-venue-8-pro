#!/usr/bin/env bash
# venue-batfix-build.sh
# =================================================================
# Build + install the batfix kernel module (Dell Venue 8 Pro 5830)
#
# Copyright (c) 2026 Rámon van Raaij
# License: BSD-3-Clause
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# Builds the out-of-tree batfix module (see /usr/local/src/venue-batfix) and
# installs it into the kernel's updates/ dir so modules-load.d picks it up at
# boot. batfix filters the transient all-zero battery readings this tablet's
# firmware emits on AC transitions (see the Battery section of README.md).
#
# An out-of-tree module is tied to one kernel's ABI, so it must be rebuilt after
# a kernel upgrade. etc/pacman.d/hooks/venue-batfix.hook calls this script with
# the new kernel's module targets on stdin after every `linux` upgrade, so the
# rebuild is automatic.
#
# Usage:
#   venue-batfix-build.sh              # build for the running kernel
#   venue-batfix-build.sh <kver>       # build for a specific kernel version
#   venue-batfix-build.sh --hook       # pacman-hook mode: read module target
#                                      # paths (usr/lib/modules/<kver>/...) on stdin
# =================================================================

set -o errexit -o nounset -o pipefail

readonly SRC=/usr/local/src/venue-batfix

build_one() {
	local kver="$1"
	local kdir="/usr/lib/modules/${kver}/build"

	if [ ! -d "${kdir}" ]; then
		echo "batfix: no build tree for ${kver} (install linux-headers), skipping" >&2
		return 0
	fi
	make -C "${SRC}" KVER="${kver}" clean >/dev/null 2>&1 || true
	make -C "${SRC}" KVER="${kver}" >/dev/null
	install -Dm644 "${SRC}/batfix.ko" "/usr/lib/modules/${kver}/updates/batfix.ko"
	depmod "${kver}"
	echo "batfix: built + installed for ${kver}"
}

case "${1:-}" in
--hook)
	# pacman-hook mode: parse the kernel version out of each target path on stdin
	while IFS= read -r target; do
		kver="$(printf '%s' "${target}" | sed -n 's|.*/modules/\([^/]*\)/.*|\1|p')"
		[ -n "${kver}" ] && build_one "${kver}"
	done
	;;
"")
	build_one "$(uname -r)"
	;;
*)
	build_one "$1"
	;;
esac
