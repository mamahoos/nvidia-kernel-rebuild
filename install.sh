#!/usr/bin/env bash
# install.sh — Install nvidia-kernel-rebuild and its hooks.
#
# Run as root:  sudo ./install.sh
# To uninstall: sudo ./install.sh --uninstall

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DEST=/usr/local/sbin/nvidia-kernel-rebuild-lib.sh
REBUILD_DEST=/usr/local/sbin/nvidia-kernel-rebuild.sh
HOOK_DEST=/usr/local/sbin/nvidia-dkms-apt-hook
POSTINST_DEST=/etc/kernel/postinst.d/zz-nvidia-kernel-rebuild
APT_HOOK_DEST=/etc/apt/apt.conf.d/99nvidia-dkms-rebuild
LOG=/var/log/nvidia-kernel-rebuild.log

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo $0"
    exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Uninstalling nvidia-kernel-rebuild..."
    rm -f "$LIB_DEST" "$REBUILD_DEST" "$HOOK_DEST" "$POSTINST_DEST" "$APT_HOOK_DEST"
    echo "Done. Log retained at $LOG"
    exit 0
fi

for dep in dkms update-initramfs apt-get; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $dep"
        echo "Install with: apt install dkms initramfs-tools"
        exit 1
    fi
done

if ! /usr/sbin/dkms status 2>/dev/null | grep -qE '^nvidia'; then
    echo "WARNING: no NVIDIA DKMS modules registered yet."
    echo "Install nvidia-kernel-dkms before expecting automatic rebuilds."
fi

echo "Installing nvidia-kernel-rebuild..."

install -m 755 "$SCRIPT_DIR/nvidia-kernel-rebuild-lib.sh" "$LIB_DEST"
install -m 755 "$SCRIPT_DIR/nvidia-kernel-rebuild.sh"       "$REBUILD_DEST"
install -m 755 "$SCRIPT_DIR/nvidia-dkms-apt-hook"           "$HOOK_DEST"
install -m 755 "$SCRIPT_DIR/kernel-postinst-hook"             "$POSTINST_DEST"
install -m 644 "$SCRIPT_DIR/99nvidia-dkms-rebuild"          "$APT_HOOK_DEST"

sed -i "s|^REBUILD=.*|REBUILD=${REBUILD_DEST}|" "$HOOK_DEST"

touch "$LOG"
chmod 644 "$LOG"

echo ""
echo "Installed:"
echo "  $LIB_DEST         — shared helpers"
echo "  $REBUILD_DEST     — main rebuild script"
echo "  $HOOK_DEST        — apt post-invoke hook wrapper"
echo "  $POSTINST_DEST    — kernel post-install hook"
echo "  $APT_HOOK_DEST    — apt config"
echo "  $LOG              — log file"
echo ""
echo "Test run (current kernel):"
echo "  sudo nvidia-kernel-rebuild.sh"
echo ""
echo "Unit tests (no root required):"
echo "  ./tests/run_tests.sh"
