#!/usr/bin/env bash
# ath6kl-tune.sh
# =================================================================
# ath6kl Wi-Fi Tuning (Dell Venue 8 Pro 5830)
#
# Copyright (c) 2026 Rámon van Raaij
# SPDX-License-Identifier: BSD-3-Clause
# License: BSD-3-Clause
# Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
#
# Re-applies the ath6kl debugfs knobs that stop the Atheros AR6004
# Wi-Fi from self-deauthenticating (CTRL-EVENT-DISCONNECTED reason=3)
# after roughly 37 minutes. The firmware's self-disconnect patience
# (disconnect_timeout) defaults to 10, which is too short; raising it
# and disabling firmware background scan keeps the link up. Verified
# with a 50-minute clean soak versus a drop on every prior boot.
#
# It performs the following actions:
# 1. Waits for the ath6kl debugfs node to appear (up to ~60s).
# 2. Re-asserts the NL regulatory domain (belt-and-suspenders for 5GHz).
# 3. Sets disconnect_timeout=60 and disables firmware background scan.
#
# Usage:
# Installed as a boot-time oneshot service (ath6kl-tune.service); it
# can also be run by hand as root:
#   sudo /usr/local/sbin/ath6kl-tune.sh
# =================================================================

set -o errexit -o nounset -o pipefail

# --- Configuration ---
readonly DISCONNECT_TIMEOUT=60                                # firmware self-disconnect patience (default 10)
readonly NODE_GLOB="/sys/kernel/debug/ieee80211/phy*/ath6kl"  # debugfs is root-only
readonly MAX_TRIES=30                                         # ~60s total at 2s per try

# --- Locate the debugfs node ---
# The node appears a few seconds after the driver/firmware loads at boot.
node=""
for _ in $(seq 1 "${MAX_TRIES}"); do
	for candidate in ${NODE_GLOB}; do
		if [ -e "${candidate}/disconnect_timeout" ]; then
			node="${candidate}"
			break
		fi
	done
	if [ -n "${node}" ]; then
		break
	fi
	sleep 2
done

if [ -z "${node}" ]; then
	echo "ath6kl-tune: debugfs node not found" >&2
	exit 1
fi

# --- Apply the tuning ---
# /etc/modprobe.d/cfg80211-regdom.conf already sets the regdom to NL at cfg80211
# load (regdom 00 forbids all 5GHz); re-assert it at runtime, no-op if iw absent.
iw reg set NL 2>/dev/null || true

# The fix: lengthen the firmware self-disconnect timeout and stop background scan.
echo "${DISCONNECT_TIMEOUT}" > "${node}/disconnect_timeout"
echo 0 > "${node}/bgscan_interval" 2>/dev/null || true

logger -t ath6kl-tune \
	"applied disconnect_timeout=$(cat "${node}/disconnect_timeout" 2>/dev/null || echo '?') bgscan_interval=$(cat "${node}/bgscan_interval" 2>/dev/null || echo '?') on ${node}"
