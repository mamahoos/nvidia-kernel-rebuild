# nvidia-kernel-rebuild

Automatically recompiles NVIDIA (and all other DKMS) kernel modules whenever a new kernel is installed on Debian/Ubuntu systems. Prevents the "black screen after kernel update" problem caused by missing NVIDIA modules.

## Fork Changes (mamahoos)

This fork hardens the upstream project:

- [x] Fail with non-zero exit when NVIDIA module or initramfs update fails
- [x] Detect `nvidia*.ko*` dynamically instead of hardcoding `nvidia-current`
- [x] Defer rebuilds from apt hooks via `systemd-run` to avoid apt re-entrancy
- [x] Filter apt hook to kernel/NVIDIA DKMS package changes
- [x] Skip work when no NVIDIA DKMS modules are registered
- [x] Fail fast when `linux-headers` are unavailable
- [x] Warn when Secure Boot is enabled
- [x] Check required commands during install
- [x] Rebuild only the newest relevant kernel from the apt hook
- [x] Add `/etc/kernel/postinst.d/` trigger for new kernel installs

Upstream: [sternecker/nvidia-kernel-rebuild](https://github.com/sternecker/nvidia-kernel-rebuild)

## How It Works

The system has four components:

```
apt installs kernel or NVIDIA DKMS package
        │
        ├─► /etc/kernel/postinst.d/zz-nvidia-kernel-rebuild
        │
        └─► DPkg::Post-Invoke → nvidia-dkms-apt-hook
                    │
                    ▼
        nvidia-kernel-rebuild.sh (deferred via systemd-run from hooks)
                    │
                    ▼
        /var/log/nvidia-kernel-rebuild.log
```

### Files

| File | Installed To | Purpose |
|------|-------------|---------|
| `nvidia-kernel-rebuild-lib.sh` | `/usr/local/sbin/` | Shared helpers for hooks and rebuild script |
| `nvidia-kernel-rebuild.sh` | `/usr/local/sbin/` | Main rebuild script — installs headers, runs DKMS, regenerates initramfs |
| `nvidia-dkms-apt-hook` | `/usr/local/sbin/` | Apt hook wrapper; filters relevant package changes and schedules rebuilds |
| `kernel-postinst-hook` | `/etc/kernel/postinst.d/zz-nvidia-kernel-rebuild` | Runs after a new kernel image is installed |
| `99nvidia-dkms-rebuild` | `/etc/apt/apt.conf.d/` | Apt config that triggers the hook after package installs |

## Installation

```bash
git clone https://github.com/mamahoos/nvidia-kernel-rebuild.git
cd nvidia-kernel-rebuild
sudo ./install.sh
```

### Uninstall

```bash
sudo ./install.sh --uninstall
```

## Manual Usage

```bash
# Rebuild for the currently running kernel
sudo nvidia-kernel-rebuild.sh

# Rebuild for a specific kernel version
sudo nvidia-kernel-rebuild.sh 6.13.0-amd64
```

## What the Script Does

1. **Checks for root** — exits immediately if not run as root
2. **Installs `linux-headers`** for the target kernel if not already present
3. **Runs `dkms autoinstall`** to rebuild all registered DKMS modules (NVIDIA + any others)
4. **Falls back to per-module rebuild** with `--force` if `autoinstall` reports failures
5. **Verifies** an `nvidia*.ko*` module is present when NVIDIA DKMS is registered
6. **Regenerates initramfs** with `update-initramfs -u -k <kernel>`
7. **Exits non-zero** if NVIDIA module verification or initramfs update fails
8. **Logs everything** to `/var/log/nvidia-kernel-rebuild.log`

## Requirements

- Debian 12+ / Ubuntu 22.04+ (uses `apt-get`, `dkms`, `update-initramfs`)
- NVIDIA driver installed via `nvidia-kernel-dkms` package (not the `.run` installer)
- `dkms` package installed (`apt install dkms`)

Check your DKMS status:

```bash
/usr/sbin/dkms status
```

Expected output (one line per kernel version):

```
nvidia-current/550.163.01, 6.12.74+deb13+1-amd64, x86_64: installed
```

## Troubleshooting

**Check the log:**

```bash
tail -50 /var/log/nvidia-kernel-rebuild.log
```

**Manually trigger for a specific kernel:**

```bash
sudo nvidia-kernel-rebuild.sh $(uname -r)
```

**DKMS module source missing:**

If `/usr/src/nvidia-current-<version>/` is missing, reinstall the DKMS package:

```bash
sudo apt install --reinstall nvidia-kernel-dkms
```

**Headers unavailable for kernel:**

On Debian testing/unstable, headers may lag behind the kernel package by a day or two. The script will attempt to install them; if it fails, wait for the headers package to appear in the repos and re-run manually.

## Tested On

| Distro | Kernel | NVIDIA Driver |
|--------|--------|---------------|
| Debian 13 (trixie) | 6.12.x | 550.163.01 |

## License

MIT
