#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Deploy Persona Model to Ollama
# --------------------------------------------------------------------------
# Usage:
#   ./deploy-persona.sh
#   ./deploy-persona.sh --adapter-file /opt/ai-stack/data/training/exports/persona-adapter.gguf
#   ./deploy-persona.sh --model-name persona-dev --force
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
AI Stack — Deploy Persona Model to Ollama

Usage:
  ./deploy-persona.sh
  ./deploy-persona.sh --adapter-file /opt/ai-stack/data/training/exports/persona-adapter.gguf
  ./deploy-persona.sh --model-name persona-dev --force
EOF
}

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

MODEL_NAME="persona"
ADAPTER_FILE="${AI_DATA_DIR:-/opt/ai-stack/data}/training/exports/persona-adapter.gguf"
LIVE_ADAPTER_DIR="${AI_DATA_DIR:-/opt/ai-stack/data}/lora-adapters"
LIVE_ADAPTER_FILE="$LIVE_ADAPTER_DIR/persona-adapter.gguf"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter-file)
      ADAPTER_FILE="$2"
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

if [ ! -f "$ADAPTER_FILE" ]; then
  echo "ERROR: Exported adapter not found: $ADAPTER_FILE"
  exit 1
fi

mkdir -p "$LIVE_ADAPTER_DIR"
cp "$ADAPTER_FILE" "$LIVE_ADAPTER_FILE"

echo "Ensuring Ollama is recreated with the latest adapter and Modelfile mounts..."
docker compose up -d ollama

if [ "$FORCE" -eq 1 ]; then
  echo "Removing existing Ollama model if present: $MODEL_NAME"
  docker exec ai-ollama ollama rm "$MODEL_NAME" >/dev/null 2>&1 || true
fi

echo "Creating persona model in Ollama..."
docker exec ai-ollama ollama create "$MODEL_NAME" -f /models/Modelfile.persona

echo ""
echo "Deployment complete."
echo "  Model name:    $MODEL_NAME"
echo "  Adapter file:  $LIVE_ADAPTER_FILE"
echo ""
echo "Quick test:"
echo "  docker exec ai-ollama ollama run $MODEL_NAME \"hey, what's up?\""