#!/usr/bin/env bash
# arch-launcher-icon.sh
# =================================================================
# Plasma Mobile Arch Launcher Icon
#
# Copyright (c) 2026 Rámon van Raaij
# License: BSD-3-Clause
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# Replaces the Plasma Mobile navigation-panel home button (the
# "cashew" / start-here-kde icon) with the Arch logo, to match the
# Dell Venue 8 Pro's Arch branding.
#
# The task panel renders this icon through Qt's QIconLoader, which
# reads the breeze-icons theme files directly; a per-user
# ~/.local/share/icons override does not reach it. So this overwrites
# the breeze and breeze-dark start-here-kde* SVGs in place with the
# Arch logo. breeze-icons upgrades restore the originals, so a pacman
# hook (/etc/pacman.d/hooks/zz-arch-launcher-icon.hook) re-runs this
# script after every breeze-icons transaction.
#
# It performs the following actions:
# 1. Backs up the original icons once, before the first replacement.
# 2. Overwrites every breeze/breeze-dark start-here-kde* icon.
# 3. Refreshes the icon-theme caches.
#
# Usage:
#   sudo /usr/local/sbin/arch-launcher-icon.sh
# Run once to apply now; reboot (or restart plasmashell) to see it.
# =================================================================

set -o errexit -o nounset -o pipefail

# --- Configuration ---
readonly ARCH_LOGO="/usr/share/pixmaps/archlinux-logo.svg" # from the archlinux-logo package
readonly ICON_THEMES=(/usr/share/icons/breeze /usr/share/icons/breeze-dark)
readonly BACKUP="/var/backups/arch-launcher-icon/start-here-kde-breeze-orig.tgz" # fixed path (runs as root)

# --- Main ---
# The Arch logo is mandatory; skip silently if the package is absent (the
# pacman hook must not abort a transaction).
[ -r "${ARCH_LOGO}" ] || { echo "missing ${ARCH_LOGO} (install archlinux-logo)" >&2; exit 0; }

# Back up the packaged originals once, so the change can be reverted.
if [ ! -e "${BACKUP}" ]; then
	mkdir -p "$(dirname "${BACKUP}")"
	( cd /usr/share/icons && find breeze breeze-dark -name 'start-here-kde*.svg' 2>/dev/null \
		| tar -czf "${BACKUP}" -T - 2>/dev/null ) || true
fi

# Overwrite every start-here-kde* variant (colour + symbolic, all sizes).
count=0
while IFS= read -r -d '' icon; do
	cp -f "${ARCH_LOGO}" "${icon}"
	count=$((count + 1))
done < <(find "${ICON_THEMES[@]}" -name 'start-here-kde*.svg' -print0 2>/dev/null)

# Refresh the freedesktop icon caches for GTK consumers. Qt's QIconLoader (which the
# task panel uses) reads the SVG files directly, so overwriting them is what takes effect.
for theme in "${ICON_THEMES[@]}"; do
	gtk-update-icon-cache -f -t "${theme}" 2>/dev/null || true
done

echo "arch-launcher-icon: replaced ${count} start-here-kde icon(s) with the Arch logo"
