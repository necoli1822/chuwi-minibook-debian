#!/usr/bin/env bash
# install/lib/common.sh - shared by every step script
#
# Design rules
#   - Idempotent: running twice is safe, and anything already done is skipped
#   - Verification built in: after applying, check the result and fail if it did not take
#   - --dry-run: show what would change before changing it
#   - Always print where the backups went

set -euo pipefail

# ── Locations ──────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Under sudo, $HOME becomes /root, but 06-refresh-rate builds vbt_patch as the
# invoking user, who cannot write there. Use the calling user's home instead.
if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
  _CALLER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  _CALLER_HOME="$HOME"
fi
WORK_DIR="${MINIBOOK_WORK_DIR:-${_CALLER_HOME}/.cache/minibook-install}"
UPSTREAM_URL="https://github.com/fstanis/chuwi-minibook.git"
# The audit and the measurements were done against this commit. If you move it,
# re-check patches/ as well.
UPSTREAM_COMMIT="496dfe4eb252c3810ddf938cc7189d80df026952"
UPSTREAM_DIR="$WORK_DIR/chuwi-minibook"

# ── Output ─────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

DRY_RUN=0
STEP_NAME="${STEP_NAME:-$(basename "${0%.sh}")}"

log()   { printf '%s\n' "${C_DIM}[${STEP_NAME}]${C_RESET} $*"; }
info()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()    { printf '%s\n' "  ${C_GREEN}ok${C_RESET}      $*"; }
skip()  { printf '%s\n' "  ${C_DIM}skipped${C_RESET} $*"; }
warn()  { printf '%s\n' "  ${C_YELLOW}warning${C_RESET} $*" >&2; }
fail()  { printf '%s\n' "  ${C_RED}failed${C_RESET}  $*" >&2; exit 1; }

section() { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }

# Under --dry-run, show the command instead of running it
run() {
  if (( DRY_RUN )); then
    printf '%s\n' "  ${C_DIM}[dry-run]${C_RESET} $*"
    return 0
  fi
  "$@"
}

# ── Argument parsing ───────────────────────────────────────────
parse_common_args() {
  while (( $# )); do
    case "$1" in
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            EXTRA_ARGS+=("$1"); shift ;;
    esac
  done
}

# ── Preconditions ──────────────────────────────────────────────
need_root() {
  if (( EUID != 0 )); then
    fail "this step needs root: sudo $0 $*"
  fi
}

refuse_root() {
  if (( EUID == 0 )); then
    fail "this step must not run as root. Run it as a normal user."
  fi
}

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail "required command missing: $c"
  done
}

# Confirm this is the right machine. Running these steps elsewhere could damage hardware.
assert_minibook() {
  local product vendor
  product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
  vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)"
  if [[ "$product" != *"MiniBook"* ]]; then
    fail "this is not a MiniBook (vendor=$vendor product=$product). Stopping."
  fi
  ok "machine: $vendor $product"
}

# ── File edits (idempotent, with backups) ──────────────────────
BACKUP_SUFFIX=".minibook-bak"

backup_once() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ -f "$f$BACKUP_SUFFIX" ]]; then
    skip "backup already exists: $f$BACKUP_SUFFIX"
  else
    run cp -a "$f" "$f$BACKUP_SUFFIX"
    ok "backed up to $f$BACKUP_SUFFIX"
  fi
}

# Append a line only if it is not already there
ensure_line() {
  local file="$1" line="$2"
  if [[ -f "$file" ]] && grep -qxF "$line" "$file"; then
    skip "already present: $line  ($file)"
    return 0
  fi
  run mkdir -p "$(dirname "$file")"
  if (( DRY_RUN )); then
    printf '%s\n' "  ${C_DIM}[dry-run]${C_RESET} would append to $file: $line"
  else
    printf '%s\n' "$line" >> "$file"
    ok "appended: $line  ($file)"
  fi
}

# Add a token to GRUB_CMDLINE_LINUX_DEFAULT, idempotently
grub_cmdline_add() {
  local token="$1"
  local key="GRUB_CMDLINE_LINUX_DEFAULT"
  local cur
  cur="$(grep -oP "^${key}=\"\K[^\"]*" /etc/default/grub || echo '')"
  if grep -qw -- "${token%%=*}" <<<"$cur"; then
    skip "kernel parameter already present: $token"
    return 0
  fi
  backup_once /etc/default/grub
  if (( DRY_RUN )); then
    printf '%s\n' "  ${C_DIM}[dry-run]${C_RESET} would add kernel parameter: $token"
  else
    sed -i "s|^${key}=\"\(.*\)\"|${key}=\"\1 ${token}\"|" /etc/default/grub
    ok "added kernel parameter: $token"
  fi
}

# ── Fetching upstream (pinned commit, then patches) ────────────
fetch_upstream() {
  run mkdir -p "$WORK_DIR"
  if [[ -d "$UPSTREAM_DIR/.git" ]]; then
    local have
    have="$(git -C "$UPSTREAM_DIR" rev-parse HEAD 2>/dev/null || echo none)"
    if [[ "$have" == "$UPSTREAM_COMMIT" ]]; then
      skip "upstream already at the pinned commit (${UPSTREAM_COMMIT:0:8})"
      return 0
    fi
    warn "upstream is at a different commit (${have:0:8}). Re-fetching."
    run rm -rf "$UPSTREAM_DIR"
  fi
  info "fetching upstream (pinned to ${UPSTREAM_COMMIT:0:8})"
  run git clone -q "$UPSTREAM_URL" "$UPSTREAM_DIR"
  run git -C "$UPSTREAM_DIR" checkout -q "$UPSTREAM_COMMIT"
  # Confirm the commit rather than trusting a tag or branch
  if (( ! DRY_RUN )); then
    local got
    got="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
    [[ "$got" == "$UPSTREAM_COMMIT" ]] || fail "commit mismatch: $got"
  fi
  if (( DRY_RUN )); then
    log "  (dry run, so nothing was actually fetched)"
  else
    ok "upstream ready: $UPSTREAM_DIR"
  fi
}

# Apply one of the patches under patches/, idempotently
apply_patch() {
  local patch="$REPO_ROOT/patches/$1"
  [[ -f "$patch" ]] || fail "patch not found: $patch"
  # Under --dry-run upstream was never fetched, so there is nothing to check against
  if (( DRY_RUN )) && [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
    printf '%s\n' "  ${C_DIM}[dry-run]${C_RESET} would apply patch: $1"
    return 0
  fi
  if git -C "$UPSTREAM_DIR" apply --reverse --check "$patch" 2>/dev/null; then
    skip "patch already applied: $1"
    return 0
  fi
  if ! git -C "$UPSTREAM_DIR" apply --check "$patch" 2>/dev/null; then
    fail "cannot apply patch: $1  (upstream is not what was expected)"
  fi
  run git -C "$UPSTREAM_DIR" apply "$patch"
  ok "applied patch: $1"
}

# Under --dry-run, upstream was never fetched, so skip existence checks on
# anything inside it. Stay strict on a real run.
require_path() {
  local path="$1" what="${2:-path}"
  if [[ -e "$path" ]]; then
    return 0
  fi
  if (( DRY_RUN )); then
    printf '%s\n' "  ${C_DIM}[dry-run]${C_RESET} skipping ${what} check: $path"
    return 1
  fi
  fail "${what} not found: $path"
}

# ── Verification helpers ───────────────────────────────────────
# Verification looks at what actually happened, not at what was written.
check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$desc = $actual"
    return 0
  fi
  warn "$desc: expected [$expected], got [$actual]"
  return 1
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$desc"
    return 0
  fi
  warn "$desc: could not find [$needle]"
  return 1
}

REBOOT_REQUIRED=0
need_reboot() {
  REBOOT_REQUIRED=1
  warn "this change needs a reboot to take effect: $*"
}

finish() {
  if (( REBOOT_REQUIRED )); then
    printf '\n%s\n' "${C_YELLOW}${C_BOLD}A reboot is required.${C_RESET}"
  fi
}
