# Survey of community work on the MiniBook X

Gathered before touching the machine, to work out what other people had already
established about this hardware. Several conclusions here were later contradicted by
measurement; where that happened it is marked, with a pointer to the note that
supersedes it.

## The hardware

| Part | Model | Notes |
|---|---|---|
| SoC | Intel N150 (Twin Lake, 4x Gracemont, 6W) | i915, UHD 24EU (Alder Lake-N) |
| WiFi | Intel AX101 (WiFi 6) | Needs recent linux-firmware; not detected on 22.04 |
| Bluetooth | Intel `8087:0026` | Not detected with older firmware |
| Webcam | 2MP Sunplus (UVC) | Works out of the box |
| Audio | Intel HDA/SST, combo jack and speakers | Turn "Intel Mic Boost" down in alsamixer |
| Storage | M.2 2242 NVMe (Gen3) | **Not eMMC.** Single-sided 2242, replaceable |
| Panel | 10.51" 1920x1200 IPS on **DSI-1**, mounted rotated 90 degrees, locked to 50Hz | |
| Accelerometers | 2x MXC6655, ACPI HID `MDA6655` (screen on bus 1, base on bus 0, both at 0x15) | Stock enumerates only one |
| Touchscreen | Goodix Capacitive TouchScreen | Needs coordinate transform when rotated |
| EC | ITE IT5570E | Exposed by `minibook_ec` |
| BIOS | AMI Aptio, locked by Chuwi | No charge limit, Advanced menus hidden |

Note: several community posts describe the firmware as InsydeH2O. On this unit it is
**AMI Aptio**; see [bios-findings.md](bios-findings.md).

### Kernel version thresholds

- **Display regression: 6.6.15 through 6.8.3 are broken**, so 6.8.4 or newer is
  required (or 6.6.14 and older)
- Accelerometers need **6.9+**, for the `MDA6655` ACPI ID added in early 2024 and for
  `serial-multi-instantiate`
- WiFi and Bluetooth need recent firmware

Kubuntu 26.04 with kernel 7.0 clears all of these.

Even on 6.9+, **only one of the two accelerometers binds automatically**, because only
one is enumerated by ACPI. The second has to be instantiated some other way.

## Why stock auto-rotation fails on every distribution

This is the root cause, and it is worth stating plainly.

- The MiniBook **produces no convertible tablet switch under Linux.** Windows uses
  ACPI `PNP0C60`/`INT33D3`.
- Linux reads **DMI chassis type 10 (Notebook)**, not the convertible types 31 or 32.
  So iio-sensor-proxy and the desktop treat it as an ordinary laptop, no
  `SW_TABLET_MODE` event is produced, and nothing auto-rotates.
- The switch would come from **intel-hid's `VGBS` method**, but the MiniBook's ID is
  **not in the VGBS allow-list in the kernel's `intel/hid.c`**.

libinput introduced that allow-list deliberately: spurious `SW_TABLET_MODE=1` reports
were rendering laptops unusable. So the gate exists for good reason, and anything that
bypasses it is taking on that responsibility.

The survey concluded the root fix was to add the MiniBook to the VGBS allow-list, which
means patching and rebuilding the kernel.

> **Superseded.** A uinput device emitting `SW_TABLET_MODE` bypasses the gate without
> touching the kernel, and the fstanis fork already does exactly that. No kernel patch
> was needed. See [d1-tablet-mode.md](d1-tablet-mode.md).

## The tooling projects

### greymouser/minibook-x-tools — the most kernel-native

- Scope: **tablet mode only**, aimed at the N150. No fan, thermal, EC, backlight or
  refresh rate work.
- Structure: a `cmx` kernel module emitting `SW_TABLET_MODE`, a root daemon computing
  the hinge angle, a session daemon for desktop integration, plus **kernel patches**
  disabling automatic MXC4005 ACPI loading and enabling `serial-multi-instantiate`.
- Debian fit: **poor**, since it assumes patching and rebuilding the kernel and ships
  neither .deb nor DKMS. If you already build a custom kernel it is the most robust
  answer to the dual accelerometer problem.
- Actively maintained, dual GPL-2.0/MIT.

### petitstrawberry/minibook-support — purely userspace

- Scope: tablet mode detection, **disabling the keyboard and trackpad in tablet mode**,
  and trackpoint correction. No rotation, thermal or EC work.
- Structure: three C daemons with virtual input passthrough to suppress the real
  devices, plus systemd units. **No kernel module or rebuild**, only kernel 6.9+.
- Tested on Ubuntu 24.04 on a MiniBook X, and desktop-agnostic.
- The most actively maintained of the three. MIT.

> **Not needed here.** Disabling the keyboard and touchpad turned out to require
> nothing at all: libinput does it from `SW_TABLET_MODE` alone.

### codingdave/MiniBookX — udev hwdb and GRUB recipes

- Scope: mostly display and console rotation. The tablet switch, touchpad freezes and
  S3 black screen are documented but unsolved.
- Nine commits in a single day in January 2023 and nothing since, aimed at the N5100
  generation.

Its outputs, assessed:

- **hwdb mount matrix** — the survey originally rated this as highly reusable.
  > **Wrong.** The rule keys on `acpi:MXC6655*` while the node that is actually enabled
  > here is `MDA6655`, so it never matches. hwdb also keys on modalias, so it cannot
  > give two sensors sharing one modalias different matrices. See
  > [accelerometer-acpi.md](accelerometer-acpi.md).
- **`fbcon=rotate:1`** — valid, and adopted. But **putting i915 in the initramfs is a
  prerequisite**; without that it has no effect at all.
- **`video=DSI-1:panel_orientation=...`** — applies, but **nothing consumes the
  property, so the display does not move.** This is not an alternative to the desktop's
  own rotation; they are different layers. See
  [display-rotation.md](display-rotation.md).
- A touchpad freeze workaround, reloading `i2c_hid_acpi`. Not needed here.

### Dual accelerometer approaches

- **rhalkyard/minibook-dual-accelerometer**, and its N150 fork **bazmonk**: a platform
  driver instantiating both IIO devices as `.display` and `.base`, exposing a
  `chuwi_dual_accel_tablet_mode` sysfs knob. Needs three kernel patches, though a DKMS
  "hack driver" exposes just the knob without them. The angle service computes the
  hinge angle with jerk and tilt rejection plus hysteresis. Notably, it uses
  **device-path udev rules** for the mount matrix precisely because hwdb cannot
  distinguish the two sensors.
- **lschans/chuwi-tablet**: activates the base sensor by hand with
  `echo mxc4005 0x15 > /sys/bus/i2c/devices/i2c-0/new_device`.
- **finalrewind**: deliberately uses only the lid sensor with a simple threshold.

The two published mount matrices disagree, and neither was verified on an N150:

```
codingdave:  0,1,0; -1,0,0; 0,0,1    determinant +1, a proper rotation
lschans:     0,1,0;  1,0,0; 0,0,1    determinant -1, a mirror
```

A mirror cannot describe a physical mounting, so at most one is right.

## Refresh rate

`godorowski/90hz-mode` and `fstanis/vbt_patch` work by the same mechanism: install a
patched `vbt` blob at `/lib/firmware/vbt`, add `i915.vbt_firmware=vbt`, and include it
in the initramfs. A VBT override is currently **the only route to anything above
50Hz.**

Both hardcode Limine and mkinitcpio, so both need porting to GRUB and initramfs-tools.

> This unit runs at 75Hz, not 90. See [vbt-refresh-rate.md](vbt-refresh-rate.md).

## Desktop integration

- **KDE (godorowski)**: `kscreen-doctor` driven by a user systemd service polling
  `iio:device0`. A workaround for the missing tablet switch, and unnecessary once one
  exists.
- **GNOME**: the Screen Rotate extension plus `gnome-kiosk` for the on-screen keyboard.
- **i3/X11**: xrandr plus an xinput coordinate transformation matrix per rotation.
- **Wayland keyboard locking**: xinput is unavailable, so an `evtest` grab running as
  root is used instead.

## BIOS and firmware

- **Turn Secure Boot off.** Required for unsigned DKMS modules and a custom kernel.
- **Unlocking the Advanced menus is an EC runtime toggle, not a reflash**:
  `echo 1 | sudo tee /sys/devices/platform/minibook_ec/bios_unlock`. No reports of
  bricking.
- Watch out for the BIOS silently disabling NVMe after boot configuration changes. If
  the SSD disappears, re-enable NVMe in the BIOS.
- **There is no LVFS or fwupd support.** BIOS updates do exist but are distributed
  individually on request rather than published, so they cannot be relied on and do not
  add features such as a charge limit.

## Power and thermals

The survey recommended **S3 `deep`** for suspend, on the grounds that S0ix drains
overnight, and `dptf_enabler` plus a thermald fork to unlock TDP.

> **Both superseded.** s2idle reaches 99.7% S0i3 residency here, so `deep` has nothing
> to offer ([suspend-mode.md](suspend-mode.md)), and thermals need no help at all:
> 180 seconds at full load throttles zero times ([hardware-status.md](hardware-status.md)).

The fan is nearly silent, and its RPM is readable only through `minibook_ec`. Battery
life is around four to five hours from 28.9Wh.

## The one genuine hardware limit

**There is no charge threshold, and charging to 100% continuously causes coil whine,
heat and eventually battery swelling.** This is worth telling anyone who buys one.

The BIOS route is closed, confirmed four ways: no such register in the EC map;
multiple unresolved feature requests to Chuwi; a vendor statement that a BIOS update
alone cannot add it without charging-IC or EC firmware logic; and no such entry even in
the unlocked Advanced menus.

A hardware Chargie dongle works by **cutting VBUS at 80%**, not by setting a charging
IC threshold. That the dongle works is what makes a software equivalent plausible in
principle: the PD controller is an ANX7447 speaking standard TCPCI, reachable through
the EC's SMBus bridge, and TCPCI has a DisableSinkVbus command.

> Investigated and parked. The blocker is that the EC's SMBus register layout is
> undocumented. See [software-chargie.md](software-chargie.md).

## What the survey got right, and what it did not

Right:

- The kernel version thresholds
- The root cause of the missing tablet switch
- That hwdb cannot distinguish the two sensors
- The parts list, and that the charge limit is a real hardware limitation

Wrong, in each case by assuming a mechanism was needed before checking whether the
platform already provided it:

| Survey said | Actually |
|---|---|
| Patch intel-hid VGBS to fix auto-rotation | A uinput device bypasses the gate; the fork already does it |
| Reuse codingdave's hwdb mount matrix | It never matches this hardware |
| `panel_orientation` alone straightens boot, login and desktop | Nothing consumes it; each layer needs its own fix |
| Use `mem_sleep_default=deep` | s2idle is already at 99.7% residency |
| Install `dptf_enabler` and a thermald fork | Thermals need no help |
| A separate stack is needed to disable input in tablet mode | libinput does it for free |

The pattern is consistent enough to be worth stating: on this machine, **measure before
building.**
