#!/usr/bin/env bash
# Convert a raw Ubuntu 26.04 disk image to a Mender image using docker-mender-convert.
#
# Usage: ./scripts/convert-ubuntu-26.04.sh
#
# Requires:  input/Ubuntu-26.04-x86-64.img   (produced by install-ubuntu-26.04.sh)
# Produces:  deploy/Ubuntu-26.04-x86-64-qemux86-64-mender.img

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT_IMG="${REPO_ROOT}/input/Ubuntu-26.04-x86-64.img"

check_cmd() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found. Install: $2"; exit 1; }; }
check_cmd docker "docker.io"

[ -f "$INPUT_IMG" ] || {
    echo "ERROR: Input image not found: ${INPUT_IMG}"
    echo "Run scripts/install-ubuntu-26.04.sh first."
    exit 1
}

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Load credentials from .env if present (survives sudo's env stripping)
# ---------------------------------------------------------------------------
[ -f "${REPO_ROOT}/.env" ] && set -a && . "${REPO_ROOT}/.env" && set +a

# ---------------------------------------------------------------------------
# Mender server overlay (optional)
#   Set MENDER_SERVER_URL and MENDER_TENANT_TOKEN in the environment or .env
# ---------------------------------------------------------------------------
OVERLAY_ARG=""
if [ -n "${MENDER_SERVER_URL:-}" ] && [ -n "${MENDER_TENANT_TOKEN:-}" ]; then
    mkdir -p input/rootfs_overlay_hosted/etc/mender
    cat > input/rootfs_overlay_hosted/etc/mender/mender.conf <<EOF
{
  "ServerURL": "${MENDER_SERVER_URL}",
  "TenantToken": "${MENDER_TENANT_TOKEN}"
}
EOF
    echo "MENDER_SERVER_URL + MENDER_TENANT_TOKEN set — built Mender overlay."
    OVERLAY_ARG="--overlay input/rootfs_overlay_hosted"
fi

# ---------------------------------------------------------------------------
# State scripts overlay
# ---------------------------------------------------------------------------
mkdir -p input/rootfs_overlay_state_scripts/etc/mender/scripts
for script in \
    "${REPO_ROOT}/input/ArtifactInstall_Leave_60" \
    "${REPO_ROOT}/input/ArtifactReboot_Enter_50"; do
    [ -f "$script" ] || { echo "WARNING: state script not found: $script"; continue; }
    cp "$script" input/rootfs_overlay_state_scripts/etc/mender/scripts/
    chmod +x "input/rootfs_overlay_state_scripts/etc/mender/scripts/$(basename "$script")"
done
OVERLAY_ARG="${OVERLAY_ARG} --overlay input/rootfs_overlay_state_scripts"

echo "Starting mender-convert for Ubuntu 26.04..."
echo "Input:  ${INPUT_IMG}"
echo ""

MENDER_ARTIFACT_NAME=release-1 ./docker-mender-convert \
    --disk-image input/Ubuntu-26.04-x86-64.img \
    --config configs/ubuntu-qemux86-64_config \
    ${OVERLAY_ARG}

echo ""
echo "Conversion complete. Output:"
ls -lh deploy/Ubuntu-26.04-x86-64-qemux86-64-mender.img 2>/dev/null \
    || ls -lh deploy/Ubuntu-26.04* 2>/dev/null \
    || echo "(check deploy/ directory)"
