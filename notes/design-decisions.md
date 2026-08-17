# Design decisions, and how they turned out

Three decisions were taken before touching the machine. Two of them were wrong, and
the reasons are more useful than the conclusions were. This file records both the
plan and what actually happened.

## Background: KDE auto-rotation needs two signals

- **Orientation** from an accelerometer, consumed by iio-sensor-proxy
- **`SW_TABLET_MODE`**, an input switch event

This machine emits neither usefully out of the box. Its DMI says laptop, and it is
missing from the `intel-hid` VGBS allowlist, so no tablet switch appears.

## D1 — the auto-rotation and tablet stack

The options considered:

- **(a)** Patch the kernel's `intel/hid.c` VGBS handling to emit `SW_TABLET_MODE`.
  Elegant, but forces building a custom kernel.
- **(b)** Use the fstanis iio-sensor-proxy fork, which reports orientation itself.
  No kernel build, but a fork to keep current.
- **(c)** Poll and drive `kscreen-doctor`. Proven on Fedora KDE. Robust, but not
  native and polls continuously.
- **(d)** Synthesise the switch: instantiate the second accelerometer from userspace,
  compute the hinge angle in a daemon, and emit `SW_TABLET_MODE` through uinput, so
  that stock iio-sensor-proxy and native KDE auto-rotation consume it.

**Planned: (d).** The appeal was getting a stock kernel and fully native KDE
behaviour at the same time, decoupling this decision from the kernel one.

**Actually used: (b), the fork.** Option (d) was never needed. The fork already
handles both accelerometers and emits the tablet switch, so the synthesis it proposed
was work that had already been done upstream. The measured result is in
[d1-tablet-mode.md](d1-tablet-mode.md).

The instinct behind (d) was not wrong: gating rotation on tablet mode does matter.
With orientation alone the screen rotates in laptop posture too, which is bad. But
that gating came for free from the fork rather than needing a new daemon.

## D2 — kernel strategy

- **(a)** Build a patched XanMod. Forced if D1 went with (a). High maintenance.
- **(b)** Stock XanMod plus DKMS and userspace workarounds.

**Decided and used: (b).** This one held. No kernel patching is needed for anything
here, and DKMS covers the one module that is wanted.

Note that XanMod x64v3 is a clang, LLD and ThinLTO build, so `clang`, `lld`, `llvm`
and `libelf-dev` are not optional. Without them, every kernel update silently fails
to rebuild the module.

## D3 — disabling the keyboard and touchpad in tablet mode

- **(a)** petitstrawberry's stack, which brings its own tablet detection and virtual
  input layer.
- **(b)** Write to `minibook_ec` sysfs directly. The EC map has `0x0C TPTL` as
  `touchpad_enabled` and `0x0D KBCD` as `keyboard_enabled`, and `minibook_ec` was
  going to be installed anyway.

**Planned: (b).**

**Actually needed: nothing.** Emitting `SW_TABLET_MODE` is sufficient on its own,
because libinput disables the internal keyboard and touchpad in tablet mode as
documented standard behaviour. This was established by elimination on the machine:
the daemon's ACPI call failed for want of `/proc/acpi/call`, `minibook_ec`'s sysfs
values stayed at 1, and input was disabled regardless.

That result removed one of the two reasons for installing `minibook_ec` at all. It
stayed for the fan tachometer, the charger temperature and `bios_unlock`, which is
covered in [hardware-status.md](hardware-status.md).

## What this cost

Both wrong decisions shared a shape: designing a mechanism before checking whether
the platform already provided it. In D1 the fork already did the work; in D3 libinput
did. Neither was expensive to correct, because nothing had been built yet, but the
lesson is worth keeping.

The resulting stack is smaller than any of the plans: stock XanMod, one DKMS module,
one patched fork, and no custom daemons.
