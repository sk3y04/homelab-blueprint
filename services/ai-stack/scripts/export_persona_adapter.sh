#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Export Persona LoRA Adapter to GGUF
# --------------------------------------------------------------------------
# Usage:
#   ./scripts/export_persona_adapter.sh \
#     --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
#     --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
#     --base-model Qwen/Qwen3.5-9B \
#     --llama-cpp-dir /opt/llama.cpp
# --------------------------------------------------------------------------
set -euo pipefail

usage() {
  cat <<'EOF'
AI Stack — Export Persona LoRA Adapter to GGUF

Usage:
  ./scripts/export_persona_adapter.sh \
    --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
    --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
    --base-model Qwen/Qwen3.5-9B \
    --llama-cpp-dir /opt/llama.cpp
EOF
}

ADAPTER_DIR=""
OUTPUT_FILE=""
BASE_MODEL=""
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter-dir)
      ADAPTER_DIR="$2"
      shift 2
      ;;
    --output-file)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --base-model)
      BASE_MODEL="$2"
      shift 2
      ;;
    --llama-cpp-dir)
      LLAMA_CPP_DIR="$2"
      shift 2
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

if [ -z "$ADAPTER_DIR" ] || [ -z "$OUTPUT_FILE" ] || [ -z "$BASE_MODEL" ]; then
  echo "ERROR: --adapter-dir, --output-file, and --base-model are required."
  exit 1
fi

if [ -z "$LLAMA_CPP_DIR" ]; then
  echo "ERROR: --llama-cpp-dir is required unless LLAMA_CPP_DIR is already set."
  exit 1
fi

if [ ! -d "$ADAPTER_DIR" ]; then
  echo "ERROR: Adapter directory not found: $ADAPTER_DIR"
  exit 1
fi

CONVERTER="$LLAMA_CPP_DIR/convert_lora_to_gguf.py"
if [ ! -f "$CONVERTER" ]; then
  echo "ERROR: llama.cpp converter not found: $CONVERTER"
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "Exporting persona adapter to GGUF..."
echo "  Adapter:    $ADAPTER_DIR"
echo "  Output:     $OUTPUT_FILE"
echo "  Base model: $BASE_MODEL"
echo "  llama.cpp:  $LLAMA_CPP_DIR"

python "$CONVERTER" \
  --base "$BASE_MODEL" \
  "$ADAPTER_DIR" \
  --outfile "$OUTPUT_FILE"

echo ""
echo "Export complete: $OUTPUT_FILE"