#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 05-tablet-mode - make auto-rotation and tablet mode work off the two accelerometers.
STEP_NAME=tablet-mode
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { cat <<EOF
Usage: sudo $0 [-n|--dry-run]

Builds the iio-sensor-proxy fork and puts it in place of the distribution binary.

This machine has **two** accelerometers, one in the lid and one in the base. The
angle between them gives the hinge position, which is what decides tablet mode. The
stock iio-sensor-proxy assumes a single accelerometer, so auto-rotation misbehaves.

**dpkg-divert --local is used deliberately.** Removing the distribution package drags
kubuntu-desktop out with it and leaves the desktop autoremovable, so only the binary
is swapped.

Nothing extra is needed to disable the keyboard and touchpad in tablet mode. Emitting
SW_TABLET_MODE is enough: libinput does that as documented standard behaviour.
EOF
}

EXTRA_ARGS=()
parse_common_args "$@"
need_root "$@"
assert_minibook

BIN=/usr/libexec/iio-sensor-proxy
DIVERTED="${BIN}.distrib"

section "1. Build dependencies"
# systemd-dev is required. libudev-dev alone does not provide udev.pc or systemd.pc
# and the build fails.
PKGS=(meson ninja-build pkg-config libgudev-1.0-dev libpolkit-gobject-1-dev
      libudev-dev libsystemd-dev systemd-dev gcc git)
missing=()
for p in "${PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
done
if (( ${#missing[@]} )); then
  info "installing: ${missing[*]}"
  run apt-get update -qq
  run apt-get install -y "${missing[@]}"
else
  skip "build dependencies already installed"
fi

section "2. Fetch upstream and patch"
fetch_upstream
# The fork did not check the MXC6655 DEVID. It does now.
# DEVID 0x02 was read off both accelerometers on this machine rather than assumed.
apply_patch "0005-iio-sensor-proxy-validate-mxc6655-devid.patch"

section "3. Build"
SRC="$UPSTREAM_DIR/iio-sensor-proxy"
BUILD="$SRC/_build"
if ! require_path "$SRC" "iio-sensor-proxy source"; then
  skip "dry run: the build and install can only be checked once upstream has been fetched"
  exit 0
fi
if [[ -x "$BUILD/src/iio-sensor-proxy" ]]; then
  skip "already built: $BUILD/src/iio-sensor-proxy"
else
  run meson setup "$BUILD" "$SRC" --prefix=/usr
  run ninja -C "$BUILD"
fi

section "4. Swap the binary with dpkg-divert"
# --local is the correct flag. --package X means "package X keeps the original
# name", which is the opposite of what is wanted here.
if dpkg-divert --list "$BIN" 2>/dev/null | grep -q "$DIVERTED"; then
  skip "diversion already in place"
else
  info "setting up the diversion"
  run dpkg-divert --local --rename --add "$BIN"
fi

if (( ! DRY_RUN )); then
  [[ -f "$DIVERTED" ]] || warn "the distribution original ($DIVERTED) is missing. Something went wrong earlier."
fi
run install -m 0755 "$BUILD/src/iio-sensor-proxy" "$BIN"
ok "fork binary installed at $BIN"

section "5. uinput module"
# The service unit sets ProtectKernelModules, so the daemon cannot modprobe this itself.
ensure_line /etc/modules-load.d/uinput.conf "uinput"
lsmod | grep -q "^uinput" || run modprobe uinput

section "6. Restart the service"
run systemctl daemon-reload
run systemctl restart iio-sensor-proxy.service

section "7. Verification"
if (( DRY_RUN )); then skip "dry run, so verification is skipped"; exit 0; fi

systemctl is-active --quiet iio-sensor-proxy.service \
  && ok "iio-sensor-proxy running" || fail "the service is not running"

# Confirm the running binary is the fork and not the distribution one. Without this
# a failed swap goes unnoticed.
if cmp -s "$BIN" "$BUILD/src/iio-sensor-proxy"; then
  ok "the installed binary matches the build"
else
  fail "the installed binary differs from what was built"
fi

# One accelerometer in IIO is correct here. Firmware declares MXC6655:00 and :01
# with _STA=0 so the kernel skips them, and only the active MDA6655:00 enumerates.
# The second sensor is alive but reachable over raw I2C only.
n=0
for d in /sys/bus/iio/devices/iio:device*; do
  [[ -d "$d" ]] || continue
  nm=$(cat "$d/name" 2>/dev/null)
  [[ "$nm" == *mxc* || "$nm" == *accel* ]] && { log "  $nm"; ((n++)) || true; }
done
(( n >= 1 )) && ok "${n} IIO accelerometer(s), via MDA6655" || fail "no IIO accelerometer"

# The second sensor is not probed over i2c here. The fork polls that address
# continuously, so touching it concurrently could disturb what is being checked,
# and nothing confirms that ACPI's I2C0 is the kernel's i2c-0. The tablet mode
# switch below is better evidence that both are being read.

# Did the virtual device emitting SW_TABLET_MODE appear
if grep -qi "tablet mode" /sys/class/input/*/name 2>/dev/null; then
  ok "tablet mode switch exposed: $(grep -il 'tablet mode' /sys/class/input/*/name | head -1 | xargs cat)"
else
  warn "no tablet mode switch found. Fold and unfold the lid, then check again."
fi

log ""
log "To check: folding the lid should disable the keyboard and touchpad, and unfolding"
log "should bring them back. Rotation only follows in tablet mode; staying fixed in"
log "laptop mode is correct."

finish
