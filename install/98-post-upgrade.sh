#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 98-post-upgrade - check what a distribution or kernel upgrade broke, and say
#                   exactly which step puts it back.
#
# Run this after every kernel update and after any point release (26.04 -> 26.04.1).
#
# Why this is a separate step from 99-verify. That script answers "is the machine
# in the right state", which is what you want after an install. This one answers
# "an upgrade just happened, what did it take away, and what do I run" -- which
# needs three things verify does not do:
#
#   1. It checks the build toolchain FIRST. Without clang and friends a kernel
#      update silently fails to rebuild minibook_ec, and the first symptom is a
#      missing fan reading days later. This is the one failure that gets worse
#      the longer it goes unnoticed.
#   2. It maps each failure onto the step that fixes it. Verify only says
#      "re-run the step they belong to".
#   3. It knows which settings live in dpkg conffiles. Those are the ones an
#      upgrade can revert while everything else survives untouched, so they are
#      worth naming explicitly rather than leaving to a general sweep.
#
# Changes nothing unless --fix is given.
STEP_NAME=post-upgrade
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { cat <<EOF
Usage: $0 [--fix]

Checks what a kernel or distribution upgrade has undone, and names the step that
restores each thing. Changes nothing by default.

  --fix     re-run the steps that are needed, in order

Run it after every kernel update and after any point release.
EOF
}

FIX=0
EXTRA_ARGS=()
for a in "$@"; do
  case "$a" in
    --fix) FIX=1 ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA_ARGS+=("$a") ;;
  esac
done
parse_common_args "${EXTRA_ARGS[@]}"

NEEDED=()            # steps to re-run, in order
need() {             # need <step> <why>
  local s=$1; shift
  for e in "${NEEDED[@]}"; do [[ $e == "$s" ]] && { printf '  %s\n' "         also: $*"; return; }; done
  NEEDED+=("$s")
  printf '  %s\n' "${C_RED}broken${C_RESET}  $* ${C_BOLD}-> ${s}${C_RESET}"
}
fine() { ok "$*"; }

KR="$(uname -r)"
section "What is running now"
log "  kernel:       $KR"
log "  distribution: $(. /etc/os-release && echo "$PRETTY_NAME")"

# ---------------------------------------------------------------------------
# 1. The build toolchain. Check this before anything else.
#
# XanMod x64v3 is a clang + LLD + ThinLTO build, so gcc alone cannot rebuild
# against it. If any of these has gone, the next kernel update leaves the
# machine with no minibook_ec and no obvious reason why.
# ---------------------------------------------------------------------------
section "Build toolchain (needed on every kernel update)"
missing=()
for p in build-essential clang lld llvm libelf-dev dkms; do
  dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -q '^installed$' || missing+=("$p")
done
if (( ${#missing[@]} )); then
  printf '  %s\n' "${C_RED}broken${C_RESET}  missing: ${missing[*]}"
  printf '  %s\n' "         ${C_BOLD}sudo apt-get install ${missing[*]}${C_RESET}"
  printf '  %s\n' "         Until this is fixed, nothing below that rebuilds a module can work."
  NEEDED+=(01-kernel)
else
  fine "build-essential clang lld llvm libelf-dev dkms all present"
fi

# The meson set is only needed if the iio-sensor-proxy fork has to be rebuilt,
# which a full release upgrade can force through a library soname change.
mmissing=()
for p in meson ninja-build libgudev-1.0-dev libpolkit-gobject-1-dev libudev-dev libsystemd-dev systemd-dev; do
  dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -q '^installed$' || mmissing+=("$p")
done
if (( ${#mmissing[@]} )); then
  warn "the iio-sensor-proxy build set is incomplete: ${mmissing[*]}"
  warn "  only needed if the fork has to be rebuilt; 05-tablet-mode installs it again"
else
  fine "iio-sensor-proxy build set present"
fi

# ---------------------------------------------------------------------------
# 2. dpkg conffiles. These are the settings an upgrade can actually revert.
#
# Everything else this project installs is a file dpkg does not own
# (/lib/firmware/vbt, the initramfs hook, the hwdb file, the DKMS module),
# so upgrades leave them alone.
# ---------------------------------------------------------------------------
section "Settings that live in dpkg conffiles"

# /etc/default/grub -> the kernel command line and the GRUB theme
if grep -q "panel_orientation=right_side_up" /proc/cmdline; then
  fine "panel_orientation is on the running command line"
else
  need 03-rotation "panel_orientation is gone from the command line"
fi
if grep -q "fbcon=rotate:1" /proc/cmdline; then
  fine "fbcon=rotate:1 is on the running command line"
else
  need 03-rotation "fbcon=rotate:1 is gone, so the TTY will be sideways"
fi
if grep -q "i915.vbt_firmware=vbt" /proc/cmdline; then
  fine "i915.vbt_firmware is on the running command line"
  [[ -f /lib/firmware/vbt ]] || need 06-refresh-rate "/lib/firmware/vbt is missing while the kernel asks for it"
else
  need 06-refresh-rate "the VBT parameter is gone, so the panel is back to 50Hz"
fi

# /etc/initramfs-tools/modules -> i915 early, which plymouth and fbcon depend on
if grep -qE '^\s*i915\s*$' /etc/initramfs-tools/modules 2>/dev/null; then
  fine "i915 is still listed in /etc/initramfs-tools/modules"
else
  need 03-rotation "i915 has gone from the initramfs module list"
fi

# ---------------------------------------------------------------------------
# 3. Things a kernel update has to rebuild or re-establish
# ---------------------------------------------------------------------------
section "Rebuilt per kernel"

if command -v dkms >/dev/null 2>&1 && dkms status minibook_ec 2>/dev/null | grep -q "$KR"; then
  fine "minibook_ec is built for $KR"
else
  need 04-minibook-ec "minibook_ec has no DKMS build for the running kernel"
fi
lsmod | grep -q '^minibook_ec' && fine "minibook_ec loaded" \
  || need 04-minibook-ec "minibook_ec is not loaded"

if [[ $EUID -eq 0 ]]; then
  if lsinitramfs "/boot/initrd.img-$KR" 2>/dev/null | grep -q i915; then
    fine "i915 is in the initramfs for $KR"
  else
    need 03-rotation "the initramfs for $KR has no i915, so plymouth draws before rotation is known"
  fi
else
  warn "checking the initramfs needs root, so that check was skipped"
fi

# ---------------------------------------------------------------------------
# 4. Things a package update can quietly replace
# ---------------------------------------------------------------------------
section "Replaceable by package updates"

# The diversion is what keeps the fork in place when the distribution package
# updates. Without it an update silently restores the stock binary and tablet
# mode stops working.
if dpkg-divert --list /usr/libexec/iio-sensor-proxy 2>/dev/null | grep -q distrib; then
  fine "the iio-sensor-proxy diversion is intact"
else
  need 05-tablet-mode "the diversion is gone, so the distribution binary is what runs"
fi
systemctl is-active --quiet iio-sensor-proxy.service \
  && fine "iio-sensor-proxy is running" \
  || need 05-tablet-mode "iio-sensor-proxy is not running"
grep -qil "tablet mode" /sys/class/input/*/name 2>/dev/null \
  && fine "the tablet mode switch is present" \
  || need 05-tablet-mode "no tablet mode switch, so auto-rotation is dead"
lsmod | grep -q '^uinput' && fine "uinput loaded" \
  || need 05-tablet-mode "uinput is not loaded and the daemon cannot load it itself"

# hwdb is not a conffile, but systemd upgrades rebuild the binary database and a
# botched rebuild would show up here.
ev=""
for d in /sys/class/input/event*; do
  nm=$(cat "$d/device/name" 2>/dev/null || true)
  [[ "$nm" == *Touchpad* ]] && ev="/dev/input/$(basename "$d")"
done
if [[ -n "$ev" ]]; then
  fz=$(udevadm info "$ev" 2>/dev/null | grep -oP 'LIBINPUT_FUZZ_35=\K[0-9]+' || echo "")
  [[ -n "$fz" && "$fz" != "0" ]] && fine "touchpad fuzz = $fz" \
    || need 07-touchpad "the touchpad fuzz is gone, so the pointer will jitter"
fi

# ---------------------------------------------------------------------------
# 5. Verdict
# ---------------------------------------------------------------------------
section "Result"

if (( ${#NEEDED[@]} == 0 )); then
  printf '\n%s\n' "${C_GREEN}${C_BOLD}The upgrade broke nothing.${C_RESET}"
  printf '%s\n' "Run 99-verify.sh for the full picture."
  exit 0
fi

# Re-run in the installer's own order rather than the order problems were found.
ORDER=(01-kernel 03-rotation 04-minibook-ec 05-tablet-mode 06-refresh-rate 07-touchpad)
SORTED=()
for s in "${ORDER[@]}"; do
  for n in "${NEEDED[@]}"; do [[ $n == "$s" ]] && SORTED+=("$s"); done
done

printf '\n%s\n' "${C_YELLOW}${C_BOLD}${#SORTED[@]} step(s) need re-running:${C_RESET}"
for s in "${SORTED[@]}"; do printf '  sudo %s/%s.sh\n' "$HERE" "$s"; done
printf '\n%s\n' "Every step is idempotent, so re-running a step that was already fine is safe."

if (( FIX )); then
  printf '\n%s\n' "${C_BOLD}--fix given, running them now.${C_RESET}"
  for s in "${SORTED[@]}"; do
    printf '\n%s\n' "${C_BOLD}${C_BLUE}━━━ ${s} ━━━${C_RESET}"
    "$HERE/${s}.sh" || fail "${s} failed. Fix what it reported, then run this again."
  done
  printf '\n%s\n' "${C_GREEN}${C_BOLD}Done.${C_RESET} Reboot, then run 99-verify.sh."
else
  printf '%s\n' "Or run everything at once with:  sudo $0 --fix"
fi
exit 1
