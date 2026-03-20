#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Stop all services
# --------------------------------------------------------------------------
# Usage: ./stop.sh
#        ./stop.sh ollama           # stop a single service
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -gt 0 ]; then
  echo "Stopping AI stack service: $*"
  docker compose stop "$@"
else
  echo "Stopping AI stack..."
  docker compose down
fi
