#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 02-kernel-cleanup - remove the distribution's stock kernel.
STEP_NAME=kernel-cleanup
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { cat <<EOF
Usage: sudo $0 [-n|--dry-run] [--yes]

Removes the stock kernel and its meta packages.

**Where this step sits matters.** It belongs immediately after 01-kernel has
installed XanMod and you have actually booted into it and confirmed it works.

  Any earlier  there is nowhere to fall back to if XanMod does not boot on your unit
  Any later    DKMS builds against both kernels until then, and the fallout from
               autoremove only surfaces once everything else is configured

So this script refuses to run unless XanMod is the kernel currently booted.

**Undoing this**: if you need the stock kernel back, sudo apt-get install linux-generic.
If the machine will not boot at all, boot a live USB, chroot in and run the same command.
EOF
}

EXTRA_ARGS=()
ASSUME_YES=0
for a in "$@"; do [[ "$a" == "--yes" ]] && ASSUME_YES=1; done
parse_common_args "${@/--yes/}"
need_root "$@"
assert_minibook

section "1. Precondition - are we booted into XanMod"
CUR="$(uname -r)"
if [[ "$CUR" != *xanmod* ]]; then
  fail "the running kernel is not XanMod ($CUR).
  Boot into XanMod and confirm it works before removing the stock kernel.
  Run 01-kernel.sh, reboot, then come back."
fi
ok "running: $CUR"

# Minimum evidence that XanMod is in a healthy state
[[ -f "/boot/vmlinuz-$CUR" && -f "/boot/initrd.img-$CUR" ]] \
  && ok "boot images intact" || fail "the running kernel's boot images are incomplete"

section "2. Working out what to remove"
# Find the stock kernels automatically (anything that is not XanMod).
# Filtering on db:Status-Status matters: a plain query also lists packages that
# were removed but still have config files, so an already-deleted kernel would be
# picked up again as a target.
mapfile -t STOCK < <(
  dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
    | awk '$1=="installed"{print $2}' | grep -v xanmod || true
)
if (( ${#STOCK[@]} == 0 )); then
  ok "no stock kernel to remove. Already clean."
  exit 0
fi
log "stock kernel images:"
printf '    %s\n' "${STOCK[@]}"

# The meta packages have to go in the same transaction. Removing only the image
# makes apt pull in linux-image-unsigned-* to satisfy the dependency, so instead
# of a removal you get a swap to an unsigned kernel, which will not boot at all
# with Secure Boot enabled.
PKGS=(linux-generic linux-image-generic linux-headers-generic)
for img in "${STOCK[@]}"; do
  ver="${img#linux-image-}"
  PKGS+=("$img" "linux-modules-${ver}" "linux-headers-${ver}" "linux-headers-${ver%-generic}")
done
# Keep only what is actually installed
INSTALLED=()
for p in "${PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" && INSTALLED+=("$p")
done
if (( ${#INSTALLED[@]} == 0 )); then
  ok "nothing to remove. Already clean."
  exit 0
fi
log "${#INSTALLED[@]} package(s) to remove:"
printf '    %s\n' "${INSTALLED[@]}"

section "3. Safety checks"
SIM="$(apt-get remove -s "${INSTALLED[@]}" 2>&1 || true)"
if grep -q '^Inst linux-image-unsigned' <<<"$SIM"; then
  fail "apt wants to install an unsigned kernel instead. The removal list is incomplete.
  Check this output:
$(grep -E '^(Inst|Remv)' <<<"$SIM" | sed 's/^/    /')"
fi
ok "no swap to an unsigned kernel"

# The running kernel must never end up in the removal list
if grep -qE "^Remv .*${CUR}" <<<"$SIM"; then
  fail "the running kernel ($CUR) is in the removal list. Stopping."
fi
ok "the running kernel is not a target"

log "packages that will be removed:"
grep -E '^Remv' <<<"$SIM" | sed 's/^Remv /    /' | cut -d' ' -f1-2

section "4. Preview what autoremove would take with it"
# thermald came out this way here. A person needs to look at this list.
AUTOSIM="$(apt-get autoremove -s 2>&1 || true)"
AUTO="$(grep -E '^Remv' <<<"$AUTOSIM" | sed 's/^Remv //' | cut -d' ' -f1 || true)"
if [[ -n "$AUTO" ]]; then
  warn "autoremove would also take these. Some may have nothing to do with the kernel:"
  printf '      %s\n' $AUTO
  # Stop if anything desktop or kernel related is in there
  if grep -qiE 'kubuntu|plasma|desktop|xanmod|systemd' <<<"$AUTO"; then
    fail "important packages are in the autoremove list. Check this by hand."
  fi
else
  log "  nothing for autoremove"
fi

section "5. Apply"
if (( DRY_RUN )); then
  skip "dry run, so nothing is removed"
  exit 0
fi
if (( ! ASSUME_YES )) && [[ -t 0 ]]; then
  printf '\n%s' "  Remove as listed above. Type yes to continue: "
  read -r ans
  [[ "$ans" == "yes" ]] || fail "cancelled"
fi

apt-get remove -y "${INSTALLED[@]}"
[[ -n "$AUTO" ]] && apt-get autoremove -y
update-grub

section "6. Verification"
ok "running: $(uname -r)"
log "remaining kernel images:"
ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-|    |'

# Boot integrity. Rebooting without checking this leaves no way back.
[[ -f "/boot/vmlinuz-$CUR" ]] || fail "the running kernel's vmlinuz has gone"
[[ -f "/boot/initrd.img-$CUR" ]] || fail "the running kernel's initrd has gone"
grep -q "vmlinuz-$CUR" /boot/grub/grub.cfg || fail "grub.cfg has no entry for the running kernel"
ok "boot images and GRUB entry are intact"

# Make sure the rotation setup survived the initramfs regeneration
if lsinitramfs "/boot/initrd.img-$CUR" 2>/dev/null | grep -q i915; then
  ok "i915 still in the initramfs"
else
  warn "i915 is missing from the initramfs. Re-run 03-rotation.sh."
fi

log ""
log "There is no fallback kernel now. Reboot and confirm the machine comes up."
log "If it does not, boot a live USB, chroot in and run apt-get install linux-generic."

finish
