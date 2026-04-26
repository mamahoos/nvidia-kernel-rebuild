#!/usr/bin/env bash
# install.sh — Install nvidia-kernel-rebuild and its apt hook.
#
# Run as root:  sudo ./install.sh
# To uninstall: sudo ./install.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBUILD_DEST=/usr/local/sbin/nvidia-kernel-rebuild.sh
HOOK_DEST=/usr/local/sbin/nvidia-dkms-apt-hook
APT_HOOK_DEST=/etc/apt/apt.conf.d/99nvidia-dkms-rebuild
LOG=/var/log/nvidia-kernel-rebuild.log

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo $0"
    exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Uninstalling nvidia-kernel-rebuild..."
    rm -f "$REBUILD_DEST" "$HOOK_DEST" "$APT_HOOK_DEST"
    echo "Done. Log retained at $LOG"
    exit 0
fi

echo "Installing nvidia-kernel-rebuild..."

install -m 755 "$SCRIPT_DIR/nvidia-kernel-rebuild.sh" "$REBUILD_DEST"
install -m 755 "$SCRIPT_DIR/nvidia-dkms-apt-hook"     "$HOOK_DEST"
install -m 644 "$SCRIPT_DIR/99nvidia-dkms-rebuild"    "$APT_HOOK_DEST"

# Update the REBUILD path inside the hook to point to the installed location
sed -i "s|^REBUILD=.*|REBUILD=${REBUILD_DEST}|" "$HOOK_DEST"

touch "$LOG"
chmod 644 "$LOG"

echo ""
echo "Installed:"
echo "  $REBUILD_DEST     — main rebuild script"
echo "  $HOOK_DEST        — apt post-invoke hook wrapper"
echo "  $APT_HOOK_DEST    — apt config (triggers hook on kernel install)"
echo "  $LOG              — log file"
echo ""
echo "Test run (current kernel):"
echo "  sudo nvidia-kernel-rebuild.sh"
