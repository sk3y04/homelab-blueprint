#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Start all services
# --------------------------------------------------------------------------
# Usage: ./start.sh
#        ./start.sh ollama          # start a single service
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Copy .env.example and configure it:"
  echo "  cp .env.example .env"
  exit 1
fi

# Ensure the monitoring network exists (created by services/monitoring).
if ! docker network inspect monitoring &>/dev/null; then
  echo "WARNING: 'monitoring' network not found."
  echo "  Start the monitoring stack first:  cd ../monitoring && docker compose up -d"
  echo "  Or create it manually:             docker network create monitoring"
  echo "  Proceeding anyway — dcgm-exporter will fail to join the monitoring network."
fi

if [ $# -gt 0 ]; then
  echo "Starting AI stack service: $*"
  if [[ " $* " == *" openclaw "* ]]; then
    docker compose --profile openclaw up -d "$@"
  else
    docker compose up -d "$@"
  fi
else
  echo "Starting AI stack..."
  docker compose up -d
fi

echo ""
echo "Services:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "Note: OpenClaw is profile-gated and is not started by default."
echo "      To start it explicitly: docker compose --profile openclaw up -d openclaw"
