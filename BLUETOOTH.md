# *** SOLVED (2026-07-02): the wall was the BAUD RATE - the ROM runs at 3686400 ***

After everything below, the internal AR3002 Bluetooth turned out to work fine. The single
reason it looked "powered but mute" across the whole investigation is that its boot ROM
communicates at **3686400 baud**, not the 115200 the Windows INF advertises as
`DefaultBaudRate`. Every probe here used 115200, or a baud sweep that stopped at 2764800
(the `ttyS4` `base_baud`), so 3.6864 Mbaud was never once tried.

Set the host UART to 3686400 (8N1 + hardware flow control, pin52 power HIGH) and the chip
answers immediately and reproducibly:
```
FC0C set-baud   -> 04 0e 04 01 0c fc 00                          (Command_Complete, status 0)
GET_VERSION     -> 04 0e 12 01 1e fc 00 01 02 02 01 32 ...       (ROM version 0x01020201)
Read_Local_Ver  -> 04 0e 0c 01 01 10 00 06 02 01 06 45 00 01 00  (HCI 4.0)
```
The ROM is fully HCI-capable on its own (valid BD_ADDR `88:12:4E:84:25:4D`, complete feature
set, classic + LE scan and pairing verified) - no rampatch/NVM firmware download is needed.
`hciattach`/`btattach` cannot drive it because 3686400 is not a POSIX termios baud constant;
only `termios2`/`BOTHER` can set it (which is why those tools time out).

Everything below - the "chip is mute/dead" conclusion, the BT_VDD core-rail theory, the PMIC
LDO hunt, the "out-of-band only / need a dongle" terminal - was WRONG. The chip was alive the
whole time; it was being addressed at the wrong baud. Two side-theories from this session were
also cleanly falsified along the way: hardware flow control was never the blocker (CTS is
asserted, bytes were delivered), and the pin52 "glitch" that first surfaced a reply was a red
herring (direct-to-3686400 works with no glitch). The confirmed CTS-tracks-power observation
(CTS drops when pin52 is driven low, returns when high) shows the RTS/CTS wiring reaches the
chip; combined with the baud fix it all lines up.

**Working, persistent bring-up** (see the repo): `bt0off` SSDT override -> `/dev/ttyS4`;
`bthci` (`src/bthci.c`) powers the chip via `gpiochip0` lines 52/53, sets 3686400 +
CRTSCTS via `termios2`, and attaches the `N_HCI` H4 line discipline -> `hci0`;
`bt-venue.service` runs it at boot. No custom kernel module (stable ABIs only), survives
kernel upgrades. README "Bluetooth" section has the details.

The original reverse-engineering trail is kept below for the record.

---

# qcbtuart.sys v2.2.0.24 RE - DLAC3002/AR3002 cold-start GPIO sequence

The binary is winre/qcbt/QualComm/FORCED/10x86/UART_2.2.0.24/qcbtuart.sys, a PE32 i386 KMDF driver. I reverse-engineered it with radare2 6.1.8 plus r2ghidra (pdg). The driver obtains its device context via (**0x41fc78)(*0x41f038). It keeps the GPIO target handles in that device context: ctx+0x10 is the power-down GPIO (pin 0x34=52) and ctx+0x14 is the wake GPIO (pin 0x35=53), while the UART/serial target lives at ctx+8. GPIO writes send a 1-byte value through IOCTL 0x480004, using WdfIoTargetFormatRequestForIoctl followed by WdfRequestSend.

## Decisive polarity (decompiler-proven)

1. The power-down GPIO is pin 52, driven by fcn.00403e5c(arg_8h, value, timeout). It reads `iVar2 = *(ctx + 0x10)`, the power-down GPIO handle, and writes pin = `(value != 0)` as one byte via IOCTL 0x480004 (write site 0x403f29). It is called with value 1 at cold-start, from PrepareHardware (0x407222) and the firmware-init fcn.00406a6e; value 0 only appears in a later teardown/RtD2 path (PrepareHardware ~0x4076xx). So powering on means driving the power-down GPIO (pin 52) high (1). The timeout argument is -1500000, which is 150 ms.

2. The wake GPIO is pin 53, driven by fcn.00404152, "DeviceWakeupTargetByGPIO". It reads `iVar2 = *(ctx + 0x14)`, the wake GPIO handle, writes pin = 0 (IOCTL 0x480004, site 0x404221), then calls KeDelayExecutionThread(-50000), which is 5 ms, then writes pin = 1 (IOCTL 0x480004, site 0x40435a). So waking pulses the pin low (0) for 5 ms, then high (1), ending high on a rising edge.

## COLD-START SEQUENCE (PrepareHardware 0x407222 + firmware-init 0x406a6e)
- PrepareHardware opens the serial (UART) and powers it on, opens the power-down GPIO target (ctx+0x10) and starts it, then opens the wake GPIO target (ctx+0x14) and starts it. It calls fcn.00403e5c(...,1,...) to drive the PD GPIO high, then fcn.00404152() to issue a wake pulse of 0->(5ms)->1.
- firmware-init/D0 (fcn.00406a6e) starts both GPIO targets again. On Win8.1 (fcn.00415b5a returns 0x6030000), if the PD GPIO is present and ctx+5==1, it calls fcn.00403e5c(...,1,...) once to drive the PD GPIO high. It then calls fcn.00404120(), which is SoC_INIT and performs the PS+rampatch download, logging "Soc sleep mode disabled, Initializing firmware now..." (0x419aa0).

## Extra power / RTS

There is no I2C, PMIC, or SMBus write in the cold-start power path; the I2C traffic is LTE-coex, and LTECoexEnabled=0. For RTS, ExplicitRtsWakeup=1 for DLAC, and RTS is handled separately on the serial target (ctx+8). The boot baud rate is 115200 and the operating rate is 3686400, with hardware flow control (RTS/CTS).

## Why my Linux attempts failed (both polarities inverted)
- I drove pin 52 low (0x04) believing low meant power-on. Windows drives it high (1) for power-on, so I was actually powering the chip off. The firmware default is 0x01, which is high and on, but my tests forced it low.
- I pulsed pin 53 high to low (a falling edge). Windows pulses it low to high, ending high.

## Corrected Linux test

1. Drive pin52 (PD) high and hold it there. The firmware default is 0x01; if it has been driven low, restore it to high. Note the pad quirk that it can't drive high via 0x05, so use 0x01 or release it to the pull-up with 0x02, and verify the readback.
2. Let it settle for about 150 ms.
3. For pin53 (wake), drive it low (0x04), wait 5 ms, then set it high by releasing to the pull-up (0x02), so it ends high.
4. Open /dev/ttyS4 at 115200 8N1 with CRTSCTS on and RTS asserted. I expect CTS to assert, followed by a GET_VERSION (ath3k 0xFC1E) response. If CTS is still 0, the pad genuinely can't hold pin52 high from Linux, which is a hardware wall; rebooting first restores pin52 to firmware-high.

## Hardware test results (tablet, ttyS4 freed, padmmio raw-MMIO GPIO writes)

What worked: the polarity fix took the chip from dead to alive, the first time on Linux.

I can drive pin52 (PD) and pin53 (wake) high via VAL=0x01 (output-en + input-en + level1), with readback level=1. The "can't drive high" quirk only affects 0x05 (input disabled, which reads back 0x04). Release-to-pullup 0x02 does not float high (it reads low), so these pads have to be actively driven high with 0x01.

The working sequence (bt-correct3.sh) is: pin52 low (0x04) and pin53 low (0x04) for 100ms (off), then pin52 high (0x01) for the power-on edge, 250ms to settle, pin53 low (0x04) for 6ms, then pin53 high (0x01) for the wake low->high transition, then open ttyS4 at 115200 8N1 CRTSCTS with RTS asserted. That gives CTS=1 reproducibly (raw=0x4026), and tcdrain is OK (TX reaches the wire). The chip is powered and awake.

What did not work (all my earlier attempts were polarity-inverted):
- Driving pin52 low (0x04) leaves the chip powered off. Every prior "dead silence" test was holding the chip powered down.
- pin53 falling edges (high->low) are the wrong wake direction, and pin53 via 0x02 stays low.
- Static both-high without a pin52 low->high power-on edge did not reliably assert CTS; the clean power-cycle edge is required.
- RTS-toggle wake plus IBS WAKE_IND 0xFD (CRTSCTS off) had no effect. That was done while the chip was powered off, so it is invalid and superseded.

Still open, the chip is awake but mute:
- With CTS=1, ath3k GET_VERSION (01 1E FC 00, x16 via bt-live) gives RX=0. hciattach ath3k 115200 flow reports "Initialization timed out". So power and wake are solved, and the remaining gap is the init handshake - either the wrong first command, or the chip re-sleeps via IBS before replying.
- Next: decompile the Windows SoC_INIT (fcn.00404120, called from fcn.00406a6e post-power-on) for the exact first bytes it sends; also try HCI Reset (01 03 0C 00) and holding the chip awake (re-pulse wake) through the exchange.

## UPDATE 2 - a new wall: the chip is powered and awake but transmits nothing (rx:0)

With the chip powered and awake (I confirmed CTS=1 before each send), I sent EDL 0xFC00 (01 00 FC 01 19), an HCI Reset (01 03 0C 00), an EDL-alt (01 00 FC 01 00), and ath3k 0xFC1E. Every one of them came back with RX=0. hciattach ath3k reported "Initialization timed out". A passive read, sending nothing after a power-cycle, produced no boot banner.

In /proc/tty/driver/serial the ttyS4 tx count climbs (344->349) while rx:0 and fe:0, so there are zero framing errors, which means the RX line is electrically idle. The chip is not transmitting at all. A chip transmitting at the wrong baud rate would accumulate framing errors, and none appear, so no baud sweep can help here.

The earlier kernel-serdev hci_qca_dell attempt also got rx:0, but that was with the chip unpowered; now I have rx:0 confirmed even with the chip powered. So power and wake are solved, but the chip stays mute.

On the Windows side, the protocol is SoC_INIT = fcn.00404120 -> fcn.00404488, with the transaction primitive fcn.004097aa reading SoC "memory"/regs at 0x1b00xx. It is WDF-abstracted through a KMDF function table, so the literal on-wire bytes are not extractable from the static decompile. The driver uses QCA EDL (0xFC00), not ath3k.

I have three hypotheses for why it is powered but mute:

(a) The chip CPU is not running: it is powered but needs a RESET or clock release to start the firmware (CTS=1 may just be a powered-pin default rather than a running-firmware signal). Windows resets (fcn.0040cc82 / "ResetFirmware") before SoC_INIT, and I have not yet replicated that on Linux.

(b) The host RX (URT1 RXD) is not muxed on Linux. But BT worked under Windows on this unit, so the line is wired; this is less likely. It is unverified, since I have no loopback available.

(c) The exact EDL framing/sequence is not yet replicated.

Next options: replicate the reset step; resolve the KMDF function table to get the literal bytes (or trace it live); or put a logic analyzer on the UART to capture Windows' actual first bytes.

## UPDATE 3 - reset/init path is UART-IOCTL plumbing; chip command bytes are dynamic (static RE wall)

Correction: the 0x1b00xx values are not chip addresses. 0x1b is FILE_DEVICE_SERIAL_PORT, so they are standard serial-control IOCTLs (for example 0x1b0044 = IOCTL_SERIAL_GET_WAIT_MASK and 0x1b0048 = WAIT_ON_MASK, plus baud and RTS). fcn.004097aa is just a generic "do a UART IOCTL" helper.

fcn.0040cc82, which runs pre-init, is GET_WAIT_MASK followed by KeSetEvent/KeWaitForSingleObject: it arms the async serial-event wait and sets up the read notification. It is not a chip reset.

So the chip is spoken to over normal HCI-style UART read/write, and the actual vendor init/version command bytes are built in dynamically-allocated buffers and sent via the KMDF read/write path (the WdfFunctions table), which means they are not recoverable from the static decompile.

Where things stand: the chip is powered and awake (CTS=1) but answers none of EDL 0xFC00, ath3k 0xFC1E, or HCI Reset, and it emits no boot banner; rx:0/fe:0, so the RX line is idle. Static RE has hit the KMDF wall, and the literal first-command bytes cannot be pulled out statically.

The remaining paths are all heavier: (a) put a logic analyzer on the UART during a Windows cold boot to capture the exact first bytes, which would be definitive; (b) do a dynamic trace of the driver; (c) resolve the full WdfFunctions table plus the buffer construction. The cheap static and empirical avenues are exhausted.

One thing is still untested and worth a cheap check next time: confirm that ttyS4 RX actually works at all via an 8250 internal loopback (the MCR LOOP bit), which would rule a Linux RX-mux problem in or out versus the chip being mute.

## Revert to stock BT behavior

The only persistent Bluetooth change I made is the ACPI override initrd in the systemd-boot entry, which disables BTH0 and so frees /dev/ttyS4. To revert:
  sudo cp /boot/loader/entries/2024-10-06_18-45-45_linux.conf.bak-btoverride \
          /boot/loader/entries/2024-10-06_18-45-45_linux.conf      # restore stock (no override)
  sudo reboot
Alternatively, just delete the `initrd /acpi_override.img` line from that entry. After the reboot BTH0 is re-enabled and URT1 is owned by serdev again (no ttyS4), which is the stock state. /boot/acpi_override.img and the local helper scripts are harmless to leave in place. The pad states reset every reboot, and nothing else persists. The WiFi fixes are separate, so keep them.

## Continuation / next steps (to finish the bring-up)

I have proven the chip is powerable and awake on Linux (bt-correct3.sh produces CTS=1). The only missing piece is the chip's exact ROM init/version command and its response, which static RE cannot yield. I can get it in one of three ways:

1. Preferred (software, on Windows): enable the driver's own logging and capture the BT init traffic. Under the qcbtuart service key (HKLM\SYSTEM\CurrentControlSet\Services\<qcbtuart>\Parameters) set HCIDumpEnabled=1, BtLogEnabled=1, and RamPatchDumpEnabled=1, then capture the WPP trace (TraceView/DebugView) during BT bring-up. That shows the version read plus the commands and the AthrBT/ramps download. (The PDB path in the binary is C:\Perforce\...\qcbtuart.pdb.)
2. Logic analyzer on URT1 TX+RX (and pins 52/53) during a Windows cold boot, 115200 8N1 - capture the first few hundred bytes after power-on. This is definitive.
3. Dynamic driver trace (heavier).

Then I replicate it on Linux: bt-correct3.sh powers and wakes the chip, so I send that exact first command on ttyS4 (CRTSCTS, 115200) and then proceed through the ar3k/QCA firmware (AthrBT_0x01020201.dfu + ramps_0x01020201_26.* are already in /lib/firmware/ar3k/). My workstation RE environment is radare2+r2ghidra via brew, with the binary at winre/qcbt/QualComm/FORCED/10x86/UART_2.2.0.24/qcbtuart.sys.

## UPDATE 4 (2026-06-26 cont.) - Root cause: the UART pins were never muxed, and "CTS=1=alive" was a floating pad
There is no Windows on the tablet anymore, so the "capture from Windows" plans (the HCIDumpEnabled trace and the logic-analyzer-during-Windows-boot idea) are off the table. The good news is that the real blocker turned out to be on the Linux side and needs no Windows at all. I re-probed the freed-ttyS4 bench and found the following.

1. Clock mismatch (a real bug, but not the whole story). ttyS4 (URT1) reports uartclk=1843200, while the identical HSUART ttyS5 (80860F0A:01) reports 44236800, exactly 24x higher. The generic-16550A bind gave ttyS4 the default 1.8432 MHz clock, so every requested baud ran 24x too fast on the wire. The workaround without setserial is to request baud 4800, which gives divisor 24 and a real 115200; the permanent fix would be `setserial /dev/ttyS4 baud_base 2764800` (which is 44236800/16) [setserial is not installed], or getting 8250_dw to bind URT1. Even at a corrected real 115200 I still got rx:0, so the clock is necessary but not sufficient. (Note: operating baud 3686400 has no integer divisor off 44.2368 MHz, so the generic 16550A cannot reach it; 8250_dw plus DLF is the real endgame for high baud.)

2. The RX path works (the apparatus is exonerated). Using the 8250 internal loopback via TIOCM_LOOP (btloop.elf), I wrote 01 02 04 08 10 20 40 80 and read all 8 back, so this passes; the loopback was confirmed engaged (CTS mirrored RTS, DSR mirrored DTR). That means the rx:0 from the chip is real, not a driver or read-code bug.

3. Correction - "CTS=1 = chip alive" was wrong (this supersedes UPDATE 2/3 and the bt-correct3 framing). With loopback off, CTS stayed stuck high regardless of RTS, which means that CTS=1 was an unmuxed pad floating high, not the chip driving flow control. So "powered+awake (CTS=1)/alive-but-mute" was an artifact, and the tcdrain "OK" only drained the controller FIFO into a disconnected pad.

Root cause: /sys/kernel/debug/pinctrl/INT33FC:00/pinmux-pins shows URT1's four UART pads - pin 70 SIO_UART1_RXD, 71 TXD, 72 RTS, 73 CTS - all as "(MUX UNCLAIMED)". They were never muxed to the uart function. (UART2 pins 74-77 are also unclaimed, since they are unused.) The generic-16550A enumeration that appears when BTH0 is disabled does not apply the pinctrl "uart" state, so my TX never left the SoC and the chip's TX never reached the controller. This, not a dead or mute chip, is why every freed-ttyS4 test got rx:0/fe:0.

Reframing this: there are two independent bugs, and no prior attempt had both fixed at once. (a) GPIO power polarity (chip off), which I fixed this session via qcbtuart RE. (b) UART pads unmuxed on the freed-ttyS4 path, which I found now. The serdev/hci_qca attempts likely muxed the pads (the driver applies pinctrl) but had the chip off (bug a); this session powered the chip but drove it over unmuxed pads (bug b).

Fix under test: mux pins 70-73 via debugfs -
   echo "uart1_grp uart" > /sys/kernel/debug/pinctrl/INT33FC:00/pinmux-select   (or "uart uart1_grp")
then power+wake (bt-correct3 polarity) and probe at real 115200 (btclk req4800). [Result: pending] The permanent options if it works are a pinctrl-state consumer or a kernel quirk, or reverting to the serdev/hci_qca path now that the GPIO polarity is known (serdev muxes the pads; add the correct power-on).

New tools: btclk.elf/btclk.c (a baud-parametric probe: dev reqbaud cmdhex readms), btloop.elf/btloop.c (TIOCM_LOOP loopback), bt-clktest.sh, bt-looptest.sh, bt-pinmux.sh, bt-muxset.sh. (req4800 gives real 115200; req115200 gives real 2764800.)

## UPDATE 5 (2026-06-26) - Correction: the UART pads were muxed all along; "unmuxed" (UPDATE 4) is withdrawn
I verified the actual hardware mux of pins 70-73 three ways: /sys/kernel/debug/gpio (live mux:N + offset), gpio-ranges (gpiochip0 line == pinctrl pin, 1:1), and the kernel source pinctrl-baytrail.c.
  gpio-70 SIO_UART1_RXD pad-2 offset:0x020 mux:1 (up 20k, reads lo)
  gpio-71 SIO_UART1_TXD pad-1 offset:0x010 mux:1 (up 20k, reads lo)
  gpio-72 SIO_UART1_RTS pad-0 offset:0x000 mux:1 (up 20k)
  gpio-73 SIO_UART1_CTS pad-4 offset:0x040 mux:1 (NO pull, reads hi)
In pinctrl-baytrail.c, PIN_GROUP_GPIO("uart1_grp", byt_score_uart1_pins, 1) means the UART function is mux 1, while GPIO = BYT_DEFAULT_GPIO_MUX = 0. So mux:1 is UART, which means the pads are muxed to UART - the firmware set it at boot. The "(MUX UNCLAIMED)" I saw in pinmux-pins only means there is no Linux owner, not a wrong hardware mux. My debugfs pinmux-select writes were no-ops (the pad-register diff showed nothing changed), but that is irrelevant since the pads were already correct. So UPDATE 4's claim that "pins unmuxed = root cause" is withdrawn.

This also re-corrects UPDATE 4 pt 3: CTS=high is the chip. Pin 73 (CTS) has no internal pull yet reads high, so it is actively driven high by the chip's RTS-out, which means the chip's UART/flow-control block is powered and alive. The loopback [4] result "CTS stuck high regardless of my RTS" was the chip driving it, not a float. So I am back to alive-but-mute (UPDATE 2/3), but now with the apparatus fully de-risked: the RX path works (loopback echo passed), the pads are muxed (source-confirmed), and the chip drives CTS-ready.

Clean net state: the chip is powered, UART-connected, drives CTS-ready, and my RX path is proven good, yet it answers nothing to GET_VERSION (0xFC1E) / EDL (0xFC00) / HCI-Reset at real-115200 (req4800) or at the wrong baud, and it emits no boot banner. Two residual unknowns remain. (i) Absolute baud: ttyS4's uartclk is the generic 1843200; req4800 assumes the true clock is ttyS5's 44236800 (giving a real 115200), but with the chip mute I cannot confirm the wire baud end-to-end. (ii) Firmware not started: only the UART block may be alive (it drives CTS), while the main CPU may need the vendor SoC_INIT/reset to boot the HCI stack (static RE can't fully yield it, and there is no Windows on the tablet to capture from).

Candidate next steps: (a) give ttyS4 the real 44236800 clock properly (8250_dw bind or install setserial + baud_base 2764800) and retry at a true 115200, which removes the baud uncertainty; (b) hold or re-pulse the wake GPIO + RTS attention through the exchange (ExplicitRtsWakeup / IBS); (c) allow a longer post-power-on settle before probing; (d) revisit the serdev/hci_uart path now that the GPIO polarity is known, so one driver owns clock+mux+power+protocol coherently. Pad CONF0 offsets (base 0xFED0C000): RTS=0x000 TXD=0x010 RXD=0x020 CTS=0x040 (VAL=+0x08); BT GPIOs pin52 CONF0=0x580/VAL=0x588, pin53 CONF0=0x5c0/VAL=0x5c8.

## UPDATE 6 (2026-06-26) - Correction: baud was never wrong; the "24x clock mismatch" (UPDATE 4 pt1) is withdrawn
I used TX-drain timing as ground truth (btdrain.elf: write N bytes, call tcdrain, time it, then real_baud = N*10/sec). Requesting 4800 took 13.4s for 5760B, a real rate of about 4300 (roughly 4800); requesting 115200 took 0.56s for 5760B, about 103000 real (roughly 115200); requesting 9600 took 6.7s for 5760B, about 8600 real (roughly 9600). So the requested baud equals the real wire baud on ttyS4. Requesting 115200 already gives a true 115200, and the req4800 "trick" was wrong, since it produced a real 4800. The uartclk sysfs reads (1843200, then 76800 after a reboot - inconsistent) are unreliable artifacts; ttyS4 is an 8250_dw/LPSS port that uses the clk framework plus a fractional divider to hit the requested baud exactly. UPDATE 4 pt1's "clock 24x too fast" is withdrawn - baud was never the problem. The chip got a correct 115200 in the original bt-correct3 / clktest[E] runs and was still mute. No setserial is needed; I use 115200 directly, not req4800.

All measurement unknowns are now closed: the pads are muxed (mux:1=uart), the RX path works (loopback echo), the chip drives CTS (alive), and the baud is correct (115200=real). At a confirmed-correct 115200 with correct RE power/wake, the chip answers nothing - no response to GET_VERSION 0xFC1E, EDL 0xFC00, or HCI-Reset, and no boot banner. This is the genuine alive-but-mute ceiling. Next I will try an hciattach ath3k full handshake at 115200 with RE power/wake, which I have never done under correct power (the old hciattach "Initialization timed out" was at the old wrong GPIO polarity, meaning the chip was off, so it is void). After that come wake-hold / RTS-IBS variants. If it is still silent, the real ceiling is the ROM init bytes (no Windows on the tablet; static RE exhausted), which leaves dynamic RE or a USB dongle (TP-Link UB400).

## UPDATE 7 (2026-06-26) - Ceiling confirmed: the Linux UART side is fully validated, but the chip firmware/CPU won't boot

I ran the final sweeps at the correct power (RE GPIO pin52 HIGH) and baud (115200 is the real rate). In every case rx stayed at 0 with CTS solid high (0x4026):
 - Cold-on plus wake plus a 3s settle plus a passive 3s listen produced no boot banner.
 - GET_VERSION 0xFC1E, HCI-Reset, and EDL 0xFC00 all got no reply. A full hciattach ath3k handshake ended in "Initialization timed out", even though the firmware was decompressed and present.
 - IBS/RTS wake (RTS pulse plus WAKE_IND 0xFD, CRTSCTS off, 6 cycles) never returned a WAKE_ACK 0xFC.
 - The GPIO sequence and timing variants (pin53 held LOW through the pin52 power-on then released; both-high-from-cold with a 1s settle; a pin52 power-glitch off-1s-on; a 2s discharge) all gave rx:0.
 - On the regulator side, Linux exposes only regulator-dummy and spi1.0-vcc; the Crystal Cove PMIC is present but registers no named BT rail, and ACPI gives BT only gpiochip0 pin52/53 (both driven). There is no disabled core rail left to flip.

So every Linux-side unknown is now closed: the baud is correct (115200 is real), the pads are muxed (mux:1=uart), the RX path works (loopback), and the chip is powered and drives CTS, which means its I/O block is alive, with no extra rail or GPIO to find. Despite all of that the chip still emits nothing. That means the AR3002's HCI/ROM CPU is not running and only its always-on UART/flow block is. The trigger to boot the firmware is the Windows cold-start init that I cannot reproduce (static RE does not recover the dynamic KMDF buffers), and there is no Windows on the tablet to trace or logic-analyze, so the old "capture from Windows" plan is dead. This is the genuine ceiling, and more probing of the same class won't move it.

Realistic options: (a) a USB BT dongle such as the TP-Link UB400, which gives instant btusb and is the pragmatic fix; (b) heavy out-of-band RE - a dynamic trace of qcbtuart.sys in an emulated or instrumented Windows, or a logic analyzer on URT1 TX/RX while the tablet boots Windows-To-Go from USB to capture the literal init bytes; or (c) shelve internal BT and keep the substantial findings.

The durable wins: the RE-corrected GPIO polarity powers the chip for the first time ever on Linux (CTS driven), loopback proves the RX path, the pads are confirmed muxed, and the baud is confirmed correct, so the entire Linux UART plumbing is functional. The wall is purely chip-internal firmware boot, not Linux. Tools added this session: btclk.elf, btloop.elf, btdrain.elf, bt-clktest.sh, bt-looptest.sh, bt-pinmux/muxread/muxapply/muxdiag.sh, bt-drain.sh, bt-hciattach.sh, bt-finalsweep.sh, bt-regcheck.sh, bt-resetorder.sh.

## UPDATE 8 (2026-06-26) - New avenues explored, all negative; the community confirms "Nope"
- Platform clock (the clk_ignore_unused idea): all 6 Bay Trail pmc_plt_clk were gated off (en=0; clk_0/1 at 19.2MHz with no device attached, clk_3 at 19.2MHz feeding the rt5640 audio, clk_2/4/5 at 25MHz). I force-enabled all of them via a clk_prepare_enable module (clken.ko stays loaded), then power-cycled the chip with the clocks present, and GET_VERSION still returned rx:0. That kills the clock hypothesis, and it is consistent with the chip's crystal being 26/40MHz per the ramps firmware, since no plt_clk matches either of those.
- Deeper reverse engineering: I confirmed that I already replicate the Windows cold-start. IOCTL 0x480004 decodes as IOCTL_GPIO_WRITE_PINS (CTL_CODE FILE_DEVICE_GPIO=0x48, fn1, METHOD_BUFFERED), so the power-down GPIO write with byte=1, meaning pin HIGH and therefore power-on, is correct - it matches CTS empirically. There is a 150ms post-GPIO delay, RTS goes through a serial IOCTL (I use CRTSCTS), and there is no I2C, PMIC, or clock-enable step anywhere in the driver's cold-start path. The literal init and version bytes are still assembled in dynamic KMDF buffers, so they cannot be extracted statically; the SoC_INIT (0x404488) is what does the version-read and the PS/rampatch download.
- Community and cross-OS check: studioteabag's writeup, the definitive Linux reference for this tablet, concludes "Bluetooth, Nope" - the UART shows up in the device tree but never initializes (kernel bug #73081), and its author gave up and switched to a TP-Link UB400 USB dongle. The NXP AR3002 hciattach-ath3k thread is unresolved and turns out to be an rfkill issue, not mine. Nobody has publicly brought up the internal UART Bluetooth on this chip under Linux, so I had already gone further than any of them.

Firm conclusion: every software and electrical avenue visible from Linux is exhausted. The chip is powered, UART-connected, and drives CTS, but its firmware/ROM CPU does not boot; the trigger is the Windows driver's dynamic init, which is neither statically extractable nor capturable live (there is no Windows on the tablet). The only routes to internal BT now are: (1) boot Windows-To-Go from USB and capture qcbtuart's init, either through the driver's HCIDumpEnabled WPP trace or a logic analyzer on URT1 TX/RX, then replicate the exact first bytes on Linux (the chip is already powerable and awake via the RE sequence); (2) a USB dongle, which is the pragmatic option and gives instant btusb. The Linux UART plumbing is fully solved and reusable the moment the init bytes are known. New tools this update: clken.c/clken.ko and bt-clktest2.sh.

## UPDATE 9 (2026-06-26) - DSDT clean, host-wake IRQ silent, so the chip CPU is not executing (only the I/O block is alive)
I kept going, without Windows To Go and without a dongle, and worked through the remaining Linux-side avenues.
- DSDT (acpidump+iasl): BTH0 (DLAC3002) declares only UartSerialBusV2(0x1C200=115200) plus Interrupt 0x46 (GSI70 Edge/ActiveLow = host-wake) and 2 GpioIo (pin52 power-down, pin53 wake; PullUp, OutputOnly). There is no _PR0/_PS0/_DSD/ClockInput/power-resource. (The sibling BTH1 for board BDID==0x03 adds GPIO pin0x93=147 input-only as host-wake-as-GPIO, but that is not my board.) So there is definitively no hidden clock, power, or reset; only the 2 GPIOs and the host-wake IRQ.
- UART-open-first ordering: I held ttyS4 open with RTS asserted through power-on, watching CTS rise 0->1 live, and still got rx:0. Ordering isn't it.
- Host-wake IRQ: a raw request_irq(70) returns -EINVAL (the GSI is unmapped until a driver claims BTH0), so I mapped it via acpi_register_gsi, giving gsi70=virq152 (IO-APIC 70-edge). Power-cycling and poking with GET_VERSION while watching gave a total of 0 edges. The chip never asserts host-wake.
Diagnosis: the chip powers up (CTS goes 0->1 live) but shows zero CPU activity - no UART TX (rx:0/fe:0) and no host-wake. Only the always-on UART I/O block runs; the main CPU/ROM does not. Every external cause is now ruled out: baud, mux, RX-path, power polarity, rail, all 6 plt_clks, reset/timing/ordering, ACPI resources, and host-wake. The remaining gap versus Windows is the chip's internal boot: either (i) it needs the exact init the Windows driver sends dynamically (I have no Windows to capture it, and I declined WtG), or (ii) the CPU is held off at the silicon level by a condition my raw-MMIO GPIO drive doesn't satisfy (note that kernel gpiod refuses to output these PCU_SMB pads, so a serdev/gpiod driver would fall back to the same raw MMIO I already use, adding nothing). To be honest, no Linux-only avenue with meaningful odds remains; the only real route into the internal chip is a live Windows init capture. New tools: bt-dsdt.sh, bt-openfirst.sh, btirq.c, btirq2.c, bt-irqtest{,2}.sh.

## UPDATE 10 (2026-06-26) - Lead to validate: the UART data pads look wrong (TXD idles low, should be high)

This is a new angle: is the output masked, is something else using it, or do I need to enable output?

I checked ttyS4 ownership first, and nothing else holds it - no fuser or lsof hits, serial-getty is inactive, rx:0, and /proc shows RTS|CTS|DTR.

Then I read the actual pad levels via padmmio (VAL bit0 = level, chip powered): RTS (pin72, off 0x000) reads HIGH, CTS (pin73, 0x040) HIGH, TXD (pin71, 0x010) LOW, and RXD (pin70, 0x020) LOW. pins 70/71/72 have a 20k pull-up; pin73 has none. The pad VAL offsets are CONF0+8. For CONF0: 70/71/72 = 0x2003cc81, 73 = 0x2003cc01, and 52 = 0x580 / 53 = 0x5c0 = 0x2003c800.

Here is why it matters: a healthy UART TXD must idle high (mark). Mine reads low, against its pull-up, so it is being actively driven low. If that is real, the chip can't frame my bytes - there is no idle-high level to detect a start bit against - which means it looks completely mute to every command, exactly what I see. RXD is also low, so the chip isn't idling high either.

There is a caveat I have to validate first: the port-closed and port-open+RTS reads came back identical, so the GPIO-VAL read may not track the live UART-function pad and could be stale. The validation is the BREAK test (btbreak.c + bt-txdtest.sh, already on the tablet and queued): TIOCCBRK (idle mark) should read TXD HIGH, and TIOCSBRK should read LOW. If the reading flips with break, then the reads are live and TXD-idle-low is real, which means the bug is the UART idle level, almost certainly because URT1 enumerated as a generic 16550A instead of the proper 8250_dw/LPSS driver. The fix path is to make 8250_dw bind URT1 (correct clock plus correct TXD idle/line-driver setup), or otherwise force TXD idle-high. If the reading does not flip, then the pad reads are meaningless in function mode, TXD-idle-low is a non-finding, and I am back to the firmware-boot wall.

Next session, step 1 is to run bt-txdtest.sh (the BREAK test) the moment the tablet is back. Then, if confirmed, pursue 8250_dw binding for URT1. Tools added: btbreak.c, bt-txdtest.sh, bt-pincheck.sh.

Blocker: the tablet WiFi dropped (~32min uptime, the ~37min ath6kl cycle) before bt-txdtest ran, so the session was lost.

## UPDATE 11 (2026-06-26) - Static RE re-sweep: the "dynamic KMDF buffer / unextractable" wall is wrong; literal init bytes recovered

I ran a targeted radare2 re-sweep of qcbtuart.sys, covering five angles: the clock, a possible third GPIO plus reset, the literal bytes, the pre-version step, and the INF flags. There were two outcomes: (A) a hard correction to UPDATE 3/8's claim that the literal bytes are dynamic and statically unextractable, and (B) code-side confirmation of UPDATE 8's negatives. On balance this does not reopen the bring-up - the chip is mute on command #1, so knowing later commands cannot elicit a reply - but the missed cold-start vendor commands are now known.

(A) The literal on-wire bytes are static (this refutes UPDATE 3/8). The HCI/vendor packets are not built in opaque KMDF buffers. The send/recv primitive fcn.00402496 frames a packet in a fixed buffer (device-ctx +0x3cc, plus a global at 0x41f040 for the FC0B download) from literal immediates:
    byte[+0x3cc]=0x01 (HCI cmd type); [+0x3cd..0x3ce]=opcode LE; [+0x3cf]=param-len; [+0x3d0..]=payload;
    on-wire length = paramlen + 4. Then fcn.004097aa is the UART write IOCTL and fcn.0040924a is the UART read (a 3-byte event header 04/evt/len, then len more bytes). All opcodes appear as `push 0xFCxx` / `mov ax,0xFCxx` immediates in the code.
    The vendor opcode set is all literal: FC04, FC05, FC0B (TLV/rampatch download), FC0C, FC16, FC18, FC1E (GET_VERSION), FC31, FC92, FCA0 (sleep-mode), FCA1; plus standard HCI 0x1001 (Read_Local_Version), 0x0C1A, and 0x0C03 (HCI_Reset).
So the prior "must capture from Windows / dynamic-only" premise is false for the command bytes, and the response parsing is static too. This does not by itself fix anything - see (C) - but it removes the "unextractable" blocker.

(B) The cold-start D0Entry order (definitive, taken off the real call graph, not the string layout). FdoDevD0Entry (fcn.00406a6e) runs, in order:
    1. fcn.00403e5c writes the PD GPIO (pin52) high, powering the chip on (matches UPDATE 1/8: byte=1=high=on, via IOCTL_GPIO_WRITE_PINS).
    2. fcn.00404120 (SoC_INIT) calls fcn.00404488, which is host-UART setup only: IOCTL_SERIAL_SET_LINE_CONTROL (0x1b000c), SET_TIMEOUTS (0x1b001c), SET_HANDFLOW (0x1b0064, RTS/CTS), SET_QUEUE_SIZE (0x1b0008), and PURGE RXABORT|RXCLEAR (0x1b004c). These are the 0x1b00xx "FILE_DEVICE_SERIAL_PORT" IOCTLs UPDATE 3 already identified - host port config, not chip.
    3. fcn.00404ec6 does LTR (PCIe, host).
    4. a Windows-version check.
    5. fcn.00404978 pulses the wake GPIO (pin53) from low to high [UPDATE 2].
    6. KeClearEvent x2 (the "call edi").
    7. fcn.004066c0 is FdoDevConfigHighBaudRate. It sends the chip baud command, opcode 0xFC0C (via fcn.00402358, 2 param bytes = the baud code), and sets the host port baud (fcn.00404f4e calls IOCTL_SERIAL_SET_BAUD_RATE 0x1b0004). The call-site log reads "Set high baud rate fail" (0x419a50). So the chip baud command is 01 0C FC 02 <baud-lo> <baud-hi>.
    8. fcn.004022aa is opcode 0xFC04, the disable-sleep command (the builder logs "Failed to setup SoC SLEEP mode" 0x41643a; the call-site log "Disable sleep mode failed" 0x419a76), with param byte (0!=0)=0x00, giving 01 04 FC 01 00. It then logs "Soc sleep mode disabled, Initializing firmware now..." (0x419aa0).
    9. fcn.00404458 calls fcn.004017a8, the firmware-init / version read, in this order:
         a. fcn.004027ba is opcode 0x0C1A, 1 param byte=0x00, giving 01 1A 0C 01 00.
         b. fcn.00401ed6 is opcode 0x1001, Read_Local_Version (std HCI), 0 params, giving 01 01 10 00.
         c. fcn.00402076 is opcode 0xFC1E, vendor GET_VERSION, 0 params, giving 01 1E FC 00.
         d. a CRC check, then fcn.00401d7c is opcode 0xFC0B, the TLV/rampatch+NVM download loop (segments from the AthrBT_*.dfu + ramps_*.pst files), with reply 04 0E 04 01 0B FC 00 per segment.
  Reply formats. A correction first: the "0x06" the builders test is the expected RX byte-count (evt_paramlen+2), not a status byte; the on-wire HCI status byte is 0x00 on success, a standard Command Complete. Each builder pre-loads the expected Command-Complete header dword (0E <plen> 01 <op-lo>) and checks it. The full on-wire replies (04 = HCI event) are:
    FC0C reply   = 04 0E 04 01 0C FC 00            (driver checks 6 bytes back)
    FC04 reply   = 04 0E 04 01 04 FC 00            (6 bytes)
    0x0C1A reply = 04 0E 04 01 1A 0C 00            (6 bytes)
    0x1001 reply = 04 0E 0C 01 01 10 00 <8B ver>   (14 bytes; HCI_Version etc.)
    FC1E reply   = 04 0E 12 01 1E FC 00 <...>      (20 bytes; ROM/FW/Chip/SysCfg ver) [or 30B=0x1e variant]
  Delays (KeDelayExecutionThread, relative 100ns): the wake-pulse low time is 5 ms (0xffff3cb0), and the version-read retry loop uses 100 ms (0xfff0bdc0) and 200 ms (0xffe17b80). There is no mandatory inter-command delay between FC0C/FC04/version beyond the request/response wait; the 100/200 ms values are retry backoffs.
  Baud handling (now resolved for attempt #1). The FC0C payload is computed, not a literal immediate: builder fcn.00402358 does `div edi,100; mov word[buf],ax`, so the payload is (baud/100) as an LE16. No hardcoded baud-byte FC0C exists anywhere; the only baud constants are 0x1c200=115200 ([0x41f79c], "DefaultBaudRate") and 0x384000=3686400 (the high rate, a literal in ConfigHighBaudRate). ConfigHighBaudRate (fcn.004066c0) runs a 2-attempt retry loop with a PD-GPIO power-cycle between attempts:
    Attempt #1 (0x40672d-0x406794): host SET_BAUD to [0x41f8a4] (the current/previous host baud, starting 0 then 115200), then FC0C carrying [0x41f79c] = 115200. So the driver's very first FC0C sets 115200, and it is both sent and replied at 115200 (the host is not yet switched up). The cold opener FC0C is therefore 01 0C FC 02 80 04, with reply 04 0E 04 01 0C FC 00 at 115200. On success it stores the new baud into [0x41f8a4] (0x40691e).
    Attempt #2 (0x4068a7-0x4068c7): host SET_BAUD, then FC0C carrying the high baud (3686400, giving 00 90) - only reached if the #1 path needs the high rate. (Runtime BaudRate=3686400 from the INF may change which rate is the operating target, but #1 still issues 115200 first.)
  So the FC0C values are: 115200 gives payload 80 04 (01 0C FC 02 80 04), and 3686400 gives payload 00 90 (01 0C FC 02 00 90).
  Note that the placeholders I tried on the tablet (0000/FFFF/00E1/80B2/00C2) are all non-standard bauds (word*100 = 0 / 6.55M / 5.76M / 4.57M / 4.97M); neither 80 04 nor 00 90 was among them, so the valid set-baud was never actually sent. Reply baud: FC0C #1's command-complete comes back at 115200 (the host switches only afterward, and #1 sets 115200 anyway).
  Host-UART line setup (regarding TXD-idle): SoC_INIT sets LINE_CONTROL = WordLength 8 (8-bit), TIMEOUTS, HANDFLOW (RTS/CTS), QUEUE, and PURGE, all on the host controller. The driver issues no IOCTL_SERIAL_SET_BREAK (no 0x1b0010/0x1b0014), only SET_RTS (0x1b0030), CLR_RTS (0x1b0034), and GET_MODEMSTATUS (0x1b0050), so it relies on the controller naturally idling TX high (mark). It does issue IOCTL_SERIAL_POWER_ON (0x1b00d0) to the UART controller at D0Entry start (fcn.00406ad3), a controller power/clock bring-up step the generic-16550A bind may skip compared to 8250_dw. So TXD-idle-low is almost certainly a Linux controller-bring-up issue (the generic 16550A not fully powering/initing URT1), not a missing chip command; it is upstream of the opener test - no command can be framed over a TX line that won't idle high - so I should fix that (8250_dw bind / controller power-on) before concluding anything from an FC0C/FC04 null result.
  Correction to my own first draft of this section: FC04 is the disable-sleep command (not baud); the baud command is FC0C (inside ConfigHighBaudRate); FCA0 is "set remote max tx power" and is not on this cold path (it lives elsewhere - my earlier draft placed it wrongly). I verified the labels via each builder's own log-string xref plus the call-site string.
  Note on order: baud (FC0C) and sleep (FC04) are issued before the version read. This is the FdoDevD0Entry (D0 power-up) path and it is the genuine cold bring-up, because PrepareHardware (0x407222) does not call the version/download chain at all (it only sets up the host UART, the worker thread, and FTM/BTTest mode); fcn.00404458 (version+download) is reached only from D0Entry (0x406de3), the FTM path (0x4082f2), and fcn.00409a18 (0x409afd). ConfigHighBaudRate sets the host baud before sending FC0C - a normal "switch host, then tell chip" pattern, not actually backwards, see the baud handling note below - and the exact 115200-vs-3686400 ordering is not statically resolvable.
  Actionable: the first cold vendor command the driver issues to the chip is 0xFC0C (baud), then 0xFC04 (disable sleep), both before any version read. My prior probes were 0xFC00 / 0xFC1E / 0x030C / hciattach-ath3k / IBS, so 0xFC0C and 0xFC04 were never tried as the opener. That is the one remaining cheap Linux experiment. Caveat: FC0C also flips the host baud on the success path, so replicate it carefully - send the chip FC0C at 115200, only change the host baud if a reply comes, otherwise stay at 115200 and try FC04 plus the version read. fcn.00402496 is strict request/response (KeWaitForSingleObject with -50000000 = a 5s timeout, then abort), so if the chip never answers #1, nothing downstream fires, which is consistent with the observed total muteness.

(C) Why this does not (yet) reopen the bring-up. Each recovered command reproduces a one-shot command/response exchange, and the chip has answered nothing to any command #1 tried so far (rx:0/fe:0, idle RX). Knowing commands #2..#N is useless while #1 gets no reply. The only way (A)+(B) becomes actionable is if 0xFC0C/0xFC04 as the opener elicits a reply where 0xFC1E/0xFC00 did not. It is worth one test, but I do not expect it to overturn the wall.

(D) This confirms UPDATE 8's negatives from the code side (each backed by RE, all five asked angles):
   - Clock: the driver imports zero clock APIs; the only clock strings are the chip reporting RefClock/ClkClass after the version read ("get clock info"), and "Turn off UART Clocks"/IOCTL_SERIAL_POWER_ON refer to the host UART controller clock (Linux 8250_dw owns that), not the chip's 26/40MHz xtal. The driver never enables a reference/platform clock. (Matches UPDATE 8: force-enabling all 6 pmc_plt_clk did nothing, and with no plt_clk it is the chip xtal anyway.)
   - 3rd GPIO / reset: the _CRS parser fcn.00407cd2 records exactly one GpioIo (2 pins, opened into ctx+0x10=PD and ctx+0x14=wake), one GpioInt (wake/host-wake IRQ, ctx+0x38, tied to "power on underlying UART controller"), and the UART. PrepareHardware fcn.00407222 opens only PD+wake GPIO plus the UART. There is no third power/reset GPIO and no chip-reset assert/deassert separate from the PD pin.
   - I2C / PMIC / ACPI method: there is no I2C/SMBus/PMIC write anywhere in cold-start, and no _DSM/_PS0/_PR0/_RST/_ON/_OFF method eval (the only "ACPI..." strings are the HWID match strings ACPI\VEN_QCA&DEV_3002 etc.). I2C is LTE-coex only.
   - Pre-version delays: settle delays only (KeDelayExecutionThread: 100ms 0xfff0bdc0, 200ms 0xffe17b80, 5ms wake 0xffff3cb0). There is no autobaud / BREAK / sync-byte sequence. (Baud stays 115200 until after init; FC04 is a vendor command, not a host-side baud change before first contact.)
   - INF flags (RadioGPIOControled=1, ExplicitRtsWakeup=1, DefaultBaudRate=115200, BaudRate=3686400): these gate GPIO-vs-RTS wake and the post-init high-baud switch; none triggers an extra clock/power/reset step.
  The conclusion is unchanged from UPDATE 8 on the physical side: the driver does only what Linux already does (power pin52 high, wake pin53, host-UART config, request/response over UART). The genuine addition versus prior RE is that the literal cold command bytes are recoverable and the real opener is 0xFC0C/0xFC04 (untried). RE env: radare2 6.1.8 + r2ghidra (brew); binary at winre/qcbt/.../UART_2.2.0.24/qcbtuart.sys. Key fcns: D0Entry 0x406a6e, SoC_INIT 0x404120/0x404488, version-read 0x404458/0x4017a8, send primitive 0x402496, _CRS parser 0x407cd2, PrepareHardware 0x407222, builders FC04 (disable-sleep) 0x4022aa / FC0C (baud) 0x402358 / FC0B (rampatch) 0x401d7c / FC1E (getver) 0x402076 / 0x1001 (read-local-ver) 0x401ed6 / 0x0C1A 0x4027ba / FCA0 (set-remote-tx-power, not on cold path) 0x4021fc.

## UPDATE 12 (2026-06-26) - RE-recovered command bytes tried on hardware; chip is mute to its own driver's opener

I acted on UPDATE 11's recovered bytes, with the chip powered and woken via the RE GPIO sequence, baud 115200 confirmed, and CTS=1:

- The TXD-idle-low observation from UPDATE 10 is a non-finding. In the BREAK test (btbreak), the pin71 GPIO-VAL read 0x002 unchanged across port-closed, break-CLEAR, and break-SET, so the GPIO-VAL register does not track the live UART-function pad. The earlier "TXD low" was a meaningless stale read, so there is no evidence that TXD idle is wrong. (I am dropping the 8250_dw-for-TXD angle.)
- With btseq (one open session, 115200), I sent FC04 (0104FC0100), 0C1A (011A0C0100), Read_Local_Version (01011000), GET_VERSION (011EFC00), and HCI_Reset (01030C00), and all returned rx:0. The FC0C-as-opener placeholder payloads (0000/FFFF/00E1/80B2/00C2) all returned rx:0 as well. The host-wake IRQ still shows 0 edges.

So the chip is mute to the driver's literal command set in the driver's own order. That means the Windows-to-Linux gap is not the command bytes - I have them, and they elicit nothing - it is something not observable or reproducible from Linux (timing, electrical, or silicon). This matches UPDATE 11(C)'s prediction. My last card is a real FC0C with the exact baud code, since the chip may strictly require a valid set-baud first and silently drop bad ones. The FC0C builder fcn.00402358 derives the 2 baud bytes (likely from BaudRate=3686400) rather than a plain literal, and I still need to extract it. If that is silent too, the internal path is provably closed and I move to the USB dongle. New tools: btseq.c, btbreak.c, bt-newtest.sh, bt-fc0c.sh, bt-pincheck.sh.

## UPDATE 13 (2026-06-26) - Provably closed: the exact-bytes FC0C opener stays silent; the host UART is confirmed perfect
Static RE handed me the exact opener bytes. The FC0C payload is the baud rate divided by 100, little-endian, so 115200 becomes 01 0C FC 02 80 04, and the success reply is 04 0E 04 01 0C FC 00. I tested this at the correct power and wake state, 115200, CTS=1: FC0C (115200 no-op) followed by FC04, then 0C1A, then Read_Local_Version, then GET_VERSION; then FC0C three times; then FC0C at 3686400 (01 0C FC 02 00 90). Every one returned rx:0. The chip ignores its own driver's exact, verified command set.

The TXD/controller caveat is now resolved by reading the UART registers directly (uartrd.ko at 0x9094D000, with the port OPEN): LCR=0x13 (8N1), IIR=0xc1 (FIFOs), MCR=0x2b (DTR+RTS+OUT2+AFE auto-flow, RTS asserted), LSR=0x60 (THRE+TEMT=1, so the transmitter is empty and idle, which means TXD sits at MARK/HIGH), MSR=0x10 (chip CTS asserted), USR=0x06. (A closed port reads 0xff, meaning runtime-suspended; open means fully powered and configured.) So the host UART is perfect and TXD idles HIGH - the UPDATE 10 "TXD low" reading was a stale GPIO-read artifact and is now disproven. That means the chip receives valid exact-byte commands and still answers nothing, and never raises host-wake (GSI70 shows 0 edges).

My conclusion, provably closed by the criterion of TXD-good plus exact-opener-silent: the Windows-to-Linux gap is not the command bytes (recovered and sent), not the UART (confirmed perfect), and not clock, rail, reset, or ACPI-resource (from DSDT and RE). The driver does only what Linux already does, which I verified by RE. The chip's CPU does not execute its ROM for a cause that is (a) absent from the Windows driver's observable behavior and (b) not reproducible or observable from Linux - that is, a timing, electrical, or silicon condition reachable only with a logic analyzer on a live (Windows) setup, or the chip itself. I took this far past any public attempt: I powered the chip, brought up the full UART, and recovered and tried the real driver commands. The realistic end is a USB BT dongle, or a logic-analyzer / Windows-To-Go capture (declined, since there is no Windows on the tablet). New tools: uartrd.c, btseq.c, bt-uartrd.sh, bt-fc0c2.sh.

## UPDATE 14 (2026-06-26) - UPDATE 13 retracted: INF plus PDB from the Dell pack reveal an untried wake path
My source was the Dell 5830 Network driver pack, which I unzipped with `unzip` since the .EXE is a ZIP self-extractor:
5830_Network_Driver_Y3DWJ_WN32_3.7.2.63705_A05.EXE -> drivers/production/Windows8.1-x86/Bluetooth-Driver/, which contains qcbtuart.inf (per-board config), qcbtuart.pdb (full debug symbols), qcbtuart.sys v2.2.0.22, ramps_0x01020201_26_DLAC.pst plus _DLAC_gpio.pst (my board's patch/GPIO config), and AthrBT_0x01020201.pst. My earlier RE was unsymbolized and I had never read the INF, so the "provably closed" conclusion in UPDATE 13 was wrong. I correct it here.

In the INF's per-board AddReg, my board is ACPI\DLAC3002 -> [BTUART_DLAC_Service.AddReg]:
  DefaultBaudRate=115200 (cold), BaudRate=3686400 (operational after the switch), which confirms the cold baud is 115200. My baud was right, and this refutes every "wrong baud" worry, coming from the vendor's own config.
  ExplicitRtsWakeup=1 (HPAA=0, DLAB=0; DLAC/SSAD/IAAE/LGAC=1). This is the smoking gun: my board needs an explicit RTS wake manipulation. All my prior tests held RTS statically asserted (CRTSCTS), so I never produced the RTS wake edge or sequence. My new leading hypothesis is that the chip cold-boots in a sleep state (UART RX off) and waits for an RTS clear-then-assert wake before it will accept or answer any command, which exactly matches "powered, CTS-capable, but mute".
  RadioGPIOControled=1 (HPAA=0), meaning GPIO power control is required (done). RadioRtD2Enabled=1, WriteRetryEnabled=1, UART_TO_READ=40 ms, UART_TO_WRITE=1500 ms.
The PDB symbols confirm the RTS-wake machinery, with real names in the same bt_hci_qca_* family as Linux hci_qca.c (AR3002 codename "valkyrie"): qca_uart_set_rts / qca_uart_clear_rts (which log "UART RTS signal asserted./cleared."), UartWaitWakeWorkerThread, bt_hci_qca_wakeup_valkyrie, bt_hci_qca_set_sleep_mode ("Enable/Disable device sleep mode"), DeviceWakeupTargetByGPIO, bt_hci_qca_get_soc_clock_info, SoC_INIT, bt_qsoc_init_state, FdoDevConfigHighBaudRate, FdoDevResumeDefBaudRate. The struct fields are IoTargetChipPowerGPIO(+0x10), IoTargetWakeupGPIO(+0x14), Ref_Clock(+0x10, crystal select), and WaitWakeThread.
Next: (1) pull the exact RTS toggle order and delays from the symbolized qca_uart_set_rts/clear_rts, wakeup_valkyrie, and SoC_INIT; (2) run a tablet test that powers plus GPIO-wakes, opens 115200, drops CRTSCTS, does an explicit RTS wake (clear RTS -> hold -> assert RTS), re-enables flow, then issues GET_VERSION / FC0C, sweeping hold time and polarity. Status: open and actionable, not closed.

## UPDATE 15 (2026-06-26) - Exact explicit-RTS-wake sequence decompiled from qcbtuart.sys v2.2.0.22
I located this via the serial-IOCTL immediates, so it does not depend on any PDB names: CLR_RTS=0x1b0034, SET_RTS=0x1b0030, and SET_BREAK_ON=0x1b0010 (zero hits, so no break) along with SET/CLR_DTR (zero hits, so no DTR). The wrappers are fcn.00404c44 = qca_uart_clear_rts (IOCTL 0x1b0034) and fcn.00405136 = qca_uart_set_rts (IOCTL 0x1b0030). The wake routine is fcn.00404aa6, called from the cold-boot/D0Entry orchestrator fcn.0040686c at 0x406e95.

The exact decompiled logic is:
  - Read the modem status (fcn.00404e48 -> var). If CTS (MSR bit 0x10) is already set, skip the wake because the chip is awake.
  - Otherwise set RTS to manual control via FlowReplace=0x40 (SERIAL_RTS_CONTROL, which drops the HW RTS handshake), then:
      do {  CLR_RTS;  KeDelayExecutionThread(-50000 = 5 ms);  SET_RTS;  KeDelay(5 ms);  read MSR;  }
      while ((MSR & 0x10 [CTS]) == 0  &&  count < 5);     // <=5 pulses, ~50 ms max
  - Final SET_RTS, then restore FlowReplace=0x80 (SERIAL_RTS_HANDSHAKE, which turns HW RTS flow control back on).

What this means is that the driver wakes the sleeping chip by pulsing RTS (deassert 5 ms, assert 5 ms) up to 5 times until the chip raises CTS, with HW flow control dropped during the pulse. This is the ExplicitRtsWakeup=1 behavior. All of my prior tests held RTS static (CRTSCTS asserted), so the pulse was never produced, which is plausibly why the chip stayed mute.

One caveat: the driver skips the pulse if CTS is already high at entry, and my UPDATE 13 reading had MSR=0x10 (CTS high under static RTS), so on Windows the pulse might be skipped too. The real differentiator could therefore be subtler - the manual-RTS-mode transition itself, or the chip needing the pulse regardless of the idle CTS level. I will test both: faithful (pulse only if CTS is low) and forced (pulse regardless). The tool is btwake.c (manual-RTS pulse plus cmd/read).

Next: deploy btwake to the tablet (sudo), do a cold power-cycle plus GPIO power+wake (bt-correct3.sh), and run it against GET_VERSION (01 1E FC 00) and the FC0C opener (01 0C FC 02 80 04); I also want to decompile fcn.0040686c for the full pre-command order.

## UPDATE 16 (2026-06-26) - Correction (RTS pulse already roughly tried) plus a new lever: the driver sweeps baud

A correction first. My prior-session tool btwake.c already does a rough RTS pulse (CLR 40ms then SET 60ms, flow off), followed by an IBS WAKE_IND 0xFD and version reads, and the chip was recorded mute to 0xFD. So a cruder, longer RTS pulse was very likely already tried and failed, which makes "RTS pulse alone" a weak lead. UPDATE 14/15 overstated it when I said I had never pulsed RTS: the exact 5ms x5 loop is still untried, but a pulse is a pulse. Honesty over hype.

Now the new finding. I decompiled fcn.0040686c, a baud-detect/re-sync helper, and the driver does a baud sweep rather than a fixed 115200. It sets the baud (fcn.004050a4), probes (fcn.004023a4), and on failure issues IOCTL_SERIAL_PURGE (0x1b004c, mask 0xf) with escalating delays (-300000 = 30ms, (1<<n)*-1500000 = 150ms*2^n, -10000000 = 1s), then retries across candidate bauds. The stack constants are 0x1c200 = 115200 and 0x384000 = 3686400, and it saves the working baud to the registry (RtlWriteRegistryValue @0x4208e4). This means the chip may actually answer at 3686400, whereas every probe I ran was 115200-only. That is the real untried lever, and it matches the research: "boot-ROM baud != operational baud" plus "power-cycle to reset baud".

Revised test: cold power-cycle (GPIO), then for baud in {115200, 3686400} open the port, do an RTS wake (exact 5ms x5 until CTS, AND forced), PURGE, send GET_VERSION (01 1E FC 00) and the FC0C opener, and read. 3686400 needs termios2/BOTHER. Tool: btwake2.c. (Reversing the probe fcn.004023a4 internals is a TODO if the sweep alone is inconclusive.)

## UPDATE 17 (2026-06-26) - the AR3002's 26 MHz reference clock comes from the AR6004 WiFi chip

Source: the QCA6234 datasheet (integrated AR6004+AR3002; "BT block is based on the AR3002"). Section 4.6 says the clock is "provided to BT internally from the WLAN block on demand from BT_CLK_REQ; the WLAN block MUST be initialized before BT clock sharing is enabled". AR6004 section 2.13.1 says that reference (the EXT_CLK_OUT pin N14, 26 MHz) is powered off in SLEEP/HOST_OFF/OFF. So with no WiFi clock the AR3002 boot-ROM CPU can't run, which leaves the UART mute and gives IRQ70=0 edges. That explains the silence: every prior BT probe ran the chip in isolation while the AR6004 runtime-suspended its SDIO (the same behavior as the ~35min WiFi drop), gating EXT_CLK_OUT even while "associated".

This rules out an external 32.768kHz source (the AR3002 has an internal sleep clock, QCA6234 section 2.7) and the SoC pmc_plt_clk (wrong clock - this overturns the old memory assumption). The module is an AR6004(WiFi)+AR3002(BT4.0) combo (HP 691921-005 equiv). BT POR is pin52 LOW->HIGH (the datasheet BT_PWD_L POR detects a LOW->HIGH edge, which matches the RE). Datasheet PDFs are saved locally.

The decisive test (carefully checked): keep the AR6004 clocking, then power BT, then probe. Order is critical - the 26 MHz must be live at the BT POR edge or the ROM latches a no-clock state (a false negative).

0. Pre-check: read the AR6004 SDIO power/runtime_status and autosuspend counters - does it actually suspend when idle? If it never suspends, the clock was likely always on and this hypothesis is weaker. Know that first.
1. echo on > .../power/control (the ath6kl SDIO func plus its mmc_host); `iw dev <if> set power_save off`; saturate the link (ping -f <gw> or iperf, NOT ping -i 0.2; 200ms gaps let firmware PS gate the clock). Snapshot /proc/interrupts IRQ70.
2. Then bt-correct3.sh (pin52 LOW->HIGH POR, pin53 wake).
3. btmatrix /dev/ttyS4 - read the 115200 / wake / GET_VERSION cell first (boot baud, highest-probability hit).
4. IRQ70 after. Run in a fresh WiFi window; if WiFi drops mid-cell its clock died, so rerun and don't score it.

There is no WiFi-down control arm (it kills ssh and proves nothing a positive doesn't). The discriminator: any rx byte or IRQ70 edge never seen before means the clock was the gate, so proceed to the ROME EDL rampatch path (FC00/TLV, ROM 0x00000302, Linaro btqca AR3002 patch). Fallback (to stop spiraling): if it is still fully mute at a verified 115200 with the clock provably on, the next suspect is not "chip-internal" but that "enable BT clock sharing" may be a WLAN-firmware step the Windows driver sends and ath6kl does not - check that before any conclusion. Tools: btmatrix.c (ready) plus the bt-clocktest.sh orchestrator (build on deploy with the real iface/SDIO/gw).

## UPDATE 18 (2026-06-26) - Keystone test ran: still silent with the AR6004 clock provably on
I ran bt-clocktest.sh on the tablet. It forced the AR6004 awake (runtime PM off, power_save off, ping -f flood), which gave SDIO ctrl=on status=active with susp frozen at 11253ms across the whole probe - not suspended, so the AR6004 was awake and clocking. I then POR'd BT (clock live at the edge) and probed.

The result was still fully silent: RX=0 in all 8 cells {115200,3686400}x{static,RTS-wake}x{GETVER,FC0C}, plus bt-live GET_VERSION x16. CTS=1 at 115200 (tcdrain OK). On baud reachability, 115200 measured ~102847 and 3686400 measured ~3249206 (=3.25M), which is above the base_baud of 2764800, so the 8250 fractional divider works and 3686400 is genuinely reachable, not clamped. Both bauds were therefore really tested; the +-10% "CLAMPED" flag was just measurement overhead.

Keeping the AR6004 awake did not break the silence, which falsifies "WiFi-suspend gated the clock" as the sole cause (and prior probes ran over active ssh, so the AR6004 was mostly awake anyway). The remaining clock thread, as a fallback, is to enable BT clock sharing: the AR6004 being awake may be necessary but not sufficient, and EXT_CLK_OUT to BT may need an explicit WLAN-firmware/coex enable that ath6kl never sends (per QCA6234, "WLAN block MUST be initialized BEFORE BT clock sharing is enabled"). Next: (1) the ath6kl BT-coex/clk knobs (params/debugfs/dmesg); (2) research how AR6004->AR3002 clock sharing is enabled and whether there is any Linux lever. If there is none, this is a rigorous wall (now genuinely exhausted, not premature): Windows trace, logic analyzer, or dongle.

## UPDATE 19 (2026-06-26) - WLAN driver does no BT bring-up; rigorous wall reached
The Dell Network pack also has the WLAN driver: WLAN-Driver/AR6KNWF81.sys (1.09MB) plus ar6knwf81.inf. I scanned both:
- The INF [btcoex.reg] sets BtCoexEnable=1, BtCoexAntConfig=5, and sdioclock=50000, which is airtime WiFi/BT coexistence (antenna/airtime sharing) plus the SDIO bus clock. It is not BT-chip bring-up.
- The .sys strings had zero hits for ext_clk/clk_out/bt_reset/bt_pwr/bt_en/bt_gpio/xtal/sleep_clk/26mhz/40mhz.

So the Windows WLAN driver does not power, clock, reset, or GPIO the AR3002; it only does airtime coex. The BT chip is brought up entirely by its own driver (qcbtuart, fully RE'd and replicated), independent of WLAN. That closes the "WLAN gates BT" hypothesis. It also closes clock-from-WiFi for the discrete board (there is no clock-out enable in the WLAN driver; the AR3002 uses its own 26MHz reference per the ath3k ref_clock - the QCA6234 "clock from WLAN" was an integrated-die over-generalization).

Rigorous wall (earned, not premature):
Linux-reachable hypotheses tested and falsified: power (chip powers on, CTS rises); host UART (perfect - loopback, TXD idles high, baud correct); exact Windows-driver bytes (FC0C/FC04/version reads RE'd and sent); baud (115200 confirmed, real ~3.6M); RTS wake (rough single plus 5ms-pulse loop); GPIO power/wake (RE-derived sequence); clock-from-WiFi (AR6004 held provably awake, still mute); and WLAN-driver BT bring-up (none). The core fact is that the AR3002 boot ROM never answers GET_VERSION (the first byte, before any patch, clock-select, or coex) despite power and its own clock, which means the BT CPU is not running for a reason not exposed to or fixable by the OS (chip strapping, board, or silicon), observable only via logic analyzer or a live Windows HW trace (there is no Windows on the tablet, and WtG/VM was declined). Prior art: studioteabag (the definitive DV8P5830 Linux reference) reports BT "Nope, UART not initialized" and switched to a dongle. The verdict is that internal BT is not bring-up-able from Linux with any available lever. Working BT means a USB dongle (UB400).

Side-benefit of today's test: WiFi was left with runtime-PM off and power_save off, a stability config worth keeping for the WiFi work.

## UPDATE 20 (2026-06-26) - Complete FdoDevD0Entry traced; every pre-response step replicated; no overlooked step

To answer the question "did I overlook anything in the working driver?", I decompiled the entire cold-boot orchestrator FdoDevD0Entry (fcn.00406c20) along with every callee. The full ordered sequence is:

  1. IOCTL 0x1b00d0 serial setup [if no wakeup-IRQ]; open the GPIO IoTargets +0x10 (power) / +0x14 (wake) / +0x758 via WdfIoTargetOpen.
  2. Power-on: fcn.00403f40 = IOCTL_GPIO_WRITE_PINS(0x480004) setting the chip-power GPIO=1, then wait 150ms.
  3. fcn.0040458e = UART config: SET_LINE_CONTROL 0x1b000c (8N1), SET_TIMEOUTS 0x1b001c, SET_HANDFLOW 0x1b0064 (ControlHandShake=0x08 CTS_HANDSHAKE + FlowReplace=0x80 RTS_HANDSHAKE = full HW RTS/CTS = CRTSCTS), SET_QUEUE_SIZE 0x1b0008 (32K/32K), PURGE 0x1b004c (mask 0xf).
  4. LTR (PCIe latency, host-side only).
  5. fcn.00404aa6 = RTS wake (CLR/5ms/SET/5ms loop <=5 until CTS).
  6. fcn.0040686c = baud sweep: set-baud + FC0C probe (payload=baud/100), retrying across only {115200,3686400} with a power-cycle (fcn.00403f40 0->30ms->1) + PURGE + escalating delays, saving the working baud to the registry.
  7. fcn.004022f0 = FC04 disable-sleep (01 04 FC 01 <0/1>).
  8. fcn.00404556 -> fcn.004017cc = rampatch/PS download (only after a responding chip).

Every pre-response step is replicated in my tests: 8N1+CRTSCTS (bt-live/btmatrix), power GPIO (bt-correct3), RTS wake (btmatrix wake=1), both bauds 115200+3686400 (btmatrix, port verified reaching ~3.6M), FC0C (btmatrix/bt-fc0c2), and FC04 (bt-fc0c2/btseq). The chip stays silent through all of it, which means there is no overlooked driver step: the working driver does exactly what I replicated through the first expected reply, and the chip answers nothing.

The only bits that are not byte-identical are host-side (timeouts/queue sizes) or electrical (I write the power pad via padmmio raw register rather than the driver's ACPI GpioIo path - but that pad demonstrably works, since CTS rises on power-on). The one diminishing-returns sub-difference left is to drive the power/reset GPIO via the ACPI-declared GpioIo (gpiod) instead of raw padmmio, which would require re-enabling BTH0 in ACPI and conflicts with the bt0off SSDT that freed ttyS4. So the gap is not in the BT driver. The rigorous wall stands: the chip boot ROM never runs under Linux for a non-driver, non-OS-reachable reason.

## UPDATE 21 (2026-06-26) - fresh-boot/BT-before-WiFi negative; "wall" retracted, BT_VDD core rail is the open lever

I had a few new ideas to test, keeping in mind that the tests might lock the chip, that I wanted to capture any boot emission, and that I should try BT before WiFi. So I set up temporary passwordless sudo plus a one-shot boot service (bt-boottest.service) with ath6kl blacklisted, and ran it on a fresh reboot before WiFi came up.

The results (/var/log/bt-boottest.log): [A] a passive listen on the fresh chip, before any probe and before WiFi, gave RX 0, CTS=0; [B] powering it (pin52 OFF->ON, pin53 wake) took CTS 0->1 with RX 0; [C] listening after power gave RX 0, CTS=1; [D] btmatrix was all RX 0; [E] loading ath6kl brought WiFi back, so the safety rails worked. In other words, the chip stayed mute even on a fresh boot with BT before WiFi and zero boot emission. That kills both the "prior tests lock the chip" and the "WiFi gates BT order" hypotheses.

I am also retracting the "rigorous wall" from UPDATE 19/20. A careful datasheet re-read caught a real conflation: "chip powers on" meant CTS toggling, but CTS is an I/O-domain signal, so it only proves the BT I/O rail BT_IOVDD is up. The boot-ROM CPU runs off a separate core rail, BT_VDD (~1.8V). QCA6234 Table 5-2 lists BT_VDD as the "BT core supply" versus BT_IOVDD as the "BT GPIO I/O power supply", which are distinct domains. I/O up with core down means CTS responds while UART TX stays mute, which is the exact symptom, and it fits [A]: CTS=0 pre-power, CTS=1 post-pin52 (pin52 gates I/O, maybe not core). qcbtuart being self-contained does not prove independence - it assumes BT_VDD is already up, brought up by platform firmware or the PMIC stack. Linux registers no BT regulator on the Crystal Cove PMIC, and that absence is the prime suspect.

The prime untried lever, and it is Linux-reachable, is to enumerate the Crystal Cove PMIC LDOs, force the BT core LDO on (a raw PMIC register write, like the GPIO MMIO pokes), and re-send GET_VERSION. If TX responds, it is solved. If there is no controllable BT LDO, or the forced rail is still silent, then the wall is genuine (the core rail is set by firmware and not OS-reachable). Tools: btlisten.c, bt-boottest.sh/.service. Temporary tablet changes to revert later: passwordless sudo (/etc/sudoers.d/99-ramon-testing) and bt-boottest.service (self-disarmed, one-shot).

## UPDATE 22 (2026-06-26) - UPDATE 21's PMIC-LDO lever closed on safety and evidence; honest terminal reached

I ran the "force the BT core LDO on" lever from UPDATE 21 all the way to ground, and then deliberately chose not to actuate it:

1. I read WFD3 (the WiFi-controller module-power enable, GPO2 pin 0x14, asserted by SDHB._PS0) on a WiFi-up system: /sys/kernel/debug/gpio shows gpiochip2[INT33FC:02] gpio-20 (ACPI:OpRegion) = "out hi". So the module power-enable is already high. It is not the missing lever, which matches the datasheet's prediction. gpio-52 (BT power-down, pad-88) and gpio-53 (BT wake, pad-92) also read "out hi".

2. There is no OS-controllable BT core LDO to force: Linux registers no BT regulator on the Crystal Cove PMIC (only regulator-dummy); the DSDT gives BTH0/BTH0-under-URT1 only the two GpioIo pins 52/53, with no _PR0/_PS0/power resource; and the one 1.8V PMIC PowerResource in the DSDT (P18X, also P28X 2.85V) is wired to the cameras (CAM0._PR0), not BT. So there is no identified BT-core-rail target to enable.

3. On hard safety, which I checked carefully: blind-poking arbitrary Crystal Cove LDO registers via raw regmap to hunt for a BT rail risks browning out a live rail (SoC core / eMMC / DRAM), with no evidence any of them feeds BT and no identified target. That is an unacceptable damage risk to a working tablet for a speculative gain, so I did not do it.

This is an honest terminal. Every OS-reachable lever is now either exhausted or unsafe to actuate blind:

- I replicated the complete Windows-driver cold-start (FdoDevD0Entry, every pre-response step) on /dev/ttyS4, and it stayed mute;
- the host UART is proven perfect (CTS responds to pin52, TX drains at 115200 and at a verified-reachable 3.6864M);
- baud sweep, static-RTS and RTS-pulse wake, and the exact driver bytes (FC0C/FC04/GET_VERSION) all returned RX 0;
- fresh-boot with BT-before-WiFi and zero boot emission killed the lock-up and ordering theories;
- the clock is AR3002's own 26 MHz crystal, and holding the AR6004 awake made no difference;
- the WLAN driver does no BT bring-up (only BtCoex airtime);
- WFD3 module-enable is confirmed high; there is no OS-controllable BT core LDO; and the PMIC blind-poke is ruled out on safety.

My conclusion is that the AR3002 boot ROM never executes for a reason fixed below the OS, in platform firmware, a board strap, or silicon. The most likely cause is a core rail BT_VDD that Dell's UEFI brings up for Windows and Linux never does, with no ACPI/OS hook to assert it. It is not OS-reachable from Linux. The remaining real paths are out-of-band only: (a) put a logic analyzer on the BT_VDD rail plus UART to see what Windows asserts that Linux doesn't; (b) capture the PMIC/GPIO state from a live Windows boot; (c) accept it and use a USB BT dongle (TP-Link UB400, community-confirmed). This is the genuine terminal for software-only work, recorded as such after the WFD3 read closed the last lever.

## UPDATE 23 (2026-06-26) - "terminal" reopened; a robust 3-signal proof that the I/O is powered but the CPU is not booting
My self-imposed rule stands: never test under Windows, never use a dongle, just keep going. I re-attacked with a fresh reframe and cleared two of my own confounds offline on the live DSDT.

First, the _STA->0 override suppresses no power path. BTH0 has no _PS0/_PR0/_INI/_DSM (only _HID/_PRW{0,0}/_CRS), and the parent URT1._PS0 just ungates the LPSS UART clock (the PSAT register), which Linux's 8250 driver does anyway.

Second, acpi_osi is a dead end. The only OSYS branches are at line 2530 (a tautology), 5897 (WinXP-SP2), and 10855 (Win8.1, inside device TBAD's power-button _DSM, which sets I2C7.PMIC.FCOT, not BT), and Linux already lands on OSYS=0x07DD by default. Nothing on the URT1/BTH0/GPO0 path branches on OS type. That saved me a reboot.

Also worth noting: the BIOS is AMI Aptio (SSDT OEM "AMI"), the PMIC is \_SB.I2C7.PMIC, and Linux has only regulator-dummy (no Crystal Cove LDO driver), so the CRC LDOs keep their firmware defaults, the same as under Windows. That means no LDO can be "off in Linux only", so the core-rail-down hypothesis is dead, not merely deferred: Windows works on that same default, so the chip is powered in Linux too. BlueZ issues #2222/#2226 are bare dmesg dumps for this exact device, unresolved, with zero fixes.

The decisive experiment (run_livetest.sh, btlive2.c, btirq2.ko) ran on a fresh reboot and watched three independent liveness signals:
  - UART (btlive2, raw 115200 8N1 CLOCAL, RTS+DTR forced): CTS=1, wrote the 4B GET_VERSION, banner_rx=0 and reply_rx=0.
  - Host-wake IRQ: btirq2 mapped GSI70 -> virq152, and /proc/interrupts showed "152: ... IO-APIC 70-edge btwake2" armed (IO-APIC, BIOS-fixed routing, not a maybe-unconfigured GPIO), count 0 across all CPUs.
  - Direct GPIO-level diff (all 200 pads, before chip-off versus after chip-on and woken): only gpio-52/53 changed, and those are mine; no other pad toggled, so the chip drove no output line anywhere.

The robust verdict, no longer resting on rx:0 alone: the AR3002 I/O block is powered (CTS responds) but the CPU is not booting or signalling - no boot banner, no reply, no host-wake assertion, no GPIO activity. The same exact Windows cold-start sequence boots the CPU under Windows, so the differentiator is OS-level and not firmware-persistent (setup-var/_OSI/PMIC-LDO are all eliminated as firmware-symmetric). The leading remaining suspect is the AR3002 CPU's 26 MHz reference clock: in this AR6004+AR3002 combo it is shared with and owned by the AR6004 WiFi side, whose BtCoex/board-data config (Windows WLAN INF [btcoex.reg]: BtCoexEnable=1, AntConfig=5) may gate the shared clock the BT CPU needs, and Linux ath6kl may not enable it. Next, I will pursue the shared-clock/BtCoex/board-data lever. (To reaffirm: no Windows test, no dongle.)

## UPDATE 24 (2026-06-26) - PMIC rail measured (no BT rail); the loaded WiFi board data is a modification of the OEM combo data
A better approach: I measured the core rail instead of reasoning about it. I pulled the Bay Trail Crystal Cove ACPI PMIC map from the kernel (drivers/acpi/pmic/intel_pmic_bytcrc.c, which had been renamed from intel_pmic_crc.c, hence my earlier 404s). Decoding its power_table against a live regmap dump (i2c-INT33FD:00):
  - addr 0x30 maps to reg 0x68, "V33U/V3P3U SDIO wifi&bt", the shared module 3.3V rail. The dump reads reg0x68=0x02, which is PWR_SOURCE_SELECT set with enable-bit(0) clear, so the rail is SOC/GPIO-enabled (WFD3) and on because WiFi works, meaning the BT supply is on.
  - The 1.8V rails reg0x5c/0x5d/0x5b (SOC-PHY/eMMC/LPDDR) read 0x00/0x02, yet LPDDR and the SOC are obviously powered, so the software enable bit does not reflect the true rail state. That makes the PMIC registers an unreliable readout and unsafe to poke. There is no dedicated, disabled BT rail. A dead core rail is now measured dead rather than just reasoned, so the PMIC line of inquiry is closed.

ath6kl is the stock upstream driver (its params are testmode/p2p/recovery_enable/uart_rate... with no coex/bt/clk/combo knob), so the driver cannot set a BT-combo clock. Only the board data, consumed by the AR6004 firmware/PMU, can.

The key discovery is in the board data. /lib/firmware/ath6k/AR6004/hw3.0/ holds bdata.bin (md5 7c80131, the loaded one, WiFi works) and bdata.bin.aur-bak (md5 61b5a38). cmp proves that bdata.bin.aur-bak is byte-identical to the Windows pack's boardData_2_1_QCA6234_050_v85_BLR.bin (the OEM QCA6234 combo data), and the loaded bdata.bin is a 1508-byte (~25%) modification of it. So Linux runs an altered board data while Windows runs the OEM combo data - a genuine OS-level difference that does not persist in firmware. The board data configures the AR6004 PMU, which plausibly gates the shared 26MHz clock the BT CPU needs. The WiFi MAC (<WIFI_MAC>) is not in either bdata (the placeholder is 12 34 56, so the MAC comes from OTP), which means reverting bdata does not change the MAC or IP and is therefore SSH-safe.

The plan is failsafe-protected and reversible: back up the loaded bdata to bdata.bin.mod-bak; revert bdata.bin to aur-bak (the OEM combo); arm a oneshot systemd service that restores mod-bak and reboots if the gateway is unreachable 4min after boot (this guards against remote loss); reboot; reconnect; and re-run run_livetest.sh (3-signal liveness) on the OEM combo board data. This is blocked for now: the tablet dropped WiFi (a ~37min ath6kl cycle) before staging ran, so it needs a reboot or self-recovery. Local files: btlive2.c, run_livetest.sh, bdata/*.bin, intel_pmic_bytcrc.c.

## UPDATE 25 (2026-06-26) - board-data/shared-clock hypothesis falsified; pivot to the "identical" assumptions
I ran the failsafe-protected swap: I backed up the loaded bdata to bdata.bin.mod-bak, put the OEM QCA6234 combo data (aur-bak) into bdata.bin, and rebooted. WiFi came up cleanly on the combo data (wlan0 up, same IP <TABLET_IP>, failsafe auto-disarmed, ath6kl fw 3.5.0.349 api5), so the combo board data is compatible. I re-ran run_livetest.sh (3-signal) on the fresh boot with combo data and WiFi up, and got an identical negative result: btlive2 CTS=1, wrote 4B, banner_rx=0, reply_rx=0; host-wake virq152 IO-APIC 70-edge showed 0 edges; and the GPIO diff was only my gpio-52/53. That means the WiFi board data does not gate the BT CPU's clock, so the shared-clock-via-board-data idea is dead. (The tablet is currently still on the combo bdata; revert to mod-bak is pending, since WiFi works on both.) By my own kill-criterion, the OS-level rail/clock story has collapsed: the PMIC measured clean, the board data tested clean, and acpi_osi/setup-var are out. I am pivoting to the assumptions I had called "identical". (A) GPIO electrical/sequence: my raw-MMIO VAL-only drive of pins 52/53 may not match the pad CONF0 (drive mode/strength/pull) that Windows programs (pin52 demonstrably powers I/O since CTS rises, but the pin53 wake drive is unverified). (B) The host->chip RX path: I proved chip->host (CTS) but never that my TXD reaches the chip's RXD, and a live-but-not-receiving CPU is indistinguishable from a dead one with my current signals (an absent boot banner is normal for ath3k, and host-wake not being asserted is also normal for an idle booted CPU). Next: find a discriminator for CPU-alive-but-RX-broken versus CPU-dead, and verify the 52/53 pad CONF0 electrical config.

## UPDATE 26 (2026-06-27) - GPIO drive confirmed clean (hypothesis A dead); host-wake only corroborating
For the first time I read the pad CONF0/CONF1/VAL for pins 52/53 in their driven state using padmmio action=read, then decoded them against the kernel pinctrl-baytrail.c bit definitions. Pin52 and pin53 came back identical: CONF0=0x2003c800, which gives PIN_MUX(2:0)=0 (GPIO func) and PULL_ASSIGN=0 (no pull); VAL=0x01, which means OUTPUT_EN(bit1, active-low)=0 so the output is enabled, LEVEL(bit0)=1 so it is driving high, and INPUT_EN(bit2)=0. So both pads are clean, properly-muxed push-pull GPIO outputs driving high. My raw-MMIO VAL drive is electrically correct, and pin53 (wake) drives exactly as cleanly as pin52. That kills hypothesis A (bad GPIO drive).

I logged a correction: the host-wake "IO-APIC 70-edge" arming (btirq2/acpi_register_gsi) is only corroborating, not conclusive - with BTH0 disabled nothing sets the host-wake pad's DIRECT_IRQ_EN/mux, so 0 edges could be a routing artifact. The GPIO-level diff (no held assertion on any of 200 pads) is the strongest of the three signals, but it only catches a held assertion. Honest state: the chip emits nothing detectable by UART-reply, armed-IRQ, or pad-level, while powered (CTS=1) under a faithful Windows-equivalent bring-up. I have downweighted the RX-path-broken theory (CTS works, and all 4 UART pads are mux:1 on the same connector; one broken pin in a uniform group is improbable). This is an instrumentation boundary: "CPU dead" versus "CPU booted-but-idle" are not separable in software once the boot-banner (normally absent for ath3k) and host-wake are both silent.

The one remaining software move that sharpens it is to let the kernel enumerate BTH0 (remove the bt0off override) and bind a minimal DLAC3002 ATH3K serdev driver, so the kernel arms the host-wake IRQ correctly from the ACPI Interrupt resource (setting the pad DIRECT_IRQ_EN), drives 52/53 via gpiod, runs ATH3K GET_VERSION (0xFC1E), and reads RX. The scaffolding exists in hci_qca_dell.c, but it forces QCA_ROME, which is the wrong protocol. Building it would be a definitive in-kernel test - it likely confirms silence, but it makes the host-wake zero meaningful. Note: the tablet is still on combo bdata (WiFi fine); reverting to mod-bak is pending at cleanup.

## UPDATE 27 (2026-06-27) - Definitive in-kernel serdev test: the kernel can now drive the pins, but the chip is still totally mute

I built a minimal DLAC3002 serdev driver (btdlac.c, compiled to btdlac.ko). I removed the bt0off override (a loader entry, reversible via .bak-btdlac) so that BTH0 enumerates as a serdev (serial0-0, modalias acpi:DLAC3002:, and ttyS4 gone). btdlac binds and runs the most faithful in-kernel bring-up possible.

The major new finding: on kernel 7.0.13, pinctrl-baytrail now drives pins 52/53 to output. After btdlac's gpiod drive, /sys/kernel/debug/gpio shows "gpio-52 (serial0-0) ... out hi" and "gpio-53 (serial0-0) ... out hi" (CONF0=0x2003c880 mux0, VAL=0x01 output-enabled high, 2k pull-up). The old "pinctrl-baytrail refuses GPIO output on 52/53" blocker, the original wall, is gone. So the chip is now powered through the kernel's own gpiod path, not just raw MMIO. host-wake armed properly: acpi_register_gsi(70) gave virq 128 "IO-APIC 70-edge btdlac_hostwake", request=0 (success).

The definitive result of this faithful kernel serdev bring-up: gpiod power-on (pin52 high, verified driven) + 2s discharge + wake-GPIO pulse + 4x explicit RTS-wake pulses (eHCILL/IBS) + serdev UART 115200 + command sweep { ath3k GET_VERSION 011EFC00, QCA EDL 0100FC00, HCI Reset 01030C00, Win FC0C set-baud 010CFC020804 } + passive boot-banner listen + host-wake armed, which produced rx_bytes=0 and hostwake_edges=0. Totally mute on every signal.

My honest, software-exhausted conclusion: every software-reachable element is now verified correct - power pins driven to output-high by the kernel itself, UART confirmed, all plausible cold-boot protocols sent, host-wake IRQ armed - and the AR3002 emits nothing: no UART data, no host-wake edge, no GPIO activity. The blocker is not in the OS/driver/GPIO/UART/protocol layer, which is all proven good. Whether the chip's CPU is not executing (no clock, or held in reset below the OS) or executing but receiving nothing it understands is not separable in software: it is an instrumentation boundary, since ath3k emits no boot banner and host-wake is a hardwired GSI I can't positively control. Resolving the root cause would require hardware observation (a logic analyzer or scope on the chip's UART TX, 26MHz clock, and reset), which I did not pursue per scope. Per my own rule, I am not declaring this terminal, not going to Windows, and not going to a dongle.

Tablet state: the bt0off override is removed (now stock - BTH0 serdev serial0-0); btdlac.ko is loaded (idle, harmless, rmmod-able); bdata = combo/aur-bak (WiFi works); passwordless sudo is still active (revert at cleanup). To restore raw-ttyS4 testing, re-add 'initrd /acpi_override.img' to the loader entry (or copy the .bak-btdlac back) and reboot.

## UPDATE 28 (2026-06-27) - Lower-odds grind: baud sweep, clock tree, and firmware presence (all negative or confirming)
I decided to keep grinding through lower-odds software variations, and I also kicked off two lines of research: one on the hardware schematics, NXP, and the 32kHz sleep clock, and one on a test-coverage audit that included the QCA ROME route. My non-overlapping work on the tablet:
- Baud sweep (via btdlac serdev, a faithful bring-up): I ran host bauds of 9600/19200/38400/57600/115200/230400/460800/921600/1500000/2000000/2764800, and all of them hit exactly (LPSS got==req), with GET_VERSION+EDL at each and rx_delta=0 at every rate. The baud rate is conclusively not the issue. (The serdev maximum is base_baud 2764800; going above 2.76M needs raw termios2, but the DSDT cold baud is 115200, so the high end is moot.)
- Clock tree (/sys/kernel/debug/clk/clk_summary): xtal=25MHz (enabled); pmc_plt_clk_2/4/5=25MHz (disabled); pll=19.2MHz feeding pmc_plt_clk_0/1/3=19.2MHz (clk 3 is the audio rt5640 mclk). There is no 32.768kHz clock anywhere and no 26MHz clock. The AR3002 wants 26MHz (ramps_*_26), which means it relies on its own crystal; the platform has no 26M or 32k to feed it. I already tried enabling the plt_clks (clken.ko) and it stayed mute. So the platform-clock angle is exhausted, and a missing 32kHz LPO/sleep clock (the QCA susclk pattern) is the live hardware hypothesis, which one research thread is chasing.
- Firmware presence: /lib/firmware/ar3k/ has the ath3k RamPatch sets, including 1020201 (my chip's AthrBT_0x01020201 from the Windows pack) plus 1020200/30000/30101/30101coex. /lib/firmware/qca/ has newer QCA and USB firmware but no UART ROME rampatch (rampatch_0x00000302). So the ath3k firmware for my exact chip is present but moot: both ath3k and ROME need the chip to answer GET_VERSION/EDL-version first (the silent step) before any patch download, so no firmware route can even start. (Still pending: the schematic/sleep-clock findings, an independent test-coverage audit, and the ROME recommendation; I will act on those next.)

## UPDATE 29 (2026-06-27) - research: QCA6234 datasheet (BT_VDD core-POR) + audit; safety limits lifted; PMIC hunt negative
I pursued two lines of research.

First, hardware and datasheet research, with the QCA6234 datasheet (LM80-P0598-12) as the primary source: the part is indeed a QCA6234 combo. The clock is internal and shared from the WLAN die over BT_CLK_REQ ("WLAN must be initialized before BT clock sharing"), and the 32kHz sleep clock is also internal ("eliminates need for external 32kHz"), so the datasheet refutes both of my clock hypotheses. The symptom I see - BT_IOVDD and CTS alive but the CPU dark - is textbook BT_VDD (core 1.8V) POR not completing.

Second, an audit pass. btdlac's EDL command was malformed (01 00 FC 00, which I fixed to 01 00 FC 01 19, still mute), and ROME is the wrong protocol family (its driver opcodes are FC1E/FC04/FC0B/FC0C..., never FC00), so I should not pursue it.

Read-only closures: there is no 32k/susclk/lpo/clkout in the clock tree (only rtc0), so the 32kHz is not OS-reachable. The host-wake line virq128 is an "IO-APIC 70-edge" native line, and its RTE is set by acpi_register_gsi, so routing is live, which makes the 0-edge count conclusive.

The earlier "rx_bytes=4" (WLAN-on) reading was debunked by an A/B test: the 2-4 bytes appear at probe-start, vary each run, and show up both WLAN-on and in sleep, so they are a power-down glitch. With the rx baseline reset after power-on, the clean result is rx_bytes=0, including for the valid EDL.

Reconciling the two: the research gives the mechanism (core-POR not completing is the symptom), and my prior logic shows it is not OS-reachable (no Windows driver enables a BT rail, so BT_VDD is board/firmware-supplied and already up, and there is no BT-specific PMIC LDO). Honest conclusion: BT core POR is not completing, below the OS, with clock, protocol, UART, GPIO, and rails all good.

Correction: "CTS rises on pin52" only proved the I/O rail (BT_IOVDD), never core POR.

I lifted my earlier safety limits. I built pmicpoke.ko (Crystal Cove regmap peek/poke, verified) and ran a comprehensive PMIC LDO hunt (pmic_hunt.sh plus pmic_hunt2.sh): I RMW-enabled each of the 23 Crystal Cove LDO regs (safe 0x5c/0x5d/0x60-0x6d; unmapped 0x5a/0x5e/0x5f; risky 0x5b-LPDDR/0x56/0x57/0x59-SOC/0x61-SFR/0x68-shared), then POR'd and probed BT after each and restored. All came back rx_bytes=0, and the system survived every poke (even DRAM/SOC, so those enable bits do not gate the live rails, which confirms the "unreliable" caveat). PMIC poking is conclusively negative - there is no BT_VDD rail to switch on. A cold boot (power-cycled by hand) made no change. I installed the long-missing WiFi-loss auto-reboot watchdog (wifi-reboot-watchdog.service, armed: it reboots ~60s after sustained gateway loss and arms only once WiFi is up, so no boot loop). Currently running: the WLAN-tie test (bt_monitor across an ath6kl reload). Tablet state: override removed (stock-serdev BTH0=serial0-0); btdlac and pmicpoke built and loaded; bdata=combo; watchdog armed; passwordless sudo on.

## UPDATE 30 (2026-06-27) - WLAN-side clock lever (0x140a4 BT_CLK_OUT_EN) built, tested, negative
I ran five lines of research: prior-art, BIOS/DSDT RE, HW/schematic, WLAN-side register, and WiFi. The decisive new lever came from the WLAN-side research: the AR6004 GPIO block CLOCK_GPIO at diag 0x000140a4, where bit0=BT_CLK_OUT_EN (drive the WLAN 26MHz out to BT), bit1=BT_CLK_REQ_EN, and bit2=CLK_REQ_OUT_EN (source: AR6kSDK hw4.0 gpio_athr_wlan_reg.h plus the Nest DFU ar6000_drv.c vendor write-site).

The debugfs reg_write/reg_addr are gated by an allow-list (diag_reg[]) that excludes the 0x14000 GPIO block, and the diag functions aren't exported. So I downloaded the exact linux-7.0.13 ath6kl source, added one allow-list entry {0x14000,0x14100} to debug.c, built ath6kl_core/sdio out-of-tree against the running kernel, installed it to /lib/modules/$V/updates/ (with an auto-revert failsafe), and rebooted. The patched ath6kl loaded and WiFi was fine.

The decisive read: 0x140a4 = 0x0000004a, which means bit0 (BT_CLK_OUT_EN)=0, bit1 (REQ_EN)=1, bit2=0. So the WLAN was not driving the clock out. I had predicted it would already be 1, which was wrong; this was genuinely the untried state. I set bit0 (0x4b), then all clock bits (0x4f); both persist through the BT POR (the firmware doesn't clear them). I ran a POR and probed BT (btdlac) at each setting, and got rx_bytes=0 and hostwake_edges=0 every time. The WLAN-side clock-out lever tested negative. (0x4024 RTC clock-out is read-only.)

The likely cause of the negative result: on this discrete two-chip board (FCC: AR6004X-9G3E + AR3002-BL3D, M.2 card, 3.3V-only), the AR6004 clock-out PAD that this bit drives may not be the board trace wired to the AR3002 clock-in (unverifiable without a scope), or the clock already reached BT via the bit1 request handshake.

That means every host-reachable lever is now exhausted, including the deep WLAN-side register (via a custom-patched driver nobody has ever built). Per the research, the BT POR fails behind the module's 3.3V boundary (BT_VDD is on-module, always up, and not host-switchable). The remaining deep long-shots (untested) are: (1) the AR6004 firmware HCI-UART bridge (hi_hci_uart_support_pins in host_interest, where the WLAN fw bridges HCI to the internal UART and drives BT reset; this needs fw-5.bin to contain the GMBOX bridge code, which is unconfirmed and needs fw disasm); and (2) setting 0x140a4 bit0 during BMI pre-fw-boot like the vendor does (low odds, since the bit persists at runtime so timing is unlikely to matter). The patched ath6kl plus failsafe are left installed (updates/); to revert, rm updates/ath6kl_*.ko, then depmod and reboot.

## UPDATE 30b (2026-06-27) - #2 BMI-time clock set also negative; clock lever fully exhausted

I patched ath6kl init.c ath6kl_configure_target() to RMW 0x000140a4 |= 0x7 via ath6kl_bmi_reg_read/write during BMI, that is, pre-firmware-boot, matching the vendor ar6000_drv.c BMIWriteSOCRegister timing. I rebuilt, installed to updates/, and rebooted. dmesg confirmed it ran: "ath6kl: BMI bt-clk: 0x140a4 before=0x4a after=0x4f". The firmware booted with the clock-out enabled from the start, but the runtime readback was still 0x4f. After a POR and probing BT (btdlac), I got rx_bytes=0 and hostwake_edges=0, which means the WLAN-side clock-out lever (0x140a4 BT_CLK_OUT_EN/REQ_EN/CLK_REQ_OUT_EN) is negative both at runtime and at BMI-time. The AR6004 clock-out pad this register drives is either not the board trace to the AR3002 (this is a discrete 2-chip board, so I cannot verify without a scope) or the clock already reached BT. The clock lever is closed.

The last remaining lever is #1: the AR6004 firmware HCI-UART bridge. The key find is that init.c ath6kl_configure_target() at line ~607 sets hi_option_flag with `(0 << HI_OPTION_FW_BRIDGE_SHIFT)`, so the firmware-bridge master switch is disabled. If fw-5.bin contains the GMBOX/HCI bridge (reverse-engineering in progress), enabling it means setting HI_OPTION_FW_BRIDGE plus hi_hci_uart_support_pins (the BT reset pin), hi_hci_bridge_flags, and hi_hci_uart_baud via BMI from the patched driver.

## STATUS (2026-06-27) - Last lever: the #1 firmware HCI/BT-reset bridge

Still in progress: I'm reverse-engineering the AR6004 fw-5.bin, disassembling it to answer whether it contains BT-reset / HCI-UART-bridge code that reads the host_interest hi_hci_* fields (offsets 0x88/0x8C/0xa0/0xa4/0xa8), and which AR3002 RESET pin hi_hci_uart_support_pins(0xa4 byte0, bit7=polarity) expects. I extracted the segments to fw_extract/ (ie3_FW_IMAGE.bin is the full ~45KB firmware). The strings were inconclusive - 296 strings over what is mostly binary code.

The decision tree from here:

- If the bridge/BT-reset code is present (plus a reset pin): patch ath6kl init.c, in ath6kl_configure_target(), changing line ~607 from `param |= (0 << HI_OPTION_FW_BRIDGE_SHIFT);` to `(1 << HI_OPTION_FW_BRIDGE_SHIFT)` (the FW_BRIDGE bit4, so hi_option_flag |= 0x10), and add `ath6kl_bmi_write_hi32(ar, hi_hci_uart_support_pins, <pin|polarity>)` (plus maybe hi_hci_bridge_flags / hi_hci_uart_baud). Then rebuild, install to updates/, reboot, and probe BT (btdlac). The theory is that the AR6004 firmware releases the AR3002 reset, which lets BT boot and respond on ttyS4, the path I already drive.
- If it's absent: the clock and bridge WLAN-side levers are all closed, which makes this an honest, comprehensive endpoint - every host-reachable path has been tried, and the blocker is proven internal to the module behind its 3.3V boundary.

Build pipeline: the source is linux-7.0.13/drivers/net/wireless/ath/ath6kl (with the patched debug.c allow-list and init.c BMI clock-set). Package it with tar -czf ath-7013.tar.gz -C linux-7.0.13/drivers/net/wireless ath; scp to the tablet; build with make -C /lib/modules/$(uname -r)/build M=athbuild/ath/ath6kl modules; install by copying ath6kl_core.ko and ath6kl_sdio.ko into /lib/modules/$V/updates/, then depmod -a and reboot.

Tablet state: the patched ath6kl is live in /lib/modules/7.0.13-arch1-1/updates/ (allow-list 0x140a4 plus BMI sets 0x140a4|=0x7; both clock variants tested negative). The safety nets are all armed: wifi-reboot-watchdog.service (reboots ~60s on WiFi loss), ath6kl-failsafe.service (reverts the updates/ ath6kl if WiFi is down 4min post-boot), and hung_task_panic=1 + panic=10 + the systemd iTCO RuntimeWatchdog (auto-reboot on kernel deadlock - validated, it already recovered a hang). bdata=combo (the WiFi ~37min drop is unfixed, a firmware-timer bug, and the Rigado fw is auth-gated). BTH0=serdev serial0-0 (override removed, so this is stock). btdlac.ko is at btdlacd/. Passwordless sudo is on. To revert the patched ath6kl: rm /lib/modules/$V/updates/ath6kl_*.ko, then depmod -a and reboot. The findings are in this file (UPDATE 1-30b). Five lines of research are done; nobody in 11 years has got this BT working on Linux.

## UPDATE 31 (2026-06-28) - Audit of every closed lever: did I miss anything? One genuinely untried lever

I re-audited every closed lever and found one thread I never pulled, the one UPDATE 18 explicitly listed as NEXT and UPDATE 19 pivoted away from before doing it: a firmware-mediated BT clock-sharing enable via WMI BTCOEX, never tried.

The evidence that it is untried: upstream ath6kl sends zero coex/bt config to the AR6004 firmware. `grep -c "WMI_SET_BTCOEX|WMI_SET_BT_" wmi.c` returns 0; wmi.c only handles inbound WMI_REPORT_BTCOEX_* events, and nothing in init.c/main.c/cfg80211.c sends a coex/colocated-BT/bt-status command. The firmware enum has them (WMI_SET_BT_STATUS_CMDID, WMI_SET_BTCOEX_COLOCATED_BT_DEV_CMDID, WMI_SET_BTCOEX_FE_ANT_CMDID, and so on), but mainline, being WiFi-only, never issues one.

Why it matters: the QCA6234 datasheet (UPDATE 17) says the BT 26MHz is shared from the WLAN block and that "BT clock sharing must be ENABLED after the WLAN block is initialized", which is a firmware-mediated enable. The Windows WLAN INF sets BtCoexEnable=1 (UPDATE 19). Every prior clock attempt was hardware-level: AR6004-held-awake (U18), the raw 0x140a4 BT_CLK_OUT_EN register poke (U30/30b), and HI_OPTION_FW_BRIDGE (2026-06-27). None of them told the WLAN firmware via WMI to turn on colocated-BT clock sharing. The 0x140a4 negative is consistent with the firmware owning that clock and overriding the raw poke, which makes the WMI path the datasheet-correct, untried way.

Independent corroboration (second RE pass, 2026-06-28): I reverse-engineered the two never-examined Windows companions - qcbtctrl.dll (user-mode, only a radio-on IOCTL_BUSENUM_SET_RADIO_ONOFF) and iaiouart.sys (host LPSS UART, standard M/N divider, no BT clock/reset). So the missed step is not on the Windows host or BT-driver side, which is consistent with it being on the WLAN-firmware side.

The deciding unknown, which gates whether this lever can matter at all: does this module have its own BT crystal? The ramps_*_26/_40 firmware implies some AR3002 configs have a 26/40MHz xtal, which would mean it wouldn't need the WLAN clock and the lever would be moot. UPDATE 19 flagged that "clock-from-WLAN may be an integrated-QCA6234 over-generalization for a DISCRETE board." FCC internal photos of the Foxconn T77H470 / DW1537 module would settle xtal-present versus not (a follow-up task).

Next experiment (if there is no BT xtal, or to test regardless): reverse-engineer the vendor ath6kl (AR6KSDK / Nest DFU ar6000) or the Windows AR6KNWF81 WLAN driver for the exact coex/clock-sharing-enable WMI command and payload; patch ath6kl to send it at bring-up (after WLAN init, before or around BT POR); reboot; probe BT. This is the one Linux-reachable lever the prior sweep identified but never actuated.

A fourth pass (2026-06-28) added corroboration and a refinement: the 0x140a4 / CLOCK_GPIO / BT_CLK_OUT_EN naming comes from GBATEK's RE of the Nintendo DSi (AR6002-class), never an AR6004 source, so UPDATE 30's negative may have poked a register that does not exist or does not mean that on AR6004 silicon, which weakens that closure - the clock is not cleanly closed. ath6kl deliberately does no host-side ref-clock control on AR6004 (clock-init is guarded to AR6003_HW_2_0/2_1_1 and skipped for AR6004, with the comment "no need to control 40/44MHz clock on AR6004"; hi_refclk_hz was made conditional "for ar6004 hw3.0"). The AR6004 datasheet LM80-P0598-10 says the WLAN-to-BT clock sharing is conditional - "supported PROVIDED AVDD33 is available", and it flows only while WLAN is in its ON state (the crystal is disabled in SLEEP). So the enable is firmware/strap-level, not a host register, which reinforces the WMI-coex path as the right untried lever. On the pessimistic branch, it may be a die-to-die strap the host cannot force beyond keeping WLAN awake - and "WLAN forced ON + powersave off, probe BT concurrently" was already done in UPDATE 18 (negative). So if the WMI-coex enable also does nothing, the missing-clock theory is genuinely exhausted from Linux.

## UPDATE 32 (2026-06-28) - A named mechanism for "powered but mute": the HOST_OFF power state

The AR4100 datasheet (MKG-16487 Ver 5.0), the closest public AR600x sibling to the AR3002, documents a cold-boot power state that is a near-exact symptom match.

HOST_OFF (Table 3-1, verbatim): "Only the host interface is powered on - the rest of the chip is power gated OFF." It adds that "The host instructs the [chip] to transition to WAKEUP by writing a register in the host interface domain." The reset sequence 3.3.2 says that after CHIP_PWD_L deassert the chip enters HOST_OFF, and then "1. host writes the enable bit in the SPI_CONFIG register... 2. brings the chip to a WAKEUP transient state... 3. the ROM code executes."

This means the host-interface (UART) block is powered and drives CTS while the CPU/ROM stays power-gated and held in reset until a domain-specific ENABLE register write transitions HOST_OFF -> WAKEUP -> ON. That enable write sits below the HCI layer, which is exactly why every opener I tried (FC0C, FC04, FC1E, FC00, HCI-Reset) was mute: each was sent to a CPU that had not yet been woken. This is the named hardware mechanism for the wall, and it is sharper than the earlier "BT_VDD core rail" framing.

The FORCE_HOST_ON_L strap bypasses the handshake ("assert during CHIP_PWD_L deassertion"), but the DLAC3002 DSDT exposes only pin52 (power-down) and pin53 (wake) - there is no third force-host-on GPIO, so any AR3002 equivalent is board-strapped, not Linux-reachable.

The 32kHz sub-lever is closed. The chip self-generates it (internal ring oscillator, AR4100 sec 2.7/3.5.2); Bay Trail's pmc_plt_clk only provides 19.2/25MHz and could never supply 32kHz, so the earlier force-all-6-clocks test was moot for 32k; and the Crystal Cove PMIC exposes no clock cell at all (intel_soc_pmic_crc.c has zero clk/32k). Linux can therefore neither gate nor supply a 32kHz.

The module is the DW1537 / Foxconn T77H470 / HP 691921-005, which is an AR6004X-9C3E plus an AR3002-BL3D, FCC PPD-QCSNFA282. The schematic, block diagram, and theory-of-operation are all FCC-confidential, and the internal-photos exhibit shows a socketed card with dies plus any crystals under the RF shield (not visible), so the "does this module have a BT crystal?" question remains unresolved from public docs.

Strategically, the missing step is a pre-HCI WAKEUP/ENABLE write, and it is not in the qcbtuart BT driver (the cold-start RE traced it completely: the first command is FC0C, with no earlier register write) nor on the host side of the WLAN driver. So it must be done by firmware: either (a) the WLAN firmware acting on a coex/colocated-BT trigger, which is the WMI-coex lever (UPDATE 31, RE in progress) - the "WAKEUP enable" may be what that command actually does - or (b) Dell UEFI asserting a radio/BT enable for Windows that Linux never does, which is the hidden UEFI setup EFI variable lever (genuinely untried, and I nominate it as the most promising since it fits the HOST_OFF model directly). Both are Linux-reachable to investigate; (a) is executing, and (b) is the strongest untried parallel.

## UPDATE 33 (2026-06-28) - Exact QCA6234 datasheet (LM80-P0598-12) validates the WMI clock-share lever

This is a primary source for the exact combo part on this device, and it resolves both the crystal question and the clock mechanism.

- The 26 MHz BT reference is in-package, shared die-to-die from the WLAN block; there is no dedicated BT crystal. Sec 4.6 states, verbatim: "The BT block is configured for 26 MHz reference clock frequency. The clock source is provided to BT internally from the WLAN block on demand from BT_CLK_REQ. The WLAN block must be initialized before BT clock sharing is enabled." Sec 3.9.1 notes that the in-package 26 MHz "is powered off in SLEEP, HOST_OFF, and OFF states." This resolves UPDATE 31's deciding unknown: the module has no BT crystal of its own, so BT depends on WLAN clock sharing, which means the WMI clock-share-enable lever is not moot. Enabling BT clock sharing is a discrete step, exactly the WMI-coex enable that mainline ath6kl never sends (UPDATE 31).
- Sec 3.6 says "The Bluetooth function should be powered down/reset whenever WLAN is reset because it derives its clock from WLAN." Table 3-1 adds "WLAN must be initialized prior to Bluetooth initialization and use." This matches the symptom exactly: BT_IOVDD powers the always-on UART pads (which drive CTS), but with no 26 MHz the BT PLL never locks, so the RISC core never executes ROM, leaving rx:0 and no host-wake.
- The rails question is closed again. Sec 4.8 shows BT_VDD (1.8V core, Table 5-2) is gated by the BT_PWD_L pin (pin52, which I drive high), with POR "after BT_VDD has stabilized," not by an unflipped PMIC rail. The module uses the shared +3V3A_WIFI and V1P8A rails, with no BT-only rail (internal-regulator SKU), so no disabled core rail exists to flip. This re-confirms U22/U24.
- The 32k and pmc_plt_clk paths are closed again too (internal ring oscillator; plt_clk is only 19.2/25MHz).
- Convergence (passes 3, 4, and 5 plus my own audit): the gate is the WLAN-die 26 MHz clock sharing, and "WLAN ON" alone is insufficient (UPDATE 18 held it awake and it was still mute), so an explicit "enable BT clock sharing" step is required, which mainline ath6kl omits. The WMI-coex command (UPDATE 31, the WMI RE that found the exact ID and payload) is the Linux-reachable mechanism to set it. This is now the strongest, primary-source-backed lead of the whole hunt.
- Residual (pass 5, modest odds, low priority): pinning WLAN truly on and driving an EN-first, reset-released-last GPIO POR edge inside the WLAN-ON window. This is largely covered by UPDATE 18 (WLAN held awake and BT POR'd); the pass itself notes that the end-state equals bt-correct3 (already failed), and the datasheet models BT power and reset as a single pin (BT_PWD_L, "BT_DISABLE not used, tie to ground"), so the 2-pin EN-versus-RESET ordering may not correspond to real silicon.

## UPDATE 34 (2026-06-28) - WMI btcoex colocated-BT lever tested on hardware: broke WLAN init (negative)
My WMI reverse engineering turned up the exact spec: WMI_SET_BTCOEX_FE_ANT_CMDID(0xF02A)=5 and WMI_SET_BTCOEX_COLOCATED_BT_DEV_CMDID(0xF02B)=5, sent after WMI-ready in the vendor ar6000_init. The important caveat is that these are RF/antenna/arbitration config, not a clock-enable (the colocated-dev enum even includes own-crystal BT parts); the 26MHz share is a hardware handshake (BT_CLK_REQ strap, WLAN-ON gated), not a host command, and the Dell AR6KNWF81.sys never writes the clock register. I decided to run it anyway as the clean empirical close.

I implemented it by patching wmi.c (a new ath6kl_wmi_set_btcoex_colocated that calls ath6kl_wmi_btcoex_u8 for the 1-byte sends), adding the wmi.h prototype, and adding the init.c call in __ath6kl_init_hw_start() after the wlan_params loop. It built clean (I verified the string in the .ko), I armed the failsafe, installed, and rebooted.

The result: the tablet did not return to the network ("No route to host"), so WLAN init failed/wedged with the coex commands active. ath6kl-failsafe (armed) reverted the patched ath6kl to stock and rebooted. In other words, the colocated-BT coex commands destabilized WLAN rather than waking BT - negative, matching the prediction.

Forensics (journalctl -b -1, after the clean failsafe recovery) resolved this to a semantic firmware crash, not an implementation bug. The sends succeeded ("EXPERIMENTAL btcoex ... FE_ANT(0xF02A)=5 r=0 COLOCATED(0xF02B)=5 r=0") and then the firmware went "ath6kl: wmi is not ready" and ath6kl dropped into a crash-recovery loop for the full 4 min (send btcoex, fw dies, recovery_enable resets, re-init, wmi-not-ready/timeout, retry, send btcoex, fw dies, and so on). WiFi never stabilized, the failsafe reverted to stock and rebooted, and the tablet recovered clean (updates/ empty, WiFi OK). So the AR6004 fw 3.5.0.349 crashes on the colocated-BT coex command (value 5): the send is correct, but the firmware chokes.

One residual remains, single and bounded rather than a value-sweep: value 5 crashed before BT could be probed, so the clock hypothesis was never cleanly tested. chromiumos wmiconfig uses AR3002=4 (vs GBATEK 5). One clean retry with COLOCATED=4 only (dropping FE_ANT, the likely RF-disruptor) would either (a) be accepted, giving a clean BT probe and a definitive answer, or (b) crash again, meaning the command path is fundamentally incompatible and btcoex is fully closed. Per the overwhelming evidence (the clock is HW-gated via the BT_CLK_REQ strap; the binary RE shows arbitration, not clock-enable; the Dell driver never writes the clock reg) it will most likely not wake BT. The broader WLAN-clock-share lever is now very thoroughly closed (AR6004-awake U18, 0x140a4 all-bits U30, FW_BRIDGE U-yesterday, WMI-coex U34). The next untried lever is the Dell UEFI hidden Setup EFI var (nominated earlier; it fits the HOST_OFF model).

Value-4 clean test result (2026-06-28): COLOCATED-only=4 was accepted by fw 3.5.0.349 ("EXPERIMENTAL btcoex COLOCATED-only(0xF02B)=4 r=0", no crash, WLAN stayed up - unlike value 5). I probed BT with WLAN forced ON (power_save off) in the awake window: the btdlac result was rx_bytes=0 hostwake_edges=0, no /sys/class/bluetooth, WiFi still OK. So declaring the colocated AR3002 to the WLAN firmware does not enable clock sharing or wake the BT. The WMI-coex lever is cleanly and definitively closed (negative), matching the binary RE (arbitration, not clock-enable). The entire WLAN->BT clock-share mechanism is now exhausted from Linux. I left the tablet on the harmless btcoex-v4 no-op build (WiFi OK); to revert, rm /lib/modules/$V/updates/ath6kl_*.ko + depmod + reboot. The active lever now is the UEFI Setup-var (RE running).

## UPDATE 35 (2026-06-28) - UEFI BT-enable Setup var found, not the discriminator (~closed) + new DXE-RE lead

I unpacked the Dell BIOS 5830A16 with the uefi_firmware Python tool to get at the AMI Setup IFR (bt-re/bios/...), and found the BT-enable item:

- It is EFI variable "Setup", GUID EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9, at byte offset 0xCB, where 0x01 means Enabled (the factory default) and 0x00 means Disabled. The QuestionId is 0x15, and the help text reads "Disabled = the internal Bluetooth device is off and not visible to the OS." Its siblings in the varstore are WLAN@0xD7, WWAN@0x2B/0x124, and NFC@0x121.
- This is not a runtime Linux lever. The AMI Setup var is NV+BS only (no RUNTIME_ACCESS), so it is hidden from efivarfs under a running OS; only the F2 menu and pre-ExitBootServices tools (setup_var.efi, grub-mod-setup_var, RU.efi) can reach it. And it is already 0x01. Because it is static, it is the same byte in Windows and Linux, so it structurally cannot be the Windows-works/Linux-mute discriminator. That leaves the firmware Setup-var lever roughly closed.
- I re-confirmed the ACPI against DSDT.dsl: BTH0 (DLAC3002) has no _STA/_PS0/_PS3/PowerResource/OSYS reference, only the 115200 UART, the host-wake IRQ, and 2 GPIOs. OSYS is consumed only by gfx/thermal/USB, never by BT, so there is no OS-discriminating BT branch (this reproduces U23).

Two residuals remain:

(1) A cheap BIOS-menu check, which is not verifiable from Linux since the var is hidden at runtime: tap F2 at boot and confirm Bluetooth reads "Enabled". This is near-certain given the factory default, but if it read Disabled, enabling it there could be the actual fix, since the help text "off, not visible to OS" matches the mute symptom exactly. I checked this on 2026-06-28. Confirmed 2026-06-28: the BIOS shows Bluetooth Enabled (along with Camera/WAN/WLAN/Media-Card Reader). So the bit is on yet BT is still mute in Linux, which closes residual (1). I also saw "UEFI Network Stack" Disabled and "XHCI Controller" Enabled, both irrelevant to the UART internal BT (PXE/boot-time UEFI networking and the USB3 host controller respectively); I left them as-is.

(2) A new heavy thread, now launched: reverse-engineer the DXE/PEI module in the BIOS that consumes Setup offset 0xCB. If the UEFI asserts a GPIO, PMIC rail, or clock to power-enable BT when 0xCB==1, that would reveal the exact hardware enable, possibly a pin or rail that is not in the DSDT and is drivable from Linux. This is the direct test of the "UEFI asserts a BT enable Linux never does" hypothesis, and the last untried mechanism. The caveat is that if the enable persists, it would be on in Linux too, which makes it low odds as a discriminator, but it could still expose the real BT power path.

## UPDATE 36 (2026-06-28) - DXE/PEI RE of the Setup[0xCB] consumer complete: answer (c), UEFI takes no BT hardware action
I reverse-engineered the Dell 5830A16 BIOS with radare2 6.1.8 plus r2ghidra. This closes the "UEFI asserts a BT enable that Linux never does" hypothesis from the firmware-code side. Here is what I found:

- The BT-enable byte (Setup offset 0xCB) and its WLAN sibling (0xD7) are consumed by exactly two hardware-capable modules: DxePlatform (GUID 056e7324, which does GPIO) and AcpiPlatform (f0f6f006, ACPI/SSDT, no GPIO). In both, 0xCB and 0xD7 appear only in the shared Setup-var-to-policy-struct copy (`mov cl,[esp+0xCB]; mov [ebx+FIELD],cl`) into a stack-local struct. It is a verbatim copy with no branch and no GPIO/PMIC/clock action. The struct feeds ACPI and policy callees, not hardware.
- DxePlatform's GPIO is driven by static const pad tables with constant loop bounds (2 and 18), so it cannot be BT-gated by construction, and the decoded pads do not include the BT pins. The tables (baked image values) program pads 65-72 and 86 (CONF0=0x20038E10, +8=0x06) via 0xFED0C000; the 2-entry table's byte-encoded pads decode to 0x47(71) and 0x41(65), neither of which is 0x58(pin52) or 0x5c(pin53), nor the BT-UART pads. The marshalled BT byte, being stack-local, never reaches these tables.
- PlatformPmic (81846a76) reads "Setup" but has zero references to 0xCB or 0xD7 and zero GPIO base, which means the Crystal Cove PMIC takes no BT-gated rail or LDO action. That is a direct code-side refutation of the BT_VDD-core-rail hypothesis.
- The SCORE GPIO base 0xFED0C000 appears in only DxePlatform and SbPeiAfterMemory (a PEI .te). I did not exhaustively decode SbPei's GPIO tables (its lone "0x580" is a coincidental I/O-PORT immediate `mov edx,0x580; out dx,eax`, not a pad write), but that gap is moot: the BT byte is marshalled to a stack-local and never reaches any GPIO write, so nothing POST does to any pin is BT-gated regardless, and since the tablet is BT-enabled, any POST pin action is already inherited by Linux and is not the fix. (The absolute BT pad registers 0xFED0C580 and 0xFED0C5C0 appear in no module, but that is a weak signal since GPIO code computes base+pad*0x10 at runtime, so it is not load-bearing.)
- The IFR "Disabled = off and not visible to OS" is Dell boilerplate (the same text appears on WLAN and WWAN); "not visible" is either a POST-time ACPI omission or a GNVS flag (I cannot determine which, since my DSDT dump is BT-enabled-only), meaning it is software visibility, not a power action. The empirical clincher is that this tablet is BT-enabled, so whatever POST does when Enabled is already inherited by Linux and demonstrably is not the fix.

So there is no BT-gated GPIO, PMIC, clock, or rail anywhere, and no new Linux-reachable lever. This confirms and reinforces U22-35: the residual gate is internal to the QCA6234 module (WLAN-die 26 MHz clock-share / HOST_OFF core-POR), not an OS-reachable pin, rail, or clock. The UEFI-Setup-var/firmware-lever family is now fully closed, both by code and empirically. Key addresses: DxePlatform main fcn.00010e66, Setup-marshaller fcn.00011ec8, GPIO fcn.00010c9d and fcn_gpioapply@0x10daa (tables @0x10a6c/0x10aa0); AcpiPlatform marshaller fcn.0001337d (BT->[ebx+0x59]), caller fcn.00011ae7. RE environment: radare2+r2ghidra (brew); BIOS at bt-re/bios/rom_out/.

## UPDATE 37 (2026-06-28) - Major reframe: the card is discrete (AR3002 QFN + AR6004 BGA + TCXO), not an integrated QCA6234
Re-reading the FCC internal photos (photos24/img-010-028.jpg, img-009-026.jpg), the card is an M.2 2230 with two discrete Atheros packages - an AR3002-BL3D (5x5mm 40-pin QFN) plus an AR6004X-9C3E (BGA) - and a "T260" TCXO can, a dedicated on-board oscillator. It is not a single-die QCA6234 LGA. This corrects the inherited premise: passes 3, 4, and 5 all reasoned from the QCA6234 integrated datasheet ("26MHz in-package, die-to-die, unprobeable"), but on a discrete card the BT 26MHz reference is a chip-to-chip PCB trace to AR3002 XTAL_OUT (pin 3), the handshake is CLK_REQ (pin 12), and there is a discrete TCXO - all real, probeable pins and parts. So the "unreachable die-to-die" wall was a datasheet mismatch; the clock path is physically accessible, and the discrete clock-forward may be register-controllable, which raises the odds on the #1 register-RE pass (RE running).

AR3002 QFN pinout (LM80-P0598-9 Rev B): XTAL_OUT=3, PWD_L=4 (reset), UART_TXD=10, UART_RXD=11, CLK_REQ=12, RTS=15, CTS=16; rails VDDIO 14/23, VDD12 9/22, LDO_IN 39. The probe guide is ready: signals and pins, capture procedure, interpretation table, and safety.

The decisive hardware measurement: with the chip powered and woken, send GET_VERSION (01 1E FC 00) on TXD, watch RXD, and scope XTAL_OUT (pin 3). If CLK_REQ is asserted but there is no 26MHz at pin 3, then WLAN never forwarded the clock, which confirms the gate (the TCXO cross-check separates this from a dead board reference); if 26MHz is present but RXD is idle, the chip is clocked but the ROM is not running (deeper silicon).

The honest hardware bar: reading 26MHz needs a >=100MHz scope (a 24MS/s logic analyzer can't - Nyquist is 12MHz); logic is 1.8V; and the QFN is under a likely-soldered shield can, so reaching it may need hot-air removal (the biggest risk). The Tier-2 fallback is to probe the BT UART at the M.2 edge / ttyS4 (no shield removal, sees BT-TX/RX but not the clock). The M.2 2230 edge pinout is not public, so I would find it by continuity from the QFN.

## UPDATE 38 (2026-06-28) - clock-register RE: the register-level clock-forward is conclusively closed, pivoting to reset/firmware
I went back to primary sources for this: the AR6004 hw4.0 vendor headers, Dell's ar6knwf81.pdb 101-define catalog, the ar6000_drv.c write-sites, and the AR3002/AR6004 datasheets.

CLOCK_GPIO 0x000140a4 is the sole register in the entire AR6004 SoC space that carries BT+CLK fields (BT_CLK_OUT_EN / BT_CLK_REQ_EN / CLK_REQ_OUT_EN, exactly 3 bits, with no hidden 4th). U30 wrote 0x4f, which fully exercised it, so the negative result is conclusive at the register level. On top of that, the vendor gates this write to AR6003 only (ar6000_drv.c: "AR6004 has no need for a CLOCK_GPIO register"), which means on the AR6004 it is not even the forwarding control. So no diag-writable register exists that can force the BT clock-forward. The analog PLL/XTAL/TOP/SYNTH registers do exist (this corrects a prior draft), but they belong to the WLAN die's own clock/RF front-end; I examined and rejected them because they are unsafe to poke (they would brown out WiFi) and have no BT linkage.

The AR3002 datasheet (LM80-P0598-9 sec 3.5) is clear that the AR3002 receives 26MHz on XTAL_OUT (pin3) from an external source and asserts CLK_REQ (pin12) to request it. If that were sourced from the AR6004, the forward would be an automatic hardware handshake gated only by power-state, and CLOCK_GPIO's 3 bits are the only software surface, which is already negative. On this discrete card with a dedicated TCXO, the 26MHz most likely comes straight from the TCXO, so the premise that "the AR6004 forwards via a writable register" is moot by construction.

The strategic upshot is that the clock-via-register lever is dead. If the AR3002 is in fact clocked (TCXO-direct being likely), then the muteness is a reset / firmware / init problem, which is exactly the path the integrated-die clock-assumption wrongly deprioritized. Next up: a discrete AR3002 cold-start/reset (LM80-P0598-9) plus a clean kernel ath3k, pending the topology analysis's reset recipe and topology verdict.

## UPDATE 39 (2026-06-28) - topology analysis: verdict (b), but the clock is not the live gate, so software is genuinely exhausted

My clock topology verdict is (b): the TCXO feeds the AR6004, which forwards 26MHz to the AR3002 over the CLK_REQ hardware handshake. My confidence that it is not (c) is high - FCC photo img-010-028 shows the T260 TCXO sitting by the AR6004 and the antenna, opposite the AR3002 QFN, and there is no resonator at the AR3002, so it does not have its own crystal - but my confidence in (b) over (a) is only moderate. This reconciles U17/33, since an automatic die-to-die handshake with zero driver strings is exactly what (b) predicts, and it withdraws U19's claim that the AR3002 uses its own reference.

The key inversion, and the important part, is that (b) does not mean I should chase the AR6004 forward: that lever is closed (U38). Under (b), WLAN being awake means the 26MHz is already present at the BT POR edge. U18 did exactly that - it held WLAN awake and POR'd the BT - and it was still mute, so the data I already have shows that the clock is not the live gate, regardless of whether the topology is (a) or (b). Re-running software clock levers is pointless, per the analysis.

The discrete reset and cold-start path (AR3002 LM80-P0598-9 sec 3.8/3.3/3.1) offers no host-actionable difference from the qcbtuart D0Entry I already replicated: a single PWD_L (pin52) LOW->HIGH POR once VDDIO and VDD12 are stable, with no datasheet-mandated boot baud (115200 is fine). The one discrete precondition, off-chip 26MHz live within 2ms of CLK_REQ at POR, is environmental - it depends on the AR6004 - not a host action.

There is also something new that reinterprets but opens no lever: AR3002 Table 2-3 note 2 says HOST_WAKE is disabled by default until firmware enables it, which means the earlier "IRQ70=0 edges" is not proof the CPU is dead; TXD silence (rx=0) is the only real signal.

On other devices, there is exactly one AR3002-over-UART Linux success (NXP thread 473175, an i.MX6 BSP): "loaded the ar3k firmware + enabled the BT enable GPIO. It works for me." That enable line is host-wired on the i.MX6 board; on the DV8P5830 it is not host-reachable, since the DSDT exposes only pin52/53, the IRQ, and the UART, with no BT power resource (U9/35). This exact module on Linux is a documented failure (studioteabag, kernel ath3k docs); every web ath3k-UART success is a USB AR3011/3012, which is not comparable. Thread 388034 shows the same silent GET_VERSION on i.MX6, and it is unresolved.

Both the clockreg and topology analyses are primary-source and now incorporate the discrete card, and they converge: the Linux/software space is genuinely exhausted. The decisive remaining diagnostic is a hardware read at the AR3002 QFN - is 26MHz present on pin3, does TXD emit? The cheapest decisive step is a roughly $15 USB logic analyzer, not a scope, for the Tier-2 UART-edge probe with no shield removal: does the BT chip transmit any byte? The remaining pure-software shots are very-low-odds refinements the research advises against.

## UPDATE 40 (2026-06-28) - "keep trying software" shots: EN-first/reset-last was negative; btenable found a 3rd BT net (GPIO_S0_15)
I decided to keep trying pure software, with two shots.

Shot 1 was an EN-first / reset-released-last ordering. I patched btdlac to assert wake/EN (pin53) HIGH and let it settle first, then release power-down/reset (pin52) LOW->HIGH last so the POR edge came last, and ran it with WLAN forced awake (power_save off plus flood). The result was rx_bytes=0 across all bauds, which is negative. This matches U39: the AR3002 has a single PWD_L reset pin, so EN-vs-reset ordering does not map to the silicon.

Shot 2 was a hidden BT-enable-line reverse-engineering effort, and the answer is (c): pin52/53, IRQ70, and the UART are the entire host-reachable BT surface. There is no ACPI EC at all (Bay Trail-T has none), which rules out an EC-enable at the root; there is no PMIC BT rail (U22/36); and no parent _PS0/_INI GPIO gates BT (URT1._PS0 is only an LPSS clock-gate, and SDHB._PS0 is WFD3, the WiFi module power pin20, not BT). The i.MX6 "BT enable GPIO" is the AR3002 PWD_L, which is my pin52 and is already driven; thread 388034 names it BT_PWR_L/rfkill. There is no un-driven AR3002 pin missing.

There is one genuinely-new residual that is untried. The schematic (ZPJA0, JWLAN1 ACES combo connector) shows a third BT net beyond pins 52/53: connector BT_DEV_WAKE, originally named BT_REG_ON (the schematic changelog shows it was renamed 2013/07/09). It strap-couples via R50 to net I2S_1_COMBO_RXD, then via R26 to SoC pad I2S1_RXD / GPIO_S0_15 (annotated "FOR BT"). "BT_REG_ON" is a classic BT regulator/clock-request enable. The caveats, calibrated: it crosses 2 strap resistors (R50/R26 are the "reserve circuit" class and may be unstuffed on this board); the net otherwise carries live PCM SCO audio (mutually exclusive with a static enable); and if BT_DEV_WAKE is a module output, driving it contends. I predict low odds, but it is untried and I have never driven this pin. Next: remux the Bay Trail SCORE pad GPIO_S0_15 from the I2S1 func to GPIO output via padmmio, drive it HIGH (assert BT_REG_ON), power-cycle BT, and GET_VERSION. Snapshot and restore the pad.

## UPDATE 41 (2026-06-28) - BT_REG_ON (gpio-15) lever tested at both polarities, no change; pristine state is already high
I drove the newly-found third BT net (BT_REG_ON / I2S1_RXD = gpio-15 = pad-84, CONF0 0xFED0C540) through raw padmmio, with WLAN forced awake and the BT power-cycled (btdlac) on each attempt:
- gpio-15 OUTPUT LOW (via gpioset; padmmio VAL=0x1/0x5 also read low): rx_bytes=0.
- gpio-15 HIGH (remux to GPIO func0, flip the pull to UP 0x2003cc80, and input-enable, so the pad confirmed "out hi"): rx_bytes=0.

Both polarities were silent. On these SCORE pads the SoC output-high is level-stuck - a pull-down pad reads low when "driven" high - so I reached HIGH by using the pull-up to let the pad float high, confirmed in /sys/kernel/debug/gpio.

The important finding is that pad-84 is pristine "out hi mux:1" on a fresh boot, meaning BT_REG_ON is already high in normal operation (the I2S function/module holds it high). So the BT regulator/enable is already asserted; this is not a missing host signal, and changing it either way does nothing. That confirms btenable's read (the net is in its natural state, straps likely unstuffed) and the convergent conclusion: the AR3002 is powered and enabled but its CPU is not booting (clock/silicon), not gated by an un-asserted host line.

Both self-directed "keep trying software" shots came back negative (EN-first/reset-last in U40, BT_REG_ON here in U41). The genuinely new lever that re-examination surfaced is now exhausted. The Linux/software space is out of identified levers; the decisive remaining diagnostic is a hardware read (a logic-analyzer probe on the UART or a scope on the 26MHz), which I don't have.

## UPDATE 42 (2026-06-28) - tty/serdev/dw8250 re-examined; TXD-idle-low retired (artifact); FC04 opener negative
I came at this from a new angle: can't I set anything in /sys/class/tty/ttyS4/power? The tty/PM angle closed several threads, and the net result is that every host-side and command-level Linux lever is now exhausted. I fixed the WiFi ~37min drop this session (ath6kl disconnect_timeout 10->60), so BT now runs on a stable platform - yet a BT probe with WiFi up and associated (5GHz, -51dBm) is still rx:0, which means WLAN association alone does not enable any BT clock-forward.
- /dev/ttyS4 does not exist. ACPI \_SB.URT1.BTH0 (DLAC3002) enumerates as a serdev child, so the serial core makes serial0 (controller) plus serial0-0 (BT client) and suppresses the char dev. serial0-0 is unbound (MODALIAS=acpi:DLAC3002:, /sys/bus/serial/drivers/ empty), because no in-kernel serdev driver matches DLAC3002 - only my btdlac. The parent HSUART 80860F0A:00 with runtime_status=suspended is benign (idle, no driver open); the autosuspend_delay_ms -EIO just means use_autosuspend is false. No tty/PM knob here boots the chip.
- dw8250 is already bound: /sys/devices/platform/80860F0A:00/driver -> dw-apb-uart, base_baud 2764800 (= 44.2368MHz/16 LPSS clk). The dmesg "is a 16550A" is only the 8250-core port autodetect string. That makes UPDATE 11(B)'s proposed fix "make 8250_dw bind URT1 for controller power-on" moot: the correct LPSS driver is already bound, and serdev/tty open does pm_runtime_get (the IOCTL_SERIAL_POWER_ON equivalent), which I confirmed by runtime_status going suspended->ACTIVE on open.
- I am retiring TXD-idle-low (UPDATE 10's last lead) as a stale-register artifact. padmmio reproduces U10 (RTS/CTS pad VAL bit0=HIGH, TXD/RXD=LOW). But with btdlac holding the port open, the controller resumed (active), and the dw8250 having just transmitted a full baud sweep (so TXD must toggle and idle high), the TXD pad VAL stays frozen at 0x02 (LOW), identical to the closed/suspended baseline. The Bay Trail GPIO VAL.LEVEL bit does not track a function-muxed pad (OUTPUT_EN is disabled because the UART owns the pad), so the LOW read is meaningless rather than a real idle-low. The host UART is healthy; "TXD can't frame, so the chip goes mute" is false.
- I re-decompiled the DSDT (iasl): BTH0 declares only UartSerialBusV2(0x1C200=115200,8N1,FlowControlHardware) plus Interrupt(0x46=GSI70,Edge,ActiveLow,Wake) plus 2 GpioIo(pin52,pin53; PullUp,OutputOnly). There is no _PS0/_PR0/_RST/_DSM/_INI. This re-confirms U9: no hidden ACPI power/reset, and FlowControlHardware=CRTSCTS is canonical (already run by bt-correct3), so the raw-MMIO bt-correct3 power-on is the full ACPI contract.
- The FC04 disable-sleep opener (UPDATE 11's "one remaining cheap experiment") came back negative. I added c_fc04 (01 04 FC 01 00) plus the faithful Windows order to btdlac: FC0C -> FC04 -> 0C1A -> 1001 -> FC1E @115200. The result was rx_bytes=0, hostwake_edges=0, no-hci. That matches U11(C): command #1 goes unanswered, so later commands are inert.
- A minor correction to "fe:0 / never transmits anything": at the port-open/power-down edge (pin52 driven LOW=off), btdlac RX logs a burst with a deterministic first byte 0x02 plus a random second byte (92/12/f2/fe across 4 runs), which is a UART line-collapse glitch, not a chip HCI reply (a real reply would be deterministic and valid HCI 04 0E..). The code already discards these, so this is substantively unchanged.
In summary, the host-side levers (baud, mux, RX-path, dw8250/controller-power, TXD-idle, ACPI resources, flow control, host-wake IRQ) and the command-level ones (GET_VERSION/EDL/HCI-Reset/FC0C/FC04 plus faithful order) are all closed. The chip's UART I/O block is alive (it drives CTS and glitches on power edges) but its CPU/ROM does not boot. The only remaining live-mechanism theory is the AR6004->AR3002 reference-clock forward (with no clock, the CPU can't run), and it is not closed because the specific AR6004 clock-forward enable (a diag-window register or WMI) is unidentified (0x140a4 CLOCK_GPIO and BTCOEX were negative per U30/38, and WLAN-associated alone does not enable it, as tested today). The next real avenue is AR6004 clock-forward register RE (Phase 1) and/or discrete-module clock topology (does the on-board TCXO clock the AR3002 directly, or only via the AR6004?), then one targeted ath6kl diag-window poke. Tools: btdlac.c (FC04 plus faithful order); /tmp/DSDT.dsl on tablet; padmmio reads.

## UPDATE 43 (2026-06-28) - live AR6004 clock-block dump: CLOCK_GPIO enables are firmware-default-on; register lever closed

I had a new idea: dump the AR6004 clock block, then reverse-engineer it. I used the patched ath6kl diag window. One gotcha: the bulk reg_dump ("All diag registers", meaning reg_addr unset) crashed the tablet - the allow-list includes {0x540000, +256KB, "RAM"}, which works out to 65536 single SDIO diag-reads in a kernel loop, and that wedged the SDIO/fw. The watchdog cleanly rebooted and WiFi auto-recovered, a nice validation that the WiFi fix survives a crash-reboot. The safe method is to echo <addr> > reg_addr (4-aligned and in the allow-list) and then cat reg_dump, which returns one register. I read the whole GPIO/Clock block 0x14000-0x14100 on a fresh boot, one register at a time, and WiFi stayed up. I saved ar6004-clock-block-dump.txt.

The key finding: CLOCK_GPIO 0x140a4 = 0x4f on a clean boot, which means bits 0,1,2 (BT_CLK_OUT_EN/BT_CLK_REQ_EN/CLK_REQ_OUT_EN) are all set by firmware default. So the AR6004 fw already enables BT clock-out/forward out of the box; the U30 "write 0x4f" wrote the value it already had (a no-op), so the U30 negative merely reflects the default state (enables on), leading to BT mute with nothing left to turn on. This empirically confirms the register-RE deliverable: CLOCK_GPIO 0x140a4 (exactly 3 BT bits) is the sole BT-named register in the AR6004 space (from 3 primary sources: hw4.0 SDK headers, the ar6knwf81.pdb d_* catalog, and vendor write-sites); there is no second BT-clock register, and the analog PLL/XTAL/TOP/SYNTH regs are the WLAN's own live RF/clock front-end (unsafe, with no BT linkage). So the clock-forward register lever is closed, both empirically and by primary source.

The implication: the forward-enables are on by default and BT is still mute, which weakens the "AR3002 CPU has no clock" theory. Either (a) the AR6004 sources the 26MHz and forwarding is already on, or (b) the discrete board's on-board TCXO (T260, U37) clocks the AR3002 directly (the RE's "most likely"; the AR3002 datasheet has a ref clock into pin3 XTAL_OUT from an external source). Either way the AR3002 most likely has power, clock, and reset-released yet emits nothing. The remaining coherent explanations are (i) a chip-internal boot condition that only a scope on AR3002 pin3/UART could see (none available), or (ii) a firmware-capability wall - BT bring-up on this combo needs a coex/bridge release from the AR6004 fw that the open fw-5.bin does not implement (consistent with HI_OPTION_FW_BRIDGE being an empirical no-op, U28-30; the OEM Windows WLAN fw that did is a different, non-ath6kl-loadable format). Artifacts: ar6004-clock-block-dump.txt (live register block).

## UPDATE 44 (2026-06-28) - Firmware avenue closed (two parallel RE passes); topology reframe: BT is WLAN-independent
I chose the firmware angle, pursuing both firmware sub-leads and checking other revisions for differences. Two read-only RE passes ran, and both converge on the same conclusion on independent grounds: the AR6004 WLAN firmware is not the BT lever.

Firmware hunt (revisions plus diff). First, topology, which is decisive: the AR3002 is a discrete HCI-UART BT on its own SoC UART (DLAC3002/ttyS4), while the AR6004 firmware's HCI/GMBOX/FW_BRIDGE machinery is for the other topology, where BT is carried through the AR6004 over SDIO. This BT's command path does not traverse the AR6004. The OEM side confirms it: the Windows WLAN INF sets IsAthrBT=0 and does only airtime BtCoex, so the WLAN driver never touches BT power, clock, reset, or HCI (matches U19). Second, availability: QCA shipped exactly one AR6004 hw3.0 image (3.5.0.349-1 api5) and never revised it. The installed fw-5.bin (md5 c138131e) is byte-identical to the QCA upstream blob across all three local copies and winre/qcafw/fw-5.bin. The one genuinely different build, the OEM Windows WLAN firmware ar6004v3_0fw.bin (md5 f61f204d, same SGMT base 0x00998000, diverges at byte 41), has zero BT strings as well. AR6004 hw1.3 fw-5 differs but is the wrong hw rev. So a different revision could only set or clear the same bits, which means it cannot beat the manual force. I will not swap firmware, since that risks stable WiFi for zero BT benefit.

Deep fw-5.bin Xtensa RE. fw-5.bin has no BT, GMBOX, HCI-bridge, or AR3002-release code: zero strings for gmbox, bridge, bluetooth, coex, uart, hci_uart, or 3002 in the whole 45KB, no GMBOX/HCI command id, and no host trigger exists. It reads hi_option_flag in general, but the FW_BRIDGE bit is the confirmed empirical no-op (U28-30). I corrected the earlier "literal pool not in extracted segment" disassembly wall, which turned out to be a wrong load-base assumption and is immaterial, since the verdict rests on three base-independent pillars: the empirical no-op, the zero BT code, and the wrong topology.

Synthesis and reframe. Topology plus the Windows INF (WLAN does nothing for BT) strongly imply the AR3002 is clocked by its own discrete TCXO (T260, U37) rather than an AR6004 forward, since a forward would be a WLAN-touches-BT dependency that the INF rules out. So the entire "AR6004 clock-forward / firmware-bridge gates BT" family is the wrong tree: the AR3002 is a fully WLAN-independent standalone UART BT. It therefore most likely has power (pin52 high, CTS), clock (its own TCXO), reset released, and the exact Windows host bring-up replicated (qcbtuart RE shows GPIO pin52-high plus UART config plus wake pulse, with no PMIC/EC/I2C/clock write), and is still mute. The remaining candidates are all below the observable software layer. First, the BT core rail BT_VDD (~1.8V) may not be enabled on Linux (the I/O rail being on gives CTS, while the core rail powers the ROM CPU); this is the standing leading theory, but the earlier PMIC measurement (intel_pmic_bytcrc, U23-27) found no disabled BT rail (BT shares V3P3U with WiFi, so it is on), which means any separate core rail is not on the measured Crystal Cove map. Second, a chip-internal boot state that only a scope (AR3002 pin3 clock / UART) could read. Low-odds untested software sub-levers remain: a UEFI hidden radio setup var (efivarfs/setup_var), an EC DSDT BT-power method scan, a deeper or transient PMIC LDO enable, and module-power-tree research. All are low-odds because the qcbtuart RE shows Windows does only GPIO plus UART (no rail/EC/PMIC write), so any Linux-vs-Windows rail delta would have to be set by UEFI/firmware, which both OSes share at boot.

## UPDATE 45 (2026-06-28) - polarity/inversion check ("could a 1 be a 0?"): CLOCK_GPIO inverted is still mute

I tested the single best untested inversion candidate: the CLOCK_GPIO 0x140a4 active-LOW hypothesis. Prior tests had only set the BT-clock bits (default 0x4f) or cleared bit2 (0x4b); I had never tried clearing bits 0 and 1. So I wrote 0x140a4=0x48 (clearing BT_CLK_OUT_EN, BT_CLK_REQ_EN, and CLK_REQ_OUT_EN) via ath6kl diag reg_write, loaded btdlac, and probed: rx_bytes=0, hostwake=0, so still mute. WLAN stayed up throughout, since clearing the BT-clock bits does not affect WLAN's own clock - they are BT-specific. I restored 0x4f and WiFi was fine. This means 0x140a4 is now closed in both polarities (0x4f mute, 0x48 mute); the bit polarity is irrelevant, and neither direction unmutes BT. That reinforces the topology finding: the AR6004 CLOCK_GPIO has no observable effect on the AR3002, which is consistent with TCXO-direct clocking with the AR6004 not in the BT clock path. The other inversion candidates are already covered: pin52 high=on is empirically proven (CTS asserts only when high; low=off=no CTS, so it is not invertible); pin53 wake low->high and the held-low variant are both negative (U40 and line 252); and host TXD idles high, the RX path is loopback-proven, and fe:0 rules out a chip-TX polarity flip. So inversion as a class is not the hidden gate.

## UPDATE 46 (2026-06-28) - power-rail, UEFI, and GPIO sequencing all closed (power-tree research + pad-level verify)
I went after the UEFI hidden-var hunt and the module power-tree. The power-tree research, my efivars
enumeration, and an empirical pad-level check close all three.

(A) The BT_VDD core-rail theory is refuted; it had been the standing leading theory. The AR3002 generates its
1.2V core on-chip: the datasheet (ar3002_ds.txt Table 3-1 and Fig 1-1) shows LDO_IN (1.6-3.6V external) feeding
an internal 1.2V LDO that produces VDD12. The only external supplies are LDO_IN and VDDIO (1.8/3.3V), which are
the module's shared +V1P8A / +3V3A_WIFI rails, and since WiFi works both must be present. There is no external
"BT_VDD core rail" for a platform to switch; the core never leaves the package. It is refuted three ways: the
silicon datasheet, the measured Crystal Cove PMIC (U24, no BT rail), and the UEFI DXE reverse-engineering below.
The TCXO (T260, 26MHz) is the combo's shared reference, feeding the AR6004, which works, so the oscillator is
running; JWLAN1 has no BT_CLK pin because the BT die's reference is internal die-to-die, and there is no
BT-dedicated TCXO enable. This is the best-supported inference about the module internals under the RF shield, but
it is not Linux-fixable regardless: Bay Trail exposes no 26M/32k clock provider to Linux.

(B) UEFI is closed. I obtained and reverse-engineered the BIOS (bt-re/bios/, using uefi_firmware, IFRExtractor,
and radare2/r2ghidra for the DXE disassembly). The settings blob is the EFI var "Setup", GUID
EC87D643-EBA4-4BB5-A1E5-3F3E36B20DA9, 484B. The only BT item is offset 0xCB (QuestionId 0x15), where 1=Enabled is
the factory default and is the visible BIOS toggle. There is no deeper hidden BT power var: the DXE
reverse-engineering shows 0xCB is marshalled into a policy struct only; DxePlatform GPIO init is static const
tables that never touch the BT pins; and PlatformPmic (the Crystal Cove driver) has zero references to 0xCB and
zero GPIO base, so it takes no BT-gated rail action. POST runs once pre-OS with BT Enabled and the chip is still
mute, so that state is already inherited by Linux and is not the fix. (Do not write the Setup blob - it is a Dell
brick vector.) My runtime efivars enumeration exposes only DELL_BBS*, DellPwdJumper, InSetup, SetupMode, and
SecureFlashSetupVar; the AMI Setup var is NV+BS-only and therefore runtime-absent, and there is no named BT/radio
var.

(C) GPIO enable/reset sequencing was flagged by the research as the remaining odds. The ZPJA0 Bay Trail schematic
relabels pin52=BT_DEV_RESET and pin53=BT_DEV_EN with an R436+C430 RC delay on EN, and proposes EN-first, settle,
then release RESET last, never pulsing EN. But that is already implemented in btdlac (U39/40) and is now
empirically verified closed. btdlac does pin52(RESET)=0 and pin53(EN)=0 (2s discharge), then pin53(EN)=1 (300ms
settle, far longer than any 10K-RC), then pin52(RESET)=1 released last, and never pulses pin53. I verified that
the pads land at the correct levels after the sequence: /sys/kernel/debug/gpio shows gpio-52/53 "out hi"; raw
padmmio VAL@0x588 and 0x5c8 = 0x01 (CONF0 0x2003c880, the input-enabled driven-high encoding that actually
reaches high, not the stuck-0x05); and the polarity is correct (RESET active-low: high=released=chip-active,
confirmed by the CTS/power-edge glitch). The result is rx_bytes=0, hostwake=0, still mute. So EN-first/reset-last
with settled EN, correct levels, and correct transition order is done and negative; the schematic's
transition-order hypothesis is faithfully produced and falsified (variants (b) reset-as-edge and (c)
hold-EN-throughout are also covered by btdlac).

Taking all four lines of research this session together with the live tests: host-UART, command-bytes,
clock-register (both polarities), firmware (two passes), power-rail, TCXO, UEFI, and GPIO-sequencing are all
closed or verified-negative. The AR3002 is powered, enabled, out-of-reset (pad levels verified 0x01), clocked
(its own TCXO, internal die-to-die), and given the exact Windows host bring-up, and its ROM CPU still does not
execute (the I/O block is alive, per the CTS/power-edge glitch, but there is zero TX and zero host-wake). The
remaining gap is chip-internal; the decisive diagnostic is a scope on the AR3002 clock pin or UART, which I don't
have. No Linux-reachable software lever with meaningful odds remains identified.

## UPDATE 47 (2026-06-28) - last exotic inversion (RTS-deasserted flow control) came back negative

My next idea was to try the RTS-deasserted exotic first. I added an RTS-DEASSERTED block to btdlac; because flow_control is off, serdev_device_set_rts drives the line directly. After power-on and wake, I set RTS=0 (de-asserted) and sent FC0C / FC04 / FC1E GET_VERSION at 115200. The RTS-deasserted read came back rx=0, meaning the chip emitted nothing, and the full result was rx_bytes=0, hostwake=0, with WiFi unaffected. So the chip stays mute both with RTS asserted (as in every prior run) and with it de-asserted, which means flow control and CTS-input polarity are not the gate. This is a clean signal: the chip is not holding a reply back on flow control, it has no reply because the ROM CPU is not executing. That closes the last identified exotic software lever. btdlac.c now carries the FC04 faithful-order and RTS-deasserted test blocks for the record.

## UPDATE 48 (2026-06-28) - Re-review and honesty correction: "CPU dead" is overstated

I did a careful re-review, re-deriving the Windows cold-start from qcbtuart.sys independently (radare2 + r2ghidra plus the full symbols from qcbtuart.pdb), and it confirmed that my prior RE is accurate rather than overstated: FdoDevD0Entry does power-on, then GPIO power, then UART config (full CRTSCTS), then RTS-wake, then FC0C, then FC04, then version and download; bt_hci_qca_reset is a plain HCI_Reset; there is zero SET_BREAK; and ath3k sends GET_VERSION cold, with no preamble. Notably, bt_hci_qca_wakeup (RTS-wake) skips the RTS pulse when CTS is already high (fcn @0x404b7e), and on this board CTS reads high post-power-on, so the Windows driver itself would skip it. That means the "I never pulsed RTS right" family of theories is doubly closed on primary evidence. I also confirmed that btseq.c (U13) already ran the combination of full CRTSCTS, tcflush, per-command flush, RTS/DTR asserted, and a faithful FC0C->FC04->0C1A->1001->FC1E at the correct GPIO power, and it stayed mute, so that combination is genuinely closed.

The honesty correction, which is the important output here: my standing conclusion that "the AR3002 ROM CPU does not execute / the blocker is below the OS" is not software-established and overstates the evidence. The 8250 internal loopback (U4) only proved the SoC-internal RX path (TIOCM_LOOP loops inside the controller); it never proved the PCB net from SoC-TXD (pin71) to AR3002-RXD (pin11). U26's "one broken pin is improbable" is an argument, not a measurement. So I have never actually distinguished "CPU dead" from "CPU alive but never receives my TX." The correct wording is that the AR3002 has a powered I/O block (it drives CTS and glitches on power edges) with no observable CPU activity (zero chip TX, zero host-wake); whether my TX reaches the chip's RXD, and whether the 26MHz is present at the AR3002, are both unverified and need a hardware probe, which is out of scope.

Remaining software experiments, honestly at low odds: Lead B (~2-3%) is one atomic run combining WLAN pinned awake (so any AR6004-sourced clock is live at the AR3002 POR edge), kernel-gpiod power/reset-last, and the faithful command order. Each precondition has been tested, but always in separate tools or sessions (U18's WLAN-awake used the old MMIO probe, and btdlac-faithful never atomically pinned WLAN awake). [Run this session - see U49.] Lead C (~1%) is a 30-60s passive listen after POR, since the most I have ever tried is about 3s.

## UPDATE 49 (2026-06-28) - LEAD B (atomic WLAN-awake + faithful POR), negative
I ran LEAD B: I pinned the WLAN maximally awake at the AR3002 power-on edge - mmc0 SDIO power/control=on plus the ath6kl_sdio function power/control=on, `iw power_save off`, and a 22s `ping -f` flood to the gateway so that any AR6004-sourced clock domain was definitely live - and during the flood I loaded btdlac (kernel-gpiod EN-first/reset-last POR, the faithful FC0C->FC04->0C1A->1001->FC1E sequence, RTS deasserted). The result was rx_bytes=0, RTS-deasserted rx=0, faithful-seq rx=0, and hostwake=0, so the chip stayed mute. The one combination that had genuinely never been run atomically came back negative. I reverted the WLAN power pins to the cleaned-up defaults (auto / power_save on). As a bonus, during the active-scan/power_save-off window the tablet finally found and roamed to the DFS 5GHz AP (wifi is now 5500MHz -55dBm), confirming that the wireless-regdb/regdom 5GHz fix works once ch100 is passively scanned. The upshot: only LEAD C (long passive listen) remains as a cheap experiment; the decisive disambiguators - does TX reach AR3002-RXD, and is 26MHz present at the AR3002 - are hardware-only and out of scope.

## UPDATE 50 (2026-06-28) - LEAD C (45s passive listen) came back negative; software experiments exhausted

I ran LEAD C, extending btdlac's post-POR passive listen to 45s, well past the ~3s I had ever tried before. The chip was powered and RTS was asserted, with no TX during the window, while I logged any RX plus host-wake. The result was "LEAD C passive-listen DONE rx=0 hostwake=0" over the full 45s (I saw only the usual 0x02 plus random power-edge glitch at open, which I discarded). So rx_bytes=0, no-hci, and WiFi stayed stable on 5GHz. This means the chip emits nothing spontaneously even over 45s. With LEAD B (U49) and LEAD C now both run and both negative, the two remaining cheap software experiments the re-review identified are exhausted. The honest end-state stands (U48): a powered I/O block with no observable CPU activity. The disambiguators - does my TX reach AR3002-RXD, and is 26MHz present at the AR3002 - are hardware-only, needing a scope, which I lack. No further software experiment with non-zero identified odds remains.

## UPDATE 51 (2026-06-28) - new idea, drive more pins / trigger the wake line: pad-84 wake-edge tested, mute

My hypothesis was that the wake might need more than pin52 and pin53: the pin where I expect a signal (host-wake) might need to be triggered, flipping receivers into senders. I checked two things. First, the host-wake (GSI70) is the chip's output (chip->host), so driving it from the host cannot wake the chip - the chip doesn't sense its own output - and it is a direct IO-APIC line whose backing pad sits in the SUS community, which makes it not worth chasing. Second, the tractable version is to pulse the host->chip wake strap BT_DEV_WAKE/BT_REG_ON = GPIO_S0_15 / pad-84 (SCORE, CONF0 0x540) as a wake edge during a live POR, whereas U41 only held it at static levels. I tested this: pad-84 remuxed to GPIO, driven low, then pulsed high at roughly the POR edge while btdlac ran the faithful POR plus a 45s listen plus the faithful command order. The result was rx_bytes=0, LEAD C rx=0, hostwake=0 - mute. I restored pad-84 to its pristine value (0x2003cd01), and WiFi was untouched (5GHz -53dBm). The decisive framing: re-reviewing the working Windows driver confirmed it drives only pin52 plus pin53 plus UART plus a conditional RTS-wake (skipped when CTS is already high, which is my case) - no extra pins, no direction flips. Since that minimal set works on Windows, the pin sequence is provably not the Linux-vs-Windows gap; the "more pins / flip receivers to senders / trigger the host-wake" family of ideas is contradicted by the working reference. The one unresolved decisive fact remains hardware-only: does my TX physically reach AR3002-RXD, and is the 26MHz present at the chip.

## UPDATE 52 (2026-06-29) - boot-timing campaign (before/after WiFi, cold-boot pristine), all mute

I tried a new plan: test at boot, before and after WiFi, from fresh state. Boot services ran btdlac at three points, logging to /var/log/bt-bootprobe.log:
- early-NOPOWER (uptime 14s, WLAN loaded but not associated): the chip was probed exactly as the firmware left it at boot, with no GPIO power-cycle (nopower=1), giving rx_bytes=0 and hostwake=0. The pristine cold-boot firmware state is mute.
- early-NORMAL (uptime 29s, WLAN not associated): a full power-cycle probe before WiFi gave rx_bytes=0.
- late-NORMAL (uptime 50s, WLAN associated 2.4GHz -62, so the WLAN clock domain is live): rx_bytes=0.

So BT is mute before WiFi, after WiFi-associated, and in the untouched firmware-default state. Boot timing relative to WiFi makes no difference, and the idea that "my power-cycling breaks it" is disproven, since the nopower probe is also mute.

One caveat: "before WiFi" here means ath6kl is loaded but not associated (ath6kl auto-loads early via udev), so the WLAN firmware and clock may already be up. The one genuinely untested state left is a full cold power-off. A warm reboot does not fully power-cycle the AR3002; a shutdown plus rail-drain plus power-on would. That is pending a manual physical power-off, which will be auto-captured by the early-nopower boot service. Boot harness: /usr/local/sbin/bt-bootprobe.sh plus bt-bootprobe-{early,late}.service (temporary test cruft, remove after the campaign).

## U53 (2026-06-30) - cctk / Dell Command Configure BIOS lead: closed

I tested the "hidden BIOS radio-enable setting" hypothesis with `dell-command-configure` (AUR;
`/opt/dell/dcc/cctk`). Surprisingly, the Dell SMBIOS/WMI stack does load on this consumer tablet
(`dell_smbios`, `dell_wmi`, `dcdbas`, `dell_laptop`), and cctk lists BIOS options - but there is
no Bluetooth token and no hidden radio token. `Advsm` covers only thermal/voltage/fan thresholds,
and `cctk -S bluetooth|radio|wireless|bt|rf` returns nothing. The only radio tokens are
`--WirelessLan` and `--WirelessWwan`, and they read nominal: `WirelessLan=Disabled` while Wi-Fi
works fine, and `WirelessWwan=Enabled` though there is no WWAN.

I flipped the one lever available: `cctk --WirelessLan=Enabled` (no setup password needed). It
persisted across a reboot and Wi-Fi was unaffected, but the AR3002 re-probe (btdlac rebuilt for
kernel 7.0.14) still returned `RESULT rx_bytes=0 hostwake_edges=0` across passive-listen,
RTS-deasserted, the faithful Windows cold-start sequence, and the full 9600-2764800 baud sweep.
cctk provides no usable BT lever, so the chip stays mute. I left `WirelessLan` at `=Enabled`
(harmless; Wi-Fi confirmed working).

## UPDATE 54 (2026-07-02) - Solved: the ROM was answering at 3686400 all along

After UPDATE 53 I had run out of software levers, with the chip addressed at 115200
every time. Going back over the evidence, one number stood out that I had read past
at every turn: the Windows INF lists two baud rates for this device, a
DefaultBaudRate of 115200 and an operating BaudRate of 3686400. Every probe I ever
ran used 115200, and my "exhaustive" baud sweep climbed to 2764800 (ttyS4's
base_baud) and stopped there - it never once tried 3686400.

So I set the host UART itself to 3686400 (8N1, CRTSCTS, pin52 held high) and sent
GET_VERSION one more time. The chip answered immediately and reproducibly:
  FC0C set-baud   -> 04 0e 04 01 0c fc 00                          (Command_Complete, status 0)
  GET_VERSION     -> 04 0e 12 01 1e fc 00 01 02 02 01 32 ...       (ROM version 0x01020201)
  Read_Local_Ver  -> 04 0e 0c 01 01 10 00 06 02 01 06 45 00 01 00  (HCI 4.0)
The AR3002 boot ROM is fully HCI-capable on its own: a valid BD_ADDR of
88:12:4E:84:25:4D, a complete feature set, and classic + LE scan and pairing all
verified, with no rampatch or NVM download needed. It was never mute or dead; it had
been sitting at 3686400 the whole time, ignoring every command I sent at the wrong rate.

Why 3686400 stayed hidden, across three signposts that all pointed the wrong way:
DefaultBaudRate=115200 reads like the boot rate but is not (the ROM comes up at the
high rate and the driver's own retry logic walks it there); ttyS4 reports
base_baud=2764800, so any sweep that respects the port's advertised maximum stops
below 3686400; and 3686400 is not one of the POSIX termios baud constants, so
hciattach and btattach physically cannot express it - only termios2 with BOTHER can -
which is why those tools always just timed out.

This closes out everything above. The "chip is mute/dead" conclusion, the BT_VDD
core-rail theory, the PMIC LDO hunt, and the "out-of-band only / need a dongle"
terminal were all wrong. Two side-theories from the final session were falsified along
the way as well: hardware flow control was never the blocker (CTS asserted and bytes
were delivered), and the pin52 glitch that first surfaced a reply was a red herring
(going straight to 3686400 works with no glitch). The working, persistent bring-up
(the bt0off SSDT override, bthci, and bt-venue.service) is described in the summary at
the top of this file and in the README.
