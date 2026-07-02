# Kbuild makefile for the batfix kernel module (see batfix.c).
# The userspace bthci tool is built separately: gcc -O2 -o bthci bthci.c
#
# Build:    make
# Install:  sudo make install    (-> /lib/modules/<ver>/updates/ + depmod)
# Clean:    make clean
obj-m := batfix.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

default:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

install: default
	install -Dm644 batfix.ko /lib/modules/$(KVER)/updates/batfix.ko
	depmod $(KVER)
