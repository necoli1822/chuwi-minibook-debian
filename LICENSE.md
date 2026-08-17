# Licences

This repository consists mostly of **modifications to, and ports of, other projects**.
Each component therefore **keeps the licence of what it derives from**.

The structure mirrors the `LICENSE.md` of
[fstanis/chuwi-minibook](https://github.com/fstanis/chuwi-minibook), which this work
builds on.

## patches/ — follows the target

A patch is a derivative of the work it modifies, so each one carries its target's
licence.

| Patch | Target | Licence |
|---|---|---|
| `0001-dptf_enabler-*.patch` | `modules/dptf_enabler/` | GPL-2.0-or-later |
| `0002-goodix_ts-*.patch` | `modules/goodix_ts/` | GPL-2.0 (derived from the kernel's `drivers/input/touchscreen/goodix.*`) |
| `0003-vbt_patch-*.patch` | `vbt_patch/` | GPL-2.0 (includes kernel VBT headers) |
| `0004-i2c_spklen-*.patch` | `modules/i2c_designware_spklen/` | GPL-2.0-or-later |
| `0005-iio-sensor-proxy-*.patch` | `iio-sensor-proxy/` | GPL-3.0 |
| `0006-minibook_ec-*.patch` | `modules/minibook_ec/` | GPL-2.0-or-later |
| `thermald-minibook-rebased.patch` | `thermal_daemon/` | GPL-2.0 |

## scripts/, install/ — 0BSD

`scripts/update-vbt-clock-debian.sh` is a Debian-family port of upstream's
`tools/update-vbt-clock.sh`, which is 0BSD, so it stays **0BSD**.

The scripts under `install/` were written for this repository and are released under
the same **0BSD** as upstream's `tools/`.

> Permission to use, copy, modify, and/or distribute this software for any
> purpose with or without fee is hereby granted.
>
> THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
> REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
> AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
> INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
> LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
> OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
> PERFORMANCE OF THIS SOFTWARE.

## notes/, README.md — CC BY 4.0

Documentation is under
**[Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)**,
matching upstream's documentation licence.

## What this repository does not distribute

`patches/` contains **diffs only**. No upstream source is included here; the scripts
under `install/` fetch the upstream repository at a pinned commit when they run.

Distributing this repository is therefore not a redistribution of upstream code. If
you distribute built artefacts, the GPL obligations of each target apply to you,
including making the corresponding source available.

## Attribution

If you cite this repository or build on it, please credit not only this work but
**[fstanis/chuwi-minibook](https://github.com/fstanis/chuwi-minibook)** as well. The
kernel modules and the EC reverse engineering are entirely that project's doing.

Full credits are in the [credits section of README.md](README.md#credits).
