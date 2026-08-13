#!/usr/bin/env bash
# Build a Ubuntu 26.04 live USB image with SSH enabled on boot.
#
# Usage:
#   sudo ./scripts/build-live-usb-26.04.sh                    # auto-selects desktop if present, else server
#   sudo ./scripts/build-live-usb-26.04.sh server             # force server ISO (cloud-init autoinstall)
#   sudo ./scripts/build-live-usb-26.04.sh desktop            # force desktop ISO (casper live session)
#   sudo ./scripts/build-live-usb-26.04.sh desktop /dev/sdX   # build and write to USB
#
# Desktop ISO: boots to live session, SSH enabled.
#   Login: installer / live  (passwordless sudo)
#   Requires network — installs openssh-server on first boot via cloud-init runcmd.
#
# Server ISO: runs cloud-init autoinstall and installs to disk.
#   Login: ubuntu / live  (passwordless sudo)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="${REPO_ROOT}/logs/build-live-usb-26.04.log"
WORK_DIR="${REPO_ROOT}/work/live-usb-build"
mkdir -p "${REPO_ROOT}/logs"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "============================================================"
echo "build-live-usb-26.04.sh  $(date)"
echo "Log: ${LOG_FILE}"
echo "============================================================"

die() { echo ""; echo "ERROR: $*"; echo "Full log: ${LOG_FILE}"; exit 1; }
trap 'echo "FAILED at line ${LINENO}. Full log: ${LOG_FILE}"' ERR

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
VARIANT="${1:-auto}"
USB_DEV="${2:-}"

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0"

check_cmd() { command -v "$1" &>/dev/null || die "'$1' not found. Install: $2"; }
check_cmd xorriso   "xorriso"
check_cmd openssl   "openssl"
check_cmd unsquashfs "squashfs-tools"
check_cmd mksquashfs "squashfs-tools"

# ---------------------------------------------------------------------------
# Resolve ISO
# ---------------------------------------------------------------------------
SERVER_ISO="${REPO_ROOT}/assets/ubuntu-26.04-live-server-amd64.iso"
DESKTOP_ISO="${REPO_ROOT}/assets/ubuntu-26.04-desktop-amd64.iso"

case "$VARIANT" in
    server)
        ISO_SRC="$SERVER_ISO"
        ISO_LABEL="Ubuntu-26-Live-SSH-Server"
        ISO_TYPE="server"
        ;;
    desktop)
        ISO_SRC="$DESKTOP_ISO"
        ISO_LABEL="Ubuntu-26-Live-SSH-Desktop"
        ISO_TYPE="desktop"
        ;;
    auto)
        if [ -f "$DESKTOP_ISO" ]; then
            ISO_SRC="$DESKTOP_ISO"
            ISO_LABEL="Ubuntu-26-Live-SSH-Desktop"
            ISO_TYPE="desktop"
            echo "Auto-selected: desktop ISO"
        elif [ -f "$SERVER_ISO" ]; then
            ISO_SRC="$SERVER_ISO"
            ISO_LABEL="Ubuntu-26-Live-SSH-Server"
            ISO_TYPE="server"
            echo "Auto-selected: server ISO"
        else
            die "No ISO found. Run: ./scripts/download-ubuntu-26.04.sh desktop"
        fi
        ;;
    *)
        die "Unknown variant '${VARIANT}'. Use: server | desktop | auto"
        ;;
esac

[ -f "$ISO_SRC" ] || die "ISO not found: ${ISO_SRC}
Run: ./scripts/download-ubuntu-26.04.sh ${VARIANT}"

OUTPUT_ISO="${REPO_ROOT}/deploy/ubuntu-26.04-live-ssh-$(basename "$ISO_SRC" .iso | sed 's/ubuntu-26.04-//').iso"

echo "Source ISO:  ${ISO_SRC} ($(du -sh "$ISO_SRC" | cut -f1))"
echo "Output ISO:  ${OUTPUT_ISO}"
echo "ISO type:    ${ISO_TYPE}"

if [ -n "$USB_DEV" ]; then
    [ -b "$USB_DEV" ] || die "${USB_DEV} is not a block device"
    echo "Target USB:  ${USB_DEV}"
    echo "WARNING: All data on ${USB_DEV} will be erased."
    echo "Press Ctrl-C within 5 seconds to abort..."
    sleep 5
fi

# ---------------------------------------------------------------------------
# [1/4] Extract ISO
# ---------------------------------------------------------------------------
echo ""
echo "[1/4] Cleaning work directory and extracting ISO..."
rm -rf "$WORK_DIR"
mkdir -p "${WORK_DIR}/iso-root" "$(dirname "$OUTPUT_ISO")"

xorriso -osirrox on \
    -indev "$ISO_SRC" \
    -extract / "${WORK_DIR}/iso-root" \
    || die "xorriso extract failed — see log above"

chmod -R u+w "${WORK_DIR}/iso-root"
echo "      Extracted OK."

# ---------------------------------------------------------------------------
# [2/4] Inject nocloud seed + patch grub
# ---------------------------------------------------------------------------
echo ""
echo "[2/4] Injecting cloud-init seed and patching grub (type: ${ISO_TYPE})..."

HASHED_PW="$(openssl passwd -6 -salt livesalt live)"

# Both ISO types get a nocloud seed — the difference is what's in user-data.
# For desktop: plain cloud-config (no autoinstall key) — sets password,
#              installs openssh-server, starts SSH.
# For server:  autoinstall cloud-config.
mkdir -p "${WORK_DIR}/iso-root/nocloud"

if [ "$ISO_TYPE" = "desktop" ]; then
    # The live session default user is 'installer' (from cloud.cfg default_user).
    # We set its password and install openssh-server on first boot.
    # openssh-server is NOT in the live squashfs — runcmd installs it.
    # openssh-server is not in the live squashfs but IS in the ISO's /pool.
    # At live boot casper mounts the ISO at /cdrom, so we install from there
    # with dpkg — no network required.
    # Create a separate 'ubuntu' user with bash shell and passwordless sudo.
    # We don't touch 'installer' (its shell is subiquity-shell, not bash).
    # Minimal cloud-config — user is baked into squashfs, just enable pw auth
    cat > "${WORK_DIR}/iso-root/nocloud/user-data" <<'EOF'
#cloud-config
ssh_pwauth: true
EOF
else
    # Server ISO: autoinstall — installs Ubuntu to disk
    cat > "${WORK_DIR}/iso-root/nocloud/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: live-usb
    username: ubuntu
    password: "${HASHED_PW}"
  ssh:
    install-server: true
    allow-pw: true
  storage:
    layout:
      name: direct
  user-data:
    chpasswd:
      list: |
        ubuntu:live
      expire: false
EOF
fi

cat > "${WORK_DIR}/iso-root/nocloud/meta-data" <<'EOF'
instance-id: live-usb
local-hostname: live-usb
EOF

echo "      nocloud seed written."

# For the desktop ISO, modify the live squashfs directly:
#  - add 'ubuntu' user to passwd/shadow/group with password 'live'
#  - enable PasswordAuthentication in sshd_config
#  - install a systemd service that installs openssh-server from the ISO pool
if [ "$ISO_TYPE" = "desktop" ]; then
    echo ""
    echo "      Modifying live squashfs (user + SSH)..."
    LIVE_SQ="${WORK_DIR}/iso-root/casper/minimal.standard.live.squashfs"
    [ -f "$LIVE_SQ" ] || die "minimal.standard.live.squashfs not found"
    SQFS_WORK="${WORK_DIR}/squashfs-live"
    rm -rf "$SQFS_WORK"
    unsquashfs -d "$SQFS_WORK" "$LIVE_SQ" \
        || die "unsquashfs of minimal.standard.live.squashfs failed"

    # Add ubuntu user to passwd (uid 1001 — installer is 1000 in the live session)
    if ! grep -q "^ubuntu:" "${SQFS_WORK}/etc/passwd" 2>/dev/null; then
        echo "ubuntu:x:1001:1001:Ubuntu Live,,,:/home/ubuntu:/bin/bash" \
            >> "${SQFS_WORK}/etc/passwd"
    fi
    # Add ubuntu group
    if ! grep -q "^ubuntu:" "${SQFS_WORK}/etc/group" 2>/dev/null; then
        echo "ubuntu:x:1001:" >> "${SQFS_WORK}/etc/group"
    fi
    # Add ubuntu to sudo group
    sed -i 's/^sudo:x:\(.*\):/sudo:x:\1:ubuntu/' "${SQFS_WORK}/etc/group" \
        || die "sed sudo group failed"
    # Write shadow entry with hashed password
    # Remove any existing ubuntu entry first
    grep -v "^ubuntu:" "${SQFS_WORK}/etc/shadow" > "${SQFS_WORK}/etc/shadow.tmp" 2>/dev/null || true
    echo "ubuntu:${HASHED_PW}:19000:0:99999:7:::" >> "${SQFS_WORK}/etc/shadow.tmp"
    mv "${SQFS_WORK}/etc/shadow.tmp" "${SQFS_WORK}/etc/shadow"
    chmod 640 "${SQFS_WORK}/etc/shadow"
    # Create home directory stub (casper will populate it on boot)
    mkdir -p "${SQFS_WORK}/home/ubuntu"
    chmod 755 "${SQFS_WORK}/home/ubuntu"

    # Enable password auth in sshd_config (sshd not installed yet but config is present)
    if [ -f "${SQFS_WORK}/etc/ssh/sshd_config" ]; then
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
            "${SQFS_WORK}/etc/ssh/sshd_config" \
            || die "sed sshd_config failed"
    fi
    # Write a drop-in that ensures it regardless
    mkdir -p "${SQFS_WORK}/etc/ssh/sshd_config.d"
    echo "PasswordAuthentication yes" > "${SQFS_WORK}/etc/ssh/sshd_config.d/60-live-pw.conf"

    # Systemd service to install openssh-server from /cdrom/pool at boot
    mkdir -p "${SQFS_WORK}/etc/systemd/system/multi-user.target.wants"
    cat > "${SQFS_WORK}/etc/systemd/system/live-enable-ssh.service" <<'SERVICE'
[Unit]
Description=Install and start openssh-server from live ISO pool
After=local-fs.target
ConditionPathExists=!/var/lib/live-ssh-done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'dpkg -i /cdrom/pool/main/o/openssh/openssh-sftp-server_*.deb /cdrom/pool/main/o/openssh/openssh-server_*.deb && systemctl daemon-reload && systemctl start ssh && touch /var/lib/live-ssh-done'

[Install]
WantedBy=multi-user.target
SERVICE

    ln -sf /etc/systemd/system/live-enable-ssh.service \
        "${SQFS_WORK}/etc/systemd/system/multi-user.target.wants/live-enable-ssh.service"

    rm -f "$LIVE_SQ"
    mksquashfs "$SQFS_WORK" "$LIVE_SQ" -comp xz -noappend \
        || die "mksquashfs repack failed"
    rm -rf "$SQFS_WORK"
    echo "      Squashfs modified OK."
fi

# Patch grub.cfg
GRUB_CFG="${WORK_DIR}/iso-root/boot/grub/grub.cfg"
[ -f "$GRUB_CFG" ] || die "grub.cfg not found in extracted ISO"

if [ "$ISO_TYPE" = "desktop" ]; then
    # Desktop grub.cfg: rewrite to add SSH-enabled entry as first/default.
    # - ds=nocloud: tells cloud-init to use our seed
    # - fsck.mode=skip: prevents casper-md5check from hanging (our nocloud dir
    #   is not in the ISO's md5sum.txt, so the check would fail)
    # - systemd.unit=multi-user.target: skip the desktop greeter; boot to text
    #   so SSH is reachable without a display
    cat > "$GRUB_CFG" <<GRUB
set timeout=5

loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "Ubuntu 26.04 Live (SSH on boot)" {
    set gfxpayload=keep
    linux  /casper/vmlinuz fsck.mode=skip ds=nocloud;s=/cdrom/nocloud/ systemd.unit=multi-user.target ---
    initrd /casper/initrd
}
menuentry "Try or Install Ubuntu (GUI)" {
    set gfxpayload=keep
    linux  /casper/vmlinuz  --- quiet splash
    initrd /casper/initrd
}
menuentry "Ubuntu (safe graphics)" {
    set gfxpayload=keep
    linux  /casper/vmlinuz nomodeset  --- quiet splash
    initrd /casper/initrd
}
grub_platform
if [ "\$grub_platform" = "efi" ]; then
menuentry 'Boot from next volume' {
    exit 1
}
menuentry 'UEFI Firmware Settings' {
    fwsetup
}
fi
GRUB
    echo "      grub.cfg rewritten — SSH entry is default (5s timeout)."
else
    # Server ISO: append ds=nocloud + autoinstall to existing linux lines
    PATCHED=0
    for cfg in \
        "${WORK_DIR}/iso-root/boot/grub/grub.cfg" \
        "${WORK_DIR}/iso-root/boot/grub/loopback.cfg"; do
        if [ -f "$cfg" ]; then
            sed -i 's|\(^\s*linux\s.*\)|\1 fsck.mode=skip ds=nocloud;s=/cdrom/nocloud/ autoinstall|' "$cfg" \
                || die "sed failed on $(basename "$cfg")"
            echo "      Patched: $(basename "$cfg")"
            PATCHED=1
        fi
    done
    [ "$PATCHED" -eq 1 ] || die "No grub.cfg found in extracted server ISO"
fi

# Recompute md5sum.txt for every file we changed (grub.cfg, nocloud/, squashfs).
# We use fsck.mode=skip so this is belt-and-suspenders, but keeps the manifest clean.
if [ -f "${WORK_DIR}/iso-root/md5sum.txt" ]; then
    echo "      Updating md5sum.txt..."
    CHANGED_PATTERNS="nocloud\|grub/grub.cfg\|minimal.standard.live.squashfs"
    grep -v "$CHANGED_PATTERNS" "${WORK_DIR}/iso-root/md5sum.txt" > "${WORK_DIR}/md5sum.tmp" || true
    (cd "${WORK_DIR}/iso-root" && \
        md5sum ./nocloud/user-data ./nocloud/meta-data ./boot/grub/grub.cfg) \
        >> "${WORK_DIR}/md5sum.tmp" \
        || die "md5sum of changed files failed"
    if [ -f "${WORK_DIR}/iso-root/casper/minimal.standard.live.squashfs" ]; then
        (cd "${WORK_DIR}/iso-root" && md5sum ./casper/minimal.standard.live.squashfs) \
            >> "${WORK_DIR}/md5sum.tmp" \
            || die "md5sum of squashfs failed"
    fi
    mv "${WORK_DIR}/md5sum.tmp" "${WORK_DIR}/iso-root/md5sum.txt"
    echo "      md5sum.txt updated."
fi

# ---------------------------------------------------------------------------
# [3/4] Extract boot args from source ISO
# ---------------------------------------------------------------------------
echo ""
echo "[3/4] Reading El Torito boot parameters from source ISO..."

BOOT_ARGS=$(xorriso -indev "$ISO_SRC" -report_el_torito as_mkisofs 2>/dev/null) \
    || die "Could not read El Torito boot args from source ISO"

echo "      Boot args extracted OK."

# ---------------------------------------------------------------------------
# [4/4] Repack ISO
# ---------------------------------------------------------------------------
echo ""
echo "[4/4] Repacking ISO..."

eval xorriso -as mkisofs \
    -r \
    -V "'${ISO_LABEL}'" \
    $BOOT_ARGS \
    -o "'${OUTPUT_ISO}'" \
    "'${WORK_DIR}/iso-root'" \
    || die "xorriso repack failed — see log above"

echo ""
echo "============================================================"
echo "ISO built:   ${OUTPUT_ISO}"
echo "Size:        $(du -sh "$OUTPUT_ISO" | cut -f1)"
echo "============================================================"

# ---------------------------------------------------------------------------
# Write to USB (optional)
# ---------------------------------------------------------------------------
if [ -n "$USB_DEV" ]; then
    echo ""
    echo "Writing to ${USB_DEV}..."
    dd if="$OUTPUT_ISO" of="$USB_DEV" bs=4M status=progress oflag=sync \
        || die "dd to ${USB_DEV} failed"
    sync
    echo "Done. Safe to remove."
fi

echo ""
echo "To write manually:"
echo "  sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress oflag=sync"
echo ""
if [ "$ISO_TYPE" = "desktop" ]; then
    echo "Boot: select 'Ubuntu 26.04 Live (SSH on boot)' at grub menu."
    echo "SSH available once cloud-init finishes (~1-2 min, no network needed)."
    echo "  ssh ubuntu@<device-ip>   password: live   (sudo is passwordless)"
else
    echo "Boot: autoinstall runs and installs Ubuntu to disk, then reboots."
    echo "Remove USB before reboot, then:"
    echo "  ssh ubuntu@<device-ip>   password: live"
fi
echo ""
echo "Full log: ${LOG_FILE}"
