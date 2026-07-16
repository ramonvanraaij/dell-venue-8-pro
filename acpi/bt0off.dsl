/*
 * bt0off.dsl - SSDT overlay that disables \_SB.URT1.BTH0 (the DLAC3002 / AR3002
 * Bluetooth serdev child) by giving it an _STA that returns 0. With BTH0 absent,
 * the HS-UART \_SB.URT1 (80860F0A:00) no longer has an ACPI serdev child, so the
 * 8250 core registers it as a real tty (/dev/ttyS4) - which the bthci bring-up
 * tool needs (it drives the port directly at 3686400 baud). Loaded as an early
 * initrd ACPI table upgrade.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 * License: BSD-3-Clause
 *
 * Build + install:
 *   iasl -tc bt0off.dsl                       # -> bt0off.aml
 *   mkdir -p kernel/firmware/acpi
 *   cp bt0off.aml kernel/firmware/acpi/
 *   find kernel | cpio -H newc --create > /boot/acpi_override.img
 * Then add an early initrd line to the systemd-boot entry, BEFORE the main
 * initramfs (order matters - ACPI overrides are read from the first initrd):
 *   initrd  /acpi_override.img
 *   initrd  /initramfs-linux.img
 *
 * Reversible: remove the "initrd /acpi_override.img" line from the loader entry
 * (this returns BTH0 to a serdev and removes /dev/ttyS4).
 */
DefinitionBlock ("", "SSDT", 2, "BT0OVR", "BT0OFF", 0x00000001)
{
    External (\_SB.URT1.BTH0, DeviceObj)
    Scope (\_SB.URT1.BTH0)
    {
        Method (_STA, 0, NotSerialized)
        {
            Return (Zero)
        }
    }
}
