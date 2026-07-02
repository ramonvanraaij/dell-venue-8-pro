// bthci.c
// =================================================================
// Dell Venue 8 Pro 5830 internal Bluetooth bring-up (Atheros AR3002)
//
// Copyright (c) 2026 Rámon van Raaij
// License: BSD-3-Clause
// Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
//
// The internal Atheros AR3002 Bluetooth (ACPI DLAC3002, HCI-UART on the Bay
// Trail HS-UART) has a boot ROM that communicates at 3686400 baud - NOT the
// 115200 its Windows INF advertises as DefaultBaudRate. 3686400 is a
// non-standard rate that hciattach/btattach cannot set (they only accept POSIX
// termios baud constants), which is why every stock tool fails with a timeout.
//
// This self-contained tool:
//   1. powers the chip through the gpio character device (SCORE community
//      gpiochip0 = INT33FC:00 = ACPI \_SB.GPO0; line 52 = power-down/enable,
//      line 53 = device-wake), holding the lines for its whole lifetime - a
//      stable kernel ABI, so no custom kernel module is needed and it survives
//      kernel upgrades;
//   2. opens the tty and sets 3686400 baud + hardware flow control via
//      termios2 / BOTHER;
//   3. attaches the N_HCI line discipline (HCI_UART_H4), so the kernel exposes
//      the controller as hci0. The ROM is fully HCI-capable (valid BD_ADDR,
//      full feature set) - no firmware download is required.
// It then blocks forever, holding the GPIOs and the line discipline. Run it via
// bt-venue.service. Requires the bt0off SSDT override (see acpi/bt0off.dsl) so
// the HS-UART enumerates as /dev/ttyS4 instead of an ACPI serdev child.
//
// Build:  gcc -O2 -o bthci bthci.c
// Usage:  bthci [tty] [baud]        (defaults: /dev/ttyS4 3686400)
// =================================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <asm/termbits.h>
#include <asm/ioctls.h>
#include <sys/ioctl.h>

#ifndef N_HCI
#define N_HCI 15
#endif
#define HCIUARTSETPROTO   _IOW('U', 200, int)
#define HCI_UART_H4        0

#define GPIOCHIP   "/dev/gpiochip0"   /* INT33FC:00 = SCORE community = \_SB.GPO0 */
#define PIN_PWR    52                 /* pin52: power-down/enable, HIGH = on  */
#define PIN_WAKE   53                 /* pin53: device-wake                   */

static int line_fd = -1;

/* set the two held lines: bit0 -> PIN_PWR, bit1 -> PIN_WAKE */
static int gpio_set(int pwr, int wake)
{
	struct gpio_v2_line_values v;

	v.mask = 0x3;
	v.bits = (pwr ? 0x1 : 0) | (wake ? 0x2 : 0);
	if (ioctl(line_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &v)) {
		perror("GPIO SET_VALUES");
		return -1;
	}
	return 0;
}

static int gpio_power_on(void)
{
	int chip = open(GPIOCHIP, O_RDONLY | O_CLOEXEC);
	struct gpio_v2_line_request req;

	if (chip < 0) { perror("open gpiochip"); return -1; }

	memset(&req, 0, sizeof(req));
	req.offsets[0] = PIN_PWR;
	req.offsets[1] = PIN_WAKE;
	req.num_lines = 2;
	req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
	strncpy(req.consumer, "bthci-venue", sizeof(req.consumer) - 1);

	if (ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req)) {
		perror("GPIO GET_LINE (lines 52/53 busy?)");
		close(chip);
		return -1;
	}
	close(chip);              /* the line request fd (req.fd) keeps the lines held */
	line_fd = req.fd;

	/* Proven power-on: discharge both low, wake(EN) high first, power high last
	 * (POR edge), then a wake pulse. Leave both high and held. Bail if any write
	 * fails - attaching HCI on an unpowered chip is pointless. */
	if (gpio_set(0, 0))
		return -1;
	usleep(500000);
	if (gpio_set(0, 1))
		return -1;
	usleep(200000);
	if (gpio_set(1, 1))
		return -1;
	usleep(300000);
	if (gpio_set(1, 0))
		return -1;
	usleep(10000);
	if (gpio_set(1, 1))
		return -1;
	usleep(200000);
	return 0;
}

int main(int argc, char **argv)
{
	const char *dev = (argc > 1) ? argv[1] : "/dev/ttyS4";
	int baud = (argc > 2) ? atoi(argv[2]) : 3686400;
	struct termios2 t;
	int fd, ldisc = N_HCI, proto = HCI_UART_H4;

	if (baud <= 0) {
		fprintf(stderr, "bthci: invalid baud '%s'\n", argv[2]);
		return 1;
	}

	if (gpio_power_on())
		return 1;

	fd = open(dev, O_RDWR | O_NOCTTY);
	if (fd < 0) { perror("open tty"); return 1; }

	if (ioctl(fd, TCGETS2, &t)) { perror("TCGETS2"); return 1; }
	t.c_cflag &= ~CBAUD;
	t.c_cflag |= BOTHER | CS8 | CLOCAL | CREAD | CRTSCTS;
	t.c_cflag &= ~(PARENB | CSTOPB | CSIZE);
	t.c_cflag |= CS8;
	t.c_iflag = 0; t.c_oflag = 0; t.c_lflag = 0;
	t.c_ispeed = baud; t.c_ospeed = baud;
	t.c_cc[VMIN] = 1; t.c_cc[VTIME] = 0;
	if (ioctl(fd, TCSETS2, &t)) { perror("TCSETS2"); return 1; }
	ioctl(fd, TCFLSH, TCIOFLUSH);

	if (ioctl(fd, TIOCSETD, &ldisc)) { perror("TIOCSETD N_HCI"); return 1; }
	if (ioctl(fd, HCIUARTSETPROTO, proto)) { perror("HCIUARTSETPROTO"); return 1; }

	fprintf(stderr, "bthci: hci attached on %s @%d (gpio power held); running\n",
		dev, baud);
	for (;;) pause();
	return 0;
}
