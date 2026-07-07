#!/usr/bin/env bash
# Shared helpers for nvidia-kernel-rebuild scripts.

LOG=/var/log/nvidia-kernel-rebuild.log

nvidia_dkms_registered() {
    /usr/sbin/dkms status 2>/dev/null | grep -qE '^nvidia'
}

nvidia_module_exists() {
    local kernel="$1"
    local dkms_dir="/lib/modules/${kernel}/updates/dkms"
    local f

    [[ -d "$dkms_dir" ]] || return 1
    shopt -s nullglob
    for f in "${dkms_dir}"/nvidia*.ko*; do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

find_nvidia_module() {
    local kernel="$1"
    local dkms_dir="/lib/modules/${kernel}/updates/dkms"
    local f

    shopt -s nullglob
    for f in "${dkms_dir}"/nvidia*.ko*; do
        [[ -e "$f" ]] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

kernel_headers_present() {
    [[ -d "/usr/src/linux-headers-${1}" ]]
}

validate_kernel_version() {
    [[ "${1}" =~ ^[0-9A-Za-z.+~_-]+$ ]]
}

secure_boot_enabled() {
    command -v mokutil >/dev/null 2>&1 \
        && mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
}

apt_recent_nvidia_driver_change() {
    local log=/var/log/dpkg.log
    [[ -f "$log" ]] || return 1
    tail -50 "$log" | grep -qE '(status installed |upgrade )[^:]+: nvidia-kernel-dkms'
}

apt_recent_kernel_change() {
    local log=/var/log/dpkg.log
    [[ -f "$log" ]] || return 1
    tail -50 "$log" | grep -qE '(status installed |upgrade )[^:]+: linux-(image|headers)-'
}

get_newest_kernel_missing_nvidia() {
    local missing=()
    local vmlinuz kv

    for vmlinuz in /boot/vmlinuz-*; do
        [[ -f "$vmlinuz" ]] || continue
        kv="${vmlinuz#/boot/vmlinuz-}"
        nvidia_module_exists "$kv" || missing+=("$kv")
    done

    [[ ${#missing[@]} -eq 0 ]] && return 1
    printf '%s\n' "${missing[@]}" | sort -V | tail -1
}

get_newest_installed_kernel() {
    ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1
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
