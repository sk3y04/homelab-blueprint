#!/usr/bin/env bash
# --------------------------------------------------------------------------
# OpenClaw — Update image and restart
# --------------------------------------------------------------------------
# Pulls the configured image, recreates the container, and verifies health.
#
# Usage: ./update.sh
#        ./update.sh ghcr.io/openclaw/openclaw:2026.3.15   # override tag
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Copy .env.example and configure it:"
  echo "  cp .env.example .env"
  exit 1
fi

echo "=== OpenClaw Update ==="

# Optional: override image tag from command line.
if [ $# -gt 0 ]; then
  NEW_IMAGE="$1"
  echo "  Overriding image to: ${NEW_IMAGE}"
  # Update .env in-place.
  if grep -q "^OPENCLAW_IMAGE=" .env; then
    sed -i "s|^OPENCLAW_IMAGE=.*|OPENCLAW_IMAGE=${NEW_IMAGE}|" .env
  else
    echo "OPENCLAW_IMAGE=${NEW_IMAGE}" >> .env
  fi
fi

echo ""
echo "Pulling image..."
docker compose pull

echo ""
echo "Recreating container with new image..."
docker compose up -d

echo ""
echo "Waiting for health check (up to 60s)..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' openclaw-gateway 2>/dev/null || echo "not-found")
  case "$STATUS" in
    healthy)
      echo "  ✓ openclaw-gateway is healthy"
      break
      ;;
    unhealthy)
      echo "  ✗ openclaw-gateway is UNHEALTHY"
      echo ""
      echo "Check logs: docker logs openclaw-gateway --tail 50"
      exit 1
      ;;
    *)
      sleep 5
      ELAPSED=$((ELAPSED + 5))
      ;;
  esac
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "  ✗ Timed out waiting for healthy status"
  echo ""
  echo "Check logs: docker logs openclaw-gateway --tail 50"
  exit 1
fi

echo ""
echo "Pruning old images..."
docker image prune -f

echo ""
echo "Current status:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Image}}"
