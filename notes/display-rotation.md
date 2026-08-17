# Display rotation

Measured and fixed on the machine (Kubuntu 26.04, XanMod 7.1.8, KDE Plasma 6 on
Wayland). **One assumption in the earlier research notes turned out to be wrong, so
this file supersedes them.**

## The hardware

| Item | Value |
|---|---|
| Connector | DSI-1, the only connected output |
| Native mode | 1200x1920 @ 50.00Hz |
| Physical size | 141 x 226 mm, portrait in the panel's own axes |
| Mounting | Rotated 90 degrees inside a landscape chassis |
| Driver | i915 (xe also loads but has zero references) |

## The assumption that was wrong

The research notes said that the kernel parameter
`video=DSI-1:panel_orientation=...` alone would straighten **the boot splash, the
login screen, the TTY and the desktop**. On the machine it does not.

The parameter applies correctly. dmesg says so:

```
[drm] cmdline forces connector DSI-1 panel_orientation to 3
```

and the DRM property changes with it (modetest shows `panel orientation` going from 0
to 3).

**Yet nothing on screen moves.** DRM's panel orientation is an *informational
property* saying "the panel is mounted like this"; whoever reads it has to do the
rotating. On this system, measurement shows nobody does:

- **KWin** ignores it and applies its stored `transform: "Normal"`, leaving the logical
  resolution at 828x1325, still portrait.
- **fbcon** keeps `/sys/class/graphics/fbcon/rotate` at 0.
- **Plymouth and SDDM** do not rotate either, confirmed by looking at the screen.

## What does work

### Desktop (KWin)

An explicit transform is required. The kernel parameter will not do it.

```bash
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0
kscreen-doctor output.DSI-1.rotation.right
```

**`right` is the correct value**, confirmed visually. It persists to
`~/.config/kwinoutputconfig.json` as `transform: "Rotated270"`, and the logical
resolution becomes 1325x828, landscape.

kscreen's rotation enum is None=1, Left=2, Inverted=4, Right=8, so this reads back as
`Rotation: 8`.

### Login screen (SDDM)

SDDM keeps **its own KWin output configuration** and does not inherit the user's.

```
/var/lib/sddm/.config/kwinoutputconfig.json
```

Its DSI-1 entry needs the same `transform: "Rotated270"`, owned by `sddm:sddm`.
Through the GUI: System Settings, Login Screen, Apply Plasma Settings.

### Plymouth boot splash

The cause was not plymouth but **module load order**. The original timeline:

```
0.69s  simpledrm initialises (EFI framebuffer, zero panel orientation properties)
2.72s  plymouth starts        <- no i915 yet
3.62s  i915 initialises (panel orientation = 3)
```

Plymouth does support panel orientation (freedesktop commit 4992f06). But starting
inside the initramfs, the only DRM device it could see was simpledrm, which has no
panel orientation property at all (confirmed as zero properties via modetest). So it
drew the logo into an EFI framebuffer that carried no rotation information.

Plymouth itself was already in the initramfs (81 files, `plymouthd` plus
`renderers/drm.so`). What was missing was i915.

**The fix**: add `i915` to `/etc/initramfs-tools/modules` and run
`update-initramfs -u -k all`. That pulls in the module and its firmware
(`adlp_dmc.bin` and friends), 50 entries in total, and the initramfs grows from 90MB
to 95MB. The result:

```
1.59s  i915 initialises   <- two seconds earlier
4.25s  plymouth starts    <- now it can see i915
```

Confirmed visually: the boot splash is upright.

### TTY text console

Add `fbcon=rotate:1` to the kernel command line. (0=normal, 1=90, 2=180, 3=270.)

Note that this parameter had **no effect at all before i915 was in the initramfs**. Up
to then fbcon was not even bound to a framebuffer: only `vtcon0: dummy device`
existed, and writing to `/sys/class/graphics/fbcon/rotate` reverted to 0. Once i915
came up early, `vtcon1: frame buffer device bound=1` appeared and `rotate=1` took
effect. **The two fixes are not independent; the initramfs change is a prerequisite.**

Confirmed visually on Ctrl+Alt+F3.

### GRUB menu: cannot be fixed

**GRUB2 has no screen rotation.** Neither the VBE driver nor gfxterm contains rotation
code, so no configuration can work around it. This is the repeated conclusion on the
Fedora, openSUSE and Arch forums, and it remains unsolved on similar machines such as
the GPD Pocket. codingdave/MiniBookX left "grub rotation" as an unresolved TODO too.

#### An idea that was tried and failed: `GRUB_TERMINAL_OUTPUT=console`

**The hypothesis**: BGRT shows that the firmware knows about the panel rotation.

```
BGRT logo image = 1920x1200 (landscape)
BGRT status = 7 -> bit0 Displayed=1, bits1-2 Orientation offset=3 (270 degrees)
```

The firmware rotates its own logo by 270 degrees, which is why the vendor logo appears
upright. GRUB defaults to `gfxterm` and draws **directly** into the GOP framebuffer,
so it never gets that correction. If GRUB were switched to firmware text output (UEFI
ConOut), would the firmware correct it the way it corrects the logo?

**No.** The menu came up in exactly the same orientation. The firmware's awareness of
rotation **applies only to the BGRT logo blit, not to general console output.** The
setting was reverted to Ubuntu's default gfxterm.

With that hypothesis dead, there is no software option left at the GRUB layer.

#### The only remaining theoretical fix, which is not recommended

It is at the firmware level. GopRotate, an EDK2 UEFI driver, rotates GOP output by
0, 90, 180 or 270 degrees. But installing a driver into locked AMI firmware risks
bricking the machine. The gain is a five-second menu screen; the potential loss is the
whole device.

**Conclusion: accept that the GRUB menu appears sideways.** Everything after it in the
boot sequence, meaning plymouth, the login screen, the desktop and the TTY, is upright.

#### Mitigation: hide the menu — considered and declined

Since it cannot be rotated, it could instead be hidden, by restoring Kubuntu's own
defaults:

```
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=0
```

**This was decided against, and no install step does it.** The setting stays at `menu`
with a 5 second timeout.

It was set that way during the work because kernel and DKMS changes need a fallback
that can be selected immediately. Once everything was stable the question was revisited
and the menu was kept anyway, for two reasons:

- Five sideways seconds is a small price. The screen is upright from plymouth onwards,
  so this is the only stage that is ever wrong.
- If Linux will not boot, GRUB's `fwsetup` entry is the **only** way into the BIOS on
  this firmware, because key entry during POST is disabled. See
  [bios-findings.md](bios-findings.md).

The rest of this section is kept because it establishes that hiding it *would* be safe,
for anyone who would rather not see it.

Hiding it is safe because of Ubuntu's **recordfail** mechanism, which was confirmed
working here:

- `/boot` is ext4, so GRUB can write to `grubenv` (this does not work on btrfs)
- `grub.cfg` contains `if [ "${recordfail}" = 1 ]; then set timeout=30`
- `grub-initrd-fallback.service` is enabled and clears the flag on a successful boot

So **a failed boot brings the menu up for 30 seconds on the next one.** Holding Esc
during boot also forces it, and the menu is usable sideways: arrow keys and Enter work
regardless.

### A sideways flash when logging in or out (accepted)

Symptom: for a moment during logout or login, the screen appears sideways.

The cause is **the same as GRUB's**. KWin is the only thing applying the rotation, so
during the window where it releases and reacquires the display there is no correction,
and the panel scans out the framebuffer in its own native portrait orientation.

SDDM jumps to a new VT on every login (the log says `sddm-helper: Jumping to VT 5`),
starting at tty2 and incrementing on each logout and login. That VT switching is normal
for a Wayland session.

The first suspicion was that this was the text console showing through unrotated. It is
not. **fbcon is unbound at that point:**

```
just after boot:  vtcon0: dummy bound=0 / vtcon1: frame buffer device bound=1
later:            vtcon0: dummy bound=1  (vtcon1 gone)
```

`fb0` is alive as `i915drmfb`, but with no console attached
`/sys/class/graphics/fbcon/rotate` reads 0 and writes do not stick. So what is visible
is not a text console but the DRM handover.

The theoretical fix is for KWin to use **hardware rotation on the DRM plane** instead
of a software transform, which Intel display hardware supports. That is an internal
KWin implementation choice and not configurable. **Accepted.**

### Summary

| Stage | Rendered by | Orientation | Fix |
|---|---|---|---|
| Vendor logo | UEFI firmware (BGRT) | upright | Firmware applies 270 degrees itself; the OS cannot intervene |
| GRUB menu | GRUB gfxterm | **sideways** | Not fixable; accepted |
| Plymouth splash | plymouth on i915 | upright | Put i915 in the initramfs |
| TTY console | fbcon on i915 | upright | `fbcon=rotate:1`, after the initramfs change |
| SDDM login | KWin (SDDM's instance) | upright | `/var/lib/sddm/.config/kwinoutputconfig.json` |
| Desktop | KWin (user session) | upright | `transform: Rotated270` |

## Why the kernel parameter is kept, and one thing to watch

`video=DSI-1:panel_orientation=right_side_up` has no observable effect, but it is
**kept**. It states a hardware fact accurately, and it becomes useful the moment KWin
or plymouth starts consuming the property.

**Watch out**: if KWin ever does start honouring panel orientation, the kernel
declaration and the explicit `Rotated270` will **compound into a double rotation**. If
the display goes strange after a KDE upgrade, suspect this combination first and
remove the explicit transform.

## Implication for auto-rotation

The plan for tablet mode assumed that native KDE auto-rotation follows once
`SW_TABLET_MODE` exists. That premise holds, but this work established that **KWin does
not automatically consume DRM rotation hints**, so do not assume "the kernel signals it
and KDE handles the rest" anywhere else either. Check it on the machine.

KDE's policy is already set to `autoRotation: "InTabletMode"`, which is what is wanted:
rotating on orientation alone would rotate the screen in laptop posture too.
