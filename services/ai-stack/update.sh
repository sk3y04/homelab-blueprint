#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Update all images and restart
# --------------------------------------------------------------------------
# Usage: ./update.sh
#        ./update.sh ollama         # update a single service
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -gt 0 ]; then
  echo "Updating AI stack service: $*"
  docker compose pull "$@"
  docker compose up -d "$@"
else
  echo "Pulling latest images..."
  docker compose pull
  echo ""
  echo "Recreating containers with new images..."
  docker compose up -d
fi

echo ""
echo "Pruning old images..."
docker image prune -f

echo ""
echo "Current status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Image}}"
