#!/usr/bin/env bash
# nvidia-kernel-rebuild.sh
#
# Recompiles NVIDIA (and all other DKMS) kernel modules for a given kernel version.
# Safe to run manually after any kernel update, or automatically via the apt hook.
#
# Usage:
#   sudo ./nvidia-kernel-rebuild.sh              # rebuild for currently running kernel
#   sudo ./nvidia-kernel-rebuild.sh <version>    # rebuild for a specific kernel version
#
# The companion apt hook (/etc/apt/apt.conf.d/99nvidia-dkms-rebuild) calls this
# automatically after any linux-image or linux-headers package is installed.

set -euo pipefail

# ── Path fixup (dkms lives in /usr/sbin, not always in PATH) ─────────────────
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DKMS=/usr/sbin/dkms
LOG=/var/log/nvidia-kernel-rebuild.log

# ── Determine target kernel ───────────────────────────────────────────────────
KERNEL="${1:-$(uname -r)}"
ARCH="$(uname -m)"

echo "=== nvidia-kernel-rebuild  $(date '+%Y-%m-%d %H:%M:%S') ===" | tee -a "$LOG"
echo "  Kernel : $KERNEL" | tee -a "$LOG"
echo "  Arch   : $ARCH"   | tee -a "$LOG"

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root (use sudo)" | tee -a "$LOG"
    exit 1
fi

# ── Ensure linux-headers are installed for this kernel ───────────────────────
HEADERS_PKG="linux-headers-${KERNEL}"
if [[ ! -d "/usr/src/linux-headers-${KERNEL}" ]]; then
    echo "  Installing missing headers: $HEADERS_PKG" | tee -a "$LOG"
    if ! apt-get install -y "$HEADERS_PKG" >> "$LOG" 2>&1; then
        echo "  WARNING: Could not install $HEADERS_PKG — trying linux-headers-amd64 meta-package" | tee -a "$LOG"
        apt-get install -y linux-headers-amd64 >> "$LOG" 2>&1 || true
    fi
else
    echo "  Headers already present: /usr/src/linux-headers-${KERNEL}" | tee -a "$LOG"
fi

# ── Run DKMS for all registered modules ───────────────────────────────────────
echo "  Running: dkms autoinstall -k $KERNEL" | tee -a "$LOG"

if $DKMS autoinstall -k "$KERNEL" >> "$LOG" 2>&1; then
    echo "  DKMS autoinstall succeeded." | tee -a "$LOG"
else
    echo "  DKMS autoinstall reported issues — checking individual modules..." | tee -a "$LOG"

    # Attempt per-module rebuild for any that failed
    FAILED=0
    while IFS= read -r line; do
        # Parse "module/version, kernel, arch: STATUS"
        MOD=$(echo "$line" | awk -F'[/,]' '{print $1}')
        VER=$(echo "$line" | awk -F'[/,]' '{print $2}' | xargs)
        STATUS=$(echo "$line" | awk -F': ' '{print $NF}' | xargs)

        if [[ "$STATUS" != "installed" ]]; then
            echo "  Rebuilding: $MOD/$VER for $KERNEL" | tee -a "$LOG"
            if $DKMS install -m "$MOD" -v "$VER" -k "$KERNEL" --force >> "$LOG" 2>&1; then
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

# ── Verify NVIDIA modules are present for this kernel ────────────────────────
NVIDIA_MOD="/lib/modules/${KERNEL}/updates/dkms/nvidia-current.ko.xz"
if [[ -f "$NVIDIA_MOD" ]]; then
    echo "  ✓ NVIDIA module verified: $NVIDIA_MOD" | tee -a "$LOG"
else
    # Try uncompressed
    NVIDIA_MOD_UNZ="/lib/modules/${KERNEL}/updates/dkms/nvidia-current.ko"
    if [[ -f "$NVIDIA_MOD_UNZ" ]]; then
        echo "  ✓ NVIDIA module verified: $NVIDIA_MOD_UNZ" | tee -a "$LOG"
    else
        echo "  WARNING: NVIDIA module not found at expected path after rebuild." | tee -a "$LOG"
        echo "    Expected: $NVIDIA_MOD" | tee -a "$LOG"
        # Show what's actually there
        ls "/lib/modules/${KERNEL}/updates/dkms/" 2>/dev/null | tee -a "$LOG" || true
    fi
fi

# ── Regenerate initramfs ──────────────────────────────────────────────────────
echo "  Regenerating initramfs for $KERNEL..." | tee -a "$LOG"
if update-initramfs -u -k "$KERNEL" >> "$LOG" 2>&1; then
    echo "  ✓ initramfs updated." | tee -a "$LOG"
else
    echo "  WARNING: initramfs update failed — check $LOG" | tee -a "$LOG"
fi

# ── Final DKMS status ─────────────────────────────────────────────────────────
echo "  DKMS status for $KERNEL:" | tee -a "$LOG"
$DKMS status -k "$KERNEL" 2>&1 | tee -a "$LOG"

echo "=== Done $(date '+%Y-%m-%d %H:%M:%S') ===" | tee -a "$LOG"
