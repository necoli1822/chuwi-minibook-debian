#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 99-verify - confirm everything actually took. Changes nothing.
#
# Why this exists: during this work there were several cases of something looking
# applied while it was not. A GRUB theme pointed at a directory that never existed,
# an SDDM setting was overridden by a backup file left in the same directory, and the
# touchpad fuzz landed one udev trigger late. In every case the config file said the
# right thing. So this script reads **results**, not configuration.
STEP_NAME=verify
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { cat <<EOF
Usage: $0

Verifies the installation against the running system. Changes nothing, so it is
always safe to run. Most checks work without root; a few need it to see anything.
EOF
}

EXTRA_ARGS=()
parse_common_args "$@"

PASS=0; FAILN=0; WARNN=0
p() { ok "$*"; ((PASS++)) || true; }
f() { printf '%s\n' "  ${C_RED}failed${C_RESET}  $*"; ((FAILN++)) || true; }
w() { warn "$*"; ((WARNN++)) || true; }

section "Machine"
prod="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
[[ "$prod" == *MiniBook* ]] && p "machine: $prod" || f "this is not a MiniBook: $prod"

section "Kernel"
kr="$(uname -r)"
[[ "$kr" == *xanmod* ]] && p "kernel: $kr" || w "kernel: $kr (not XanMod)"
for c in clang ld.lld; do
  command -v "$c" >/dev/null 2>&1 && p "$c present (needed to rebuild DKMS modules)" \
    || f "$c missing, so module builds will fail on the next kernel update"
done

section "Display rotation"
grep -q "panel_orientation=right_side_up" /proc/cmdline \
  && p "panel_orientation active" || f "panel_orientation is not in this boot"
grep -q "fbcon=rotate:1" /proc/cmdline \
  && p "console rotation active" || w "fbcon=rotate:1 is not in this boot"
if img=$(ls -1 "/boot/initrd.img-$kr" 2>/dev/null); then
  if [[ $EUID -eq 0 ]]; then
    n=$(lsinitramfs "$img" 2>/dev/null | grep -c i915 || echo 0)
    (( n > 0 )) && p "${n} i915 file(s) in the initramfs" \
      || f "no i915 in the initramfs, so plymouth draws before rotation is known"
  else
    w "checking the initramfs needs root"
  fi
fi

section "Panel refresh rate"
mode=""
for m in /sys/class/drm/card*-DSI-1/modes; do [[ -f "$m" ]] && mode=$(head -1 "$m"); done
[[ -n "$mode" ]] && log "  mode: $mode"
if grep -q "i915.vbt_firmware=vbt" /proc/cmdline; then
  p "patched VBT active"
  [[ -f /lib/firmware/vbt ]] && p "/lib/firmware/vbt present" \
    || f "the kernel is looking for vbt but the file is missing"
else
  w "no patched VBT (stock 50Hz)"
fi

section "minibook_ec"
if lsmod | grep -q "^minibook_ec"; then
  p "module loaded"
  found=0
  for h in /sys/class/hwmon/hwmon*; do
    nm=$(cat "$h/name" 2>/dev/null || true)
    [[ "$nm" == *minibook* ]] || continue
    if [[ -f "$h/fan1_input" ]]; then p "fan RPM: $(cat "$h/fan1_input")"; found=1; fi
  done
  (( found )) || f "cannot find the fan RPM node"
  [[ -d /sys/class/leds/minibook_ec::kbd_backlight ]] \
    && f "the keyboard backlight is exposed, so patch 0006 did not apply" \
    || p "keyboard backlight removed"
  if command -v dkms >/dev/null 2>&1; then
    dkms status minibook_ec 2>/dev/null | grep -q "$kr" \
      && p "DKMS build present for the running kernel" || w "no DKMS build for the running kernel"
  fi
else
  f "minibook_ec is not loaded"
fi

section "Auto-rotation and tablet mode"
systemctl is-active --quiet iio-sensor-proxy.service \
  && p "iio-sensor-proxy running" || f "iio-sensor-proxy is not running"
if dpkg-divert --list /usr/libexec/iio-sensor-proxy 2>/dev/null | grep -q distrib; then
  p "diversion in place for the fork binary"
else
  f "no diversion, so the distribution binary is probably what is running"
fi
# One IIO accelerometer is correct here. Firmware declares MXC6655:00 and :01 with
# _STA=0 so the kernel skips them. The second sensor is alive but reachable over raw
# I2C only, which is how the fork reads it and why patch 0005 validates its DEVID there.
n=0
for d in /sys/bus/iio/devices/iio:device*; do
  [[ -d "$d" ]] || continue
  nm=$(cat "$d/name" 2>/dev/null)
  [[ "$nm" == *mxc* || "$nm" == *accel* ]] && ((n++)) || true
done
(( n >= 1 )) && p "${n} IIO accelerometer(s), via MDA6655, which is correct" \
             || f "no IIO accelerometer"

# The second sensor is not probed over i2c here. The fork polls that address
# continuously, so touching it concurrently could disturb what is being checked,
# and nothing confirms that ACPI's I2C0 is the kernel's i2c-0. The tablet mode
# switch is better evidence that both are being read: hinge angle needs the
# difference between them.
grep -qil "tablet mode" /sys/class/input/*/name 2>/dev/null \
  && p "tablet mode switch present, which means both sensors are being read" \
  || f "no tablet mode switch, so the hinge angle calculation is not working"
lsmod | grep -q "^uinput" && p "uinput loaded" || f "uinput missing (the daemon cannot load it itself)"

section "Touchpad jitter"
ev=""
for d in /sys/class/input/event*; do
  nm=$(cat "$d/device/name" 2>/dev/null || true)
  [[ "$nm" == *Touchpad* ]] && ev="/dev/input/$(basename "$d")"
done
if [[ -n "$ev" ]]; then
  fz=$(udevadm info "$ev" 2>/dev/null | grep -oP 'LIBINPUT_FUZZ_35=\K[0-9]+' || echo "")
  if [[ -n "$fz" && "$fz" != "0" ]]; then
    p "LIBINPUT_FUZZ_35 = $fz"
  else
    f "no fuzz set, so the pointer will jitter"
  fi
else
  w "no touchpad found"
fi

section "Suspend"
log "  mem_sleep: $(cat /sys/power/mem_sleep 2>/dev/null)"
if [[ $EUID -eq 0 ]]; then
  hw=$(cat /sys/power/suspend_stats/last_hw_sleep 2>/dev/null || echo 0)
  if (( hw > 0 )); then
    p "last suspend spent $((hw/1000000))s in hardware sleep"
  else
    log "  no suspend recorded yet"
  fi
fi

section "Result"
printf '  %d passed, %d failed, %d warnings\n' "$PASS" "$FAILN" "$WARNN"
if (( FAILN )); then
  printf '\n%s\n' "${C_RED}${C_BOLD}Some checks failed.${C_RESET} Re-run the step they belong to."
  exit 1
fi
printf '\n%s\n' "${C_GREEN}${C_BOLD}Everything passed.${C_RESET}"
