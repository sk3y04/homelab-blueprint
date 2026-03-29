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

warn_adapter_runtime_limit() {
  local modelfile_path="$1"

  if [ -f "$modelfile_path" ] && grep -q '^ADAPTER ' "$modelfile_path"; then
    echo "WARNING: This Modelfile uses an ADAPTER directive."
    echo "Current Ollama builds may allow 'ollama create' to succeed but still fail at runtime with:"
    echo "  failed to initialize model: loras are not yet implemented"
    echo "If that happens, this GGUF adapter export is valid, but Ollama cannot serve it directly in this environment."
    echo "Use a merged full-model GGUF workflow or a runtime that supports LoRA adapters."
    echo ""
  fi
}

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

DATA_DIR="${AI_ACTIVE_DATA_DIR:-${AI_DATA_DIR:-/opt/ai-stack/data}}"
MODEL_NAME="persona"
ADAPTER_FILE="$DATA_DIR/training/exports/persona-adapter.gguf"
LIVE_ADAPTER_DIR="$DATA_DIR/lora-adapters"
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

warn_adapter_runtime_limit "./Modelfile.persona.example"

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
warn_adapter_runtime_limit "./Modelfile.persona.example"

echo "Quick test:"
echo "  docker exec ai-ollama ollama run $MODEL_NAME \"hey, what's up?\""