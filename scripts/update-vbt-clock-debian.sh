#!/bin/bash
# SPDX-License-Identifier: 0BSD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly REPO_DIR="${SCRIPT_DIR%/*}"
readonly VBT_TOOL_DIR="${REPO_DIR}/upstream/vbt_patch"
readonly VBT_TOOL="${VBT_PATCH_BIN:-${VBT_TOOL_DIR}/vbt_patch}"
readonly FIRMWARE_VBT="/lib/firmware/vbt"
readonly GRUB_CONF="/etc/default/grub"
readonly GRUB_KEY="GRUB_CMDLINE_LINUX_DEFAULT"
readonly CMDLINE_KEY="i915.vbt_firmware"
readonly CMDLINE_PARAM="i915.vbt_firmware=vbt"
readonly HOOK_DIR="/etc/initramfs-tools/hooks"
readonly HOOK_FILE="${HOOK_DIR}/vbt_firmware"
readonly HOOK_MARKER="update-vbt-clock-debian.sh"
readonly HOOK_FUNCTIONS="/usr/share/initramfs-tools/hook-functions"

# vbt_patch rewrites the DTD pixel clock as hz * htotal * vtotal, so the
# requested rate maps straight onto the DSI link rate and a silly value
# produces a panel that never lights up -- recoverable only by editing
# the kernel command line from the GRUB menu. 30 Hz is the floor because
# nothing below the panel's native ~50 Hz is useful and very low clocks
# can stop the panel locking; 120 Hz is the ceiling because 1920x1200
# with this panel's blanking already needs roughly 300 MHz there. 90 Hz
# is the rate this device is known to run at.
readonly MIN_HZ=30
readonly MAX_HZ=120

sys_vbt=""
work_dir=""
grub_backup=""
rollback_armed=0
success=0

usage() {
  cat <<EOF
Usage: ${0##*/} <framerate>
       ${0##*/} --revert

Patches the DSI panel VBT to <framerate> Hz (${MIN_HZ}-${MAX_HZ}) and
makes the kernel use it at boot:

  1. reads the live VBT from debugfs
  2. installs the patched blob as ${FIRMWARE_VBT}
  3. adds it to the initramfs via ${HOOK_FILE}
  4. appends ${CMDLINE_PARAM} to ${GRUB_KEY}
     in ${GRUB_CONF}
  5. runs update-initramfs and update-grub

--revert undoes all four changes and rebuilds both.
EOF
}

die() {
  echo "Error: $1" >&2
  shift
  local line
  for line in "$@"; do
    echo "  ${line}" >&2
  done
  exit 1
}

require_root() {
  if (( EUID != 0 )); then
    die "this script must be run as root (use sudo)"
  fi
}

validate_framerate() {
  local framerate="$1"
  if [[ ! "${framerate}" =~ ^[1-9][0-9]{0,2}$ ]]; then
    die "framerate must be a plain positive integer, got: '${framerate}'"
  fi
  if (( framerate < MIN_HZ || framerate > MAX_HZ )); then
    die "framerate ${framerate} is outside ${MIN_HZ}-${MAX_HZ} Hz"
  fi
}

detect_sys_vbt() {
  local candidate
  for candidate in /sys/kernel/debug/dri/*/i915_vbt; do
    if [[ -r "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

resolve_sys_vbt() {
  if sys_vbt="$(detect_sys_vbt)"; then
    return 0
  fi
  die "no readable i915_vbt under /sys/kernel/debug/dri" \
    "The i915 driver must be bound and debugfs mounted:" \
    "  mount -t debugfs none /sys/kernel/debug" \
    "(a panel driven by the xe driver has no i915_vbt and no" \
    "i915.vbt_firmware parameter)"
}

require_grub() {
  if [[ ! -f "${GRUB_CONF}" ]]; then
    die "${GRUB_CONF} not found -- only GRUB is supported"
  fi
  if [[ ! -d /boot/grub ]]; then
    die "/boot/grub not found -- only GRUB is supported"
  fi
  if ! command -v update-grub &>/dev/null; then
    die "update-grub not found -- only GRUB is supported"
  fi
}

require_initramfs_tools() {
  if ! command -v update-initramfs &>/dev/null; then
    die "update-initramfs not found -- only initramfs-tools is supported"
  fi
  if [[ ! -f "${HOOK_FUNCTIONS}" ]]; then
    die "${HOOK_FUNCTIONS} not found" \
      "-- only initramfs-tools is supported"
  fi
  if [[ ! -d "${HOOK_DIR}" ]]; then
    die "${HOOK_DIR} not found -- only initramfs-tools is supported"
  fi
}

check_environment() {
  require_grub
  require_initramfs_tools
  resolve_sys_vbt
}

# The vbt_patch Makefile fetches intel_vbt_defs.h from torvalds/master
# over the network, unpinned and unverified. Compiling and running that
# from a root-privileged script would execute unreviewed, unversioned
# code as root, so this script never builds the tool: it requires a
# binary the user built beforehand as themselves, with a chance to look
# at what was downloaded.
require_vbt_tool() {
  if [[ -x "${VBT_TOOL}" ]]; then
    return 0
  fi
  die "vbt_patch is not built: ${VBT_TOOL}" \
    "Build it first as your normal (non-root) user:" \
    "  make -C ${VBT_TOOL_DIR}" \
    "That downloads intel_vbt_defs.h from git.kernel.org master;" \
    "review it before re-running this script."
}

hook_is_ours() {
  [[ "$(<"${HOOK_FILE}")" == *"${HOOK_MARKER}"* ]]
}

refuse_existing_state() {
  if [[ -e "${FIRMWARE_VBT}" ]]; then
    die "${FIRMWARE_VBT} already exists" \
      "Remove it or run: ${0} --revert"
  fi
  if [[ -e "${HOOK_FILE}" ]] && ! hook_is_ours; then
    die "${HOOK_FILE} exists and was not written by this script" \
      "Move it aside and re-run."
  fi
}

setup_work_dir() {
  work_dir="$(mktemp -d)"
}

remove_work_dir() {
  if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
    rm -rf -- "${work_dir}"
  fi
}

require_nonempty_output() {
  local output="$1"
  if [[ ! -s "${output}" ]]; then
    die "vbt_patch wrote no output -- nothing has been installed" \
      "It exits 0 without writing when it finds nothing to patch" \
      "(no Block 58 generic DTD in this VBT), so the blob would" \
      "have been empty."
  fi
}

require_same_size() {
  local input="$1"
  local output="$2"
  local in_size out_size
  in_size="$(wc -c < "${input}")"
  out_size="$(wc -c < "${output}")"
  in_size=$((in_size))
  out_size=$((out_size))
  if (( in_size != out_size )); then
    die "patched VBT is ${out_size} bytes, source is ${in_size}" \
      "-- refusing to install a truncated blob"
  fi
}

require_vbt_signature() {
  local output="$1"
  if [[ "$(head -c 4 -- "${output}")" != '$VBT' ]]; then
    die "patched blob does not start with the \$VBT signature" \
      "-- refusing to install it"
  fi
}

validate_patched_blob() {
  local input="$1"
  local output="$2"
  require_nonempty_output "${output}"
  require_same_size "${input}" "${output}"
  require_vbt_signature "${output}"
}

install_patched_vbt() {
  local framerate="$1"
  local input="${work_dir}/vbt.in"
  local output="${work_dir}/vbt.out"

  cp -- "${sys_vbt}" "${input}"
  "${VBT_TOOL}" "${input}" --hz "${framerate}" "${output}"
  validate_patched_blob "${input}" "${output}"

  rollback_armed=1
  install -m 0644 -o root -g root -- "${output}" "${FIRMWARE_VBT}"
  echo "Installed patched VBT -> ${FIRMWARE_VBT}"
}

write_hook_file() {
  cat > "${HOOK_FILE}" <<'HOOK'
#!/bin/sh
# SPDX-License-Identifier: 0BSD
# Installed by update-vbt-clock-debian.sh -- its --revert removes this.
# Puts the patched VBT blob into the initramfs so i915 can load it via
# i915.vbt_firmware=vbt before the DSI panel is brought up.
PREREQ=""

prereqs() {
  echo "${PREREQ}"
}

case "$1" in
  prereqs)
    prereqs
    exit 0
    ;;
esac

. /usr/share/initramfs-tools/hook-functions

if [ ! -e /lib/firmware/vbt ]; then
  exit 0
fi

if command -v add_firmware >/dev/null 2>&1; then
  add_firmware vbt
else
  copy_file firmware /lib/firmware/vbt /lib/firmware/vbt
fi

exit 0
HOOK
}

install_hook() {
  write_hook_file
  chmod 0755 "${HOOK_FILE}"
  echo "Installed initramfs hook -> ${HOOK_FILE}"
}

remove_firmware() {
  if [[ ! -e "${FIRMWARE_VBT}" ]]; then
    return 1
  fi
  rm -f -- "${FIRMWARE_VBT}"
  echo "Removed ${FIRMWARE_VBT}"
}

remove_hook() {
  if [[ ! -e "${HOOK_FILE}" ]]; then
    return 1
  fi
  if ! hook_is_ours; then
    echo "Warning: ${HOOK_FILE} is not ours -- left in place" >&2
    return 1
  fi
  rm -f -- "${HOOK_FILE}"
  echo "Removed ${HOOK_FILE}"
}

is_cmdline_line() {
  local line="$1"
  [[ "${line}" =~ ^[[:space:]]*${GRUB_KEY}= ]]
}

grub_line_quote() {
  local raw="${1#*=}"
  case "${raw:0:1}" in
    '"') printf '%s' '"' ;;
    "'") printf '%s' "'" ;;
    *) printf '%s' '"' ;;
  esac
}

grub_line_value() {
  local raw="${1#*=}"
  local quote="${raw:0:1}"
  if [[ "${quote}" != '"' && "${quote}" != "'" ]]; then
    printf '%s' "${raw}"
    return 0
  fi
  local inner="${raw:1}"
  printf '%s' "${inner:0:${#inner}-1}"
}

validate_grub_line() {
  local raw="${1#*=}"
  local quote="${raw:0:1}"
  if [[ "${quote}" != '"' && "${quote}" != "'" ]]; then
    [[ "${raw}" != *[[:space:]]* ]]
    return
  fi
  local inner="${raw:1}"
  if [[ "${inner: -1}" != "${quote}" ]]; then
    return 1
  fi
  inner="${inner:0:${#inner}-1}"
  [[ "${inner}" != *"${quote}"* ]]
}

value_has_token() {
  local value="$1"
  local needle="$2"
  local -a tokens=()
  read -r -a tokens <<< "${value}" || true
  if (( ${#tokens[@]} == 0 )); then
    return 1
  fi
  local token
  for token in "${tokens[@]}"; do
    # shellcheck disable=SC2053 # needle is a glob on purpose
    if [[ "${token}" == ${needle} ]]; then
      return 0
    fi
  done
  return 1
}

strip_vbt_params() {
  local value="$1"
  local -a tokens=()
  local -a kept=()
  read -r -a tokens <<< "${value}" || true
  if (( ${#tokens[@]} == 0 )); then
    return 0
  fi
  local token
  for token in "${tokens[@]}"; do
    if [[ "${token}" == "${CMDLINE_KEY}="* ]]; then
      continue
    fi
    kept+=("${token}")
  done
  if (( ${#kept[@]} == 0 )); then
    return 0
  fi
  printf '%s' "${kept[*]}"
}

apply_param_to_value() {
  local value="$1"
  local action="$2"
  local stripped
  stripped="$(strip_vbt_params "${value}")"
  if [[ "${action}" == "remove" ]]; then
    printf '%s' "${stripped}"
    return 0
  fi
  if [[ -z "${stripped}" ]]; then
    printf '%s' "${CMDLINE_PARAM}"
    return 0
  fi
  printf '%s' "${stripped} ${CMDLINE_PARAM}"
}

rewrite_cmdline_line() {
  local line="$1"
  local action="$2"
  local indent="${line%%[![:space:]]*}"
  local quote value new_value
  quote="$(grub_line_quote "${line}")"
  value="$(grub_line_value "${line}")"
  new_value="$(apply_param_to_value "${value}" "${action}")"
  printf '%s%s=%s%s%s' \
    "${indent}" "${GRUB_KEY}" "${quote}" "${new_value}" "${quote}"
}

count_cmdline_lines() {
  local count=0
  local line
  while IFS='' read -r line || [[ -n "${line}" ]]; do
    if is_cmdline_line "${line}"; then
      count=$((count + 1))
    fi
  done < "${GRUB_CONF}"
  printf '%s' "${count}"
}

grub_has_token() {
  local needle="$1"
  local line
  while IFS='' read -r line || [[ -n "${line}" ]]; do
    if ! is_cmdline_line "${line}"; then
      continue
    fi
    if value_has_token "$(grub_line_value "${line}")" "${needle}"; then
      return 0
    fi
  done < "${GRUB_CONF}"
  return 1
}

grub_needs_change() {
  local action="$1"
  if [[ "${action}" == "remove" ]]; then
    grub_has_token "${CMDLINE_KEY}=*"
    return
  fi
  if grub_has_token "${CMDLINE_PARAM}"; then
    return 1
  fi
  return 0
}

require_wellformed_cmdline_lines() {
  local line
  while IFS='' read -r line || [[ -n "${line}" ]]; do
    if ! is_cmdline_line "${line}"; then
      continue
    fi
    if ! validate_grub_line "${line}"; then
      die "cannot safely edit this line in ${GRUB_CONF}:" \
        "  ${line}" \
        "Expected ${GRUB_KEY}=\"...\" with no trailing comment and" \
        "no embedded quotes. Fix it by hand and re-run."
    fi
  done < "${GRUB_CONF}"
}

require_editable_grub_conf() {
  local action="$1"
  local count
  count="$(count_cmdline_lines)"
  if [[ "${action}" == "add" ]] && (( count > 1 )); then
    die "found ${count} uncommented ${GRUB_KEY} lines in ${GRUB_CONF}" \
      "Leave exactly one and re-run."
  fi
  require_wellformed_cmdline_lines
}

backup_grub_conf() {
  local stamp suffix
  stamp="$(date +%Y%m%d-%H%M%S)"
  grub_backup="${GRUB_CONF}.bak.${stamp}"
  suffix=1
  while [[ -e "${grub_backup}" ]]; do
    grub_backup="${GRUB_CONF}.bak.${stamp}.${suffix}"
    suffix=$((suffix + 1))
  done
  cp -p -- "${GRUB_CONF}" "${grub_backup}"
  echo "Backed up ${GRUB_CONF} -> ${grub_backup}"
}

install_grub_conf() {
  local tmp="$1"
  if cat -- "${tmp}" > "${GRUB_CONF}"; then
    return 0
  fi
  cp -p -- "${grub_backup}" "${GRUB_CONF}" || true
  die "failed to write ${GRUB_CONF} -- restored ${grub_backup}"
}

rewrite_grub_conf() {
  local action="$1"
  local tmp="${work_dir}/grub.new"
  local found=0
  local line
  : > "${tmp}"
  while IFS='' read -r line || [[ -n "${line}" ]]; do
    if is_cmdline_line "${line}"; then
      found=1
      line="$(rewrite_cmdline_line "${line}" "${action}")"
    fi
    printf '%s\n' "${line}" >> "${tmp}"
  done < "${GRUB_CONF}"
  if (( found == 0 )) && [[ "${action}" == "add" ]]; then
    printf '%s="%s"\n' "${GRUB_KEY}" "${CMDLINE_PARAM}" >> "${tmp}"
  fi
  install_grub_conf "${tmp}"
}

set_cmdline_param() {
  local action="$1"
  if [[ ! -f "${GRUB_CONF}" ]]; then
    return 1
  fi
  require_editable_grub_conf "${action}"
  if ! grub_needs_change "${action}"; then
    return 1
  fi
  backup_grub_conf
  rewrite_grub_conf "${action}"
}

update_grub() {
  if ! command -v update-grub &>/dev/null; then
    die "update-grub not found -- ${GRUB_CONF} was changed but" \
      "grub.cfg was not regenerated"
  fi
  echo "Regenerating grub.cfg (update-grub)..."
  if ! update-grub; then
    die "update-grub failed" \
      "${GRUB_CONF} was changed; fix the error and re-run" \
      "update-grub, or restore ${grub_backup}"
  fi
}

rebuild_initramfs() {
  if ! command -v update-initramfs &>/dev/null; then
    die "update-initramfs not found -- the initramfs is now stale"
  fi
  echo "Rebuilding initramfs (update-initramfs -u -k all)..."
  if ! update-initramfs -u -k all; then
    die "update-initramfs failed"
  fi
}

restore_grub_conf() {
  if [[ -z "${grub_backup}" || ! -f "${grub_backup}" ]]; then
    return 1
  fi
  cp -p -- "${grub_backup}" "${GRUB_CONF}"
  echo "Restored ${GRUB_CONF} from ${grub_backup}"
}

rollback() {
  echo "Aborting -- undoing the changes made so far" >&2
  if restore_grub_conf; then
    update-grub || echo "Warning: update-grub failed" >&2
  fi
  local rebuild=0
  if remove_firmware; then
    rebuild=1
  fi
  if remove_hook; then
    rebuild=1
  fi
  if (( rebuild == 1 )); then
    update-initramfs -u -k all \
      || echo "Warning: update-initramfs failed" >&2
  fi
}

cleanup() {
  remove_work_dir
  if (( rollback_armed == 0 )) || (( success == 1 )); then
    return 0
  fi
  rollback || true
}

print_grub_summary() {
  if [[ -z "${grub_backup}" ]]; then
    echo "  ${GRUB_CONF}: unchanged, ${CMDLINE_PARAM} was already set"
    return 0
  fi
  echo "  ${GRUB_CONF}: ${CMDLINE_PARAM} added to ${GRUB_KEY}"
  echo "    backup: ${grub_backup}"
}

print_apply_summary() {
  local framerate="$1"
  echo
  echo "Changed:"
  echo "  ${FIRMWARE_VBT} (new: VBT patched to ${framerate} Hz)"
  echo "  ${HOOK_FILE} (new: adds that blob to the initramfs)"
  print_grub_summary
  echo "  regenerated grub.cfg and the initramfs of every kernel"
  echo
  echo "Reboot to apply. To undo everything: ${0} --revert"
  echo "If the panel stays black, press 'e' in the GRUB menu, delete"
  echo "${CMDLINE_PARAM} from the linux line, boot, then run --revert."
}

apply() {
  local framerate="$1"
  validate_framerate "${framerate}"
  check_environment
  require_vbt_tool
  refuse_existing_state
  require_editable_grub_conf add

  install_patched_vbt "${framerate}"
  install_hook
  rebuild_initramfs
  set_cmdline_param add || true
  update_grub
  success=1
  print_apply_summary "${framerate}"
}

revert() {
  local rebuild=0
  local changed=0
  if set_cmdline_param remove; then
    echo "Removed ${CMDLINE_KEY}=... from ${GRUB_CONF}"
    update_grub
    changed=1
  fi
  if remove_firmware; then
    rebuild=1
  fi
  if remove_hook; then
    rebuild=1
  fi
  if (( rebuild == 1 )); then
    rebuild_initramfs
    changed=1
  fi
  success=1
  print_revert_summary "${changed}"
}

print_revert_summary() {
  local changed="$1"
  if (( changed == 0 )); then
    echo "Nothing to revert -- no changes of ours were found."
    return 0
  fi
  echo "Revert complete -- reboot to apply."
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    return 0
  fi

  if (( $# != 1 )); then
    usage >&2
    exit 1
  fi

  if [[ "$1" != "--revert" ]]; then
    validate_framerate "$1"
  fi

  require_root
  trap cleanup EXIT
  setup_work_dir

  if [[ "$1" == "--revert" ]]; then
    revert
    return 0
  fi

  apply "$1"
}

main "$@"
