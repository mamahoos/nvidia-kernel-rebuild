#!/usr/bin/env bash
# End-to-end test: hook exit codes propagate synchronous rebuild failures.
# Regression test for the `|| exit 0` bug that masked rebuild failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Fake /usr/local/sbin layout
FAKE_SBIN="${TMP_ROOT}/sbin"
FAKE_LIB="${FAKE_SBIN}/nvidia-kernel-rebuild-lib.sh"
FAKE_REBUILD="${FAKE_SBIN}/nvidia-kernel-rebuild.sh"
FAKE_APT_HOOK="${FAKE_SBIN}/nvidia-dkms-apt-hook"
FAKE_POSTINST_HOOK="${FAKE_SBIN}/kernel-postinst-hook"
FAKE_LOG="${TMP_ROOT}/nvidia-kernel-rebuild.log"
mkdir -p "$FAKE_SBIN"

# Build a fake rebuild script that fails synchronously with a distinct code.
cat > "$FAKE_REBUILD" <<'EOF'
#!/usr/bin/env bash
echo "fake rebuild: failing on purpose" >&2
exit 7
EOF
chmod +x "$FAKE_REBUILD"

# Install the real lib and hooks, but rewrite paths so they run under the sandbox.
cp "${REPO_ROOT}/nvidia-kernel-rebuild-lib.sh" "$FAKE_LIB"
cp "${REPO_ROOT}/nvidia-dkms-apt-hook"        "$FAKE_APT_HOOK"
cp "${REPO_ROOT}/kernel-postinst-hook"        "$FAKE_POSTINST_HOOK"
chmod +x "$FAKE_APT_HOOK" "$FAKE_POSTINST_HOOK"

# Point the hooks at the fake rebuild and log.
sed -i "s|^REBUILD=.*|REBUILD=${FAKE_REBUILD}|" "$FAKE_APT_HOOK" "$FAKE_POSTINST_HOOK"

# Pretend NVIDIA DKMS is registered and force the synchronous path (no systemd-run).
OVERRIDE_LIB="${TMP_ROOT}/override.sh"
cat > "$OVERRIDE_LIB" <<'EOF'
nvidia_dkms_registered() { return 0; }
apt_recent_nvidia_driver_change() { return 0; }
apt_recent_kernel_change() { return 0; }
get_newest_installed_kernel() { printf '6.12.0-amd64\n'; }
get_newest_kernel_missing_nvidia() { printf '6.12.0-amd64\n'; }
nvidia_module_exists() { return 1; }
defer_rebuild() { "$@"; }
EOF

# Source the override after the lib in each hook by injecting a line.
# The apt hook sources via SCRIPT_DIR; the postinst hook sources via $LIB
# (it lives in a different directory than the lib). Match each marker.
inject_override() {
    local file="$1"
    local marker="$2"
    # shellcheck disable=SC2016
    local inject='source "'"${OVERRIDE_LIB}"'"'
    local tmp="${file}.tmp"
    awk -v inject="$inject" -v marker="$marker" '
        $0 == marker { print; print inject; next }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    chmod +x "$file"
}
inject_override "$FAKE_APT_HOOK"      'source "${SCRIPT_DIR}/nvidia-kernel-rebuild-lib.sh"'
inject_override "$FAKE_POSTINST_HOOK" 'source "$LIB"'

# Point the postinst hook's LIB at the sandbox lib (install.sh does this via sed).
sed -i "s|^LIB=.*|LIB=${FAKE_LIB}|" "$FAKE_POSTINST_HOOK"

# Also redirect the lib's LOG to the sandbox log.
sed -i "s|^LOG=.*|LOG=${FAKE_LOG}|" "$FAKE_LIB"
sed -i "1a LOG=${FAKE_LOG}" "$OVERRIDE_LIB"

# Stub systemd-run so the synchronous path is taken.
mkdir -p "${TMP_ROOT}/bin"
cat > "${TMP_ROOT}/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "systemd-run should not be called in sync-path test" >&2
exit 99
EOF
chmod +x "${TMP_ROOT}/bin/systemd-run"

export PATH="${TMP_ROOT}/bin:${FAKE_SBIN}:/usr/bin:/bin"

run_hook() {
    local hook="$1"
    shift
    set +e
    "$hook" "$@"
    local rc=$?
    set -e
    return $rc
}

PASS=0
FAIL=0

expect_rc() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo "PASS: $description (exit $actual)"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $description — expected exit $expected, got $actual"
    fi
}

# --- apt hook: sync rebuild failure should propagate ---
rc=0
run_hook "$FAKE_APT_HOOK" || rc=$?
expect_rc "apt-hook propagates sync rebuild failure" 7 "$rc"

# --- postinst hook: sync rebuild failure should propagate ---
rc=0
run_hook "$FAKE_POSTINST_HOOK" "6.12.0-amd64" || rc=$?
expect_rc "postinst-hook propagates sync rebuild failure" 7 "$rc"

# --- postinst hook: missing kernel argument exits 0 ---
rc=0
run_hook "$FAKE_POSTINST_HOOK" "" || rc=$?
expect_rc "postinst-hook with no kernel exits 0" 0 "$rc"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
