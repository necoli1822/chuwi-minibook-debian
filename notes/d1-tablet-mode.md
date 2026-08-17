# Dual accelerometer and SW_TABLET_MODE

**It works**, and it needed no new code. Installing the fstanis iio-sensor-proxy fork
was enough.

## Plan versus reality

The design notes had "synthesise a tablet switch through uinput" down as the project's
central piece of new work. In fact **the fork's `src/drv-mxc6655-accel.c` already
implements exactly that design.** Nothing needed writing.

## Measured

Sixty seconds of folding and unfolding the lid:

```
[18s]  88.4 deg   KWin tabletMode=false  SW_TABLET_MODE=OFF   <- laptop
[20s] 328.4 deg   KWin tabletMode=true   SW_TABLET_MODE=ON    <- switches
[22s] 359.3 deg   KWin tabletMode=true   SW_TABLET_MODE=ON
[24s]   3.5 deg   KWin tabletMode=true   SW_TABLET_MODE=ON    <- wrapped past 360
[30s] 302.7 deg   KWin tabletMode=true   SW_TABLET_MODE=ON    <- unfolding
[32s]  84.7 deg   KWin tabletMode=false  SW_TABLET_MODE=OFF   <- back to laptop
```

The whole chain is connected:
**two accelerometers -> hinge angle -> uinput SW_TABLET_MODE -> KWin tabletMode**

The virtual device it creates:

```
N: Name="MXC6655 Tablet Mode Control"
I: Bus=0006 (BUS_VIRTUAL) Vendor=4358 Product=0001
S: Sysfs=/devices/virtual/input/input19   H: Handlers=event15
B: SW=0x2  (SW_TABLET_MODE)
```

The `3.5 deg` reading at 24s shows how carefully this was built. The angle wrapped past
360 and tablet mode held anyway, because a `min_angle=30` rule discards readings below
30 degrees so they are not mistaken for a closed lid.

## acpi_call is not needed

During the audit this fork appeared to require the out-of-tree `acpi_call` module,
which would have been the single largest increase in attack surface in this project.
**Reading the code shows otherwise.**

```c
static gboolean load_gmtr (DrvData *drv_data)
{
	drv_data->tablet_thresh = GMTR_TABLET_THRESH;   /* 185.0 */
	drv_data->laptop_thresh = GMTR_LAPTOP_THRESH;   /* 175.0 */
	drv_data->min_angle     = GMTR_MIN_ANGLE;       /*  30.0 */

	if (acpi_call_read (ACPI_GMTR_CMD, buf, sizeof (buf)) < 0)
		return FALSE;      /* the defaults are already in place */
	...
}
```

The defaults are set **before** the ACPI read is attempted. `call_ltsm()` likewise just
warns once and returns -1 on failure. As the measurements above show, the default
thresholds work correctly on their own.

Disabling the keyboard and touchpad does not need it either; see below.
**`acpi_call` is not installed.**

## Do not use --lazy

An earlier reading of the audit suggested `--lazy` to save battery. **That is wrong for
this use.**

The option's own help says why: "Only poll sensors while a D-Bus client has claimed
them".

```c
:788   if (!data->lazy) driver_set_polling (sensor_device, TRUE);
:430   if (data->lazy && ... size == 0) driver_set_polling (sensor_device, FALSE);
```

Watching a hinge requires continuous polling by definition. Worse, KDE is set to
`autoRotation: InTabletMode`, so **it only claims the sensors once tablet mode is
active, and detecting tablet mode is what needs the polling.** The fork's non-lazy
default is correct.

## Installing without removing the distribution package

Upstream's guide says to `apt remove iio-sensor-proxy`. On this system that is
dangerous: it takes the `kubuntu-desktop` meta package with it, which marks desktop
components as no longer required and leaves them exposed to a later `apt autoremove`.

The audit supplies a better route. The fork's **systemd unit, udev rules, D-Bus policy
and polkit policy are byte-identical to upstream's**; only the binary differs. So swap
only the binary:

```bash
dpkg-divert --local --divert /usr/libexec/iio-sensor-proxy.distrib \
            --rename --add /usr/libexec/iio-sensor-proxy
install -m755 -o root -g root _build/src/iio-sensor-proxy /usr/libexec/iio-sensor-proxy
```

`--local` is required. `--package iio-sensor-proxy` means "that package keeps using the
original name", which does the opposite of what is wanted and causes the rename to be
skipped.

Package updates now put the distribution's file at `.distrib` and leave the fork in
place.

The distribution ships 3.8 and the fork is based on 3.9, but the only data file
differences are two Qualcomm SSC items (a fastrpc DSP udev rule and the `AF_QIPCRTR`
socket family), neither of which applies to Intel hardware. The 3.8 unit and rules are
used unchanged.

## Build notes

What Ubuntu 26.04 needs:

```
meson ninja-build libgudev-1.0-dev libpolkit-gobject-1-dev
libudev-dev libsystemd-dev systemd-dev
```

`systemd-dev` is the important one. `meson.build` resolves `dependency('udev')` and
`dependency('systemd')`, which need `udev.pc` and `systemd.pc`. Those come from
`systemd-dev`, not from `libudev-dev`, which only provides `libudev.pc`.

GTK is only used by the `gtk-tests` option and is not required.

## uinput has to be loaded explicitly

The `/dev/uinput` node exists but the module was not loaded, and the systemd unit sets
`ProtectKernelModules=true`, so it cannot load it itself.

```bash
modprobe uinput
echo uinput > /etc/modules-load.d/uinput.conf
```

The rest of the unit's hardening is fine. There is no `PrivateDevices=` or
`DeviceAllow=`, so `/dev/uinput` and `/dev/i2c-*` remain reachable, and
`ProtectSystem=strict` still leaves `/sys` writable, so unbinding mxc4005 works.

## Auto-rotation

Confirmed by use: the screen rotates in tablet mode and stays put in laptop mode, which
is what `autoRotation: InTabletMode` is meant to do.

## Disabling the keyboard and touchpad came free

This was planned as separate work. **Emitting `SW_TABLET_MODE` solved it on its own.**

Folding the lid stops the keyboard and touchpad responding, and unfolding brings them
back. Which mechanism does it was established by elimination:

- The daemon's LTSM call **failed**:
  `iio-sensor-proxy: Cannot open /proc/acpi/call: No such file or directory`
- Neither the `acpi_call` module nor `/proc/acpi/call` exists
- `minibook_ec`'s `keyboard_enabled` and `touchpad_enabled` **stayed at 1**

That leaves libinput, and this is its documented standard behaviour:

> When the device switches to tablet mode, the touchpad and internal keyboard
> are disabled. If a trackpoint exists, it is disabled too.
> (libinput, Switches)

So neither writing `minibook_ec` sysfs nor petitstrawberry's userspace stack is needed.
The uinput switch simply feeds libinput's existing path.

This is the other side of a problem the community has had. libinput introduced a DMI
chassis type allow-list (31 Convertible, 32 Detachable) because spurious
`SW_TABLET_MODE=1` reports were making laptops unusable. This machine reports chassis
type 10 (Notebook), which is why no switch appeared through intel-hid or intel-vbtn,
and why a uinput device bypasses that gate.

### Reassessing the case for minibook_ec, honestly

Providing sysfs for this was one of the main reasons to install `minibook_ec`, and
**that reason has evaporated.** What remains:

- `bios_unlock`
- Fan RPM, with no other source
- Charger temperature, with no other source

`keyboard_enabled` and `touchpad_enabled` remain useful as a manual override, for
instance to disable the keyboard while not in tablet mode.

## Left open

The battery cost of continuous non-lazy polling was never measured.
