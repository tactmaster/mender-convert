#!/usr/bin/env bash
# Boot the mender-converted Ubuntu 26.04 image with QEMU/KVM + swtpm (TPM 2.0).
# Reuses the TPM state and UEFI NVRAM produced by install-ubuntu-26.04.sh so
# the TPM identity is consistent between install and runtime.
#
# Usage: ./scripts/boot-ubuntu-26.04-mender.sh
#
# SSH access: ssh mender@localhost -p 8822

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPM_STATE_DIR="${REPO_ROOT}/input/tpm-state-26.04"
NVRAM_TEMPLATE="${REPO_ROOT}/input/ovmf-nvram-26.04.fd"
NVRAM="/tmp/ovmf-nvram-26.04-mender-boot.fd"
TPM_SOCKET="/tmp/tpm-26.04-mender-boot.sock"
SSH_PORT="${SSH_PORT:-8822}"

OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd

# ---------------------------------------------------------------------------
# Prereq checks
# ---------------------------------------------------------------------------
check_cmd() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found. Install: $2"; exit 1; }; }
check_cmd qemu-system-x86_64 "qemu-system-x86"
check_cmd swtpm              "swtpm"

[ -d "$TPM_STATE_DIR" ] || {
    echo "ERROR: TPM state dir not found: ${TPM_STATE_DIR}"
    echo "Run scripts/install-ubuntu-26.04.sh first."
    exit 1
}
[ -f "$NVRAM_TEMPLATE" ] || {
    echo "ERROR: UEFI NVRAM not found: ${NVRAM_TEMPLATE}"
    echo "Run scripts/install-ubuntu-26.04.sh first."
    exit 1
}

# ---------------------------------------------------------------------------
# Find converted image
# ---------------------------------------------------------------------------
DISK_IMG="${DISK_IMG:-}"
if [ -z "$DISK_IMG" ]; then
    # Pick the most recently modified mender image in deploy/
    DISK_IMG=$(ls -t "${REPO_ROOT}/deploy/Ubuntu-26.04"*mender*.img 2>/dev/null | head -1)
fi
[ -n "$DISK_IMG" ] || {
    echo "ERROR: No converted image found in deploy/. Run scripts/convert-ubuntu-26.04.sh first."
    exit 1
}

echo "Booting: ${DISK_IMG}"

# ---------------------------------------------------------------------------
# UEFI NVRAM — fresh writable copy each boot (preserves original)
# ---------------------------------------------------------------------------
cp -f "$NVRAM_TEMPLATE" "$NVRAM"

# ---------------------------------------------------------------------------
# swtpm
# ---------------------------------------------------------------------------
rm -f "$TPM_SOCKET"

echo "Starting swtpm..."
swtpm socket \
    --tpm2 \
    --tpmstate dir="$TPM_STATE_DIR" \
    --ctrl type=unixio,path="$TPM_SOCKET" \
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
# Boot
# ---------------------------------------------------------------------------
echo ""
echo "VM starting — SSH will be available on localhost:${SSH_PORT} once booted."
echo "Connect with: ssh mender@localhost -p ${SSH_PORT}"
echo ""

qemu-system-x86_64 \
    -enable-kvm \
    -m 1024 \
    -smp 2 \
    -nographic \
    -drive file="${OVMF_CODE}",if=pflash,format=raw,unit=0,readonly=on \
    -drive file="${NVRAM}",if=pflash,format=raw,unit=1 \
    -chardev socket,id=chrtpm,path="${TPM_SOCKET}" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -device virtio-scsi-pci,id=scsi0 \
    -device scsi-hd,drive=hd0,bus=scsi0.0 \
    -drive if=none,id=hd0,file="${DISK_IMG}",format=raw,cache=none \
    -net user,hostfwd=tcp::"${SSH_PORT}"-:22 \
    -net nic,macaddr=52:54:00$(od -txC -An -N3 /dev/urandom | tr ' ' ':' | head -c 8) \
    -serial mon:stdio
