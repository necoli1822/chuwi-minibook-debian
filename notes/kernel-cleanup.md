# Removing the stock kernel

After moving to XanMod, the distribution's stock kernel (`7.0.0-29-generic`) was
removed. `install/02-kernel-cleanup.sh` automates the procedure.

## When to do it

**Immediately after booting into XanMod and confirming it works.** The position
matters in both directions.

| Doing it | Problem |
|---|---|
| Any earlier | Nothing to fall back to if XanMod does not boot on your unit |
| Any later | DKMS builds against both kernels until then, and the fallout from `autoremove` only surfaces once everything else is configured |

The script therefore **refuses to run unless XanMod is the booted kernel.**

## Trap 1: removing the image alone is a swap, not a removal

Asking to remove just `linux-image-7.0.0-29-generic` produces this:

```
Remv linux-image-7.0.0-29-generic
Inst linux-image-unsigned-7.0.0-29-generic     <- an unsigned kernel installed instead
```

`linux-main-modules-zfs-7.0.0-29-generic` depends on the kernel image, so apt
satisfies that dependency by **pulling in the unsigned variant.** The stock kernel
stays installed, and with Secure Boot enabled it is one that cannot boot at all.

**The meta packages have to go in the same transaction.**

```bash
sudo apt-get remove \
  linux-generic linux-image-generic linux-headers-generic \
  linux-image-7.0.0-29-generic linux-modules-7.0.0-29-generic \
  linux-headers-7.0.0-29-generic linux-headers-7.0.0-29
```

That takes `linux-main-modules-zfs-*` with it and installs nothing. The script aborts
if the simulation shows `Inst linux-image-unsigned`.

Leaving the meta packages (`linux-generic`, `linux-image-generic`) has a second cost:
the next `apt upgrade` reinstalls a stock kernel.

## Trap 2: autoremove takes thermald with it

Running `apt autoremove` afterwards pulls out things that look unrelated to the kernel:

```
Remv thermald
Remv ubuntu-kernel-accessories
Remv linux-tools-common  linux-tools-7.0.0-29  linux-perf
Remv python3-bpfcc  libbpfcc
```

`thermald` was attached to the stock kernel meta by way of
`ubuntu-kernel-accessories`.

**On this machine that changed nothing.** `thermald` was already `inactive` before the
removal, and thermal management is done by `intel_pstate` (active, powersave). That
matches what was measured earlier: 2900MHz held for 180 seconds at full load with zero
throttling, and the fan governed autonomously by the EC. See
[hardware-status.md](hardware-status.md).

Even so, **this is not a step to run unattended.** The script prints what `autoremove`
would take and stops if anything desktop or kernel related appears in the list.

## Trap 3: dpkg-query lists removed packages too

Found while checking idempotency: an already-removed kernel was picked up as a target
again.

```bash
dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*'
# also lists packages that were removed but still have config files
```

Filter on status instead:

```bash
dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-[0-9]*' \
  | awk '$1=="installed"{print $2}'
```

## Result

```
8 packages removed, nothing installed
/boot freed:  585MB
GRUB entries: XanMod only, the stock entries gone
reboot:       40 seconds, clean
verification: everything in 99-verify.sh passed
```

Always confirm this afterwards:

```bash
[ -f /boot/vmlinuz-$(uname -r) ]        # running kernel's image
[ -f /boot/initrd.img-$(uname -r) ]     # its initrd
grep vmlinuz-$(uname -r) /boot/grub/grub.cfg
lsinitramfs /boot/initrd.img-$(uname -r) | grep i915   # rotation setup survived
```

The last one matters: `autoremove` regenerates the initramfs, so check that the
`i915` entry in `/etc/initramfs-tools/modules` still took effect.

## Undoing it

```bash
sudo apt-get install linux-generic
```

If the machine will not boot at all, boot a live USB, chroot in and run the same
command. **Go into this knowing there is no fallback kernel afterwards.**
