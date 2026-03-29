#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Deploy Merged Persona Model to Ollama
# --------------------------------------------------------------------------
# Usage:
#   ./deploy-persona-merged.sh
#   ./deploy-persona-merged.sh --model-file /opt/ai-stack/data/training/exports/persona-merged.gguf
#   ./deploy-persona-merged.sh --model-name persona-dev --force
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
AI Stack — Deploy Merged Persona Model to Ollama

Usage:
  ./deploy-persona-merged.sh
  ./deploy-persona-merged.sh --model-file /opt/ai-stack/data/training/exports/persona-merged.gguf
  ./deploy-persona-merged.sh --model-name persona-dev --force
EOF
}

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

DATA_DIR="${AI_ACTIVE_DATA_DIR:-${AI_DATA_DIR:-/opt/ai-stack/data}}"
MODEL_NAME="persona"
SOURCE_MODEL_FILE="$DATA_DIR/training/exports/persona-merged.gguf"
LIVE_MODEL_DIR="$DATA_DIR/merged-models"
LIVE_MODEL_FILE="$LIVE_MODEL_DIR/persona-merged.gguf"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model-file)
      SOURCE_MODEL_FILE="$2"
      shift 2
      ;;
    --model-name)
      MODEL_NAME="$2"
      shift 2
      ;;
    --force)
      FORCE=1
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

if [ ! -f "$SOURCE_MODEL_FILE" ]; then
  echo "ERROR: Merged GGUF model not found: $SOURCE_MODEL_FILE"
  exit 1
fi

mkdir -p "$LIVE_MODEL_DIR"
cp "$SOURCE_MODEL_FILE" "$LIVE_MODEL_FILE"

echo "Ensuring Ollama is recreated with the latest merged model mount..."
docker compose up -d ollama

if [ "$FORCE" -eq 1 ]; then
  echo "Removing existing Ollama model if present: $MODEL_NAME"
  docker exec ai-ollama ollama rm "$MODEL_NAME" >/dev/null 2>&1 || true
fi

echo "Creating merged persona model in Ollama..."
docker exec ai-ollama ollama create "$MODEL_NAME" -f /models/Modelfile.persona.merged

echo ""
echo "Deployment complete."
echo "  Model name:   $MODEL_NAME"
echo "  Model file:   $LIVE_MODEL_FILE"
echo ""
echo "Quick test:"
echo "  docker exec ai-ollama ollama run $MODEL_NAME \"hey, what's up?\""