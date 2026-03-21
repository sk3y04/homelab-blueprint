#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Promote Persona Model Defaults
# --------------------------------------------------------------------------
# Usage:
#   ./promote-persona-defaults.sh
#   ./promote-persona-defaults.sh --model-name persona-dev --recreate
#   ./promote-persona-defaults.sh --env-file .env
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
AI Stack — Promote Persona Model Defaults

Usage:
  ./promote-persona-defaults.sh
  ./promote-persona-defaults.sh --model-name persona-dev --recreate
  ./promote-persona-defaults.sh --env-file .env
EOF
}

ENV_FILE=".env"
MODEL_NAME="persona"
RECREATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --model-name)
      MODEL_NAME="$2"
      shift 2
      ;;
    --recreate)
      RECREATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: Env file not found: $ENV_FILE"
  echo "Create it first from .env.example."
  exit 1
fi

backup_file="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$ENV_FILE" "$backup_file"

set_or_append() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

set_or_append "OPENCLAW_DEFAULT_MODEL" "$MODEL_NAME"
set_or_append "OPENCODE_MODEL" "ollama/${MODEL_NAME}"

echo "Updated persona defaults in $ENV_FILE"
echo "  OPENCLAW_DEFAULT_MODEL=$MODEL_NAME"
echo "  OPENCODE_MODEL=ollama/$MODEL_NAME"
echo "Backup written to $backup_file"

if [ "$RECREATE" -eq 1 ]; then
  echo ""
  echo "Recreating services..."
  docker compose up -d openclaw opencode
fi

echo ""
echo "Next steps:"
echo "  1. Verify the persona model exists in Ollama: docker exec ai-ollama ollama list"
echo "  2. Recreate services if you did not use --recreate: docker compose up -d openclaw opencode"