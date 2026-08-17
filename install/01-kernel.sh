#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# 01-kernel - install the XanMod kernel and the DKMS build tools.
STEP_NAME=kernel
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { cat <<EOF
Usage: sudo $0 [-n|--dry-run]

Installs the XanMod x64v3 kernel and everything DKMS needs to build against it.

Why XanMod: the stock kernel works for most of this, but XanMod brings a newer
i915 and input stack and proved stable here. Another kernel is fine as long as it
is 6.9 or newer, otherwise the accelerometers will not enumerate.

**Important**: XanMod x64v3 is built with clang, LLD and ThinLTO, so clang, lld and
llvm must be present for DKMS to build anything against it. Without them every
kernel update silently fails to rebuild minibook_ec.
EOF
}

EXTRA_ARGS=()
parse_common_args "$@"
need_root "$@"
assert_minibook

section "1. DKMS build tools"
# XanMod is a clang + ThinLTO build, so this whole set is required. Miss one and
# module rebuilds fail on the next kernel update.
PKGS=(build-essential dkms clang lld llvm libelf-dev git)
missing=()
for p in "${PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
done
if (( ${#missing[@]} )); then
  info "installing: ${missing[*]}"
  run apt-get update -qq
  run apt-get install -y "${missing[@]}"
else
  skip "build tools already installed"
fi

section "2. XanMod kernel"
if dpkg-query -W -f='${Status}' linux-xanmod-x64v3 2>/dev/null | grep -q "ok installed"; then
  skip "linux-xanmod-x64v3 already installed ($(dpkg-query -W -f='${Version}' linux-xanmod-x64v3))"
else
  info "adding the XanMod repository"
  # Fetch the key into a keyring. apt-key is deprecated and is not used here.
  run mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/xanmod-archive-keyring.gpg ]]; then
    run bash -c 'curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg'
  fi
  ensure_line /etc/apt/sources.list.d/xanmod-release.list \
    'deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main'
  run apt-get update -qq
  info "installing linux-xanmod-x64v3"
  run apt-get install -y linux-xanmod-x64v3
  need_reboot "boot into the new kernel"
fi

section "3. Verification"
if (( DRY_RUN )); then
  skip "dry run, so verification is skipped"
  exit 0
fi
for c in clang ld.lld llvm-ar dkms; do
  command -v "$c" >/dev/null 2>&1 && ok "$c present" || fail "$c is missing, so DKMS builds will fail."
done
if ls /boot/vmlinuz-*xanmod* >/dev/null 2>&1; then
  ok "XanMod kernel image: $(basename "$(ls /boot/vmlinuz-*xanmod* | head -1)")"
else
  fail "no XanMod kernel image found"
fi

# Knowing whether the installed clang matches the one the kernel was built with
# saves time later
if [[ -r /proc/version ]]; then
  log "running kernel was built with: $(grep -o 'clang version [0-9.]*' /proc/version || echo '(not clang)')"
  log "installed clang: $(clang --version | head -1)"
fi

finish
