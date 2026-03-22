#!/usr/bin/env bash
# --------------------------------------------------------------------------
# ComfyUI — Start services
# --------------------------------------------------------------------------
# Usage: ./scripts/start.sh
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Run first-time setup:"
  echo "  ./scripts/init.sh"
  exit 1
fi

echo "Starting ComfyUI..."
docker compose up -d

echo ""
echo "Services:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
