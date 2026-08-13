# livecopy — requirements

This file is the source of truth for what the Alpine live USB must do.
Before changing `build-live-usb-alpine.sh`, check every item here is still met.

## Must boot

- Boots on Intel x86_64 hardware (tested: Gigabyte board, Intel I210 NIC)
- Boots on other common hardware — broad NIC driver list loaded at kernel cmdline
- Boots entirely from RAM (tmpfs) — nothing written to the target machine's disk

## Must have network

- DHCP on all wired ethernet interfaces, automatically at boot
- IP address displayed in the login banner (motd) once assigned
- Hostname is `livecopy`

## Must have SSH

- `sshd` running and reachable on port 22 within ~30 seconds of boot
- Password login: username `alpine`, password `live`
- Key login: build machine's `~/.ssh/*.pub` injected into `authorized_keys` — `ssh alpine@<ip>` with no password prompt
- **`apk add openssh` does NOT install `/etc/init.d/sshd`.** The init script is in `openssh-server-common-openrc`. Both must be installed.
- **sshd is started directly via `/usr/sbin/sshd` at the end of `local.d/10-setup.start`**, not by OpenRC. OpenRC cannot reliably start sshd mid-runlevel from a local.d script.
- **`ssh-keygen -A` must be run in local.d before `/usr/sbin/sshd`** — the live tmpfs has no persistent host keys.
- **Do NOT put `UsePAM no` in sshd_config.** Alpine's openssh is not compiled with PAM. It rejects the option and refuses to start.
- The `sshd` runlevel symlink is kept so `rc-service sshd status` works after boot, but sshd is already running by the time OpenRC tries it.

## Must have root access

- `doas sh` from the `alpine` user — passwordless, no password required
- `doas` itself must be installed — it ships in the ISO's signed main repo, but is NOT installed by default; must be added to the `apk add --repository` line alongside openssh.

## Must have these tools (all offline, no network after boot)

| Tool          | Purpose                                  | How it gets there                                            |
|---------------|-------------------------------------------|---------------------------------------------------------------|
| `dd`          | Raw image writing                        | busybox — in base Alpine                                      |
| `lsblk`       | List block devices                       | util-linux — fetched (with full dep closure) via docker/apk    |
| `lspci`       | Identify NIC and storage controllers     | pciutils — fetched (with full dep closure) via docker/apk      |
| `fdisk`       | Partition inspection                     | busybox — in base Alpine                                      |
| `sfdisk`      | Scriptable partition manipulation        | util-linux — fetched (with full dep closure) via docker/apk    |
| `python3`     | Runs bmaptool                            | fetched (with full dep closure) via docker/apk                 |
| `zstd`        | bmaptool shells out to it for .zst images | fetched (with full dep closure) via docker/apk                |
| `bmaptool`    | Sparse/bmap-aware image writing          | script+modules bundled from build host; needs python3 above    |
| `ssh`/`scp`   | Pull images from a remote host           | openssh — installed from signed ISO repo                       |
| `e2fsck`      | Check ext2/3/4 filesystems after flashing | e2fsprogs — fetched (with full dep closure) via docker/apk     |
| `fsck.vfat`   | Check the boot/ESP partition after flashing | dosfstools — fetched (with full dep closure) via docker/apk |

## Must survive reboot without silent failures

These are boot-time failure modes that all passed the build-time "verify against
requirements" static checks (the apkovl had the right files/lines) but still
failed at runtime — the static checks were checking the wrong thing. Each one
now has its own static check AND should be caught by `ed-test-live-usb-alpine.sh`
actually booting the ISO and invoking every tool, not just checking `command -v`.

- **Hand-picked package lists silently miss transitive deps.** `apk add` refuses
  to install *any* package in a batch if *any* dependency can't be resolved —
  it doesn't partially install. Resolve the full closure with
  `apk fetch --recursive` (via a throwaway `alpine:$ALPINE_VERSION` docker
  container) instead of hand-listing `.apk` filenames.
- **`apk add <local files>` on a diskless/overlay root needs `--force-non-repository`.**
  Without it: `ERROR: You tried to add a non-repository package to system,
  but it would be lost on next reboot.` — even though "lost on next reboot" is
  exactly what we want on a live tmpfs system.
- **A package bundled from the build host must be unpacked to the LIVE BOX's
  own paths, not the build host's.** The build host is Ubuntu
  (`/usr/lib/python3/dist-packages/`); Alpine's python3 looks in
  `/usr/lib/python3.<X>/site-packages/`. Resolve the live box's real
  site-packages dir at boot time with `python3 -c 'import site; ...'` — do not
  hardcode a path, since the python3.X version can drift between builds.
- **`/dev/null` (and `/dev/zero`, `/dev/random`, etc.) are created at `0660
  root:root`, not the permissive `0666` that `mdev.conf` declares.** The
  `mdev.conf` rule only re-applies on device (re)creation, not to nodes that
  already exist by the time `local.d` runs — so a non-root user (`alpine`)
  can't write to `/dev/null` at all (every `>/dev/null` redirect fails) unless
  `local.d` explicitly `chmod 666`s them.
- **Any `apk add` failure in `local.d` must not be allowed to abort the whole
  script (no bare `|| exit 1`) if sshd startup depends on later lines in the
  same script.** sshd/ssh-keygen binaries already ship on the ISO regardless
  of whether the openssh package install succeeds — an early failure must
  `echo ... >&2` a warning and continue, not `die`.

## Must not

- Write anything to the target machine's disk
- Require network access after the USB is written
- Change the ISO volume label from `alpine-std 3.24.1 x86_64` (the initramfs finds boot media by this label — changing it causes `/sbin/init not found`)
