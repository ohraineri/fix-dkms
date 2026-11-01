# dkms-fix

A bash script I wrote after my NVIDIA driver broke for the third time after an `apt upgrade`.

My setup is Debian 13 with an RTX 4060 (`nvidia-current` 550 through DKMS) and `v4l2loopback` so I can use my phone as a webcam. Every now and then a new kernel would land, I'd reboot, and GDM would come up with a black screen or fall back to software rendering. The fix was always some mix of installing headers, running `dkms autoinstall`, poking at `modprobe` and restarting GDM. I got tired of doing it by hand.

In my case the real cause was pretty dumb: `linux-headers-amd64` wasn't installed, so new kernels showed up without headers and DKMS had nothing to build against. The script fixes that, plus the other stuff I ran into along the way.

## What it does

Run it with no arguments and it goes through everything:

- finishes any half-configured dpkg/apt state
- installs missing headers for every installed kernel, not only the running one, plus the gcc version that kernel was built with
- installs `linux-headers-<flavor>` if it's missing and marks it manual so `apt autoremove` leaves it alone
- builds every DKMS module that isn't installed for a kernel. If a build fails it cleans up, tries once more and shows the useful part of `make.log`
- removes leftovers from kernels you already removed (`rc` packages, old `/lib/modules/<version>` dirs, DKMS builds for kernels that are gone)
- checks Secure Boot and whether the DKMS signing key is enrolled in MOK, and offers to enroll it if not
- regenerates the initramfs for the kernels it rebuilt
- loads the modules into the running kernel and runs `nvidia-smi` to make sure the driver really works
- prints a table with every kernel and the state of each module

It only offers to restart the display manager when that makes sense (the driver wasn't loaded when your session started, or the DM is down). It asks first, because restarting it kills your graphical session.

Nothing in it is NVIDIA-specific. It works from whatever is registered in `/var/lib/dkms`, so VirtualBox, ZFS, Wi-Fi drivers and so on get the same treatment.

## Usage

```sh
git clone https://github.com/ohraineri/dkms-fix.git
cd dkms-fix
./fix-dkms.sh --check
```

`--check` is read-only and doesn't need root. It tells you what's wrong and exits with 1 if it finds anything. To actually fix things:

```sh
sudo ./fix-dkms.sh
```

If you forget `sudo` it asks for it.

This is what `--check` showed on my machine before fixing (trimmed a bit):

```
==> Summary
    KERNEL                 FLAGS  HEADERS      nvidia-current  v4l2loopback
    6.12.85+deb13-amd64    -      ok           installed       installed
    6.12.107+deb13-amd64   -      ok           installed       installed
    6.12.111+deb13-amd64   -      missing      missing         missing
    6.12.113+deb13-amd64   RN     ok           installed       installed
```

`R` is the running kernel and `N` is the newest one, which GRUB boots by default. If the `N` row is red, your next reboot is going to hurt.

### Options

```
-n, --check          diagnose only, change nothing
-c, --current        only the running kernel
-k, --kernel VER     only this kernel (can be repeated)
-f, --force          rebuild even if already installed
-y, --yes            don't ask, assume yes
-q, --quiet          only print problems
    --no-update      skip apt-get update
    --prune          remove old kernels, keep the newest 3 plus the running one
    --keep N         change that 3
    --purge-orphans  delete DKMS source dirs in /usr/src that aren't registered
    --restart-dm     restart GDM/SDDM/whatever at the end without asking
    --no-restart-dm  never touch it
```

`--help` has everything.

## Catching it before you reboot

This was the part I wanted most.

```sh
sudo ./fix-dkms.sh --install-hook
```

This copies the script to `/usr/local/sbin/fix-dkms` and adds an APT hook (`/etc/apt/apt.conf.d/99fix-dkms`) that runs `fix-dkms --check --quiet` after every install or upgrade. If a kernel came in without its modules, you get this at the end of `apt upgrade`:

```
fix-dkms: 6.12.111+deb13-amd64: kernel headers missing, DKMS modules cannot be built (fix: apt-get install linux-headers-6.12.111+deb13-amd64)
fix-dkms: 1 problem(s) found, repair with: sudo fix-dkms
```

It never makes apt fail, it only complains. When everything is fine it stays quiet.

To remove it:

```sh
sudo fix-dkms --remove-hook
```

## Logs

Every repair run gets its own log in `/var/log/fix-dkms/`. Logs older than 30 days are deleted automatically.

## Notes

- Written for Debian 13 (trixie). It only depends on apt, dpkg and dkms 3.x, so Debian 12 and Ubuntu will probably work, but I haven't tried them.
- `--prune` and `--purge-orphans` delete stuff. Both show what they're about to remove and ask first, unless you pass `-y`.
- It doesn't call `dkms status`, because on my machine that takes about 10 seconds per call. It reads `/var/lib/dkms` directly instead. Same information, a lot faster.
- If the loaded NVIDIA module is older than the one on disk (the driver got upgraded under you), it tells you to reboot instead of restarting GDM. Restarting GDM won't unload the old module.

Exit codes: `0` everything is fine, `1` something is still broken, `2` bad arguments.
