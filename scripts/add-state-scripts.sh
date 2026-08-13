#!/usr/bin/env bash
# Inject state scripts into an existing .mender artifact.
#
# Usage:
#   ./scripts/add-state-scripts.sh                        # auto-picks newest artifact in deploy/
#   ./scripts/add-state-scripts.sh deploy/my.mender       # explicit artifact
#
# Modifies the artifact in-place (backs up original as <artifact>.orig).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

check_cmd() { command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found."; exit 1; }; }
check_cmd mender-artifact

# ---------------------------------------------------------------------------
# Resolve artifact path
# ---------------------------------------------------------------------------
ARTIFACT="${1:-}"
if [ -z "$ARTIFACT" ]; then
    ARTIFACT=$(ls -t "${REPO_ROOT}/deploy/"*.mender 2>/dev/null | head -1)
fi
[ -n "$ARTIFACT" ] || { echo "ERROR: No .mender artifact found in deploy/"; exit 1; }
[ -f "$ARTIFACT" ] || { echo "ERROR: Artifact not found: $ARTIFACT"; exit 1; }

# ---------------------------------------------------------------------------
# Resolve state scripts
# ---------------------------------------------------------------------------
SCRIPT_INSTALL="${REPO_ROOT}/input/ArtifactInstall_Leave_60"
SCRIPT_REBOOT="${REPO_ROOT}/input/ArtifactReboot_Enter_50"

for s in "$SCRIPT_INSTALL" "$SCRIPT_REBOOT"; do
    [ -f "$s" ] || { echo "ERROR: State script not found: $s"; exit 1; }
    chmod +x "$s"
done

# ---------------------------------------------------------------------------
# Inject
# ---------------------------------------------------------------------------
echo "Artifact: ${ARTIFACT}"
echo "Adding state scripts:"
echo "  $(basename "$SCRIPT_INSTALL")"
echo "  $(basename "$SCRIPT_REBOOT")"
echo ""

cp -f "$ARTIFACT" "${ARTIFACT}.orig"

mender-artifact modify \
    --script "$SCRIPT_INSTALL" \
    --script "$SCRIPT_REBOOT" \
    "$ARTIFACT"

echo ""
echo "Done. Original backed up as $(basename "${ARTIFACT}").orig"
echo ""
mender-artifact read "$ARTIFACT" | grep -A2 "State scripts"
