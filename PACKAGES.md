# Installed packages (Dell Venue 8 Pro 5830)

A record of the packages explicitly installed on this tablet, plus the notable ones that
were installed and later removed. Reconstructed from `pacman -Qe` / `pacman -Qm`, the
`/var/log/pacman.log` install and removal history, and the `ramon` and `root` shell
histories.

- Base install: 2024-10-06, via `archinstall`
  (`base base-devel linux linux-firmware btrfs-progs intel-ucode`).
- Extra repositories enabled: **chaotic-aur** (`chaotic-keyring`, `chaotic-mirrorlist`)
  and **archlinuxcn** (`archlinuxcn-keyring`); AUR builds via **yay**.

## Explicitly installed (`pacman -Qe`), grouped by purpose

Packages marked `(AUR)` come from the AUR / archlinuxcn rather than the official repos.

### Kernel, firmware, boot
`linux` `linux-headers` `linux-firmware` `intel-ucode` `sof-firmware`
`btrfs-progs` `efibootmgr` `breeze-plymouth` `plymouth-kcm`
`dell-venue-8-pro-5830-wifi-firmware` (AUR)

### Login / session
`sddm` `sddm-kcm` `archlinux-themes-sddm` (AUR) `pam_autologin` (AUR) `kwallet-pam`
`ksshaskpass`

### Plasma Mobile shell + KDE
`plasma-mobile` `plasma-mobile-debug` (AUR) `plasma-desktop` `kde-system-meta` `discover`
`layer-shell-qt5` (AUR) `spectacle` `systemsettings` `kinfocenter` `kdeconnect`
`kscreen` `kde-gtk-config` `kdeplasma-addons` `kgamma` `kmenuedit` `krdp`
`kwalletmanager` `kwrited` `plasma-browser-integration` `plasma-disks` `plasma-firewall`
`plasma-sdk` `plasma-systemmonitor` `plasma-vault` `plasma-welcome`
`plasma-workspace-wallpapers` `polkit-kde-agent` `print-manager` `drkonqi` `breeze-gtk`
`oxygen` `oxygen-sounds` `qt5-quickcontrols` `qt5-wayland` `qt6-wayland`

The on-screen keyboard is Plasma's own (`org.kde.plasma.keyboard`, Qt Virtual Keyboard),
which ships with `plasma-mobile`; the AUR `maliit-keyboard` it replaced has been removed.

### Audio (PipeWire)
`pipewire` `pipewire-alsa` `pipewire-jack` `pipewire-pulse` `wireplumber` `libpulse`
`gst-plugin-pipewire` `alsa-utils`

### Networking + Bluetooth
`networkmanager` `iw` `wireless-regdb` `bluez` `bluez-utils`
`bluez-deprecated-tools` `bluedevil`

### Tablet hardware / power
`iio-sensor-proxy` (auto-rotation) `wacomtablet` (touch/stylus) `libgpiod` `acpi` `acpica`
`powertop` `thermald` `power-profiles-daemon` `usbutils` `zram-generator`

### Browsers / applications
`vivaldi` `google-chrome` `octopi` (chaotic-aur, pacman GUI) `flatpak` `flatpak-kcm` `qmlkonsole`
`gvim` `nano` `ex-vi-compat`

### Shell / CLI tools
`fish` `tmux` `git` `chezmoi` `fastfetch` `bashtop` `openssh` `wget`

### Repository keyrings / AUR helper
`chaotic-keyring` `chaotic-mirrorlist` `archlinuxcn-keyring` `yay` `yay-debug`

## AUR / foreign packages (`pacman -Qm`)

`accounts-qml-module` `archlinux-themes-sddm` `archlinuxcn-keyring`
`dell-venue-8-pro-5830-wifi-firmware` `layer-shell-qt5` `openssl-1.1-debug`
`pam_autologin` `plasma-mobile-debug` `yay-debug`

## Installed then removed (experiments / replaced)

- **`maliit-keyboard` + `maliit-framework` + `presage`** - the Maliit on-screen keyboard;
  replaced by Plasma's own `org.kde.plasma.keyboard` (ships with `plasma-mobile`).
- **`iwd` + `impala`** - iwd and its TUI; removed in favour of NetworkManager's default
  (wpa_supplicant) backend. (`networkmanager-iwd`, the NM iwd backend, was removed earlier.)
- **`plasma-thunderbolt`** - no Thunderbolt on this tablet.
- **`go`** - build toolchain no longer needed.
- **`dkms`** - not used; the one out-of-tree module (`batfix`, the battery-gauge fix) is
  rebuilt by a pacman hook rather than DKMS, and the Bluetooth bring-up uses only stable
  userspace ABIs (no kernel module - see `BLUETOOTH.md`).
- **`screen`** - `tmux` is used instead.
- **`mpv`** and its codec cascade - removed with the Jellyfin cleanup.
- **`jellyfin-desktop-git` + `cef` + `sdl2`** - the CEF/Chromium Jellyfin client. Touch
  input did not work on Plasma Mobile Wayland (upstream bug); it had been replaced by a
  Vivaldi web-app launcher, since dropped too.
- **`pulseaudio` + `pavucontrol`** - replaced by PipeWire (`pipewire-pulse`).
- **`konsole`** - replaced by `qmlkonsole` (the mobile-friendly terminal).
- **`atheros-ar3012`** - an early Bluetooth firmware attempt for the AR3002. The internal
  Bluetooth now works (the ROM just needed 3686400 baud - see `BLUETOOTH.md`); no extra
  firmware package is required.
- **`freerdp2`** - removed.
- **`vi`** - replaced by `ex-vi-compat` / `gvim`.

Dependency-only churn pulled in and then removed with the above (`cairomm`, `glibmm`,
`gtkmm-4.0`, `pangomm`, `libsigc++`, `kdsoap-qt6`, `libnm`, `alpm_octopi_utils`, ...) is
omitted.
