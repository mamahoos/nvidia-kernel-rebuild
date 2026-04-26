# nvidia-kernel-rebuild

Automatically recompiles NVIDIA (and all other DKMS) kernel modules whenever a new kernel is installed on Debian/Ubuntu systems. Prevents the "black screen after kernel update" problem caused by missing NVIDIA modules.

## How It Works

The system has three components:

```
apt installs new kernel
        │
        ▼
DPkg::Post-Invoke fires
        │
        ▼
nvidia-dkms-apt-hook   ← scans /boot/vmlinuz-* for kernels missing modules
        │
        ▼
nvidia-kernel-rebuild.sh   ← installs headers, runs dkms, regenerates initramfs
        │
        ▼
/var/log/nvidia-kernel-rebuild.log
```

### Files

| File | Installed To | Purpose |
|------|-------------|---------|
| `nvidia-kernel-rebuild.sh` | `/usr/local/sbin/` | Main rebuild script — installs headers, runs DKMS, regenerates initramfs |
| `nvidia-dkms-apt-hook` | `/usr/local/sbin/` | Wrapper called by apt; detects new kernels missing NVIDIA modules |
| `99nvidia-dkms-rebuild` | `/etc/apt/apt.conf.d/` | apt config that triggers the hook after every `apt install/upgrade` |

## Installation

```bash
git clone https://github.com/sternecker/nvidia-kernel-rebuild.git
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
5. **Verifies** the NVIDIA `.ko.xz` module is present in `/lib/modules/<kernel>/updates/dkms/`
6. **Regenerates initramfs** with `update-initramfs -u -k <kernel>`
7. **Logs everything** to `/var/log/nvidia-kernel-rebuild.log`

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
