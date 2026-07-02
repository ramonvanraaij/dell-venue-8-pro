#!/usr/bin/env bash
# install.sh
# =================================================================
# Dell Venue 8 Pro 5830 - apply all fixes from this repo
#
# Copyright (c) 2026 Rámon van Raaij
# License: BSD-3-Clause
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# Automates the manual steps documented in README.md: installs the required
# packages, copies every config file to its system path, builds and installs the
# bthci Bluetooth bring-up tool and the batfix kernel module, builds the bt0off
# ACPI override and wires it into the systemd-boot entries, and enables the
# services. It is idempotent - safe to re-run.
#
# It is deliberately conservative with the bootloader: it backs up each loader
# entry before editing and only adds the acpi_override initrd / the extra kernel
# cmdline options if they are missing. If the bootloader is not systemd-boot, it
# skips those two steps and prints what to do by hand.
#
# Usage:
#   sudo ./install.sh
# Then reboot to pick up the ACPI override (ttyS4/Bluetooth), the 5 GHz
# regulatory domain, and the batfix module.
# =================================================================

set -o errexit -o nounset -o pipefail

# --- preconditions ---
if [ "$(id -u)" -ne 0 ]; then
	echo "install.sh must run as root: sudo ./install.sh" >&2
	exit 1
fi

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The plasma-systemmonitor page is a per-user file; find the invoking user.
USER_NAME="${SUDO_USER:-root}"
USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
[ -n "${USER_HOME}" ] || USER_HOME="/root"
USER_GROUP="$(id -gn "${USER_NAME}" 2>/dev/null || echo "${USER_NAME}")"

log() { printf '\n== %s ==\n' "$*"; }

# --- 1. packages ---
log "Installing packages"
pacman -S --needed --noconfirm \
	base-devel linux-headers acpica \
	wireless-regdb powertop acpi thermald zram-generator \
	bluez bluez-utils bluez-deprecated-tools
# (the Arch logo used by the launcher fix ships in the base `filesystem` package)

# --- 2. config files -> real system paths ---
log "Installing config files"
install -Dm644 "${REPO}/etc/modprobe.d/ath6kl.conf"                   /etc/modprobe.d/ath6kl.conf
install -Dm644 "${REPO}/etc/modprobe.d/cfg80211-regdom.conf"          /etc/modprobe.d/cfg80211-regdom.conf
install -Dm644 "${REPO}/etc/NetworkManager/conf.d/30-no-mac-rand.conf" /etc/NetworkManager/conf.d/30-no-mac-rand.conf
install -Dm644 "${REPO}/etc/sysctl.d/99-venue-power.conf"             /etc/sysctl.d/99-venue-power.conf
install -Dm644 "${REPO}/etc/sysctl.d/99-zram-tablet.conf"             /etc/sysctl.d/99-zram-tablet.conf
install -Dm644 "${REPO}/etc/systemd/zram-generator.conf"             /etc/systemd/zram-generator.conf
install -Dm644 "${REPO}/etc/systemd/coredump.conf.d/disable-storage.conf" /etc/systemd/coredump.conf.d/disable-storage.conf
install -Dm644 "${REPO}/etc/udev/rules.d/99-emmc-fixed-disk.rules"    /etc/udev/rules.d/99-emmc-fixed-disk.rules
install -Dm644 "${REPO}/etc/modules-load.d/venue-batfix.conf"         /etc/modules-load.d/venue-batfix.conf
install -Dm644 "${REPO}/etc/pacman.d/hooks/zz-arch-launcher-icon.hook" /etc/pacman.d/hooks/zz-arch-launcher-icon.hook
install -Dm644 "${REPO}/etc/pacman.d/hooks/venue-batfix.hook"         /etc/pacman.d/hooks/venue-batfix.hook
install -Dm755 "${REPO}/usr/local/sbin/ath6kl-tune.sh"               /usr/local/sbin/ath6kl-tune.sh
install -Dm755 "${REPO}/usr/local/sbin/arch-launcher-icon.sh"        /usr/local/sbin/arch-launcher-icon.sh
install -Dm755 "${REPO}/usr/local/sbin/venue-batfix-build.sh"        /usr/local/sbin/venue-batfix-build.sh
install -Dm644 "${REPO}/etc/systemd/system/ath6kl-tune.service"      /etc/systemd/system/ath6kl-tune.service
install -Dm644 "${REPO}/etc/systemd/system/bt-venue.service"         /etc/systemd/system/bt-venue.service

# Per-user System Monitor overview page. Pre-create the dir with the user's
# ownership so a freshly created config dir is not left root-owned.
install -d -o "${USER_NAME}" -g "${USER_GROUP}" "${USER_HOME}/.local/share/plasma-systemmonitor"
install -Dm644 -o "${USER_NAME}" -g "${USER_GROUP}" \
	"${REPO}/home/.local/share/plasma-systemmonitor/overview.page" \
	"${USER_HOME}/.local/share/plasma-systemmonitor/overview.page"

# --- 3. bthci (Bluetooth bring-up tool) ---
log "Building bthci"
gcc -O2 -o /usr/local/sbin/bthci "${REPO}/src/bthci.c"
chmod 755 /usr/local/sbin/bthci

# --- 4. batfix (battery transient-zero kernel module) ---
log "Building + installing batfix kernel module"
install -Dm644 "${REPO}/usr/local/src/venue-batfix/batfix.c" /usr/local/src/venue-batfix/batfix.c
install -Dm644 "${REPO}/usr/local/src/venue-batfix/Makefile" /usr/local/src/venue-batfix/Makefile
/usr/local/sbin/venue-batfix-build.sh

# --- 5. bt0off ACPI override + systemd-boot wiring ---
log "Building the bt0off ACPI override"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
( cd "${tmp}" && cp "${REPO}/acpi/bt0off.dsl" . && iasl -tc bt0off.dsl >/dev/null )
mkdir -p "${tmp}/cpio/kernel/firmware/acpi"
cp "${tmp}/bt0off.aml" "${tmp}/cpio/kernel/firmware/acpi/"
# Build to a temp file on /boot's own filesystem, then atomically rename, so a
# failed/partial cpio (e.g. a full ESP) can never truncate the live image the
# bootloader already points at.
( cd "${tmp}/cpio" && find kernel | cpio -H newc --create --quiet > /boot/acpi_override.img.new )
mv -f /boot/acpi_override.img.new /boot/acpi_override.img
echo "wrote /boot/acpi_override.img"

# Extra kernel cmdline options for boot stability (README "Boot-to-desktop stability").
CMDLINE_OPTS="intel_idle.max_cstate=1 panic=10 zswap.enabled=0"

boot_manual_note() {
	echo "NOTE: add 'initrd /acpi_override.img' (before the main initramfs line) and the"
	echo "      kernel options '${CMDLINE_OPTS}' to your bootloader entries by hand."
}

if [ -d /boot/loader/entries ]; then
	processed=0
	for entry in /boot/loader/entries/*.conf; do
		[ -e "${entry}" ] || continue
		case "${entry}" in *.bak-*) continue ;; esac        # skip our own backups
		grep -q '^initrd[[:space:]]*/initramfs-linux\.img' "${entry}" || continue  # main kernel only
		processed=$((processed + 1))
		cp -n "${entry}" "${entry}.bak-install" || true

		# add the early acpi_override initrd before the main initramfs, once
		if ! grep -q 'acpi_override\.img' "${entry}"; then
			sed -i 's|^\(initrd[[:space:]]*/initramfs-linux\.img\)|initrd  /acpi_override.img\n\1|' "${entry}"
			echo "added acpi_override initrd to $(basename "${entry}")"
		fi

		# ensure the boot-stability cmdline options are on the (first) options line
		opts_line="$(grep -m1 '^options ' "${entry}" || true)"
		if [ -n "${opts_line}" ]; then
			for opt in ${CMDLINE_OPTS}; do
				key="${opt%%=*}"
				case " ${opts_line} " in
				*" ${key} "* | *" ${key}="*)
					: ;;                     # already present
				*)
					# only the first options line (systemd-boot concatenates them)
					sed -i "0,/^options /s|^\(options .*\)\$|\1 ${opt}|" "${entry}"
					opts_line="${opts_line} ${opt}"
					echo "added '${opt}' to $(basename "${entry}")"
					;;
				esac
			done
		else
			printf 'options %s\n' "${CMDLINE_OPTS}" >> "${entry}"
			echo "added options line to $(basename "${entry}")"
		fi
	done
	if [ "${processed}" -eq 0 ]; then
		echo "NOTE: no main systemd-boot entry (initramfs-linux.img) found."
		boot_manual_note
	fi
else
	echo "NOTE: not systemd-boot."
	boot_manual_note
fi

# --- 6. runtime settings + services ---
log "Applying runtime settings and enabling services"
sysctl --system >/dev/null || true
udevadm control --reload && udevadm trigger --name-match=mmcblk1 || true
systemctl restart udisks2 2>/dev/null || true
/usr/local/sbin/arch-launcher-icon.sh || true

systemctl daemon-reload
systemctl enable thermald.service ath6kl-tune.service bt-venue.service
modprobe batfix 2>/dev/null || true

log "Done"
echo "Reboot to apply: the ACPI override (/dev/ttyS4 + Bluetooth), the 5 GHz"
echo "regulatory domain, the batfix module, and the boot-stability cmdline."
