#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 06-refresh-rate - raise the panel refresh rate by patching the VBT.
STEP_NAME=refresh-rate
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DEFAULT_HZ=75

usage() { cat <<EOF
Usage: sudo $0 [-n|--dry-run] [Hz]

Patches the pixel clock in the panel's VBT to raise the refresh rate.
Default ${DEFAULT_HZ}Hz.

Stock is 50Hz. **This machine cannot hold 90Hz.** Image-heavy regions of the screen
fail to render, and the cause is LPDDR5 bandwidth. Scanout alone is 460MB/s at 50Hz,
690MB/s at 75Hz and 830MB/s at 90Hz, on top of whatever compositing is happening.

Panels vary between units. If you see artefacts, try a lower value.
To undo: sudo scripts/update-vbt-clock-debian.sh --revert

The full diagnosis is in notes/vbt-refresh-rate.md.
EOF
}

EXTRA_ARGS=()
parse_common_args "$@"
HZ="${EXTRA_ARGS[0]:-$DEFAULT_HZ}"
need_root "$@"
assert_minibook

[[ "$HZ" =~ ^[1-9][0-9]{0,2}$ ]] || fail "invalid refresh rate: $HZ"
(( HZ >= 30 && HZ <= 120 )) || fail "refresh rate must be between 30 and 120: $HZ"

section "1. Current state"
CUR=""
for m in /sys/class/drm/card*-DSI-1/modes; do
  [[ -f "$m" ]] && CUR=$(head -1 "$m")
done
log "panel mode: ${CUR:-unknown}"
if grep -q "i915.vbt_firmware=vbt" /proc/cmdline; then
  ok "booted with the patched VBT already in place"
else
  log "no patched VBT yet, so the panel is presumably at the stock 50Hz"
fi

section "2. Build tools"
# vbt_patch's Makefile hardcodes CC=clang.
need_cmd clang git make
ok "clang: $(clang --version | head -1)"

section "3. Fetch upstream and patch"
fetch_upstream
# Adds checksum verification to the kernel headers that get downloaded.
# Unverified headers are refused.
apply_patch "0003-vbt_patch-verify-fetched-kernel-headers.patch"

section "4. Build vbt_patch"
# This tool must not be built as root. That was one of the bugs fixed in the
# ported script.
VBT_DIR="$UPSTREAM_DIR/vbt_patch"
if ! require_path "$VBT_DIR" "vbt_patch source"; then
  skip "dry run: the build and apply can only be checked once upstream has been fetched"
  exit 0
fi
if [[ -x "$VBT_DIR/vbt_patch" ]]; then
  skip "vbt_patch already built"
else
  BUILD_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
  [[ "$BUILD_USER" == "root" ]] && fail "run this with sudo from a normal user account (the build must not be root)"
  info "building as $BUILD_USER"
  # The first build refuses to proceed because the headers are unverified. They
  # have to be reviewed and recorded before it will continue.
  run sudo -u "$BUILD_USER" make -C "$VBT_DIR" verify-headers || {
    warn "the kernel headers have not been verified yet."
    warn "review them yourself, then run:"
    warn "    sudo -u $BUILD_USER make -C $VBT_DIR record-checksums"
    fail "not proceeding without verification"
  }
  run sudo -u "$BUILD_USER" make -C "$VBT_DIR"
fi

section "5. Apply"
SCRIPT="$REPO_ROOT/scripts/update-vbt-clock-debian.sh"
[[ -x "$SCRIPT" ]] || run chmod +x "$SCRIPT"
info "applying ${HZ}Hz"
run env VBT_TOOL="$VBT_DIR/vbt_patch" "$SCRIPT" "$HZ"
need_reboot "VBT firmware and kernel parameters changed"

section "6. Verification"
if (( DRY_RUN )); then skip "dry run, so verification is skipped"; exit 0; fi

[[ -f /lib/firmware/vbt ]] && ok "firmware installed: /lib/firmware/vbt ($(stat -c%s /lib/firmware/vbt) bytes)" \
  || fail "/lib/firmware/vbt is missing"
grep -q "i915.vbt_firmware=vbt" /etc/default/grub \
  && ok "kernel parameter registered" || fail "the kernel parameter is missing"
grep -q "i915.vbt_firmware=vbt" /boot/grub/grub.cfg 2>/dev/null \
  && ok "present in grub.cfg" || fail "not present in grub.cfg"
[[ -f /etc/initramfs-tools/hooks/vbt_firmware ]] \
  && ok "initramfs hook installed" || warn "the initramfs hook is missing"

log ""
log "After rebooting, check with:"
log "    cat /sys/class/drm/card*-DSI-1/modes"
log "If image-heavy pages show tearing or corruption, run this again with a lower value."

finish
