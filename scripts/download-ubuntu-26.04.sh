#!/usr/bin/env bash
# Download Ubuntu 26.04 ISOs (server and/or desktop).
#
# Usage:
#   ./scripts/download-ubuntu-26.04.sh           # downloads server ISO (default)
#   ./scripts/download-ubuntu-26.04.sh desktop   # downloads desktop ISO
#   ./scripts/download-ubuntu-26.04.sh all       # downloads both

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="${REPO_ROOT}/assets"
LOG_FILE="${REPO_ROOT}/logs/download-ubuntu-26.04.log"
mkdir -p "${REPO_ROOT}/logs" "$ASSETS_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "============================================================"
echo "download-ubuntu-26.04.sh  $(date)"
echo "Log: ${LOG_FILE}"
echo "============================================================"

die() { echo ""; echo "ERROR: $*"; echo "Full log: ${LOG_FILE}"; exit 1; }
trap 'echo "FAILED at line ${LINENO}. Full log: ${LOG_FILE}"' ERR

check_cmd() { command -v "$1" &>/dev/null || die "'$1' not found. Install: $2"; }
check_cmd curl      "curl"
check_cmd sha256sum "coreutils"

MODE="${1:-server}"
BASE_URL="https://releases.ubuntu.com/26.04"
SHA256_URL="${BASE_URL}/SHA256SUMS"

download_iso() {
    local name="$1"
    local dest="${ASSETS_DIR}/${name}"

    if [ -f "$dest" ]; then
        echo "Already present: ${dest}"
        echo "Delete manually to re-download."
        return
    fi

    echo ""
    echo "Downloading ${name} (~$(curl -sI "${BASE_URL}/${name}" | grep -i content-length | awk '{printf "%.1fGB", $2/1073741824}'))..."
    echo "  URL: ${BASE_URL}/${name}"
    curl -fL --progress-bar -o "${dest}.tmp" "${BASE_URL}/${name}" \
        || die "Download failed for ${name}"
    mv "${dest}.tmp" "$dest"

    echo ""
    echo "Verifying checksum..."
    EXPECTED=$(curl -fsL "$SHA256_URL" | grep " \*${name}$" | awk '{print $1}') \
        || die "Could not fetch SHA256SUMS"
    [ -n "$EXPECTED" ] || die "No checksum found for ${name} in SHA256SUMS"
    ACTUAL=$(sha256sum "$dest" | awk '{print $1}')

    if [ "$EXPECTED" = "$ACTUAL" ]; then
        echo "Checksum OK: ${ACTUAL}"
    else
        rm -f "$dest"
        die "Checksum mismatch for ${name}!
  Expected: ${EXPECTED}
  Actual:   ${ACTUAL}"
    fi

    echo "Saved: ${dest}"
}

case "$MODE" in
    server)
        download_iso "ubuntu-26.04-live-server-amd64.iso"
        ;;
    desktop)
        download_iso "ubuntu-26.04-desktop-amd64.iso"
        ;;
    all)
        download_iso "ubuntu-26.04-live-server-amd64.iso"
        download_iso "ubuntu-26.04-desktop-amd64.iso"
        ;;
    *)
        die "Unknown argument '${MODE}'. Use: server | desktop | all"
        ;;
esac

echo ""
echo "============================================================"
echo "Done. Full log: ${LOG_FILE}"
echo "============================================================"
