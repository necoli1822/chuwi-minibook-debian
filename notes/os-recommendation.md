# Choosing the distribution

Target hardware: **MiniBook X N150** (Intel N150, Twin Lake, effectively an
Alder Lake-N rebadge). The priority was stability and long-term support, with the
complication that this hardware needs a recent kernel for basic functionality.

## The binding constraint is the kernel version

The N150 shipped in 2025. Twin Lake is close enough to Alder Lake-N that any 6.x
kernel covers the SoC and graphics, but older ones do not.

Reported in the wild:

- Ubuntu 22.04, old kernel: **WiFi not detected**
- Ubuntu 24.10 (6.11): sound, Bluetooth, WiFi, camera and suspend/resume all fine
- Kubuntu 24.04 LTS: essentially works, apart from the display coming up rotated

So **6.8 is the floor and 6.11 or newer is sensible.** Old LTS releases such as
Ubuntu 22.04 and Debian 12 are unsuitable.

Enumerating both accelerometers additionally needs **6.9 or newer**, for
`serial-multi-instantiate`.

## Candidates considered

| Distribution | Kernel | Support until | Fit |
|---|---|---|---|
| Ubuntu 24.04 LTS (HWE) | 6.8, HWE 6.14 | ~2029 | Verified on this hardware by others |
| Debian 13 "Trixie" | 6.12 LTS | ~2028 | Plain Debian, non-free-firmware included by default |
| Ubuntu 26.04 LTS | 7.0 | 2031 | Newest kernel, but a new release |
| Ubuntu 22.04 / Debian 12 | 5.15 / 6.1 | — | Kernel too old, WiFi problems. Excluded |

## What was chosen

**Kubuntu 26.04 LTS**, with the **XanMod** kernel and **KDE Plasma 6 on Wayland**.

The reasoning was to take the newest kernel and Mesa available in an LTS, since almost
every problem on this machine is a hardware-enablement problem where newer is better.
Ubuntu 24.04 LTS with HWE would have been the more conservative choice and is a
reasonable alternative.

A point release was preferred over `.0` for stability, though installing `.0` and
running `apt full-upgrade` reaches the same place.

## Porting from the Arch-based guide

Upstream's guide assumes CachyOS, so several things needed changing for the Debian
family:

- **Bootloader**: the guide assumes Limine and mkinitcpio. Here it is GRUB with
  `update-grub` and `update-initramfs`.
- **`tools/update-vbt-clock.sh`** hardcodes Limine and mkinitcpio paths, so it was
  ported. See [vbt-refresh-rate.md](vbt-refresh-rate.md).
- **iio-sensor-proxy**: the guide says to remove the distribution package before
  installing the fork. On Kubuntu that drags `kubuntu-desktop` out with it, so
  `dpkg-divert --local` is used instead.
- **DKMS**: XanMod x64v3 is a clang, LLD and ThinLTO build, so `clang`, `lld`, `llvm`
  and `libelf-dev` are mandatory. gcc alone is not enough, contrary to the initial
  assumption here.

## How the plan changed once it met the hardware

This file originally listed a much larger set of work. Most of it turned out to be
unnecessary, and the reasons are recorded in the notes rather than here:

| Planned | What happened |
|---|---|
| Four DKMS modules | Only `minibook_ec` earns its place. See [hardware-status.md](hardware-status.md) |
| thermald fork | Not installed. 180s at full load throttles zero times without it |
| `i915.enable_psr=0` for tearing | Not applicable. PSR is eDP-only and this panel is DSI |
| `mem_sleep_default=deep` for overnight drain | Not set. s2idle already reaches 99.7% residency. See [suspend-mode.md](suspend-mode.md) |
| Custom hinge daemon for tablet mode | Not needed. The fork already does it. See [design-decisions.md](design-decisions.md) |
| Writing EC sysfs to disable input in tablet mode | Not needed. libinput does it from `SW_TABLET_MODE` alone |

The aim of the project was never to fork one upstream and follow it, but to combine
what several community efforts had found into something that works on the Debian
family. In practice that mostly meant **measuring which of their fixes this machine
actually needs**, and the answer was fewer than expected.

## What still needs fixing on any distribution

Everything below is hardware, not desktop environment, so the choice of DE does not
change it:

- The display comes up rotated 90 degrees, including at boot, login and on the TTY
- Auto-rotation and tablet mode, because there is no tablet switch out of the box
- The panel is locked to 50Hz
- Fan speed, temperatures and CPU power limits are invisible without the EC module
- Fractional scaling on a 1200x1920 panel, which the desktop settings handle

Out of the box the following already work on stock Kubuntu: WiFi, Bluetooth, audio,
webcam, trackpad, touchscreen, keyboard, and suspend/resume.
