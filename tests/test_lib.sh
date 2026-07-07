#!/usr/bin/env bash
# Unit tests for nvidia-kernel-rebuild-lib.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../nvidia-kernel-rebuild-lib.sh
source "${REPO_ROOT}/nvidia-kernel-rebuild-lib.sh"

PASS=0
FAIL=0

assert_true() {
    local description="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local description="$1"
    shift
    if ! "$@"; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

test_validate_kernel_version() {
    assert_true "accepts normal kernel version" validate_kernel_version "6.12.74+deb13+1-amd64"
    assert_true "accepts tilde version" validate_kernel_version "6.13.0~rc1-amd64"
    assert_false "rejects empty version" validate_kernel_version ""
    assert_false "rejects path traversal" validate_kernel_version "../../etc/passwd"
    assert_false "rejects shell metacharacters" validate_kernel_version '6.12; rm -rf /'
    assert_false "rejects spaces" validate_kernel_version "6.12 bad"
}

test_parse_dkms_status_line() {
    local line="nvidia-current/550.163.01, 6.12.74+deb13+1-amd64, x86_64: installed"

    assert_true "parses installed line" parse_dkms_status_line "$line"
    assert_eq "module name" "nvidia-current" "$dkms_mod"
    assert_eq "module version" "550.163.01" "$dkms_ver"
    assert_eq "module status" "installed" "$dkms_status"

    assert_false "rejects malformed line" parse_dkms_status_line "not-a-dkms-line"
}

test_nvidia_module_exists() {
    local tmp
    tmp="$(mktemp -d)"
    local kernel="6.12.0-test-amd64"
    local dkms_dir="${tmp}/lib/modules/${kernel}/updates/dkms"

    mkdir -p "$dkms_dir"
    assert_false "missing module returns false" nvidia_module_exists "$kernel"

    touch "${dkms_dir}/nvidia-current.ko"
    MODULES_ROOT="${tmp}/lib/modules"
    nvidia_module_exists() {
        local k="$1"
        local dir="${MODULES_ROOT}/${k}/updates/dkms"
        [[ -d "$dir" ]] || return 1
        _with_nullglob _nvidia_module_exists_in_dir "$dir"
    }
    assert_true "nvidia module file is detected" nvidia_module_exists "$kernel"

    rm -rf "$tmp"
}

test_boot_kernel_selection() {
    local tmp
    tmp="$(mktemp -d)"
    BOOT_DIR="$tmp"

    touch "${BOOT_DIR}/vmlinuz-6.11.0-amd64"
    touch "${BOOT_DIR}/vmlinuz-6.12.5-amd64"
    touch "${BOOT_DIR}/vmlinuz-6.12.10-amd64"

    assert_eq "newest installed kernel" "6.12.10-amd64" "$(get_newest_installed_kernel)"

    MODULES_ROOT="${tmp}/lib/modules"
    nvidia_module_exists() {
        [[ "$1" == "6.12.10-amd64" ]] && return 1
        return 0
    }

    assert_eq "newest kernel missing nvidia" "6.12.10-amd64" "$(get_newest_kernel_missing_nvidia)"

    rm -rf "$tmp"
}

test_nullglob_not_leaked() {
  shopt -u nullglob 2>/dev/null || true
  assert_false "nullglob starts disabled" shopt -q nullglob

  local tmp
  tmp="$(mktemp -d)"
  MODULES_ROOT="${tmp}/lib/modules"
  mkdir -p "${MODULES_ROOT}/6.12.0-test-amd64/updates/dkms"
  nvidia_module_exists() {
      local k="$1"
      local dir="${MODULES_ROOT}/${k}/updates/dkms"
      [[ -d "$dir" ]] || return 1
      _with_nullglob _nvidia_module_exists_in_dir "$dir"
  }

  nvidia_module_exists "6.12.0-test-amd64" || true
  assert_false "nullglob restored after helper" shopt -q nullglob

  rm -rf "$tmp"
}

test_validate_kernel_version
test_parse_dkms_status_line
test_nvidia_module_exists
test_boot_kernel_selection
test_nullglob_not_leaked

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
