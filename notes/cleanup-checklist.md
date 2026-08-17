# Cleanup checklist

What accumulates on a machine set up this way, and what of it **does not need to
stay**. Work through this after a few days of normal use.

Note that the installer is fairly frugal: the only packages `install/` adds are the
DKMS toolchain and the meson build set for iio-sensor-proxy. Everything else listed
below arrives only if you went looking at the hardware by hand, as this work did.

## Must be kept

```
linux-xanmod-x64v3          the kernel
build-essential  clang  lld  llvm  libelf-dev
                            Required by DKMS. XanMod is a clang + ThinLTO build, so
                            without these minibook_ec fails to rebuild. Needed on
                            every kernel update, so never remove them.
```

## Diagnostics, safe to remove

**Not installed by any script.** These were fetched by hand while working out causes,
and none of them is needed day to day. Worth keeping if you expect to look at the
hardware again.

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
for iio-sensor-proxy (installed by 05-tablet-mode.sh):
  meson  ninja-build  libgudev-1.0-dev  libpolkit-gobject-1-dev
  libudev-dev  libsystemd-dev  systemd-dev  pkg-config
```

**Only if you built the thermald fork by hand.** The installer never does, because
thermald is not installed here, so these will not be present unless you fetched them
yourself:

```
  autoconf  automake  libtool  autoconf-archive  gtk-doc-tools
  libdbus-1-dev  libdbus-glib-1-dev  libxml2-dev  libglib2.0-dev
  libupower-glib-dev  libevdev-dev  libnl-3-dev  libnl-genl-3-dev
```

**Careful**: other packages may depend on some of these, `libglib2.0-dev` in
particular. Do not clear them in one go with `apt-get autoremove --purge`. Simulate
with `apt-get remove -s` first and check that `kubuntu-desktop` is not dragged out
with them.

## Temporary files

The installer clones upstream into `~/.cache/minibook-install/chuwi-minibook`
(override with `MINIBOOK_WORK_DIR`), and every build happens there. Nothing is built
inside this repository.

```
~/.cache/minibook-install/  the whole working tree: the upstream clone, the meson
                            build under iio-sensor-proxy/_build/, and vbt_patch/ with
                            its downloaded kernel headers and built binary.
                            Removing it costs only a re-clone and a rebuild, but keep
                            vbt_patch/ if you might change the refresh rate again
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

If you ran any of upstream's DPTF diagnostic scripts by hand, they load the `msr`
kernel module. Nothing in this repository does, and `dptf_enabler` is not installed
here, so `modprobe -r msr` is safe if it is loaded.

## Kernel

The stock kernel was kept as a fallback initially and removed once XanMod had proven
itself. See [kernel-cleanup.md](kernel-cleanup.md) for the procedure and its traps.
