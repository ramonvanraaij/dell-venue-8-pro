// SPDX-License-Identifier: GPL-2.0-only
// batfix.c
// =================================================================
// Dell Venue 8 Pro 5830 - transient all-zero battery-reading filter
//
// Copyright (c) 2026 Rámon van Raaij
// License: GPL-2.0-only (required: this module links GPL-only kprobe symbols)
// Author: Rámon van Raaij | Bluesky: @ramonvanraaij.nl | GitHub: https://github.com/ramonvanraaij | Website: https://ramon.vanraaij.eu
//
// This tablet's ACPI firmware returns an all-zero _BST (voltage / charge /
// capacity all 0, status "Not charging") for ~1.5 s on every AC transition.
// UPower faithfully reports that momentary reading as 0%, so Plasma fires a
// false "battery critical" warning twice per plug cycle. It is cosmetic (no
// suspend, thanks to AllowRiskyCriticalPowerAction=false) but annoying.
//
// A kretprobe on the exported power_supply_get_property() intercepts reads of
// the BATC battery and, for the properties that can never legitimately drop to
// 0 in one step (voltage, charge, energy, capacity), substitutes the last good
// value when the driver returns a transient 0. A genuinely draining battery
// ramps down gradually (100 -> ... -> 3 -> 2 -> 1 -> 0), so a real low battery
// still reports correctly - only the impossible instant 71 -> 0 jump is masked.
//
// It uses no fixed struct offsets (the power_supply layout comes from the
// kernel header), so it recompiles cleanly against a new kernel. It is still an
// out-of-tree module and must be rebuilt after a kernel upgrade; the pacman hook
// etc/pacman.d/hooks/venue-batfix.hook automates that.
// =================================================================
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/power_supply.h>
#include <linux/string.h>
#include <linux/ratelimit.h>
#include <asm/ptrace.h>

#define BATNAME "BATC"

static int debug;
module_param(debug, int, 0644);
MODULE_PARM_DESC(debug, "log each transient 0 that gets filtered");

/* args of power_supply_get_property(), captured at entry for the return handler */
struct pg_args {
	struct power_supply *psy;
	enum power_supply_property psp;
	union power_supply_propval *val;
};

/* last known-good value per sanitized property */
static int lg_volt, lg_charge, lg_energy, lg_cap;
static bool hv_volt, hv_charge, hv_energy, hv_cap;

/* Substitute a transient 0 with the last good value when it would be a physically
 * impossible instant drop (last good was above `floor`). Otherwise remember the
 * value. Returns true if a substitution was made. */
static bool filter0(int *v, int *lg, bool *have, int floor)
{
	if (*v == 0 && READ_ONCE(*have) && READ_ONCE(*lg) > floor) {
		*v = READ_ONCE(*lg);
		return true;
	}
	if (*v > 0) {
		WRITE_ONCE(*lg, *v);
		WRITE_ONCE(*have, true);
	}
	return false;
}

static int entry_h(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct pg_args *a = (struct pg_args *)ri->data;

	a->psy = (struct power_supply *)regs_get_kernel_argument(regs, 0);
	a->psp = (enum power_supply_property)regs_get_kernel_argument(regs, 1);
	a->val = (union power_supply_propval *)regs_get_kernel_argument(regs, 2);
	return 0;
}

static int ret_h(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct pg_args *a = (struct pg_args *)ri->data;
	int ret = regs_return_value(regs);
	bool fixed = false;

	if (ret != 0 || !a->psy || !a->val || !a->psy->desc || !a->psy->desc->name)
		return 0;
	if (strcmp(a->psy->desc->name, BATNAME) != 0)
		return 0;

	switch (a->psp) {
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		fixed = filter0(&a->val->intval, &lg_volt, &hv_volt, 500000);   /* 0.5 V */
		break;
	case POWER_SUPPLY_PROP_CHARGE_NOW:
		fixed = filter0(&a->val->intval, &lg_charge, &hv_charge, 100000);
		break;
	case POWER_SUPPLY_PROP_ENERGY_NOW:
		fixed = filter0(&a->val->intval, &lg_energy, &hv_energy, 100000);
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		fixed = filter0(&a->val->intval, &lg_cap, &hv_cap, 4);          /* 4 % */
		break;
	default:
		return 0;
	}

	if (debug && fixed)
		pr_info_ratelimited("batfix: BATC prop %d transient 0 filtered -> %d\n",
				    a->psp, a->val->intval);
	return 0;
}

static struct kretprobe krp = {
	.handler = ret_h,
	.entry_handler = entry_h,
	.data_size = sizeof(struct pg_args),
	.maxactive = 32,
};

static int __init batfix_init(void)
{
	int r;

	krp.kp.symbol_name = "power_supply_get_property";
	r = register_kretprobe(&krp);
	if (r < 0) {
		pr_err("batfix: register_kretprobe failed: %d\n", r);
		return r;
	}
	pr_info("batfix: installed BATC transient-zero filter on power_supply_get_property\n");
	return 0;
}

static void __exit batfix_exit(void)
{
	unregister_kretprobe(&krp);
	pr_info("batfix: unloaded (missed %d probes)\n", krp.nmissed);
}

module_init(batfix_init);
module_exit(batfix_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Filter transient all-zero _BST battery readings on the Dell Venue 8 Pro 5830");
MODULE_AUTHOR("Ramon van Raaij");
