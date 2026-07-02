# Dell Venue 8 Pro 5830 - Arch Linux setup and fixes

Working configuration and fixes for running Arch Linux (Plasma Mobile, Wayland) on the
Dell Venue 8 Pro 5830 (model TD01001, Bay Trail-T / Atom Z3740D, 2 GB RAM). Network
addresses and hardware identifiers are shown as placeholders (e.g. `<TABLET_IP>`,
`<WIFI_MAC>`); substitute your own.

The actual config files live in this repo under their real system paths, so they can be
copied straight into place:

```
etc/modprobe.d/ath6kl.conf                     -> /etc/modprobe.d/ath6kl.conf
etc/modprobe.d/cfg80211-regdom.conf            -> /etc/modprobe.d/cfg80211-regdom.conf
etc/sysctl.d/99-venue-power.conf               -> /etc/sysctl.d/99-venue-power.conf
etc/sysctl.d/99-zram-tablet.conf               -> /etc/sysctl.d/99-zram-tablet.conf
etc/systemd/zram-generator.conf                -> /etc/systemd/zram-generator.conf
etc/systemd/coredump.conf.d/disable-storage.conf -> /etc/systemd/coredump.conf.d/disable-storage.conf
etc/systemd/system/ath6kl-tune.service         -> /etc/systemd/system/ath6kl-tune.service
etc/NetworkManager/conf.d/30-no-mac-rand.conf  -> /etc/NetworkManager/conf.d/30-no-mac-rand.conf
usr/local/sbin/ath6kl-tune.sh                  -> /usr/local/sbin/ath6kl-tune.sh
usr/local/sbin/arch-launcher-icon.sh           -> /usr/local/sbin/arch-launcher-icon.sh
etc/pacman.d/hooks/zz-arch-launcher-icon.hook  -> /etc/pacman.d/hooks/zz-arch-launcher-icon.hook
etc/udev/rules.d/99-emmc-fixed-disk.rules      -> /etc/udev/rules.d/99-emmc-fixed-disk.rules
home/.local/share/plasma-systemmonitor/overview.page -> ~/.local/share/plasma-systemmonitor/overview.page
src/bthci.c                                    -> build (gcc -O2 -o bthci src/bthci.c), install to /usr/local/sbin/bthci
acpi/bt0off.dsl                                -> build to /boot/acpi_override.img (see the file header)
etc/systemd/system/bt-venue.service            -> /etc/systemd/system/bt-venue.service
usr/local/src/venue-batfix/{batfix.c,Makefile} -> /usr/local/src/venue-batfix/ (kernel module source)
usr/local/sbin/venue-batfix-build.sh           -> /usr/local/sbin/venue-batfix-build.sh
etc/pacman.d/hooks/venue-batfix.hook           -> /etc/pacman.d/hooks/venue-batfix.hook
etc/modules-load.d/venue-batfix.conf           -> /etc/modules-load.d/venue-batfix.conf
```

## Install

To apply everything at once, run the install script from the repo root:

```
sudo ./install.sh
```

It is idempotent (safe to re-run) and does what the per-fix sections below describe: installs
the packages, copies each config file into place, builds and installs `bthci` and the `batfix`
kernel module, builds the `bt0off` ACPI override and adds it to the systemd-boot loader entries
(backing each entry up first), applies the runtime settings, and enables the services. Reboot
afterwards to pick up the ACPI override (`/dev/ttyS4` + Bluetooth), the 5 GHz regulatory domain,
the `batfix` module, and the boot-stability kernel options.

The per-fix sections below explain each change and its manual steps, for reference or to apply
them selectively.

## Hardware

- SoC: Intel Atom Z3740D (Bay Trail-T), 4 cores
- RAM: 2 GB; eMMC storage (btrfs root, subvol `@`)
- PMIC: Intel Crystal Cove (`INT33FD`)
- Wi-Fi: Atheros AR6004 hw3.0, SDIO, `ath6kl` driver, firmware `fw-5.bin` (3.5.0.349-1)
- Bluetooth: Atheros AR3002 (ACPI `DLAC3002`), HCI-UART on the Bay Trail HSUART (`ttyS4`); works (see below - the ROM runs at 3686400 baud)
- Desktop: Plasma Mobile on Wayland, SDDM autologin

## Fixes

### Wi-Fi: ~37-minute disconnect (the important one)

Symptom: the link dies to "unreachable" after ~35-40 min, usually needing a reboot. The
journal shows a station-side firmware self-deauth (`CTRL-EVENT-DISCONNECTED reason=3
locally_generated=1`); afterwards every reconnect scan fails `ret=-16/EBUSY` because the
wedged firmware never delivered `scan_complete`.

Root cause: the `ath6kl` debugfs `disconnect_timeout` (the firmware's self-disconnect
patience) defaults to **10**, which is too short.

Fix: `usr/local/sbin/ath6kl-tune.sh` + `etc/systemd/system/ath6kl-tune.service` set
`disconnect_timeout=60` and disable firmware background scan on every boot (it waits for
the debugfs node, then writes the knobs). Verified with a ~50-min clean soak versus a
drop on every prior boot. When reading the node by hand, use the explicit `phy0` path - a
`phy*` glob expanded by your non-root shell before `sudo` comes back empty (debugfs is
root-only); the service runs as root, so its own `phy*` glob works.

```
sudo cp usr/local/sbin/ath6kl-tune.sh /usr/local/sbin/ && sudo chmod +x /usr/local/sbin/ath6kl-tune.sh
sudo cp etc/systemd/system/ath6kl-tune.service /etc/systemd/system/
sudo systemctl enable --now ath6kl-tune.service
```

### Wi-Fi: 5 GHz access

`wireless-regdb` was not installed, so `/lib/firmware/regulatory.db` was missing and the
regulatory domain stayed at `00` (world), which forbids all 5 GHz channels - `iw reg set`
was silently a no-op.

Fix: install the regdb and set the domain early, before NetworkManager associates:

```
sudo pacman -S wireless-regdb
sudo cp etc/modprobe.d/cfg80211-regdom.conf /etc/modprobe.d/   # options cfg80211 ieee80211_regdom=NL
sudo reboot
```

Note: 5 GHz works well here - the main router has a strong 5 GHz BSS on DFS channel 100
(5500 MHz, around -44 dBm) and the tablet connects to it. Because DFS channels only show up
on the slower passive scan, NetworkManager can briefly settle on the 2.4 GHz BSS at connect
time and roam to 5 GHz once the passive scan completes (a fresh scan of the same SSID may
even miss the DFS 5 GHz BSS entirely). Staying on 5 GHz is also the clean way to sidestep
Wi-Fi/Bluetooth coexistence: the internal Bluetooth is 2.4 GHz-only, so with Wi-Fi on 5 GHz
the two radios no longer share the band and stop fighting.

### Wi-Fi: firmware self-heal

`etc/modprobe.d/ath6kl.conf` enables `recovery_enable=1 heart_beat_poll=2000` so the
driver resets/recovers the AR6004 if its firmware asserts or hangs. (Belt-and-suspenders;
the `disconnect_timeout` fix above is what actually prevents the ~37-min drop.)

### MAC randomization off

`etc/NetworkManager/conf.d/30-no-mac-rand.conf` disables scan MAC randomization - ath6kl
does not support it (`set-hw-addr ... failure 95 Operation not supported`), which spammed
the journal and interfered with reassociation.

### Power management

The modern stack is already in place and preferred: `power-profiles-daemon` +
`intel_pstate` (passive) + `schedutil`. Added on top, non-conflicting:

```
sudo pacman -S powertop acpi thermald
sudo systemctl enable --now thermald          # thermal management for the fanless tablet
sudo cp etc/sysctl.d/99-venue-power.conf /etc/sysctl.d/ && sudo sysctl --system
```

`99-venue-power.conf` sets `kernel.nmi_watchdog=0` and `vm.dirty_writeback_centisecs=1500`.
The dated manual studioteabag scripts (forcing `no_turbo`, a fixed governor, offlining
cores) are intentionally skipped - they fight power-profiles-daemon.

### zram (2 GB RAM)

The `zram-generator` package provides RAM-backed compressed swap; sized to full RAM with
zstd, plus sysctl tuning to prefer it.

```
sudo pacman -S zram-generator
sudo cp etc/systemd/zram-generator.conf /etc/systemd/
sudo cp etc/sysctl.d/99-zram-tablet.conf /etc/sysctl.d/ && sudo sysctl --system
sudo systemctl daemon-reload && sudo systemctl start dev-zram0.swap   # or reboot
```

`zram-generator.conf`: `zram-size = ram`, `compression-algorithm = zstd`,
`swap-priority = 100`. `99-zram-tablet.conf`: `vm.swappiness=150`, `vm.page-cluster=0`.
The kernel cmdline also sets `zswap.enabled=0` (zram is used instead).

### Boot-to-desktop stability (Bay Trail freezes)

Bay Trail Atom hangs/freezes in deep idle C-states - on this tablet that showed up as an
intermittent freeze on the SDDM splash during boot. The fix is in the kernel command line
(systemd-boot loader entry, the `options` line):

```
intel_idle.max_cstate=1     # the key fix - cap idle at C1, avoids the deep-C-state hangs
panic=10                    # auto-reboot 10s after a kernel panic
zswap.enabled=0             # zram is used for swap instead
```

If a frozen splash still happens once in a while, the session has usually actually started
behind it; `sudo systemctl restart sddm` (or kill the stale `kwin_wayland`/`plasmashell`
and restart SDDM) recovers it without a reboot.

### Coredump disable (slow eMMC)

`etc/systemd/coredump.conf.d/disable-storage.conf` sets `Storage=none` /
`ProcessSizeMax=0`. The eMMC is far too slow to process core dumps; a crash-loop otherwise
turns coredump processing into a disk-saturating freeze.

### Launcher home button: Arch logo

The Plasma Mobile navigation panel's centre home button shows the Plasma "cashew"
(`start-here-kde`). To match the device's Arch branding it is replaced with the Arch logo.

The task panel renders that icon via Qt's QIconLoader, which reads the `breeze-icons` theme
files directly - a per-user `~/.local/share/icons/<theme>/` override does NOT reach it (KDE's
own `kiconfinder6` resolves the override, but the panel still renders the packaged file). So
`usr/local/sbin/arch-launcher-icon.sh` overwrites the breeze / breeze-dark `start-here-kde*`
SVGs in place with `/usr/share/pixmaps/archlinux-logo.svg`. Because `breeze-icons` upgrades
revert those files, `etc/pacman.d/hooks/zz-arch-launcher-icon.hook` re-runs the script after
every `breeze-icons` transaction.

```
sudo cp usr/local/sbin/arch-launcher-icon.sh /usr/local/sbin/ && sudo chmod +x /usr/local/sbin/arch-launcher-icon.sh
sudo cp etc/pacman.d/hooks/zz-arch-launcher-icon.hook /etc/pacman.d/hooks/
sudo /usr/local/sbin/arch-launcher-icon.sh   # apply now; reboot (or restart plasmashell) to see it
```

The originals are backed up to `/var/backups/arch-launcher-icon/` before the first
replacement (the script runs as root, via the pacman hook). To revert, restore them and
remove the hook.

### System Monitor: Disks widget (eMMC shows as "no regular disks")

The Plasma System Monitor "Disks" widget (Overview page) was empty. The internal eMMC
(`mmcblk1`) is reported by udev as flash media (`ID_DRIVE_FLASH_MMC=1`), so KDE
Solid/UDisks2 classify it as `driveType=SdMmc`. ksystemstats' disk plugin skips SD/MMC
drives, so it creates no disk sensors and the only one left is the empty `disk/all`
aggregate (`used=0`) - the widget renders nothing.

Fix: `etc/udev/rules.d/99-emmc-fixed-disk.rules` clears the flash-MMC udev flags on
`mmcblk1`, so Solid reports `driveType=HardDisk`; ksystemstats then enumerates the eMMC
(`disk/mmcblk1`, `disk/<uuid>`, and `disk/all` with real `used`/`total`).

```
sudo cp etc/udev/rules.d/99-emmc-fixed-disk.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger --name-match=mmcblk1
sudo systemctl restart udisks2          # then re-login or reboot so ksystemstats re-enumerates
```

`home/.local/share/plasma-systemmonitor/overview.page` additionally switches the Disks
face to a pie of `disk/all/used` (matching the CPU/Memory faces); with the udev rule in
place the stock widget works too.

### Bluetooth: internal AR3002 (works - the ROM runs at 3686400 baud)

The internal Bluetooth (AR3002 / `DLAC3002`, HCI-UART on the Bay Trail HS-UART) works. The
one thing that made it look "dead" through a long investigation was the **baud rate**: the
AR3002 boot ROM communicates at **3686400 baud**, not the 115200 that its Windows INF lists
as `DefaultBaudRate`. Every earlier attempt used 115200 (or a baud sweep that topped out at
2764800, the `ttyS4` `base_baud`), so 3.6864 Mbaud was never tried. At 3686400 the ROM
answers `GET_VERSION` immediately (ROM version `0x01020201`) and is fully HCI-capable - a
valid `BD_ADDR`, the complete feature set, classic + LE scanning and pairing. No firmware
download is needed; the ROM alone is enough. (`hciattach`/`btattach` cannot drive it, because
3686400 is not a POSIX termios baud constant - only `termios2` / `BOTHER` can set it, which
is why the stock tools time out.)

Three pieces make it work and persist across reboots:

1. **`bt0off` SSDT override** (`acpi/bt0off.dsl`) - gives `\_SB.URT1.BTH0` an `_STA` that
   returns 0, so the HS-UART enumerates as a plain `/dev/ttyS4` instead of an ACPI serdev
   child. Built into `/boot/acpi_override.img` and loaded as an early initrd (add
   `initrd /acpi_override.img` *before* the main initramfs line in the systemd-boot entry;
   the build/install steps are in the file header). Reversible by removing that initrd line.
2. **`bthci`** (`src/bthci.c`) - a small self-contained tool that powers the chip via the
   gpio character device (`gpiochip0` = `INT33FC:00` = `\_SB.GPO0`, line 52 = power/enable,
   line 53 = wake), sets `ttyS4` to 3686400 + hardware flow control via `termios2`/`BOTHER`,
   and attaches the `N_HCI` line discipline (`HCI_UART_H4`) so the kernel exposes `hci0`. It
   uses only stable kernel ABIs (gpio chardev + line discipline), so nothing here needs a
   custom kernel module and it survives kernel upgrades. Build: `gcc -O2 -o bthci src/bthci.c`,
   install to `/usr/local/sbin/bthci`.
3. **`bt-venue.service`** - runs `bthci` at boot (after loading `hci_uart` and waiting for
   `/dev/ttyS4`); `bluetoothd` then auto-enables the adapter. `systemctl enable --now
   bt-venue.service`.

`BLUETOOTH.md` tells the full story (why it looked dead for so long, every theory that got
ruled out, and the anticlimactic baud-rate reveal).

### Battery: spurious 0% warning on AC transition

On every AC plug/unplug the tablet's ACPI firmware returns an all-zero `_BST` (voltage /
charge / capacity all 0, status "Not charging") for ~1.5 s. UPower reports that momentary
reading as 0%, so Plasma fires a false "battery critical" warning twice per plug cycle. It is
cosmetic (no suspend, since `AllowRiskyCriticalPowerAction=false`), but annoying, and no
UPower policy suppresses it (a discharging battery at 0 energy is 0%, whatever the policy).

Fix: a small kernel module (`batfix`) puts a kretprobe on the exported
`power_supply_get_property()` and, for the `BATC` battery, substitutes the last good value
whenever a sanitized property (voltage, charge, energy, capacity) returns a transient 0 that
would be a physically impossible instant drop. A genuinely draining battery ramps down
gradually, so real low-battery warnings still work; only the impossible 71% -> 0% jump is
masked. It uses no fixed struct offsets (the layout comes from the kernel header), so it
recompiles cleanly, but it is out-of-tree and must be rebuilt after a kernel upgrade -
`etc/pacman.d/hooks/venue-batfix.hook` does that automatically via `venue-batfix-build.sh`.

```
sudo pacman -S --needed linux-headers          # required to build the module
sudo mkdir -p /usr/local/src/venue-batfix
sudo cp usr/local/src/venue-batfix/{batfix.c,Makefile} /usr/local/src/venue-batfix/
sudo cp usr/local/sbin/venue-batfix-build.sh /usr/local/sbin/ && sudo chmod +x /usr/local/sbin/venue-batfix-build.sh
sudo cp etc/pacman.d/hooks/venue-batfix.hook /etc/pacman.d/hooks/
sudo cp etc/modules-load.d/venue-batfix.conf /etc/modules-load.d/
sudo /usr/local/sbin/venue-batfix-build.sh    # build + install into the kernel tree
sudo modprobe batfix                          # load now (also loads at boot)
```

The module is GPL-2.0 (a kprobe module must be); everything else in the repo is BSD 3-Clause.
See `LICENSE.md`.
