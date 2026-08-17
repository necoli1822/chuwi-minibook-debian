# Hardware status, measured

A full sweep of the running machine (Kubuntu 26.04, XanMod 7.1.8, KDE Plasma 6 on
Wayland). This is the baseline that decides **which modules are actually needed, by
measurement rather than assumption.**

## Already working on a stock install

| Item | State |
|---|---|
| Temperature sensors | Seven (coretemp x5, x86_pkg_temp, TCPU, TCPU_PCI, SEN3, acpitz, iwlwifi) |
| Display brightness | `intel_backlight`, 0 to 96000 |
| **Keyboard backlight** | **Fn+F5 cycles off, low, high, including auto-off.** Handled entirely by EC firmware |
| Battery | BAT0 fine |
| CPU scaling | `intel_pstate` with EPP support |
| Audio, Bluetooth, cameras (2), WiFi | All fine |
| Touchscreen | Full multitouch type B, correct coordinates |
| Touchpad and keyboard | Fine |
| Suspend | `freeze mem disk` all available |

## Missing on a stock install

- **Fan RPM and PWM**: all six hwmon devices report `fan=0 pwm=0`
- **`bios_unlock`**: access to the hidden BIOS Advanced menus
- **Charge threshold**: no `charge_control_end_threshold`, hence the software charge
  limiting question
- **One of the two accelerometers**
- **Most DPTF participants inactive**, see below

## The fan, measured

**The fan is real.** Reviews confirm active cooling with a fan and heatpipe, and it is
declared in ACPI. But it is in **SSDT6, not the DSDT**, so searching only the DSDT
finds nothing:

```
SSDT6:  Device (FAN0), Device (TFN1/TFN2/TFN3)
        Method (_FIF), Method (_FSL), Method (_FST)
```

All-core load for 100 seconds:

```
idle     RPM=0     SoC=34C  3010MHz
 50s     RPM=0     SoC=50C  2899MHz
100s     RPM=0     SoC=55C  2899MHz
+10s     RPM=2343  SoC=51C  3385MHz   <- fan starts
+20s     RPM=273   SoC=45C  2901MHz
throttle counters: core=0 pkg=0
```

Repeated with 180 seconds of load and 60 of cooldown, for the full curve:

```
 90s   RPM=0      pwm=0    SoC=54C   2900MHz
110s   RPM=2259   pwm=42   SoC=55C   2900MHz   <- starts
150s   RPM=2355   pwm=39   SoC=53C   2900MHz
180s   RPM=2343   pwm=38   SoC=54C   2900MHz
+10s   RPM=2343   pwm=39   SoC=49C   3375MHz   <- keeps running with no load
+20s   RPM=700    pwm=0    SoC=46C   3237MHz   <- EC cuts power, fan coasts
+30s   RPM=0      pwm=0    SoC=44C   3405MHz   <- stopped
```

What this shows:

1. **On at 55C, off between 46 and 49C.** A 6 to 9 degree hysteresis stops it
   oscillating.
2. **PWM eases down from 42 to 38.** The EC runs a closed loop and backs off once it
   decides the fan is doing enough.
3. PWM 38 to 43 is **about 15 to 17% of the maximum of 255**. There is a great deal of
   cooling headroom.
4. `minibook_ec`'s tachometer read works. Nothing else exposes this value.
5. **2900MHz held for the full 180 seconds with zero thermal throttling.** Once the
   fan is on, temperature settles at 53 to 54C.
6. ACPI `cooling_device0` stayed at 0 the whole time the fan was spinning at 2343 RPM.
   **The Linux ACPI fan interface is not involved; the EC governs the fan itself.**

## Fan speed cannot be controlled

Three routes were checked. All are closed.

**1. ACPI `FAN0` (SSDT6): on/off only.**

```
Device (FAN0) {
    Name (_HID, EisaId ("PNP0C0B"))
    Name (_PR0, Package (0x01) { FN00 })
}
```

It is a power-resource fan, so it can only be switched. There is no `_FPS` and no
`_FSL`, which is why `cooling_device0` has `max_state` 1. In any case the EC does not
use this path at all: the fan spins while `cur_state` stays 0.

**2. DPTF `TFN1-3` (which do have `_FPS`, in SSDT1): unusable, EC fields missing.**

Upstream's `docs/acpi.md` already records this:

```
TFN1  INTC1048  CFSP  CPU fan (EC field missing)
TFN2  INTC1048  DFSP  DDR fan (EC field missing)
TFN3  INTC1048  GFSP  GFX fan (EC field missing)
```

`dptf_enabler`'s own description of its `enable_fans` parameter says the same:
"broken: CFSP/DFSP/GFSP EC fields missing, causes AE_NOT_FOUND in dmesg".

Firmware declares the participants, but the EC fields they reference do not exist in
the EC firmware. **Never pass `enable_fans=1`.**

The reason is guessable. TFN1/2/3 as "CPU fan, DDR fan, GFX fan" is Intel's
three-fan reference template. This machine has one fan driven directly by the EC, so
Chuwi never implemented the DPTF-side fields.

**3. `minibook_ec`'s `pwm1`: read-only by design.**

`fan.c`'s `is_visible` returns 0444 for both `fan1_input` and `pwm1`. The I2EC write
path (`minibook_ec_i2ec_write`) does exist, so writing the PWM duty register
(`0x1809`) is not technically impossible, but the EC's control loop overwrites it on
the next cycle. Taking the fan over would mean disabling that loop first, and the
command to do so is undocumented.

**Conclusion: it cannot be controlled, and does not need to be.** The EC holds
temperature using 15% of the fan's range, backs off when it can, and has hysteresis.

A caveat on those numbers: they come from the second run, held on the `performance`
profile from start to finish. During the first run the power profile changed partway
through and the clock dropped from 2900 to 1357MHz **immediately, independent of
temperature.** That it was 51C at the time is coincidence, not cause; the throttle
counters were zero. Do not use the later part of that first run.

When testing thermals, check `powerprofilesctl get` first and do not change it mid-run.

## Which DKMS modules are worth it

| Module | Decision | Reason |
|---|---|---|
| **minibook_ec** | **installed** | Fan RPM, charger temperature and `bios_unlock` are all unavailable otherwise |
| `goodix_ts` | not installed | The touchscreen works perfectly on the in-tree driver. This patch targets a resume problem whose presence here is unconfirmed, and it disables the ESD recovery path as a side effect. Revisit if touch dies after a suspend |
| `i2c_designware_spklen` | not installed | Zero I2C errors. A 40ms touchscreen tap arrives intact through both evtest and libinput. There is no fault to fix |
| `dptf_enabler` | not installed | See below |

### What was removed from minibook_ec

`kbd_backlight.c` (234 lines, 26% of the module) is excluded from the build. See
`patches/0006-minibook_ec-drop-keyboard-backlight.patch`. The EC firmware already
handles the backlight perfectly, so there is nothing to gain, and this is the most
invasive code in the module: it writes GPIO gates and EC settings directly, and its own
comments admit it races the EC firmware.

`thermal.c` was kept. The SoC temperature duplicates one of the existing seven, but
the **charger temperature** (`minibook_charger`, IT5570E ADC channel 0) is available
nowhere else and is the only way to watch charging behaviour.

### Why dptf_enabler was not installed

The measured participant states:

```
INTC1041:00  status=15  driver=int3400   (active)
INTC1046:03  status=15  driver=int3403   (active)
INTC1046:00-02,04-06    status=0
INTC1048:00-02          status=0   <- TFN1/2/3, the fans
INTC1049:00             status=0
INTC1060:00             status=0
INTC1061:00             status=0
```

Most of them are indeed off. But:

- The point of waking them is to let **the thermald fork tune thermals and power**.
  That fork's `verify_dptf_participants()` refuses to start the daemon at all unless
  INTC1049, INTC1060 and INTC1061 are active.
- **Thermal management has no problem to solve.** 100 seconds at full load reaches
  55C with zero throttling.
- The EC governs the fan competently on its own.

So **no fault has been observed to fix.** If a concrete need for more sustained
performance appears, `dptf_enabler` and the thermald fork can be introduced together
at that point.

Note also that the BIOS offers every one of these as a native toggle, which is far
safer than a kernel module writing physical memory. See
[bios-findings.md](bios-findings.md).

## Aside: the RAPL numbers are nonsense

```
long_term  = 200000 mW   (max_power_uw = 6000000)
short_term =  15000 mW
peak_power =  78000 mW
```

A sustained limit of 200W on a 6W-class part is effectively no limit. Power is
evidently governed by the EC and firmware rather than by RAPL, which is why the
thermald fork tries to overwrite PPCC with 8000 to 17000 mW. The BIOS confirms it:
`Platform PL1 Enable` and `PL2 Enable` are both `Disabled`.

`energy_uj` is root-readable only, as mitigation for the RAPL side channel.

## The lock screen virtual keyboard cannot be made to appear

In tablet mode the internal keyboard is disabled, so if the screen locks while folded
**it can only be unlocked by unfolding it.** Attempts to get an on-screen keyboard
failed.

What was established:

- `qt6-virtualkeyboard-plugin` and `plasma-keyboard` are **both already installed**
  (`/usr/bin/plasma-keyboard` and `libqtvirtualkeyboardplugin.so` exist, and load
  without error)
- `kwinrc [Wayland] InputMethod` is **a single global setting**, so the lock screen
  cannot be given its own
- fcitx5's `virtualkeyboard` addon is a **DBus backend**, not a frontend that draws a
  keyboard. `ShowVirtualKeyboard` succeeds but the addon never loads
- ArchWiki notes that KWin hides the virtual keyboard when a physical keyboard is
  present, so `KWIN_IM_SHOW_ALWAYS=1` is needed

The combinations tried:

| InputMethod | KWIN_IM_SHOW_ALWAYS | Keyboard appeared | Input method still worked |
|---|---|---|---|
| fcitx5 | no | no | yes |
| Plasma Keyboard | no | no | no |
| fcitx5 | yes | no | yes |

The same problem is reported across distributions (NixOS issue 303526, KDE Discuss and
others). With every prerequisite present and still no keyboard, there was little left
to try, so this was abandoned and every setting reverted.

The only mitigation is to lengthen or disable the automatic lock timeout.

This belongs in a hardware note rather than a desktop one: on an ordinary laptop an
on-screen keyboard is a convenience, but **this machine disables its keyboard when
folded**, so its absence removes the means of unlocking.
