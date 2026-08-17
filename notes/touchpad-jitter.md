# Touchpad pointer jitter

The pointer shook constantly under a resting or lightly moving finger. **Fixed by
giving libinput a `fuzz` value of 24 through hwdb.**

## The symptom, and the first wrong diagnosis

"The pointer shakes rapidly." It looked like a sensitivity problem. It was not: the
adaptive acceleration profile was already scaling the deltas **down**.

```
raw -5.00 -> actual -3.76
raw +7.00 -> actual +5.27
```

## The cause

These are the only evdev axes this touchpad (`0911:5288`) has:

```
ABS_X / ABS_Y            0..1156 / 0..619, resolution 14/mm
ABS_MT_POSITION_X / Y    same
ABS_MT_SLOT              0..4
ABS_MT_TRACKING_ID
```

**It reports neither pressure (`ABS_MT_PRESSURE`) nor contact size
(`ABS_MT_TOUCH_MAJOR`)**, and every axis had a `fuzz` of 0.

libinput derives its jitter hysteresis margin from the kernel's `fuzz` value. A fuzz
of 0 makes that margin 0, so **there is effectively no filter and raw sensor noise
reaches the pointer directly.**

There were zero I2C errors and zero HID errors, so this is neither a bus problem nor a
hardware fault. The decision not to install `i2c_designware_spklen` still stands.

The decisive clue came from using the machine: **a fingertip shakes more than a flat
finger.** A touchpad computes its coordinate from the centroid of the activated sensor
cells, so a small contact area lets one noisy cell move the centroid a long way. On a
pad that does not report contact size, libinput cannot adapt the filter to how much
finger is touching, which means **one fixed fuzz has to cover both cases.**

## The fix

```
/etc/udev/hwdb.d/61-evdev-minibook-touchpad.hwdb

evdev:name:XXXX0000:05 0911:5288 Touchpad:*
 EVDEV_ABS_00=0:1156:14:24
 EVDEV_ABS_01=0:619:14:24
 EVDEV_ABS_35=0:1156:14:24
 EVDEV_ABS_36=0:619:14:24
```

The format is `min:max:resolution:fuzz`. A fuzz of 24 is 24/14, about 1.7mm.

The value was raised through 8, 16, 20 and 24, judged each time by using the machine.
At 24 the jitter is essentially gone and the response is slightly slower but not
troublesome. Higher values make the start of a movement sticky and small targets hard
to hit.

## Two udev traps, without which the value never lands

Changing the value repeatedly appeared to do nothing, or worked and then reverted on
its own. Both causes were in udev.

**1. The trigger must target the event node.**

```
/lib/udev/rules.d/90-libinput-fuzz-override.rules
  KERNEL!="event*", GOTO="libinput_fuzz_override_end"
  IMPORT{program}=".../libinput-fuzz-extract"   # kernel fuzz -> LIBINPUT_FUZZ_* property
  RUN{program}+=".../libinput-fuzz-to-zero"     # kernel fuzz -> 0
```

Triggering the parent input node runs `60-evdev.rules` but skips this one. The hwdb
value then reaches the kernel while **the `LIBINPUT_FUZZ_*` property that libinput
actually reads stays at its old value.** The fuzz appeared to be 20 for a while when
it was still 16.

**2. It takes two triggers.**

`IMPORT{program}` runs inline during rule processing, but the builtin that writes the
hwdb value into the kernel (`RUN{builtin}="keyboard"`) runs only after all rules have
been processed. So the extract program always reads the **previous** value, and the
setting lands one trigger late.

```bash
sudo systemd-hwdb update
sudo udevadm trigger --action=add /sys/class/input/event4   # first
sudo udevadm trigger --action=add /sys/class/input/event4   # second, this one lands
udevadm info /dev/input/event4 | grep LIBINPUT_FUZZ_35      # confirm
```

**Neither applies after a reboot.** At boot the kernel fuzz starts at the hwdb value,
so it is correct on the first pass.

## What not to do while diagnosing this

**Do not casually run `libinput debug-events`.** Running it opens the device and has
the same effect as `libinput-fuzz-to-zero`, setting the kernel fuzz to 0. It is
entirely possible to undo the fix while trying to measure it.

A kernel fuzz of 0 is **normal by design**. libinput reads the value, uses it for
hysteresis, then zeroes the kernel copy to avoid double filtering, storing the
original in a `LIBINPUT_FUZZ_*` udev property. So do not check this with `evtest`;
check `udevadm info`.

## Mistakes made along the way

- `evtest --query` was used to check for pressure support. evtest had actually printed
  its usage text, and that was misread as an exit code. A full dump shows there is no
  pressure axis at all.
- The report rate was called 50Hz. That came from dividing 399 events by the whole
  8-second window; the timestamps are 7.5ms apart, so **it is 133Hz, which is normal**.
- Seeing zero events while idle and while holding still nearly led to a verdict of "no
  jitter". Without being told that the pointer visibly drifted under a stationary
  finger, this would have been signed off as working. When what is on screen and what
  the capture says disagree, suspect the capture.

## Limits

Hysteresis only applies **while stationary**. Once the finger crosses the margin and
real movement starts, the filter releases and tracks directly, so **jitter during
movement cannot be fixed with fuzz.** The only remaining lever there is pointer speed,
in the `[Libinput][...]` group of `kcminputrc`.

Keep the acceleration profile on `adaptive`. It scales slow movement down, which helps
suppress jitter; `flat` makes it worse.
