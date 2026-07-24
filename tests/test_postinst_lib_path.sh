#!/usr/bin/env bash
# Regression test: the kernel postinst hook is installed to a different
# directory than the shared lib. It must source the lib from the absolute
# install path (rewritten by install.sh), not from its own directory.
#
# Reproduces the bug where the hook ran from /etc/kernel/postinst.d/ and tried
# to source /etc/kernel/postinst.d/nvidia-kernel-rebuild-lib.sh (missing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Simulated install layout:
#   FAKE_SBIN          -> /usr/local/sbin   (lib, rebuild, apt hook)
#   FAKE_POSTINST_DIR  -> /etc/kernel/postinst.d  (postinst hook, separate dir!)
FAKE_SBIN="${TMP_ROOT}/usr-local-sbin"
FAKE_POSTINST_DIR="${TMP_ROOT}/etc-kernel-postinst.d"
FAKE_LIB="${FAKE_SBIN}/nvidia-kernel-rebuild-lib.sh"
FAKE_REBUILD="${FAKE_SBIN}/nvidia-kernel-rebuild.sh"
FAKE_POSTINST="${FAKE_POSTINST_DIR}/zz-nvidia-kernel-rebuild"
FAKE_LOG="${TMP_ROOT}/nvidia-kernel-rebuild.log"
mkdir -p "$FAKE_SBIN" "$FAKE_POSTINST_DIR"

# Fake rebuild that succeeds (exit 0).
cat > "$FAKE_REBUILD" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_REBUILD"

# Install the real lib and postinst hook into the simulated layout.
cp "${REPO_ROOT}/nvidia-kernel-rebuild-lib.sh" "$FAKE_LIB"
cp "${REPO_ROOT}/kernel-postinst-hook"        "$FAKE_POSTINST"
chmod +x "$FAKE_POSTINST"

# Apply the same sed rewrites install.sh performs.
sed -i "s|^LIB=.*|LIB=${FAKE_LIB}|" "$FAKE_POSTINST"
sed -i "s|^REBUILD=.*|REBUILD=${FAKE_REBUILD}|" "$FAKE_POSTINST"
sed -i "s|^LOG=.*|LOG=${FAKE_LOG}|" "$FAKE_LIB"

# Stub out environment probes so the hook reaches schedule_rebuild.
# Pretend NVIDIA DKMS is registered and a recent kernel change happened.
OVERRIDE_LIB="${TMP_ROOT}/override.sh"
cat > "$OVERRIDE_LIB" <<'EOF'
nvidia_dkms_registered() { return 0; }
# Force the synchronous path (no systemd-run) so we exercise defer_rebuild.
defer_rebuild() { "$@"; }
EOF

# Inject the override right after the lib is sourced in the postinst hook.
inject_after_source() {
    local file="$1"
    local marker='source "$LIB"'
    # shellcheck disable=SC2016
    local inject='source "'"${OVERRIDE_LIB}"'"'
    local tmp="${file}.tmp"
    awk -v inject="$inject" -v marker="$marker" '
        $0 == marker { print; print inject; next }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    chmod +x "$file"
}
inject_after_source "$FAKE_POSTINST"

# Stub systemd-run so the synchronous path is taken.
mkdir -p "${TMP_ROOT}/bin"
cat > "${TMP_ROOT}/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "systemd-run should not be called in this test" >&2
exit 99
EOF
chmod +x "${TMP_ROOT}/bin/systemd-run"

export PATH="${TMP_ROOT}/bin:${FAKE_SBIN}:/usr/bin:/bin"

PASS=0
FAIL=0
expect_rc() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1)); echo "PASS: $description (exit $actual)"
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $description — expected exit $expected, got $actual"
    fi
}

# The hook must NOT fail with "No such file or directory" for the lib.
# With the bug, it exits 1 (source fails under set -e). With the fix, exit 0.
rc=0
"$FAKE_POSTINST" "6.12.95+deb13-amd64" || rc=$?
expect_rc "postinst hook sources lib from absolute path (not its own dir)" 0 "$rc"

# Sanity: the hook must not have created a stray lib next to itself.
if [[ -e "${FAKE_POSTINST_DIR}/nvidia-kernel-rebuild-lib.sh" ]]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: a stray lib file appeared next to the postinst hook"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
