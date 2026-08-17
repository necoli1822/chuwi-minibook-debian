#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 04-minibook-ec - install the EC access kernel module via DKMS.
STEP_NAME=minibook_ec
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MODULE_NAME=minibook_ec
MODULE_VER=1.0

usage() { cat <<EOF
Usage: sudo $0 [-n|--dry-run]

Installs the minibook_ec kernel module through DKMS. On this machine it does three
things worth having.

  Fan RPM             exposed through hwmon. There is no other way to read it
  Charger temperature IT5570E ADC channel 0, usable as a charging indicator
  bios_unlock         reveals the hidden BIOS menus

**Keyboard backlight support is removed by patch 0006.** This machine has no keyboard
backlight, so that code drives hardware which is not there.

Fan speed cannot be controlled. The EC takes the PWM back, which was measured
directly. See notes/hardware-status.md.
EOF
}

EXTRA_ARGS=()
parse_common_args "$@"
need_root "$@"
assert_minibook
need_cmd dkms git

section "1. Already installed?"
if dkms status "$MODULE_NAME/$MODULE_VER" 2>/dev/null | grep -q installed; then
  ok "already installed: $(dkms status "$MODULE_NAME/$MODULE_VER" | head -1)"
  ALREADY=1
else
  ALREADY=0
fi

section "2. Fetch upstream and patch"
fetch_upstream
apply_patch "0006-minibook_ec-drop-keyboard-backlight.patch"

section "3. Place the DKMS source"
SRC="$UPSTREAM_DIR/modules/$MODULE_NAME"
DEST="/usr/src/${MODULE_NAME}-${MODULE_VER}"
require_path "$SRC" "module source" || SRC_MISSING=1

if [[ -n "${SRC_MISSING:-}" ]]; then
  skip "dry run: the rest can only be checked once upstream has been fetched"
elif (( ALREADY )); then
  skip "leaving the DKMS registration alone (run dkms remove first to reinstall)"
else
  run rm -rf "$DEST"
  run cp -a "$SRC" "$DEST"
  ok "source placed at $DEST"

  info "dkms add / build / install"
  run dkms add -m "$MODULE_NAME" -v "$MODULE_VER"
  run dkms build -m "$MODULE_NAME" -v "$MODULE_VER"
  run dkms install -m "$MODULE_NAME" -v "$MODULE_VER"
fi

section "4. Load at boot"
ensure_line "/etc/modules-load.d/${MODULE_NAME}.conf" "$MODULE_NAME"

section "5. Load now"
if lsmod | grep -q "^${MODULE_NAME}"; then
  skip "already loaded"
else
  run modprobe "$MODULE_NAME"
fi

section "6. Verification"
if (( DRY_RUN )); then skip "dry run, so verification is skipped"; exit 0; fi

lsmod | grep -q "^${MODULE_NAME}" || fail "the module did not load"
ok "module loaded"

# Confirm the keyboard backlight really did go, which tells us the patch applied
if [[ -d /sys/class/leds/${MODULE_NAME}::kbd_backlight ]]; then
  warn "the keyboard backlight LED is still exposed, so patch 0006 did not apply."
else
  ok "keyboard backlight removed (patch 0006 confirmed)"
fi

# Check the three reasons for installing this module actually work
found_fan=0
for h in /sys/class/hwmon/hwmon*; do
  nm=$(cat "$h/name" 2>/dev/null || true)
  [[ "$nm" == *minibook* ]] || continue
  [[ -f "$h/fan1_input" ]] && { ok "fan RPM exposed: $h/fan1_input = $(cat "$h/fan1_input")"; found_fan=1; }
  for t in "$h"/temp*_label; do
    [[ -f "$t" ]] && log "  temperature sensor: $(cat "$t") = $(cat "${t%_label}_input" 2>/dev/null)"
  done
done
(( found_fan )) || warn "could not find the fan RPM node"

[[ -e /sys/kernel/${MODULE_NAME}/bios_unlock ]] && ok "bios_unlock exposed" \
  || log "the bios_unlock path can differ by kernel version"

# Confirm DKMS built for every installed kernel, which avoids an unbootable
# system after a kernel update
log "DKMS status:"
dkms status "$MODULE_NAME" | sed 's/^/    /'

finish
