# What is in the hidden BIOS

Findings from opening the hidden AMI Aptio menus with `minibook_ec`'s `bios_unlock`
and going through all of them.

## The unlock itself

```bash
echo 1 | sudo tee /sys/devices/platform/minibook_ec/bios_unlock
```

This is a **single volatile write** of the magic value `0xAA` to EC register `0xF0`.
It touches neither NVRAM nor flash. When it works, the Advanced menu expands to around
24 entries; locked, only a handful are visible.

**Important: the flag survives exactly one reboot.** Unlock and reboot must be done as
one action. Any other boot in between loses it, as does cutting power entirely.

## Getting into the BIOS: not with the keyboard

**Neither Esc nor Del works.** Not after raising `Setup Prompt Timeout` from 1 to 3,
and not from a cold start either. Chuwi appears to have disabled key entry. (ArchWiki
lists Esc for this model; it did not work on this unit.)

Two things do work:

```bash
sudo systemctl reboot --firmware-setup   # the reliable one
```

or picking **UEFI Firmware Settings** from the GRUB menu.

`OsIndicationsSupported` is 31 with bit 0 (BOOT_TO_FW_UI) set, which is what makes the
first one available.

**Safety implication**: if Linux will not boot, the first method is unavailable. GRUB's
`fwsetup` entry is then the only way in. This is one of the two reasons the GRUB menu
is **left visible** rather than hidden; see
[display-rotation.md](display-rotation.md). Even if it were hidden, `recordfail`
brings it up automatically after a failed boot, so the path would still exist.

## Battery charge limiting: not present

Checked `Oem Extend Setup Configuration` (the most likely place), DPTF, `Chipset`,
`Security` and `Boot`. There is no charge threshold anywhere. `Oem Extend` contains
only a TPM check, Auto Power On, Wake On LAN and RTC Wake.

DPTF's `Battery Participant` throttles charge current on thermal grounds; it is not a
"stop at 80%" control.

**This is what keeps the software charge limiting idea alive.** See
[software-chargie.md](software-chargie.md).

## dptf_enabler is unnecessary

`Advanced -> Thermal Configuration -> Intel(R) Dynamic Tuning Technology Configuration`
offers **as native toggles everything that module pokes GNVS memory to achieve**, and
the values map one to one onto what Linux reports:

```
Intel(R) Dynamic Tuning Technology:  [Enabled]
INT3400 Device:                      [Enabled]            <- INTC1041:00 status=15
Processor Thermal Device:            [SA Thermal Device]  <- INTC1046:03 status=15
PPCC Step Size:                      [0.5 Watts]

FAN1/FAN2/FAN3 Device:               [Disabled]  <- TFN1-3 = INTC1048:00-02 status=0
Charger participant:                 [Disabled]
Power participant:                   [Disabled]  <- INTC1049
Battery Participant:                 [Disabled]  <- INTC1060/1061
PCH FIVR Participant:                [Disabled]

Sensor Device 1,2,4,5:               [Disabled]
Sensor Device 3:                     [Enabled]   <- SEN3, the one Linux sees
```

Setting these in firmware is incomparably safer than writing physical memory from a
kernel module.

**Do not enable `FAN1-3`.** The EC does not implement the fields they reference
(CFSP, DFSP, GFSP), so they only produce `AE_NOT_FOUND`.

## Screen Rotation Policy: GRUB cannot be fixed

This lives under `Boot` and offers Normal, Right Rotation, Left Rotation and
Reversion. Three of the four were tested directly:

| Setting | Logo and BIOS screen | GRUB | BGRT status |
|---|---|---|---|
| `Normal` | rotated 90 left | **rotated 90 left** | 0 (not displayed), image 1024x768 |
| `Right Rotation` | **upright** | **rotated 90 left** | 7 (displayed, offset 3) |
| `Left Rotation` | 180 degrees | **rotated 90 left** | 3 (displayed, offset 1) |

**The logo and the BIOS screen follow the setting exactly, while GRUB stays rotated 90
left in every case.** GRUB ignores the firmware's rotation policy entirely and draws
into the GOP framebuffer in its own coordinate system. There was no point testing
`Reversion`.

This confirms by measurement what [display-rotation.md](display-rotation.md) had
concluded about GRUB, which is now established rather than inferred.

**`Right Rotation` is the correct value.** It is the only one where the logo and the
BIOS screen come up upright, so it stays.

Incidental finding: under `Normal` the firmware drops to a lower GOP mode (1024x768).
This shows up as a lower GRUB resolution and is confirmed by the BGRT image size.

## Quiet Boot removes the vendor logo

Setting `Boot -> Quiet Boot` to `Disabled` flips bit 0 (Displayed) of the BGRT status
from 1 to 0, meaning **the firmware does not draw the logo at all.**

On this firmware `Quiet Boot` means "do not draw the logo" rather than "show POST text
instead of the logo". The visible difference is small enough to miss, but BGRT
confirms it.

Note that `Quiet Boot` is itself hidden when the BIOS is locked. It is a standard AMI
entry so it was expected to remain visible; it does not. Reverting it needs another
unlock.

## Other values worth recording

| Item | Value | Meaning |
|---|---|---|
| `Platform PL1 Enable` | `Disabled` | Why RAPL reports a meaningless 200W long_term |
| `Platform PL2 Enable` | `Disabled` | Same |
| `Boot performance mode` | `Turbo Performance` | |
| `LPM S0i2.0` / `S0i3.0` | `Enabled` | S0ix is on, relevant to the suspend mode decision |
| `DeepSx Power Policies` | `Disabled` | Same |
| `Sensor Hub Type` | `I2C Sensor Hub` | Why the accelerometers hang directly off I2C |
| `Fast Boot` | `Disabled` | Already off |
| `Setup Prompt Timeout` | 1 -> **3** | Key entry still does not work, but harmless |
| `Boot Option #1` | `USB Device` | Left alone for USB boot convenience |

`CFG Lock` is probably under
`Advanced -> Power & Performance -> CPU - Power Management Control -> CPU Lock Configuration`,
but this was not checked. There is no reason to unlock it here.

`Chipset -> System Agent -> Display setup menu` and `Graphics Configuration` were not
examined and may be relevant to VBT work.

## Deliberately left alone

- **`Platform PL1/PL2 Enable`**: enabling them would make RAPL meaningful, but thermals
  are not a problem here and the firmware defaults could cap performance instead.
- **DPTF `Power` and `Battery` participants**: only useful with the thermald fork,
  which is not being used.
- **`CFG Lock`**: no reason to unlock MSR 0xE2.
