#!/usr/bin/env bash
# --------------------------------------------------------------------------
# ComfyUI — Update image and custom nodes
# --------------------------------------------------------------------------
# Rebuilds the ComfyUI image (pulls latest ComfyUI core + dependencies)
# and optionally updates all custom nodes.
#
# Usage:
#   ./scripts/update.sh               # rebuild image only
#   ./scripts/update.sh --nodes       # also update custom nodes
#   ./scripts/update.sh --nodes-only  # update custom nodes without rebuild
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source ./scripts/load-env.sh
load_dotenv .env

DATA_DIR="${COMFYUI_DATA_DIR:-/opt/comfyui/data}"
UPDATE_NODES=false
NODES_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --nodes)      UPDATE_NODES=true ;;
    --nodes-only) NODES_ONLY=true; UPDATE_NODES=true ;;
  esac
done

# ── Update custom nodes ─────────────────────────────────────────────────
if $UPDATE_NODES; then
  echo "── Updating custom nodes ──"
  fail=0
  for d in "${DATA_DIR}/custom_nodes"/*/; do
    [ -d "$d/.git" ] || continue
    name=$(basename "$d")
    echo -n "  ${name}: "
    if git -C "$d" pull --ff-only 2>/dev/null; then
      echo "updated"
    else
      echo "FAILED (may have local changes)"
      ((fail++))
    fi
  done
  if [ "$fail" -gt 0 ]; then
    echo ""
    echo "  ⚠ ${fail} node(s) failed to update."
    echo "    To force-update a node: cd ${DATA_DIR}/custom_nodes/<name> && git reset --hard origin/main && git pull"
  fi
  echo ""
fi

if $NODES_ONLY; then
  echo "Restarting ComfyUI to load updated nodes..."
  docker compose restart comfyui
  echo "Done."
  exit 0
fi

# ── Rebuild image ────────────────────────────────────────────────────────
echo "── Rebuilding ComfyUI image ──"
echo "  (This re-clones ComfyUI core and reinstalls dependencies)"
docker compose build --no-cache
echo ""

echo "── Recreating container ──"
docker compose up -d
echo ""

echo "── Pruning old images ──"
docker image prune -f
echo ""

echo "Current status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Image}}"
