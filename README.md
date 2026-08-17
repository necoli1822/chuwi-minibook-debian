# Chuwi MiniBook X N150 — Debian-family Linux setup

Patches, scripts and measurements for getting Kubuntu 26.04 working properly on the
10.5-inch **Chuwi MiniBook X (N150)** convertible.

This machine mounts a **1200x1920 DSI panel rotated 90 degrees inside a landscape
chassis**, carries two accelerometers, and hides its fan and charging circuit behind
the embedded controller. Out of the box the display comes up sideways, auto-rotation
does not work, and there is no way to read the fan. This repository closes that gap.

> **This repository stands on
> [fstanis/chuwi-minibook](https://github.com/fstanis/chuwi-minibook).** The kernel
> modules, the VBT patcher and the forks are all that project's work. What is here is
> a port to the Debian family, verified against the hardware, with a handful of
> safety problems fixed. See [credits](#credits) for the full picture.

## Scope

**Booting the machine and making its hardware work — nothing else.** Theming, shell
and editor configuration are deliberately excluded.

```
install/     step-by-step scripts (00 through 99). The order is deliberate
patches/     seven modifications to upstream; the installer applies three of them
scripts/     panel refresh rate (ported to GRUB + initramfs-tools)
notes/       what was measured, and why each decision went the way it did
```

## Quick start

```bash
git clone <this-repo> && cd chuwi-minibook-debian

sudo ./install/install.sh --dry-run     # see what would change first
sudo ./install/install.sh               # apply in order
./install/99-verify.sh                  # confirm it actually took
```

Steps can be run individually. Each is idempotent, so running one twice is safe.

## After a kernel or distribution upgrade

```bash
sudo ./install/98-post-upgrade.sh          # what broke, and which step restores it
sudo ./install/98-post-upgrade.sh --fix    # re-run those steps
```

Run it after every kernel update and after any point release, 26.04 to 26.04.1
included. Most of what this repository installs is invisible to dpkg and survives
untouched, but three kinds of thing do not:

| What | Why it is at risk |
|---|---|
| `/etc/default/grub`, `/etc/initramfs-tools/modules` | dpkg conffiles. An upgrade can revert them, taking the rotation, the TTY and the 75Hz VBT with them |
| The `minibook_ec` DKMS build and the initramfs | Rebuilt per kernel. Silently fails if the clang toolchain was removed |
| The `iio-sensor-proxy` diversion | A package update restores the stock binary if the diversion is gone, and tablet mode stops |

**Do not remove `build-essential`, `clang`, `lld`, `llvm`, `libelf-dev` or `dkms`.**
Without them a kernel update leaves the machine with no `minibook_ec` and no
indication why. This is the failure that costs the most to notice late, so
`98-post-upgrade.sh` checks it before anything else.

## What needs fixing, and why

| Problem | Fix | Notes |
|---|---|---|
| Display comes up rotated 90 degrees | Kernel parameters + i915 in initramfs | [display-rotation.md](notes/display-rotation.md) |
| Auto-rotation does not work (two accelerometers) | iio-sensor-proxy fork | [d1-tablet-mode.md](notes/d1-tablet-mode.md) |
| Fan RPM and charger temperature unreadable | `minibook_ec` via DKMS | [hardware-status.md](notes/hardware-status.md) |
| Panel runs at 50Hz only | VBT patch to 75Hz | [vbt-refresh-rate.md](notes/vbt-refresh-rate.md) |
| Pointer jitters under a resting finger | hwdb `fuzz` value | [touchpad-jitter.md](notes/touchpad-jitter.md) |
| Which suspend mode to use | s2idle, measured | [suspend-mode.md](notes/suspend-mode.md) |
| When and how to drop the stock kernel | Once XanMod is proven, meta packages included | [kernel-cleanup.md](notes/kernel-cleanup.md) |

## What this adds to upstream

Upstream was audited rather than taken as-is. Seven patches came out of that audit,
all in `patches/`. They fall into two groups, and the difference matters: **only
three of them are applied by the installer.**

### Applied by the installer

Each of these patches a component that is actually installed on this machine.

| Patch | Applied by | What it does |
|---|---|---|
| 0003 | `06-refresh-rate.sh` | Adds checksum verification to the kernel headers `vbt_patch` downloads |
| 0005 | `05-tablet-mode.sh` | Makes the `iio-sensor-proxy` fork check the MXC6655 DEVID rather than assuming it |
| 0006 | `04-minibook-ec.sh` | Removes keyboard backlight support from `minibook_ec`, which this machine has no hardware for |

### Not applied here

These fix real defects in upstream, but they patch components that measurement showed
this machine does not need, so no install step references them. They are kept because
**"unnecessary on this unit" and "worthless upstream" are different claims** — anyone
who does install these components, on this or another machine, wants these fixes. See
[what is deliberately not installed](#what-is-deliberately-not-installed) for why each
component was dropped.

| Patch | Component | What it does |
|---|---|---|
| 0001 | `dptf_enabler` | Stops it writing GNVS offsets without a bounds check |
| 0002 | `goodix_ts` | Makes the build fail on a patch mismatch instead of ignoring it, and pins the fetched sources by checksum |
| 0004 | `i2c_designware_spklen` | Drops device IDs this machine does not have, and defaults `clkgate` off |
| thermald | `thermal_daemon` fork | Rebases the MiniBook delta onto upstream master and fixes two out-of-bounds reads |

### The porting work

`scripts/update-vbt-clock-debian.sh` is upstream's Arch script (mkinitcpio/limine)
ported to GRUB and initramfs-tools, with four bugs in the original fixed along the
way. One of those is `--revert` leaving the firmware and hook behind, which made
changing the refresh rate a second time impossible.

## What is deliberately not installed

These were not overlooked. Each was **measured and found unnecessary**; the evidence
is in [hardware-status.md](notes/hardware-status.md).

- `goodix_ts` — the in-tree driver already works. This patch costs the ESD recovery path
- `i2c_designware_spklen` — zero I2C errors anywhere, so there is no fault to fix
- `dptf_enabler` — 180 seconds at full load with zero throttling. Thermal control needs no help
- the `thermald` fork — same measurement. `thermald` was already `inactive` before it was
  removed, and `intel_pstate` (active, powersave) governs on its own, with the fan driven
  autonomously by the EC. Removing the stock kernel takes `thermald` with it by way of
  `ubuntu-kernel-accessories`, and on this machine that changed nothing measurable.
  See [kernel-cleanup.md](notes/kernel-cleanup.md)
- `acpi_call` — established as unnecessary

## Credits

The substance of this work belongs to other people. What was done here is the port to
the Debian family, verification against real hardware, and a few safety fixes.

### What this is built on

- **[fstanis/chuwi-minibook](https://github.com/fstanis/chuwi-minibook)**
  — the `minibook_ec`, `dptf_enabler`, `i2c_designware_spklen` and `goodix_ts` kernel
  modules, `vbt_patch`, the thermald and iio-sensor-proxy forks, and the diagnostic
  scripts. **Every patch in this repository is a modification of that project.**
  Mapping the EC's I2EC bridge and SMBus layout by decompiling the firmware is also
  their work.

### Consulted while working out the hardware

Used to compare approaches and establish what the hardware actually is. The
comparison is in [community-research.md](notes/community-research.md).

- **[greymouser/minibook-x-tools](https://github.com/greymouser/minibook-x-tools)**
  — the most kernel-native approach: a `cmx` module, daemons and kernel patches
- **[petitstrawberry/minibook-support](https://github.com/petitstrawberry/minibook-support)**
  — a purely userspace approach
- **[codingdave/MiniBookX](https://github.com/codingdave/MiniBookX)**
  — udev hwdb and GRUB recipes
- **bazmonk/minibook-dual-accelerometer** — dual accelerometer handling
- **godorowski/90hz-mode** — unlocking the refresh rate by the same mechanism as `vbt_patch`

### Upstream projects

- **[Linux kernel](https://kernel.org)** — the `goodix` touchscreen driver and the VBT
  definition headers (`intel_vbt_defs.h`, `intel_dsi_vbt_defs.h`)
- **[intel/thermal_daemon](https://github.com/intel/thermal_daemon)** — thermald
- **[iio-sensor-proxy](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy)**
  — the accelerometer and auto-rotation daemon
- **[XanMod](https://xanmod.org)** — the kernel used here

### What was done here

- Audited every upstream component and made the seven changes above
- Ported the Arch-only script to the Debian family
- Measured: the fan curve, thermal behaviour, the refresh rate ceiling (diagnosed as
  memory bandwidth), suspend residency, the cause of the touchpad jitter, and the
  full BIOS menu
- Gathered the evidence for what **not** to install
- Wrote the step scripts

## Licence

Each component keeps the licence of what it derives from. See [LICENSE.md](LICENSE.md).

In short: `patches/` follows its target (GPL-2.0, GPL-2.0-or-later or GPL-3.0),
`scripts/` and `install/` are 0BSD, and `notes/` is CC BY 4.0.

## Caveats

Everything here was **measured on a single machine**. Panel or firmware revisions may
differ even within the same model. The refresh rate in particular varies by unit: this
one shows artefacts at 90Hz, so it runs at 75.

Unlocking the BIOS and driving the EC include steps that are hard to undo. Read the
warnings in the relevant notes first.
