# Panel refresh rate: 75Hz

Stock is 50Hz. This machine runs at **75Hz**. 90Hz was tried and reverted because of
rendering artefacts.

## Result

```
stock:    1200x1920 @ 50.00Hz, pixel_clock 136887 kHz
current:  1200x1920 @ 75.00Hz, pixel_clock 205320 kHz
```

Zero i915 or DSI errors. Clean even with video playing alongside an image-heavy page.

## Why 90Hz failed: memory bandwidth

At 90Hz (246385 kHz), **only the image-heavy regions of the screen** failed to render
properly. Each of these was ruled out in turn:

| Suspected | Outcome |
|---|---|
| DSI link bandwidth | Ruled out. Zero DSI errors and zero FIFO underruns, pipe healthy |
| Compositor performance | Ruled out. The GPU stayed pinned at 300MHz even while scrolling |
| Software rotation overhead | Ruled out. Turning rotation off made it **worse** |
| PSR | Not applicable. It is eDP-only and this panel is DSI |
| Firefox WebRender compositing | Ruled out. Neither value of `gfx.webrender.compositor` changed anything |
| XWayland | Ruled out. Firefox runs native with `MOZ_ENABLE_WAYLAND=1` |

The decisive observation was that **it splits within a single page**: the image-heavy
top of a news site broke while the text-heavy bottom of the same page was fine, and a
mobile version of the same site with the same adverts broke too, while a
near-static page did not.

That rules out both the site and the browser. It tracks nothing but **how much image
is on screen**.

The N150 shares LPDDR5 between CPU and GPU. Scanout alone costs:

```
50Hz: 1200x1920x4 x 50 = 460 MB/s
75Hz:                    690 MB/s   <- adopted
90Hz:                    830 MB/s   <- over the limit
```

Add the cost of compositing a screenful of images on top of that and the display FIFO
starves, so image regions are not filled in time. Text survives because it moves far
less data, which is the same explanation.

Upstream's documentation warned about exactly this case: not every unit has the same
panel, so try a lower value if you see artefacts. This unit cannot hold 90Hz.

## Applying it

```bash
sudo scripts/update-vbt-clock-debian.sh 75
sudo scripts/update-vbt-clock-debian.sh --revert   # undo
```

What the ported script does:

1. Reads the current VBT from debugfs
   (`/sys/kernel/debug/dri/0000:00:02.0/i915_vbt`)
2. Rewrites the pixel clock with `vbt_patch --hz` and installs the result to
   `/lib/firmware/vbt`
3. Adds an `/etc/initramfs-tools/hooks/vbt_firmware` hook so it lands in the initramfs
4. Adds `i915.vbt_firmware=vbt` to `GRUB_CMDLINE_LINUX_DEFAULT`
5. Runs `update-initramfs -u -k all` and `update-grub`

**The fixed `--revert` earned its keep.** The original clears only the kernel
parameter, leaving the firmware file and the initramfs hook behind. In that state
going from 90Hz back to 75Hz would have been blocked by `refuse_existing_state()`.
This version clears all four and regenerates the initramfs for every kernel.

## Building vbt_patch

`clang` is required; the Makefile hardcodes `CC = clang`. It is already installed for
XanMod.

Patch 0003's checksum pinning works as intended. The first build **refuses to proceed**
because the downloaded headers are unverified, and only continues after they have been
reviewed and `make record-checksums` has been run. They were reviewed: Intel
copyright, MIT SPDX, includes limited to `<linux/types.h>` and sibling headers,
**zero function definitions**, and nothing suspicious.

Recorded checksums (mainline HEAD at the time):

```
75f0d7e96dd8aa00564b69fcfef6fe2781c84def6fe1705ad40e37db34bcb1fe  intel_vbt_defs.h
7fbcf6a94dd0ded194f8cb8b2faa3ffa4edb08b3ba0c6da5622d2d23ba1aa14a  intel_dsi_vbt_defs.h
```

## Left unexplored

Trying 80Hz would locate the ceiling more precisely, somewhere between 690 and
830 MB/s. There is not much in it though: 75Hz is a 50% improvement over stock and
stays stable under mixed load.
