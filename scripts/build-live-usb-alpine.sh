#!/usr/bin/env bash
# Build an Alpine Linux live USB for imaging drives.
# All tools available offline — no network needed after boot.
# SSH public keys from ~/.ssh/*.pub are injected for passwordless login.
#
# Usage:
#   sudo ./scripts/build-live-usb-alpine.sh
#   sudo ./scripts/build-live-usb-alpine.sh /dev/sdX   # build and write to USB
#
# Login: alpine / live  (use 'doas' for root — passwordless)
# SSH:   ssh alpine@<ip>  (no password — uses your ~/.ssh key)
# Tools: dd, lsblk, lspci, fdisk, sfdisk, bmaptool

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="${REPO_ROOT}/logs/build-live-usb-alpine.log"
WORK_DIR="${REPO_ROOT}/work/alpine-usb"
ASSETS_DIR="${REPO_ROOT}/assets"
mkdir -p "${REPO_ROOT}/logs"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "============================================================"
echo "build-live-usb-alpine.sh  $(date)"
echo "Log: ${LOG_FILE}"
echo "============================================================"

die() { echo ""; echo "ERROR: $*"; echo "Full log: ${LOG_FILE}"; exit 1; }
trap 'echo "FAILED at line ${LINENO}. Full log: ${LOG_FILE}"' ERR

USB_DEV="${1:-}"

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0"

check_cmd() { command -v "$1" &>/dev/null || die "'$1' not found — install: $2"; }
check_cmd curl      "curl"
check_cmd sha256sum "coreutils"
check_cmd xorriso   "xorriso"
check_cmd tar       "tar"
check_cmd docker    "docker.io / docker-ce"

if [ -n "$USB_DEV" ]; then
    [ -b "$USB_DEV" ] || die "${USB_DEV} is not a block device"
    echo "Target USB: ${USB_DEV}"
    echo "WARNING: all data on ${USB_DEV} will be erased."
    echo "Press Ctrl-C within 5 seconds to abort..."
    sleep 5
fi

ALPINE_VERSION="3.24.1"
ALPINE_ISO="alpine-standard-${ALPINE_VERSION}-x86_64.iso"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/${ALPINE_ISO}"
ALPINE_SHA256="f4dd613206676c62949144c8ad75fc64582099f444dd1485bae104a60f51dd26"
ISO_PATH="${ASSETS_DIR}/${ALPINE_ISO}"
OUTPUT_ISO="${REPO_ROOT}/deploy/alpine-live-ssh.iso"

# ---------------------------------------------------------------------------
# [1/5] Download Alpine ISO
# ---------------------------------------------------------------------------
echo ""
echo "[1/6] Checking Alpine ISO..."

mkdir -p "$ASSETS_DIR"

if [ ! -f "$ISO_PATH" ]; then
    echo "      Downloading ${ALPINE_ISO} (~270MB)..."
    curl -fL --progress-bar -o "${ISO_PATH}.tmp" "$ALPINE_URL" \
        || die "Download failed"
    mv "${ISO_PATH}.tmp" "$ISO_PATH"
else
    echo "      Already present: ${ISO_PATH}"
fi

ACTUAL=$(sha256sum "$ISO_PATH" | awk '{print $1}')
[ "$ACTUAL" = "$ALPINE_SHA256" ] \
    || die "Checksum mismatch — delete ${ISO_PATH} and retry"
echo "      Checksum OK."

# ---------------------------------------------------------------------------
# [2/5] Extract ISO and add extra packages to the apk repository
# ---------------------------------------------------------------------------
echo ""
echo "[2/6] Extracting ISO and adding packages..."

ISO_ROOT="${WORK_DIR}/iso-root"
rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT"

xorriso -osirrox on -indev "$ISO_PATH" -extract / "$ISO_ROOT" \
    || die "xorriso extract failed"
chmod -R u+w "$ISO_ROOT"

# The ISO ships /apks/x86_64/ with a .boot_repository marker file.
# Alpine's apk finds this dir automatically and treats it as a local repo.
#
# Packages not in the standard ISO that we need offline:
#   pciutils (lspci), util-linux (lsblk/sfdisk/etc.), python3 (to run bmaptool),
#   zstd (bmaptool shells out to the zstd/unzstd binary for .zst images —
#   it does not decompress zstd in pure Python), e2fsprogs (e2fsck, for
#   checking ext2/3/4 filesystems on a freshly flashed drive), dosfstools
#   (fsck.vfat, for checking the boot/ESP partition)
# We resolve the FULL transitive dependency closure with `apk fetch --recursive`
# inside a throwaway Alpine container (matching ALPINE_VERSION) rather than
# hand-listing packages — a hand-picked list silently misses transitive deps
# (e.g. python3 needs libexpat + libpanelw; mpdecimal needs libgcc + libstdc++)
# and apk then refuses to install anything in that batch at boot.

# Put extra apks in a separate subdir — do NOT touch APKINDEX.tar.gz in the
# main apks dir (it's signed by Alpine; regenerating it breaks signature checks).
# The local.d script installs them directly by path with --allow-untrusted.
EXTRA_DIR="${ISO_ROOT}/apks/extra"
mkdir -p "$EXTRA_DIR"

echo "      Resolving full dependency closure for pciutils, util-linux, python3, zstd, e2fsprogs, dosfstools..."
docker run --rm -v "${EXTRA_DIR}:/out" "alpine:${ALPINE_VERSION}" sh -c '
    apk update -q &&
    apk fetch --no-cache --recursive -o /out pciutils util-linux python3 zstd e2fsprogs dosfstools
' || die "docker apk fetch failed — is docker installed and the daemon running?"
echo "      Fetched $(find "$EXTRA_DIR" -maxdepth 1 -name '*.apk' | wc -l) packages."

# Bundle bmaptool (Python script + modules) from the host — not in Alpine repos.
# We tar it up and extract on the live system just like the extra apks.
echo "      Bundling bmaptool from host..."
BMAP_BUNDLE="${EXTRA_DIR}/bmaptool-bundle.tar.gz"
[ -f /usr/bin/bmaptool ] || die "bmaptool not found on host — install: apt install bmap-tools"
[ -d /usr/lib/python3/dist-packages/bmaptool ] || die "bmaptool Python modules not found on host"
tar -czf "$BMAP_BUNDLE" \
    -C / \
    usr/bin/bmaptool \
    usr/lib/python3/dist-packages/bmaptool \
    || die "Failed to bundle bmaptool"
echo "      bmaptool bundled ($(du -sh "$BMAP_BUNDLE" | cut -f1))."

echo "      Extra packages ready."

# Patch syslinux config to load igb (Intel I210/I217/I219) in the initramfs
# before the real system starts — this ensures the NIC exists when ifupdown-ng runs
SYSLINUX_CFG="${ISO_ROOT}/boot/syslinux/syslinux.cfg"
[ -f "$SYSLINUX_CFG" ] || die "syslinux.cfg not found in extracted ISO"
# Common wired NIC drivers — Intel, Realtek, Broadcom, Mellanox, Marvell, etc.
NIC_MODS="igb,igc,e1000e,e1000,i40e,ice,ixgbe,iavf,r8169,tg3,bnxt_en,bnx2,bnx2x,sky2,skge,mlx5_core,mlx4_en,be2net,alx,atl1c,atlantic,forcedeth,pcnet32,via-rhine,sis900"
sed -i "s/modules=loop,squashfs,sd-mod,usb-storage/modules=loop,squashfs,sd-mod,usb-storage,${NIC_MODS}/" \
    "$SYSLINUX_CFG" || die "sed syslinux.cfg failed"
GRUB_CFG="${ISO_ROOT}/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
    sed -i "s/modules=loop,squashfs,sd-mod,usb-storage/modules=loop,squashfs,sd-mod,usb-storage,${NIC_MODS}/" \
        "$GRUB_CFG" || die "sed grub.cfg failed"
fi
echo "      Kernel cmdline patched with broad NIC driver list."

# Remove 'quiet' from kernel cmdline so boot messages are visible
sed -i 's/ quiet//' "$SYSLINUX_CFG" || true
[ -f "$GRUB_CFG" ] && sed -i 's/ quiet//' "$GRUB_CFG" || true

# ---------------------------------------------------------------------------
# [3/5] Build apkovl overlay
# ---------------------------------------------------------------------------
echo ""
echo "[3/6] Building apkovl overlay..."

OVERLAY="${WORK_DIR}/overlay"
rm -rf "$OVERLAY"
mkdir -p "${OVERLAY}/etc"

# Collect SSH public keys from the invoking user's home (not root's home,
# since this script runs under sudo)
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SSH_KEYS=""
for pubkey in "${REAL_HOME}/.ssh"/*.pub; do
    [ -f "$pubkey" ] || continue
    key=$(cat "$pubkey")
    SSH_KEYS="${SSH_KEYS}${key}"$'\n'
    echo "      Injecting key: ${pubkey}"
done
[ -n "$SSH_KEYS" ] || echo "      WARNING: no ~/.ssh/*.pub found for ${REAL_USER} — password login only"

# Hostname
echo "livecopy" > "${OVERLAY}/etc/hostname"

# Network interfaces — loopback only; real NICs handled by livenet service
mkdir -p "${OVERLAY}/etc/network"
cat > "${OVERLAY}/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF

# Custom OpenRC service that:
# 1. Waits for modloop (/lib/modules) to be mounted
# 2. Loads all common NIC drivers via modprobe
# 3. Runs udhcpc on every ethernet interface it finds
# 4. Writes the assigned IPs to /etc/motd so they show at login
mkdir -p "${OVERLAY}/etc/init.d"
cat > "${OVERLAY}/etc/init.d/livenet" <<'EOF'
#!/sbin/openrc-run

description="livecopy: bring up all ethernet interfaces"
depend() {
    need modloop localmount local
}

start() {
    ebegin "Loading NIC drivers"
    for mod in igb igc e1000e e1000 i40e ice ixgbe iavf \
                r8169 tg3 bnxt_en bnx2 bnx2x sky2 skge \
                mlx5_core mlx4_en be2net alx atl1c atlantic \
                forcedeth pcnet32 via-rhine sis900 \
                smsc911x lan743x dwmac-intel; do
        modprobe -q "$mod" 2>/dev/null || true
    done
    eend 0

    ebegin "Starting DHCP on all ethernet interfaces"
    sleep 3  # give mdev time to create interfaces and link to come up
    for iface in /sys/class/net/*/; do
        name=$(basename "$iface")
        [ "$name" = "lo" ] && continue
        [ -f "${iface}type" ] || continue
        [ "$(cat "${iface}type")" = "1" ] || continue
        ip link set "$name" up 2>/dev/null || continue
        # Wait up to 5s for carrier
        for i in 1 2 3 4 5; do
            carrier=$(cat "${iface}carrier" 2>/dev/null || echo 0)
            [ "$carrier" = "1" ] && break
            sleep 1
        done
        carrier=$(cat "${iface}carrier" 2>/dev/null || echo 0)
        if [ "$carrier" != "1" ]; then
            einfo "  $name: no link, skipping"
            continue
        fi
        einfo "  DHCP on $name (link up)"
        # Run udhcpc in foreground with timeout so we get the IP before returning
        udhcpc -i "$name" -t 5 -T 3 -A 3 -n \
            -s /usr/share/udhcpc/default.script \
            -x hostname:livecopy 2>/dev/null || true
    done
    eend 0

    # Write IPs to /etc/issue — shown BEFORE the login prompt by getty
    {
        echo ""
        echo "  livecopy -- imaging USB"
        echo "  ========================"
        for iface in /sys/class/net/*/; do
            name=$(basename "$iface")
            [ "$name" = "lo" ] && continue
            addr=$(ip -4 addr show "$name" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
            [ -n "$addr" ] && echo "  $name : $addr"
        done
        echo "  ssh: ssh alpine@<ip above>  (or password: live)"
        echo ""
    } > /etc/issue
}
EOF
chmod +x "${OVERLAY}/etc/init.d/livenet"

# Pre-populate authorized_keys in the overlay so it's on the tmpfs at boot,
# before the alpine user is created. The local.d script fixes ownership.
if [ -n "$SSH_KEYS" ]; then
    mkdir -p "${OVERLAY}/home/alpine/.ssh"
    printf '%s' "$SSH_KEYS" > "${OVERLAY}/home/alpine/.ssh/authorized_keys"
    chmod 700 "${OVERLAY}/home/alpine/.ssh"
    chmod 600 "${OVERLAY}/home/alpine/.ssh/authorized_keys"
fi

# local.d script: add user + install extra packages from the local repo
mkdir -p "${OVERLAY}/etc/local.d"
cat > "${OVERLAY}/etc/local.d/10-setup.start" <<SCRIPT
#!/bin/sh

# Create alpine user with password 'live' using busybox adduser
if ! grep -q "^alpine:" /etc/passwd; then
    adduser -D -s /bin/ash -h /home/alpine alpine
    echo "alpine:live" | chpasswd
    addgroup alpine wheel
fi

# mdev.conf declares null/zero/full/random as 0666, but that rule only
# applies on device (re)creation — /dev/null etc. already exist by the time
# this script runs, created earlier at 0660 root:root, so non-root users
# (alpine) can't write to them (e.g. every ">/dev/null" redirect fails).
# Re-apply the permissive mode directly instead of relying on mdev coldplug.
chmod 666 /dev/null /dev/zero /dev/full /dev/random /dev/urandom 2>/dev/null || true

# Fix ownership of pre-seeded authorized_keys (apkovl extracts as root)
if [ -d /home/alpine/.ssh ]; then
    chown -R alpine:alpine /home/alpine/.ssh
    chmod 700 /home/alpine/.ssh
    chmod 600 /home/alpine/.ssh/authorized_keys 2>/dev/null || true
fi

# Find the local apk repo — Alpine mounts the boot media at /media/*/
# and the .boot_repository marker tells apk where to look.
# Use --repository explicitly so this works regardless of /etc/apk/repositories.
# None of this is allowed to be fatal: sshd/ssh-keygen already ship on the ISO,
# so a broken/missing APKINDEX or a media-not-mounted-yet race must not block
# reaching the ssh-keygen/sshd startup at the bottom of this script.
LOCAL_REPO=""
for dir in /media/*/apks/x86_64; do
    [ -d "\$dir" ] && LOCAL_REPO="\$dir" && break
done
if [ -z "\$LOCAL_REPO" ]; then
    echo "WARNING: could not find local apk repo under /media/*/apks/x86_64 — skipping apk add" >&2
else
    echo "Using local repo: \$LOCAL_REPO"
    # Install openssh's OpenRC init script (openssh alone does NOT install /etc/init.d/sshd)
    # and doas (both ship in the ISO's signed main repo already).
    # The sshd/ssh-keygen binaries are already present on the ISO regardless.
    apk add --no-network --repository "\$LOCAL_REPO" openssh openssh-server-common-openrc doas \
        || echo "WARNING: apk add openssh/doas failed — sshd binary already on ISO, continuing" >&2
fi

# Install extra packages (pciutils, util-linux, python3 + deps) from /apks/extra/
# These were downloaded at build time and are unsigned — use --allow-untrusted.
# --force-non-repository is required: apk refuses non-repository packages on a
# diskless/overlay root otherwise ("would be lost on next reboot"), even though
# that's exactly what we want on a live tmpfs system.
EXTRA_DIR=""
for dir in /media/*/apks/extra; do
    [ -d "\$dir" ] && EXTRA_DIR="\$dir" && break
done
if [ -n "\$EXTRA_DIR" ]; then
    apk add --no-network --allow-untrusted --force-non-repository \$EXTRA_DIR/*.apk \
        || echo "WARNING: apk add extra packages failed — continuing without them" >&2
fi

# Extract bmaptool bundle (Python script + modules from the build host).
# The bundle is packed from the build host's own path layout
# (usr/lib/python3/dist-packages/bmaptool — Debian/Ubuntu convention), which is
# NOT on Alpine's python3 sys.path (Alpine uses usr/lib/python3.X/site-packages).
# Extract the bmaptool/ package dir into wherever THIS box's python3 actually
# looks, determined at boot since the exact python3.X version can drift
# between builds.
for f in /media/*/apks/extra/bmaptool-bundle.tar.gz; do
    [ -f "\$f" ] || continue
    TMP_EXTRACT="\$(mktemp -d)"
    tar -xzf "\$f" -C "\$TMP_EXTRACT"
    install -m 755 "\${TMP_EXTRACT}/usr/bin/bmaptool" /usr/bin/bmaptool
    SITE_PACKAGES="\$(python3 -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null)"
    if [ -z "\$SITE_PACKAGES" ]; then
        echo "ERROR: could not determine python3 site-packages dir" >&2
    else
        mkdir -p "\$SITE_PACKAGES"
        cp -r "\${TMP_EXTRACT}/usr/lib/python3/dist-packages/bmaptool" "\${SITE_PACKAGES}/"
    fi
    rm -rf "\$TMP_EXTRACT"
done

# Write sshd_config after openssh installs its defaults.
# No UsePAM — Alpine openssh is not compiled with PAM support, it rejects the option.
cat > /etc/ssh/sshd_config <<'SSHEOF'
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PrintMotd yes
Subsystem sftp /usr/lib/ssh/sftp-server
SSHEOF

# Generate host keys (live tmpfs — none exist until created)
ssh-keygen -A

# Start sshd directly — OpenRC is still running other services at this point
/usr/sbin/sshd
SCRIPT
chmod +x "${OVERLAY}/etc/local.d/10-setup.start"

# doas — passwordless sudo for wheel
cat > "${OVERLAY}/etc/doas.conf" <<'EOF'
permit nopass :wheel
EOF
chmod 400 "${OVERLAY}/etc/doas.conf"

# OpenRC runlevels
# sshd is NOT in the runlevel — it is started by local.d/10-setup.start
# AFTER openssh is installed and host keys are generated.
# OpenRC would try to start sshd before local finishes, which fails with
# "no host keys" and leaves the daemon dead.
mkdir -p \
    "${OVERLAY}/etc/runlevels/boot" \
    "${OVERLAY}/etc/runlevels/default"
ln -sf /etc/init.d/local   "${OVERLAY}/etc/runlevels/default/local"
ln -sf /etc/init.d/livenet "${OVERLAY}/etc/runlevels/default/livenet"
ln -sf /etc/init.d/sshd    "${OVERLAY}/etc/runlevels/default/sshd"

# Pack — must be named <hostname>.apkovl.tar.gz
APKOVL="${WORK_DIR}/livecopy.apkovl.tar.gz"
tar -czf "$APKOVL" -C "$OVERLAY" . \
    || die "tar apkovl failed"
echo "      apkovl: $(du -sh "$APKOVL" | cut -f1)"

# ---------------------------------------------------------------------------
# [4/6] Verify build artefacts against requirements
# ---------------------------------------------------------------------------
echo ""
echo "[4/6] Verifying build against requirements..."

FAIL=0
check_req() {
    local desc="$1" result="$2"
    if [ "$result" = "ok" ]; then
        echo "      OK  $desc"
    else
        echo "      FAIL $desc  ($result)"
        FAIL=1
    fi
}

# apkovl contains required files
APKOVL_LIST=$(tar -tzf "$APKOVL")

grep -q "etc/init.d/livenet"                     <<< "$APKOVL_LIST" \
    && check_req "livenet service present"          ok \
    || check_req "livenet service present"          "missing etc/init.d/livenet"

grep -q "etc/runlevels/default/sshd"              <<< "$APKOVL_LIST" \
    && check_req "sshd in default runlevel"         ok \
    || check_req "sshd in default runlevel"         "missing etc/runlevels/default/sshd"

grep -q "etc/runlevels/default/local"             <<< "$APKOVL_LIST" \
    && check_req "local in default runlevel"        ok \
    || check_req "local in default runlevel"        "missing etc/runlevels/default/local"

grep -q "etc/runlevels/default/livenet"           <<< "$APKOVL_LIST" \
    && check_req "livenet in default runlevel"      ok \
    || check_req "livenet in default runlevel"      "missing etc/runlevels/default/livenet"

grep -q "etc/local.d/10-setup.start"              <<< "$APKOVL_LIST" \
    && check_req "local.d setup script present"     ok \
    || check_req "local.d setup script present"     "missing etc/local.d/10-setup.start"

grep -q "etc/doas.conf"                            <<< "$APKOVL_LIST" \
    && check_req "doas.conf present"                ok \
    || check_req "doas.conf present"                "missing etc/doas.conf"

grep -q "etc/hostname"                             <<< "$APKOVL_LIST" \
    && check_req "hostname set"                     ok \
    || check_req "hostname set"                     "missing etc/hostname"

# authorized_keys
if [ -n "$SSH_KEYS" ]; then
    grep -q "home/alpine/.ssh/authorized_keys"     <<< "$APKOVL_LIST" \
        && check_req "authorized_keys injected"     ok \
        || check_req "authorized_keys injected"     "missing home/alpine/.ssh/authorized_keys"
else
    check_req "authorized_keys (no host keys found — password only)" ok
fi

# apkovl local.d script installs openssh and generates keys
grep -q "openssh-server-common-openrc" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "local.d installs openssh-server-common-openrc (provides /etc/init.d/sshd)" ok \
    || check_req "local.d installs openssh-server-common-openrc (provides /etc/init.d/sshd)" "missing from apk add in local.d"

grep -q "ssh-keygen -A"     "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "local.d generates host keys"      ok \
    || check_req "local.d generates host keys"      "ssh-keygen -A missing from local.d"

grep -q "PasswordAuthentication yes" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "sshd_config enables password auth" ok \
    || check_req "sshd_config enables password auth" "PasswordAuthentication yes missing"

grep -q "AuthorizedKeysFile" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "sshd_config has AuthorizedKeysFile" ok \
    || check_req "sshd_config has AuthorizedKeysFile" "AuthorizedKeysFile missing from sshd_config"

grep -qE "^UsePAM" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "sshd_config does NOT contain UsePAM (Alpine openssh has no PAM)" \
                 "UsePAM present — Alpine openssh rejects this option, sshd will fail to start" \
    || check_req "sshd_config does NOT contain UsePAM (Alpine openssh has no PAM)" ok

grep -q "ssh-keygen -A" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "local.d generates host keys before starting sshd" ok \
    || check_req "local.d generates host keys before starting sshd" "ssh-keygen -A missing"

grep -q "/usr/sbin/sshd" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "local.d starts sshd directly" ok \
    || check_req "local.d starts sshd directly" "/usr/sbin/sshd missing from local.d"

grep -qE "apk add.*\bdoas\b" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "local.d installs doas (required for passwordless root)" ok \
    || check_req "local.d installs doas (required for passwordless root)" "doas missing from apk add in local.d"

grep -q -- "--force-non-repository" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "extra apk install uses --force-non-repository (required on diskless/overlay root)" ok \
    || check_req "extra apk install uses --force-non-repository (required on diskless/overlay root)" "--force-non-repository missing — apk add will fail with 'non-repository package... would be lost on next reboot'"

grep -q "chmod 666 /dev/null" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "local.d fixes /dev/null etc. permissions for non-root user" ok \
    || check_req "local.d fixes /dev/null etc. permissions for non-root user" "missing — alpine user can't write to /dev/null (mdev.conf's 0666 rule doesn't reapply to pre-existing nodes)"

# extra packages bundled
for pkg in pciutils util-linux python3 zstd e2fsprogs dosfstools; do
    ls "${ISO_ROOT}/apks/extra/${pkg}"*.apk &>/dev/null \
        && check_req "${pkg} apk bundled"           ok \
        || check_req "${pkg} apk bundled"           "no ${pkg}*.apk in /apks/extra/"
done

# a hand-picked list previously missed transitive deps (libgcc, libexpat, etc.)
# and silently broke apk add at boot — guard against that regressing by requiring
# a sane minimum package count from the recursive fetch.
EXTRA_APK_COUNT=$(find "${ISO_ROOT}/apks/extra" -maxdepth 1 -name '*.apk' | wc -l)
[ "$EXTRA_APK_COUNT" -ge 30 ] \
    && check_req "extra apk dependency closure looks complete (${EXTRA_APK_COUNT} pkgs)" ok \
    || check_req "extra apk dependency closure looks complete (${EXTRA_APK_COUNT} pkgs)" "only ${EXTRA_APK_COUNT} packages fetched — docker apk fetch may have failed partway"

[ -f "${ISO_ROOT}/apks/extra/bmaptool-bundle.tar.gz" ] \
    && check_req "bmaptool bundle present"          ok \
    || check_req "bmaptool bundle present"          "missing bmaptool-bundle.tar.gz"

# bmaptool's modules must land in THIS box's python3 site-packages, not the
# build host's Debian/Ubuntu dist-packages path — else `import bmaptool` fails
# even though the bmaptool script itself is present and executable.
grep -q "site.getsitepackages" "${OVERLAY}/etc/local.d/10-setup.start" \
    && check_req "bmaptool modules installed to live box's own site-packages" ok \
    || check_req "bmaptool modules installed to live box's own site-packages" "local.d still hardcodes the build host's dist-packages path"

# livenet writes /etc/issue (shown before login prompt)
grep -q "/etc/issue"  "${OVERLAY}/etc/init.d/livenet" \
    && check_req "livenet writes /etc/issue (IP before login)" ok \
    || check_req "livenet writes /etc/issue (IP before login)" "livenet does not write /etc/issue"

# NIC drivers in syslinux cmdline
grep -q "igb" "$SYSLINUX_CFG" \
    && check_req "NIC drivers in syslinux cmdline"  ok \
    || check_req "NIC drivers in syslinux cmdline"  "igb not found in syslinux.cfg"

[ "$FAIL" -eq 0 ] || die "Requirements check failed — see FAIL lines above"
echo "      All checks passed."

# ---------------------------------------------------------------------------
# [5/6] Inject apkovl into ISO root
# ---------------------------------------------------------------------------
echo ""
echo "[5/6] Injecting apkovl..."

cp "$APKOVL" "${ISO_ROOT}/livecopy.apkovl.tar.gz"
echo "      Done."

# ---------------------------------------------------------------------------
# [6/6] Repack ISO
# ---------------------------------------------------------------------------
echo ""
echo "[6/6] Repacking ISO..."

mkdir -p "${REPO_ROOT}/deploy"

BOOT_ARGS=$(xorriso -indev "$ISO_PATH" -report_el_torito as_mkisofs 2>/dev/null) \
    || die "Could not read El Torito boot args"

eval xorriso -as mkisofs \
    -r \
    -V "'alpine-std 3.24.1 x86_64'" \
    $BOOT_ARGS \
    -o "'${OUTPUT_ISO}'" \
    "'${ISO_ROOT}'" \
    || die "xorriso repack failed"

echo ""
echo "============================================================"
echo "ISO built:  ${OUTPUT_ISO}"
echo "Size:       $(du -sh "$OUTPUT_ISO" | cut -f1)"
echo "============================================================"

if [ -n "$USB_DEV" ]; then
    echo ""
    echo "Writing to ${USB_DEV}..."
    for part in "${USB_DEV}"[0-9]*; do
        [ -b "$part" ] && umount "$part" 2>/dev/null || true
    done
    dd if="$OUTPUT_ISO" of="$USB_DEV" bs=4M status=progress oflag=sync \
        || die "dd failed"
    sync
    echo "Done."
fi

echo ""
echo "To write to USB:  bmap ${OUTPUT_ISO}"
echo ""
echo "Login: alpine / live  (or ssh alpine@<ip> with your key — no password)"
echo "Root:  doas sh   (passwordless)"
echo "Tools: dd  lsblk  lspci  fdisk  sfdisk  bmaptool"
echo ""
echo "Full log: ${LOG_FILE}"
