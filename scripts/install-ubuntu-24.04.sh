#!/usr/bin/env bash
# Install Ubuntu 24.04 LTS to a raw disk image using QEMU/KVM + swtpm (TPM 2.0).
# The cloud-init autoinstall mechanism drives an unattended installation.
#
# Usage: ./scripts/install-ubuntu-24.04.sh
#
# Produces:  input/Ubuntu-24.04-x86-64.img
# Preserves: input/tpm-state-24.04/   (TPM state reused by boot script)
#            input/ovmf-nvram-24.04.fd (UEFI NVRAM with boot entries)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${REPO_ROOT}/assets/ubuntu-24.04-live-server-amd64.iso"
OUTPUT_IMG="${REPO_ROOT}/input/Ubuntu-24.04-x86-64.img"
SEED_ISO="${REPO_ROOT}/work/ubuntu-24.04-seed.iso"
TPM_STATE_DIR="${REPO_ROOT}/input/tpm-state-24.04"
NVRAM="${REPO_ROOT}/input/ovmf-nvram-24.04.fd"
TPM_SOCKET="/tmp/tpm-24.04.sock"
IMG_SIZE_GB=12

OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd

# ---------------------------------------------------------------------------
# Prereq checks
# ---------------------------------------------------------------------------
check_cmd() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found. Install: $2"; exit 1; }; }
check_cmd qemu-system-x86_64 "qemu-system-x86"
check_cmd swtpm              "swtpm"
check_cmd genisoimage        "genisoimage"
check_cmd openssl            "openssl"

[ -f "$ISO" ] || {
    echo "ERROR: ISO not found at ${ISO}"
    echo "Run ./scripts/download-ubuntu-24.04.sh first."
    exit 1
}

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/input" "${REPO_ROOT}/work"

# ---------------------------------------------------------------------------
# Build cloud-init seed ISO
# ---------------------------------------------------------------------------
SEED_DIR=$(mktemp -d)
trap 'rm -rf "$SEED_DIR"' EXIT

HASHED_PW="$(openssl passwd -6 -salt mender00 mender)"

cat > "${SEED_DIR}/user-data" <<EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ubuntu-mender
    username: mender
    password: "${HASHED_PW}"
  ssh:
    install-server: true
    allow-pw: true
  storage:
    layout:
      name: direct
  packages:
    - openssh-server
  late-commands:
    - sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /target/etc/ssh/sshd_config
    - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /target/etc/ssh/sshd_config
  user-data:
    disable_root: false
EOF

touch "${SEED_DIR}/meta-data"

echo "Building seed ISO..."
genisoimage \
    -output "$SEED_ISO" \
    -volid cidata \
    -joliet -rock \
    "${SEED_DIR}/user-data" \
    "${SEED_DIR}/meta-data"

# ---------------------------------------------------------------------------
# Disk image
# ---------------------------------------------------------------------------
if [ -f "$OUTPUT_IMG" ]; then
    echo "Existing disk image found — reusing it (delete manually to reinstall from scratch)."
else
    echo "Creating ${IMG_SIZE_GB}G disk image..."
    qemu-img create -f raw "$OUTPUT_IMG" "${IMG_SIZE_GB}G"
fi

# ---------------------------------------------------------------------------
# UEFI NVRAM (writable copy of template)
# ---------------------------------------------------------------------------
cp -f "$OVMF_VARS_TEMPLATE" "$NVRAM"

# ---------------------------------------------------------------------------
# swtpm — auto-initialises state on first run
# ---------------------------------------------------------------------------
rm -rf "$TPM_STATE_DIR"
mkdir -p "$TPM_STATE_DIR"
rm -f "$TPM_SOCKET"

echo "Starting swtpm..."
swtpm socket \
    --tpm2 \
    --tpmstate dir="$TPM_STATE_DIR" \
    --ctrl type=unixio,path="$TPM_SOCKET" \
    --flags startup-clear \
    --daemon \
    --log level=0

sleep 0.5

cleanup() {
    echo "Stopping swtpm..."
    pkill -f "swtpm.*${TPM_SOCKET}" 2>/dev/null || true
    rm -f "$TPM_SOCKET"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# QEMU install
# ---------------------------------------------------------------------------
echo ""
echo "Booting Ubuntu 24.04 installer — this will take 10-20 minutes."
echo "A QEMU window will open. The VM will power off automatically when done."
echo ""

qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -smp 2 \
    -display gtk,zoom-to-fit=on \
    -drive file="${OVMF_CODE}",if=pflash,format=raw,unit=0,readonly=on \
    -drive file="${NVRAM}",if=pflash,format=raw,unit=1 \
    -chardev socket,id=chrtpm,path="${TPM_SOCKET}" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -device virtio-scsi-pci,id=scsi0 \
    -device scsi-hd,drive=hd0,bus=scsi0.0 \
    -drive if=none,id=hd0,file="${OUTPUT_IMG}",format=raw,cache=none \
    -device ide-cd,bus=ide.0,drive=cd0 \
    -drive if=none,id=cd0,file="${ISO}",format=raw,readonly=on \
    -device ide-cd,bus=ide.1,drive=cd1 \
    -drive if=none,id=cd1,file="${SEED_ISO}",format=raw,readonly=on

echo ""
echo "Installation complete."
echo "Output image: ${OUTPUT_IMG}"
echo "TPM state:    ${TPM_STATE_DIR}"
echo "UEFI NVRAM:   ${NVRAM}"
