#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 03-rotation - stand the sideways-mounted panel upright at every layer.
STEP_NAME=rotation
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { cat <<EOF
Usage: sudo $0 [-n|--dry-run]

This machine mounts a 1200x1920 portrait panel rotated 90 degrees inside a
landscape chassis. Each layer rotates differently, so three things are set together.

  video=DSI-1:panel_orientation=right_side_up   the DRM panel orientation property
  fbcon=rotate:1                                 the framebuffer console
  i915 in the initramfs                          so it loads before plymouth does

**The DRM panel orientation property is informational only.** The kernel does not
rotate anything; consumers such as the compositor and the console read the value and
rotate themselves. That is why each layer needs its own setting.

The GRUB menu itself cannot be straightened this way. See notes/display-rotation.md.
EOF
}

EXTRA_ARGS=()
parse_common_args "$@"
need_root "$@"
assert_minibook

section "1. Kernel parameters"
grub_cmdline_add "video=DSI-1:panel_orientation=right_side_up"
grub_cmdline_add "fbcon=rotate:1"

section "2. i915 in the initramfs"
# Plymouth draws on whichever DRM device exists when it starts. If i915 comes up
# late, plymouth has already drawn without knowing the orientation.
# Measured: i915 initialisation moves from 3.62s to 1.59s, ahead of plymouth at 4.25s.
ensure_line /etc/initramfs-tools/modules "i915"

section "3. Regenerate"
CHANGED=0
grep -q "panel_orientation=right_side_up" /etc/default/grub && CHANGED=1
if (( CHANGED )); then
  info "update-grub"
  run update-grub
  info "update-initramfs (all kernels)"
  run update-initramfs -u -k all
  need_reboot "kernel parameters and initramfs changed"
fi

section "4. Verification"
if (( DRY_RUN )); then skip "dry run, so verification is skipped"; exit 0; fi

ok "grub setting: $(grep -oP '^GRUB_CMDLINE_LINUX_DEFAULT="\K[^"]*' /etc/default/grub)"

# Confirm it reached grub.cfg. Editing the config without running update-grub
# changes nothing at boot.
if grep -q "panel_orientation=right_side_up" /boot/grub/grub.cfg 2>/dev/null; then
  ok "present in grub.cfg"
else
  fail "not present in grub.cfg. update-grub may have failed."
fi

# Confirm i915 actually made it into the initramfs
for img in /boot/initrd.img-*; do
  k="${img##*/initrd.img-}"
  n=$(lsinitramfs "$img" 2>/dev/null | grep -c "i915" || echo 0)
  if (( n > 0 )); then ok "initramfs $k: ${n} i915 file(s)"; else warn "initramfs $k: no i915"; fi
done

# Whether this boot already has it (before a reboot, absent is expected)
if grep -q "panel_orientation" /proc/cmdline; then
  ok "already active in the current boot"
else
  warn "not in the current boot yet (takes effect after a reboot)"
fi

finish
