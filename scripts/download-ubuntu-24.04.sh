#!/usr/bin/env bash
# Download the Ubuntu 24.04 LTS (Noble Numbat) live server ISO.
#
# Usage: ./scripts/download-ubuntu-24.04.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/assets"
ISO_NAME="ubuntu-24.04-live-server-amd64.iso"
ISO_PATH="${ASSETS_DIR}/${ISO_NAME}"
# 24.04 has moved to old-releases; use the .2 point release
ISO_URL="https://old-releases.ubuntu.com/releases/24.04.2/ubuntu-24.04.2-live-server-amd64.iso"
SHA256_URL="https://old-releases.ubuntu.com/releases/24.04.2/SHA256SUMS"
# The downloaded file is named after the point release; save it under the plain name
DOWNLOAD_NAME="ubuntu-24.04.2-live-server-amd64.iso"

check_cmd() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found. Install: $2"; exit 1; }; }
check_cmd curl  "curl"
check_cmd sha256sum "coreutils"

mkdir -p "$ASSETS_DIR"

if [ -f "$ISO_PATH" ]; then
    echo "ISO already present at ${ISO_PATH}"
    echo "Delete it manually if you want to re-download."
    exit 0
fi

echo "Downloading Ubuntu 24.04 LTS server ISO..."
echo "  URL: ${ISO_URL}"
echo "  Destination: ${ISO_PATH}"
echo ""
# -f makes curl fail (exit non-zero) on HTTP errors instead of saving an error page
curl -fL --progress-bar -o "${ISO_PATH}.tmp" "$ISO_URL"
mv "${ISO_PATH}.tmp" "$ISO_PATH"

echo ""
echo "Verifying checksum..."
EXPECTED=$(curl -fsL "$SHA256_URL" | grep "$DOWNLOAD_NAME" | awk '{print $1}')
ACTUAL=$(sha256sum "$ISO_PATH" | awk '{print $1}')

if [ "$EXPECTED" = "$ACTUAL" ]; then
    echo "Checksum OK: ${ACTUAL}"
else
    echo "ERROR: Checksum mismatch!"
    echo "  Expected: ${EXPECTED}"
    echo "  Actual:   ${ACTUAL}"
    rm -f "$ISO_PATH"
    exit 1
fi

echo ""
echo "Done: ${ISO_PATH}"
