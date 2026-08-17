#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 00-preflight - check the machine and its environment. Changes nothing.
STEP_NAME=preflight
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { cat <<EOF
Usage: $0 [-n|--dry-run]

Checks the machine model, distribution, kernel, network and disk space.
Nothing is modified, so this is safe to run at any point.
EOF
}

EXTRA_ARGS=()
parse_common_args "$@"

FAILED=0
soft_fail() { warn "$*"; FAILED=1; }

section "1. Machine"
assert_minibook
log "BIOS: $(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo unknown)"

section "2. Distribution"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  ok "$PRETTY_NAME"
  case "${ID}${ID_LIKE:-}" in
    *debian*|*ubuntu*) ;;
    *) soft_fail "not a Debian-family distribution. These scripts assume apt, dpkg and initramfs-tools." ;;
  esac
else
  soft_fail "cannot read /etc/os-release"
fi

section "3. Bootloader and initramfs"
[[ -f /etc/default/grub ]] && ok "GRUB configuration present" || soft_fail "/etc/default/grub is missing (GRUB is assumed)"
[[ -d /etc/initramfs-tools ]] && ok "initramfs-tools present" \
  || soft_fail "initramfs-tools is missing (dracut-based systems are not supported here)"
[[ -d /sys/firmware/efi ]] && ok "booted via UEFI" || warn "this looks like a legacy BIOS boot"

section "4. Kernel"
log "running: $(uname -r)"
if [[ "$(uname -r)" == *xanmod* ]]; then
  ok "running XanMod"
else
  warn "not XanMod. 01-kernel.sh installs it."
fi
# Enumerating both accelerometers needs 6.9 or newer
kver=$(uname -r | cut -d. -f1,2)
if awk -v v="$kver" 'BEGIN{split(v,a,"."); exit !(a[1]>6 || (a[1]==6 && a[2]>=9))}'; then
  ok "kernel $kver meets the serial-multi-instantiate requirement (6.9+)"
else
  soft_fail "kernel $kver is below 6.9, so the accelerometers will not enumerate"
fi

section "5. Required commands"
for c in git make gcc sudo apt-get update-grub update-initramfs dkms; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else warn "$c missing (the relevant step installs it)"; fi
done

section "6. Network"
if timeout 8 git ls-remote --exit-code "$UPSTREAM_URL" HEAD >/dev/null 2>&1; then
  ok "upstream reachable"
else
  soft_fail "cannot reach the upstream repository: $UPSTREAM_URL"
fi

section "7. Disk space"
avail_mb=$(df -Pm / | awk 'NR==2{print $4}')
boot_mb=$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')
if (( avail_mb > 4000 )); then ok "/ has ${avail_mb}MB free"; else soft_fail "/ has only ${avail_mb}MB free (4GB recommended)"; fi
if [[ -n "${boot_mb:-}" ]]; then
  if (( boot_mb > 300 )); then ok "/boot has ${boot_mb}MB free"; else soft_fail "/boot has only ${boot_mb}MB free, which may not fit a kernel"; fi
fi

section "8. Hardware inventory"
log "panel:"
for m in /sys/class/drm/card*-DSI-1/modes; do
  [[ -f "$m" ]] && log "  $(head -1 "$m")"
done
# One accelerometer in IIO is correct on this machine. Firmware declares
# MXC6655:00 and :01 with _STA=0 so the kernel skips them, and only the active
# MDA6655:00 enumerates. The second sensor is reachable over raw I2C only.
log "IIO accelerometers (one is correct here):"
n=0
for d in /sys/bus/iio/devices/iio:device*; do
  [[ -d "$d" ]] || continue
  log "  $(cat "$d/name" 2>/dev/null)"
  ((n++)) || true
done
(( n >= 1 )) && ok "${n} IIO device(s)" || soft_fail "no IIO accelerometer at all"

log "touchpad:"
for d in /sys/class/input/event*/device/name; do
  nm=$(cat "$d" 2>/dev/null)
  [[ "$nm" == *Touchpad* ]] && log "  $nm"
done

section "Result"
if (( FAILED )); then
  fail "preflight found problems. Resolve the warnings above before continuing."
fi
ok "all preconditions met. Next: 01-kernel.sh"
