#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 07-touchpad - suppress pointer jitter.
STEP_NAME=touchpad
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

HWDB=/etc/udev/hwdb.d/61-evdev-minibook-touchpad.hwdb
DEFAULT_FUZZ=24
TP_NAME="XXXX0000:05 0911:5288 Touchpad"

usage() { cat <<EOF
Usage: sudo $0 [-n|--dry-run] [fuzz]

Suppresses the pointer jitter on this touchpad. Default fuzz=${DEFAULT_FUZZ}, which is
about 1.7mm at the reported resolution of 14 units/mm.

The cause: this touchpad reports neither pressure (ABS_MT_PRESSURE) nor contact size
(ABS_MT_TOUCH_MAJOR), and every axis has a fuzz of 0. libinput derives its hysteresis
margin from the kernel fuzz, so a fuzz of 0 leaves no filtering and raw sensor noise
reaches the pointer directly.

This is not a sensitivity or acceleration setting, and it is not a hardware fault
either: there are zero I2C errors.

Higher values suppress more jitter but make the start of a movement feel sticky.
The full explanation and two udev traps are in notes/touchpad-jitter.md.
EOF
}

EXTRA_ARGS=()
parse_common_args "$@"
FUZZ="${EXTRA_ARGS[0]:-$DEFAULT_FUZZ}"
need_root "$@"
assert_minibook

[[ "$FUZZ" =~ ^[0-9]+$ ]] || fail "invalid fuzz value: $FUZZ"

section "1. Find the touchpad"
EVDEV=""
for d in /sys/class/input/event*; do
  nm=$(cat "$d/device/name" 2>/dev/null || true)
  [[ "$nm" == *Touchpad* ]] || continue
  EVDEV="/dev/input/$(basename "$d")"
  ok "touchpad: $nm  ($EVDEV)"
  TP_NAME="$nm"
done
[[ -n "$EVDEV" ]] || fail "no touchpad found"

# Read the axis ranges off the device and write them back unchanged. Only the
# fuzz, the fourth field, is added.
read_abs() {  # $1=code(hex) -> "min:max:res"
  local code="$1"
  python3 - "$EVDEV" "$code" <<'PY' 2>/dev/null || echo ""
import sys, fcntl, struct
dev, code = sys.argv[1], int(sys.argv[2], 16)
EVIOCGABS = 0x80184540 + code
with open(dev, 'rb') as f:
    buf = fcntl.ioctl(f, EVIOCGABS, b'\0'*24)
val, mn, mx, fuzz, flat, res = struct.unpack('6i', buf)
print(f"{mn}:{mx}:{res}")
PY
}

declare -A ABS
for code in 00 01 35 36; do
  v=$(read_abs "$code")
  [[ -n "$v" ]] || fail "cannot read ABS axis 0x$code"
  ABS[$code]="$v"
  log "  ABS_0x$code: $v (min:max:res)"
done

section "2. Write the hwdb rule"
if [[ -f "$HWDB" ]] && grep -q ":${FUZZ}\$" "$HWDB"; then
  skip "already set to fuzz=$FUZZ"
else
  if (( DRY_RUN )); then
    printf '%s\n' "  ${C_DIM}[dry-run]${C_RESET} would write $HWDB with fuzz=$FUZZ"
  else
    mkdir -p "$(dirname "$HWDB")"
    {
      echo "# Chuwi MiniBook X N150 touchpad"
      echo "#"
      echo "# This pad reports neither ABS_MT_PRESSURE nor ABS_MT_TOUCH_MAJOR, and every"
      echo "# axis has a fuzz of 0, so libinput's hysteresis margin ends up at 0 and sensor"
      echo "# jitter reaches the pointer unfiltered. Setting a fuzz restores the filter."
      echo "#"
      echo "# Format: EVDEV_ABS_<code>=<min>:<max>:<resolution>:<fuzz>"
      echo "evdev:name:${TP_NAME}:*"
      for code in 00 01 35 36; do
        echo " EVDEV_ABS_${code}=${ABS[$code]}:${FUZZ}"
      done
    } > "$HWDB"
    ok "wrote $HWDB (fuzz=$FUZZ)"
  fi
fi

section "3. Apply"
run systemd-hwdb update
# There are two traps here. See notes/touchpad-jitter.md.
#  1) The trigger must target the event node. Triggering the parent input node
#     skips 90-libinput-fuzz-override.rules, which matches on KERNEL=="event*".
#  2) IMPORT{program} runs inline during rule processing, but the builtin that
#     writes the hwdb value into the kernel runs after all rules have been
#     processed. A single trigger therefore always records the previous value,
#     so this runs twice.
run udevadm trigger --action=add "/sys/class/input/$(basename "$EVDEV")"
sleep 1
run udevadm trigger --action=add "/sys/class/input/$(basename "$EVDEV")"
sleep 1

section "4. Verification"
if (( DRY_RUN )); then skip "dry run, so verification is skipped"; exit 0; fi

# Do not read the kernel fuzz. libinput reads it and then sets it back to 0, so
# the value libinput actually uses lives in the udev properties.
GOT=$(udevadm info "$EVDEV" 2>/dev/null | grep -oP 'LIBINPUT_FUZZ_35=\K[0-9]+' || echo "")
if [[ "$GOT" == "$FUZZ" ]]; then
  ok "LIBINPUT_FUZZ_35 = $GOT"
else
  warn "LIBINPUT_FUZZ_35 = ${GOT:-absent} (expected $FUZZ)"
  warn "run udevadm trigger once more, or reboot, and it will catch up"
fi
udevadm info "$EVDEV" 2>/dev/null | grep -q "EVDEV_ABS_35=.*:${FUZZ}\$" \
  && ok "hwdb property applied" || warn "the hwdb property is not visible"

log ""
log "Note: do not casually run libinput debug-events."
log "      Running it sets the kernel fuzz to 0 and undoes what was just configured."

finish
