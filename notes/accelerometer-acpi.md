# Accelerometer ACPI, measured

Read off the running machine (XanMod 7.1.8, Kubuntu 26.04). This matters for how the
dual accelerometer and tablet mode work, and it contains facts that were not in the
earlier research notes.

## Firmware declares three ACPI devices, not two

| Device | ACPI path | `_STA` | Physical node |
|---|---|---|---|
| `MXC6655:00` | `\_SB.PC00.I2C0.ACMG` | **0 (disabled)** | none |
| `MXC6655:01` | `\_SB.PC00.I2C2.ACMG` | **0 (disabled)** | none |
| `MDA6655:00` | `\_SB.ACMK` | 15 (enabled) | i2c-1 / `iio:device0` |

The earlier notes said only that firmware exposes both sensors behind a single
`MDA6655` HID. In fact **per-sensor `MXC6655` nodes exist as well, but with `_STA` at
0, so the kernel skips them.** Both carry uid 1.

**I2C0**, where `MXC6655:00` sits, is the same bus on which the second accelerometer
answers over raw I2C (address 0x15, DEVID 0x02). The hardware is alive; firmware has
simply switched it off at the ACPI level.

## What this means in practice

The obvious approach is to instantiate the second sensor from userspace:

```bash
echo mxc4005 0x15 > /sys/bus/i2c/devices/i2c-0/new_device
```

That works and is the simplest option. A cleaner one exists in principle: an SSDT
override making `MXC6655:00` return `_STA` 0x0F, so the kernel instantiates it through
the normal path, which would also make per-device udev rules for the mount matrix
natural.

The trade-offs:

- An SSDT override goes into the initramfs, so it is easy to undo and never touches
  firmware.
- But `MDA6655` (ACMK) and `MXC6655` may refer to the same physical chip, in which
  case enabling both would attach two drivers to one device. `MDA6655` is on i2c-1
  and `MXC6655:00` is on I2C0, so they are probably distinct, but that is unconfirmed.
- `MXC6655:01` sits on I2C2, and nothing has been confirmed on that bus at all.

In the end neither was needed. The iio-sensor-proxy fork reads the second sensor over
raw I2C directly, which is why patch 0005 validates its DEVID there rather than
assuming it. See [d1-tablet-mode.md](d1-tablet-mode.md).

**One consequence is worth remembering when reading any diagnostic:** a single
accelerometer in IIO is the correct state on this machine, not a symptom. Verification
scripts that expect two will report a false failure.

## Re-assessing codingdave/MiniBookX's hwdb

The research notes rated that project's hwdb mount-matrix rule as highly reusable.
**That was an overestimate.** Measured against the hardware:

- The rule's match key is `sensor:modalias:acpi:MXC6655*`, but the node that is
  actually enabled here is `MDA6655`. The modalias of the live node differs, so the
  rule **never matches**.
- The DMI half is fine. `/sys/class/dmi/id/modalias` strips the space and reads
  `pnMiniBookX`, matching the rule. (`product_name` itself is `MiniBook X`, with the
  space.)
- More fundamentally, hwdb keys on modalias, so it **cannot give two sensors sharing
  one modalias different matrices**. The same research note said as much seventy lines
  further down, contradicting its own earlier assessment.

So the delivery mechanism is not reusable. The matrix values might still be a
reference, but they disagree with each other:

- codingdave: `0,1,0; -1,0,0; 0,0,1`, determinant +1, a proper 90 degree rotation
- lschans: `0,1,0; 1,0,0; 0,0,1`, determinant -1, a mirror, which cannot describe a
  physical mounting

At most one of them is right, and neither was verified on an N150. This has to be
measured on the machine.

On the repository itself: nine commits in a single day in January 2023 and nothing
since, four files totalling a two-line hwdb entry and a two-line shell script, aimed
at the N5100 generation. GRUB rotation and tablet mode are left as TODOs by the author
too. Worth citing, but not leaning on.
