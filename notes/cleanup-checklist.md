# Cleanup checklist

Things installed during setup that **do not need to stay**. Work through this after a
few days of normal use.

## Must be kept

```
linux-xanmod-x64v3          the kernel
build-essential  clang  lld  llvm  libelf-dev
                            Required by DKMS. XanMod is a clang + ThinLTO build, so
                            without these minibook_ec fails to rebuild. Needed on
                            every kernel update, so never remove them.
```

## Diagnostics, safe to remove

Used to work out causes rather than needed day to day. Worth keeping if you expect to
look at the hardware again.

```
acpica-tools                iasl and acpidump, for ACPI, GNVS and SSDT work
                            (needed again if a BIOS update changes GNVS offsets)
libdrm-tests                modetest, for panel modes and panel orientation
evtest  libinput-tools      input event measurement
i2c-tools                   i2cget, used to read the accelerometer DEVID
                            and likely needed again for any EC work
```

## Build-only, safe to remove

The builds are done and only their output matters. Remove these if you do not expect
to rebuild.

```
for iio-sensor-proxy:
  meson  ninja-build  libgudev-1.0-dev  libpolkit-gobject-1-dev
  libudev-dev  libsystemd-dev  systemd-dev

for verifying the thermald build (thermald itself is not installed):
  autoconf  automake  libtool  pkg-config  autoconf-archive  gtk-doc-tools
  libdbus-1-dev  libdbus-glib-1-dev  libxml2-dev  libglib2.0-dev
  libupower-glib-dev  libevdev-dev  libnl-3-dev  libnl-genl-3-dev
```

**Careful**: other packages may depend on some of these, `libglib2.0-dev` in
particular. Do not clear them in one go with `apt-get autoremove --purge`. Simulate
with `apt-get remove -s` first and check that `kubuntu-desktop` is not dragged out
with them.

## Temporary files

```
/tmp/td/                    thermald build tree (gone on reboot)
upstream/iio-sensor-proxy/_build/
                            meson build tree
upstream/vbt_patch/         downloaded kernel headers and the built vbt_patch binary.
                            Keep this if you might change the refresh rate again
/etc/default/grub.bak.*     backups made by the script
/etc/default/grub.orig-*    the first backup
~/.config/kwinoutputconfig.json.bak-*
/var/lib/sddm/.config/kwinoutputconfig.json.bak-*
```

## Settings that should stay

| Item | Why |
|---|---|
| `/etc/modules-load.d/uinput.conf` | Needed by the tablet mode daemon |
| `/etc/modules-load.d/minibook_ec.conf` | Fan RPM, charger temperature, `bios_unlock` |
| `/etc/udev/hwdb.d/61-evdev-minibook-touchpad.hwdb` | Pointer jitter suppression (fuzz=24). See [touchpad-jitter.md](touchpad-jitter.md) |
| `dpkg-divert` for iio-sensor-proxy | Needed for as long as the fork is in use |
| BIOS `Screen Rotation Policy` = Right Rotation | The correct value for this panel |

The `msr` kernel module is loaded by `dptf-status.sh`. Run `modprobe -r msr` if you do
not use it.

## Kernel

The stock kernel was kept as a fallback initially and removed once XanMod had proven
itself. See [kernel-cleanup.md](kernel-cleanup.md) for the procedure and its traps.
