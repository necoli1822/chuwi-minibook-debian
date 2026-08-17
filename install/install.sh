#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD
# install.sh - runs the steps in order
STEP_NAME=install
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { cat <<EOF
Usage: sudo $0 [-n|--dry-run] [--from N] [--only N]

Applies the Chuwi MiniBook X N150 setup in order.

  00  preflight       machine and environment checks (changes nothing)
  01  kernel          XanMod plus the DKMS build tools    [reboot]
  02  kernel-cleanup  remove the stock kernel             [reboot]
  03  rotation        display rotation                    [reboot]
  04  minibook-ec     EC module (fan, temperatures, bios_unlock)
  05  tablet-mode     auto-rotation from the two accelerometers
  06  refresh-rate    VBT at 75Hz                         [reboot]
  07  touchpad        pointer jitter suppression
  99  verify          verify everything against the running system (changes nothing)

Why 02 sits there: the right moment is immediately after booting into XanMod and
confirming it works. Any earlier and there is nowhere to fall back to if XanMod does
not boot; any later and DKMS builds against both kernels until then, with the fallout
from autoremove only surfacing at the end.

Options
  -n, --dry-run   show what would change without changing it
      --from N    resume from step N (for example --from 03)
      --only N    run step N alone

The run stops at each step that needs a reboot. Resume afterwards with --from.
Every step is idempotent, so starting over from the beginning is also safe.

Examples
  sudo $0 --dry-run          # see the whole plan
  sudo $0                    # from the beginning
  sudo $0 --from 03          # resume after a reboot
  sudo $0 --only 06          # just redo the refresh rate
  $0 --only 99               # verify only (no root needed)
EOF
}

FROM=""
ONLY=""
PASSTHRU=()
while (( $# )); do
  case "$1" in
    -n|--dry-run) PASSTHRU+=("$1"); shift ;;
    --from) FROM="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

STEPS=(00-preflight 01-kernel 02-kernel-cleanup 03-rotation 04-minibook-ec 05-tablet-mode 06-refresh-rate 07-touchpad 99-verify)
# These steps need a reboot before the next one runs
declare -A REBOOT_AFTER=([01-kernel]=1 [02-kernel-cleanup]=1 [03-rotation]=1 [06-refresh-rate]=1)

run_step() {
  local s="$1"
  local script="$HERE/${s}.sh"
  [[ -x "$script" ]] || run chmod +x "$script"
  printf '\n%s\n' "${C_BOLD}${C_BLUE}━━━ ${s} ━━━${C_RESET}"
  if ! "$script" "${PASSTHRU[@]}"; then
    fail "${s} failed. Fix what it reported, then resume with --from ${s%%-*}."
  fi
}

if [[ -n "$ONLY" ]]; then
  match=""
  for s in "${STEPS[@]}"; do [[ "$s" == "$ONLY"* ]] && match="$s"; done
  [[ -n "$match" ]] || fail "no such step: $ONLY"
  run_step "$match"
  exit 0
fi

started=0
[[ -z "$FROM" ]] && started=1
for s in "${STEPS[@]}"; do
  if (( ! started )); then
    [[ "$s" == "$FROM"* ]] && started=1 || continue
  fi
  run_step "$s"
  if [[ -n "${REBOOT_AFTER[$s]:-}" ]]; then
    # Under --dry-run, keep going so the whole plan is visible
    for a in "${PASSTHRU[@]}"; do [[ "$a" == "-n" || "$a" == "--dry-run" ]] && continue 2; done
    printf '\n%s\n' "${C_YELLOW}${C_BOLD}A reboot is needed here.${C_RESET}"
    # Work out the next step number for the resume hint
    nxt=""
    seen=0
    for c in "${STEPS[@]}"; do
      if (( seen )); then nxt="${c%%-*}"; break; fi
      [[ "$c" == "$s" ]] && seen=1
    done
    printf '%s\n' "After rebooting, resume with:  sudo $0 --from ${nxt}"
    exit 0
  fi
done

printf '\n%s\n' "${C_GREEN}${C_BOLD}All steps complete.${C_RESET}"
printf '%s\n' "Verify with: $HERE/99-verify.sh"
