#!/usr/bin/env bash
# --------------------------------------------------------------------------
# ComfyUI — Backup workflows, user data, and custom node manifest
# --------------------------------------------------------------------------
# Creates a timestamped tarball of user data.  Models are excluded by
# default because they are large and can be re-downloaded.
#
# Usage:
#   ./scripts/backup.sh                    # standard backup
#   ./scripts/backup.sh --include-models   # include models (very large!)
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
# shellcheck source=/dev/null
source .env
set +a

DATA_DIR="${COMFYUI_DATA_DIR:-/opt/comfyui/data}"
BACKUP_DIR="${DATA_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
INCLUDE_MODELS=false

if [ "${1:-}" = "--include-models" ]; then
  INCLUDE_MODELS=true
fi

mkdir -p "$BACKUP_DIR"

# ── Snapshot installed custom nodes (git remotes, not full repos) ────────
echo "Snapshotting custom node list..."
NODELIST="${DATA_DIR}/custom_nodes_manifest.txt"
: > "$NODELIST"
for d in "${DATA_DIR}/custom_nodes"/*/; do
  [ -d "$d/.git" ] || continue
  name=$(basename "$d")
  url=$(git -C "$d" remote get-url origin 2>/dev/null || echo "unknown")
  rev=$(git -C "$d" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  echo "${name}|${url}|${rev}|${branch}" >> "$NODELIST"
done
echo "  ✓ Custom node manifest saved ($(wc -l < "$NODELIST") nodes)."

# ── Build tar command ────────────────────────────────────────────────────
BACKUP_FILE="${BACKUP_DIR}/comfyui_backup_${TIMESTAMP}.tar.gz"
TAR_ITEMS=(user output input custom_nodes_manifest.txt)

if $INCLUDE_MODELS; then
  echo "Including models (this may take a while and produce a large file)..."
  TAR_ITEMS+=(models)
fi

echo "Creating backup..."
tar -czf "$BACKUP_FILE" -C "$DATA_DIR" "${TAR_ITEMS[@]}"

SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo ""
echo "✓ Backup complete: ${BACKUP_FILE} (${SIZE})"
echo ""
echo "To restore:"
echo "  tar -xzf ${BACKUP_FILE} -C ${DATA_DIR}"
echo ""
echo "To restore custom nodes from manifest:"
echo "  while IFS='|' read -r name url rev branch; do"
echo "    git clone \"\$url\" \"${DATA_DIR}/custom_nodes/\$name\""
echo "  done < ${DATA_DIR}/custom_nodes_manifest.txt"
