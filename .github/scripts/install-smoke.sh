#!/usr/bin/env bash
# .github/scripts/install-smoke.sh
#
# Integration smoke test: run install.sh end-to-end in a sandboxed root
# environment, then exercise the installed hooks. Reproduces the layout that
# caused the postinst-lib-path bug (hook in /etc/kernel/postinst.d/, lib in
# /usr/local/sbin/) at the integration level.
#
# Runs on an ephemeral GitHub Actions runner as root. It temporarily replaces
# /usr/sbin/dkms and /usr/bin/systemd-run with mocks and restores them on exit.

set -euo pipefail

[[ $EUID -eq 0 ]] || {
  echo "ERROR: must run as root"
  exit 1
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

# --- Backup real binaries we are about to mock, restore on exit -------------
backup_and_mock_dkms() {
  if [[ -e /usr/sbin/dkms ]]; then mv /usr/sbin/dkms /usr/sbin/dkms.real; fi
  cat >/usr/sbin/dkms <<'EOF'
#!/usr/bin/env bash
# Mock dkms: report one nvidia module as installed so nvidia_dkms_registered
# is true and the hooks proceed past their guard.
echo "nvidia-current/550.163.01, 6.12.0-smoke-amd64, x86_64: installed"
EOF
  chmod +x /usr/sbin/dkms
}

backup_and_hide_systemd_run() {
  if [[ -e /usr/bin/systemd-run ]]; then mv /usr/bin/systemd-run /usr/bin/systemd-run.real; fi
  # defer_rebuild falls back to the synchronous path and invokes the rebuild
  # script directly, which we replace with a no-op below.
}

restore() {
  if [[ -e /usr/sbin/dkms.real ]]; then mv /usr/sbin/dkms.real /usr/sbin/dkms; fi
  if [[ -e /usr/bin/systemd-run.real ]]; then mv /usr/bin/systemd-run.real /usr/bin/systemd-run; fi
  "$REPO_ROOT/install.sh" --uninstall >/dev/null 2>&1 || true
}
trap restore EXIT

# --- Install deps that install.sh checks for --------------------------------
apt-get update -qq
apt-get install -y -qq initramfs-tools >/dev/null 2>&1 || true

backup_and_mock_dkms
backup_and_hide_systemd_run

# --- Run install.sh ----------------------------------------------------------
"$REPO_ROOT/install.sh" >/tmp/install.out 2>&1 || {
  cat /tmp/install.out
  fail "install.sh failed"
  exit 1
}

# --- Verify files installed at the expected paths ----------------------------
for f in \
  /usr/local/sbin/nvidia-kernel-rebuild-lib.sh \
  /usr/local/sbin/nvidia-kernel-rebuild.sh \
  /usr/local/sbin/nvidia-dkms-apt-hook \
  /etc/kernel/postinst.d/zz-nvidia-kernel-rebuild \
  /etc/apt/apt.conf.d/99nvidia-dkms-rebuild; do
  if [[ -e "$f" ]]; then pass "installed: $f"; else fail "missing: $f"; fi
done

# --- Verify the postinst hook sources the lib from the absolute path ---------
# (the bug: it used to source ${SCRIPT_DIR}/nvidia-kernel-rebuild-lib.sh,
#  which does not exist in /etc/kernel/postinst.d/.)
grep -q '^LIB=/usr/local/sbin/nvidia-kernel-rebuild-lib.sh$' /etc/kernel/postinst.d/zz-nvidia-kernel-rebuild &&
  pass "postinst hook points LIB at absolute install path" ||
  fail "postinst hook LIB not rewritten to absolute path"

# Replace the rebuild script with a no-op so the synchronous defer path exits 0.
cat >/usr/local/sbin/nvidia-kernel-rebuild.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x /usr/local/sbin/nvidia-kernel-rebuild.sh

set +e
/etc/kernel/postinst.d/zz-nvidia-kernel-rebuild "6.12.0-smoke-amd64"
rc=$?
set -e
[[ $rc -eq 0 ]] &&
  pass "postinst hook exits 0 (lib sourced from absolute path)" ||
  fail "postinst hook exited $rc (lib sourcing broken?)"

# --- Exercise the apt hook too (it must source the lib and schedule) ---------
set +e
/usr/local/sbin/nvidia-dkms-apt-hook
rc=$?
set -e
[[ $rc -eq 0 ]] &&
  pass "apt hook exits 0" ||
  fail "apt hook exited $rc"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
