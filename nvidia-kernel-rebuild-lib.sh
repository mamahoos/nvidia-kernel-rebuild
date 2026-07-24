#!/usr/bin/env bash
# Shared helpers for nvidia-kernel-rebuild scripts.

LOG=/var/log/nvidia-kernel-rebuild.log
BOOT_DIR="${NVIDIA_REBUILD_BOOT_DIR:-/boot}"

# Restore nullglob if it was off before enabling it in a helper.
_with_nullglob() {
  local restore=0
  shopt -q nullglob || restore=1
  shopt -s nullglob
  "$@"
  local status=$?
  [[ $restore -eq 1 ]] && shopt -u nullglob
  return "$status"
}

nvidia_dkms_registered() {
  /usr/sbin/dkms status 2>/dev/null | grep -qE '^nvidia'
}

nvidia_module_exists() {
  local kernel="$1"
  local dkms_dir="/lib/modules/${kernel}/updates/dkms"
  local f

  [[ -d "$dkms_dir" ]] || return 1
  _with_nullglob _nvidia_module_exists_in_dir "$dkms_dir"
}

_nvidia_module_exists_in_dir() {
  local dkms_dir="$1"
  local f
  for f in "${dkms_dir}"/nvidia*.ko*; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

find_nvidia_module() {
  local kernel="$1"
  local dkms_dir="/lib/modules/${kernel}/updates/dkms"
  local f

  _with_nullglob _find_nvidia_module_in_dir "$dkms_dir"
}

_find_nvidia_module_in_dir() {
  local dkms_dir="$1"
  local f
  for f in "${dkms_dir}"/nvidia*.ko*; do
    [[ -e "$f" ]] && {
      printf '%s\n' "$f"
      return 0
    }
  done
  return 1
}

kernel_headers_present() {
  [[ -d "/usr/src/linux-headers-${1}" ]]
}

validate_kernel_version() {
  [[ "${1}" =~ ^[0-9A-Za-z.+~_-]+$ ]]
}

headers_meta_package() {
  if command -v dpkg >/dev/null 2>&1; then
    printf 'linux-headers-%s' "$(dpkg --print-architecture)"
    return 0
  fi
  case "$(uname -m)" in
  x86_64) printf '%s' 'linux-headers-amd64' ;;
  aarch64) printf '%s' 'linux-headers-arm64' ;;
  armv7l) printf '%s' 'linux-headers-armhf' ;;
  *) return 1 ;;
  esac
}

secure_boot_enabled() {
  command -v mokutil >/dev/null 2>&1 &&
    mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
}

# Parse one line from `dkms status`. Sets dkms_mod, dkms_ver, dkms_status.
# Returns 0 when the line matches the expected format.
parse_dkms_status_line() {
  local line="$1"
  local rest status

  [[ "$line" == */*,*:* ]] || return 1

  # shellcheck disable=SC2034
  dkms_mod="${line%%/*}"
  rest="${line#*/}"
  dkms_ver="${rest%%,*}"
  dkms_ver="${dkms_ver// /}"
  status="${line##*: }"
  # shellcheck disable=SC2034
  dkms_status="${status// /}"
  return 0
}

apt_recent_nvidia_driver_change() {
  local log=/var/log/dpkg.log
  [[ -f "$log" ]] || return 1
  tail -200 "$log" | grep -qE '(status installed |upgrade )[^:]+: nvidia-kernel-dkms'
}

apt_recent_kernel_change() {
  local log=/var/log/dpkg.log
  [[ -f "$log" ]] || return 1
  tail -200 "$log" | grep -qE '(status installed |upgrade )[^:]+: linux-(image|headers)-'
}

_list_boot_kernels() {
  local vmlinuz kv
  for vmlinuz in "${BOOT_DIR}"/vmlinuz-*; do
    [[ -f "$vmlinuz" ]] || continue
    kv="${vmlinuz#"${BOOT_DIR}"/vmlinuz-}"
    printf '%s\n' "$kv"
  done
}

get_newest_kernel_missing_nvidia() {
  local missing=()
  local kv

  while IFS= read -r kv; do
    [[ -n "$kv" ]] || continue
    nvidia_module_exists "$kv" || missing+=("$kv")
  done < <(_list_boot_kernels)

  [[ ${#missing[@]} -eq 0 ]] && return 1
  printf '%s\n' "${missing[@]}" | sort -V | tail -1
}

get_newest_installed_kernel() {
  _list_boot_kernels | sort -V | tail -1
}

log_rebuild_schedule() {
  local source="$1"
  local kernel="$2"

  echo "$(date '+%Y-%m-%d %H:%M:%S') ${source}: scheduling rebuild for ${kernel}" >>"$LOG"
  logger -t nvidia-dkms "Scheduling nvidia-kernel-rebuild for kernel ${kernel} (${source})"
}

defer_rebuild() {
  local rebuild="$1"
  local kernel="$2"

  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --no-block --description="nvidia-kernel-rebuild ${kernel}" \
      "$rebuild" "$kernel" >>"$LOG" 2>&1
    return 0
  fi

  "$rebuild" "$kernel"
}

# Schedule a rebuild via systemd-run when available, otherwise run synchronously.
# Returns:
#   0  — skipped (invalid kernel version) or scheduled asynchronously
#   *  — synchronous rebuild's exit code, so callers under `set -e` propagate
#        rebuild failures. Asynchronous (systemd-run) scheduling cannot know
#        the rebuild's outcome and always returns 0.
schedule_rebuild() {
  local source="$1"
  local rebuild="$2"
  local kernel="$3"

  if ! validate_kernel_version "$kernel"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${source}: ignoring invalid kernel version: ${kernel}" >>"$LOG"
    return 0
  fi

  log_rebuild_schedule "$source" "$kernel"
  defer_rebuild "$rebuild" "$kernel"
}
