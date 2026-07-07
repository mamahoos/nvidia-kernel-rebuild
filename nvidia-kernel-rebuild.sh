#!/usr/bin/env bash
# nvidia-kernel-rebuild.sh
#
# Recompiles NVIDIA (and all other DKMS) kernel modules for a given kernel version.
# Safe to run manually after any kernel update, or automatically via hooks.
#
# Usage:
#   sudo ./nvidia-kernel-rebuild.sh              # rebuild for currently running kernel
#   sudo ./nvidia-kernel-rebuild.sh <version>    # rebuild for a specific kernel version

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=nvidia-kernel-rebuild-lib.sh
source "${SCRIPT_DIR}/nvidia-kernel-rebuild-lib.sh"

DKMS=/usr/sbin/dkms
KERNEL="${1:-$(uname -r)}"
ARCH="$(uname -m)"

echo "=== nvidia-kernel-rebuild  $(date '+%Y-%m-%d %H:%M:%S') ===" | tee -a "$LOG"
echo "  Kernel : $KERNEL" | tee -a "$LOG"
echo "  Arch   : $ARCH"   | tee -a "$LOG"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root (use sudo)" | tee -a "$LOG"
    exit 1
fi

if ! validate_kernel_version "$KERNEL"; then
    echo "ERROR: invalid kernel version: $KERNEL" | tee -a "$LOG"
    exit 1
fi

if secure_boot_enabled; then
    echo "  WARNING: Secure Boot is enabled — unsigned NVIDIA modules may fail to load." | tee -a "$LOG"
fi

HEADERS_PKG="linux-headers-${KERNEL}"
if ! kernel_headers_present "$KERNEL"; then
    echo "  Installing missing headers: $HEADERS_PKG" | tee -a "$LOG"
    if ! apt-get -y -o DPkg::Lock::Timeout=120 install "$HEADERS_PKG" >>"$LOG" 2>&1; then
        echo "  WARNING: Could not install $HEADERS_PKG — trying linux-headers-amd64" | tee -a "$LOG"
        apt-get -y -o DPkg::Lock::Timeout=120 install linux-headers-amd64 >>"$LOG" 2>&1 || true
    fi
fi

if ! kernel_headers_present "$KERNEL"; then
    echo "ERROR: linux headers not available for $KERNEL" | tee -a "$LOG"
    echo "  Install $HEADERS_PKG when it appears in your repos, then re-run." | tee -a "$LOG"
    exit 1
fi

echo "  Headers present: /usr/src/linux-headers-${KERNEL}" | tee -a "$LOG"

echo "  Running: dkms autoinstall -k $KERNEL" | tee -a "$LOG"

if $DKMS autoinstall -k "$KERNEL" >>"$LOG" 2>&1; then
    echo "  DKMS autoinstall succeeded." | tee -a "$LOG"
else
    echo "  DKMS autoinstall reported issues — checking individual modules..." | tee -a "$LOG"

    FAILED=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        MOD="${line%%/*}"
        REST="${line#*/}"
        VER="${REST%%,*}"
        VER="${VER// /}"
        STATUS="${line##*: }"
        STATUS="${STATUS// /}"

        if [[ "$STATUS" != "installed" ]]; then
            echo "  Rebuilding: $MOD/$VER for $KERNEL" | tee -a "$LOG"
            if $DKMS install -m "$MOD" -v "$VER" -k "$KERNEL" --force >>"$LOG" 2>&1; then
                echo "    OK: $MOD/$VER rebuilt" | tee -a "$LOG"
            else
                echo "    FAILED: $MOD/$VER could not be built" | tee -a "$LOG"
                FAILED=$((FAILED + 1))
            fi
        fi
    done < <($DKMS status -k "$KERNEL" 2>/dev/null)

    if [[ $FAILED -gt 0 ]]; then
        echo "  ERROR: $FAILED module(s) failed to build. See $LOG for details." | tee -a "$LOG"
        exit 1
    fi
fi

if nvidia_dkms_registered; then
    NVIDIA_MOD="$(find_nvidia_module "$KERNEL" || true)"
    if [[ -n "$NVIDIA_MOD" ]]; then
        echo "  ✓ NVIDIA module verified: $NVIDIA_MOD" | tee -a "$LOG"
    else
        echo "  ERROR: NVIDIA DKMS is registered but no nvidia*.ko module was built for $KERNEL." | tee -a "$LOG"
        ls "/lib/modules/${KERNEL}/updates/dkms/" 2>/dev/null | tee -a "$LOG" || true
        exit 1
    fi
fi

echo "  Regenerating initramfs for $KERNEL..." | tee -a "$LOG"
if update-initramfs -u -k "$KERNEL" >>"$LOG" 2>&1; then
    echo "  ✓ initramfs updated." | tee -a "$LOG"
else
    echo "  ERROR: initramfs update failed — check $LOG" | tee -a "$LOG"
    exit 1
fi

echo "  DKMS status for $KERNEL:" | tee -a "$LOG"
$DKMS status -k "$KERNEL" 2>&1 | tee -a "$LOG"

echo "=== Done $(date '+%Y-%m-%d %H:%M:%S') ===" | tee -a "$LOG"
