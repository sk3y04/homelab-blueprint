#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Export Merged Persona Model to Full GGUF
# --------------------------------------------------------------------------
# Usage:
#   ./scripts/export_persona_merged_gguf.sh \
#     --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
#     --merged-dir /opt/ai-stack/data/training/merged/persona-v1-qwen35-9b \
#     --output-file /opt/ai-stack/data/training/exports/persona-merged.gguf \
#     --llama-cpp-dir /opt/llama.cpp
# --------------------------------------------------------------------------
set -euo pipefail

usage() {
  cat <<'EOF'
AI Stack — Export Merged Persona Model to Full GGUF

Usage:
  ./scripts/export_persona_merged_gguf.sh \
    --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
    --merged-dir /opt/ai-stack/data/training/merged/persona-v1-qwen35-9b \
    --output-file /opt/ai-stack/data/training/exports/persona-merged.gguf \
    --llama-cpp-dir /opt/llama.cpp

Notes:
  Run this inside the training container or another environment with peft,
  torch, and transformers installed.
EOF
}

ADAPTER_DIR=""
MERGED_DIR=""
OUTPUT_FILE=""
BASE_MODEL=""
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-}"
OUTTYPE="f16"
DEVICE_MAP="auto"
MAX_SHARD_SIZE="5GB"

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter-dir)
      ADAPTER_DIR="$2"
      shift 2
      ;;
    --merged-dir)
      MERGED_DIR="$2"
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
    --outtype)
      OUTTYPE="$2"
      shift 2
      ;;
    --device-map)
      DEVICE_MAP="$2"
      shift 2
      ;;
    --max-shard-size)
      MAX_SHARD_SIZE="$2"
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

if [ -z "$ADAPTER_DIR" ] || [ -z "$MERGED_DIR" ] || [ -z "$OUTPUT_FILE" ]; then
  echo "ERROR: --adapter-dir, --merged-dir, and --output-file are required."
  exit 1
fi

if [ -z "$LLAMA_CPP_DIR" ]; then
  echo "ERROR: --llama-cpp-dir is required unless LLAMA_CPP_DIR is already set."
  exit 1
fi

if ! command -v python >/dev/null 2>&1; then
  echo "ERROR: python is required."
  exit 1
fi

MERGE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/merge_persona_model.py"
CONVERTER="$LLAMA_CPP_DIR/convert_hf_to_gguf.py"

if [ ! -f "$MERGE_SCRIPT" ]; then
  echo "ERROR: merge script not found: $MERGE_SCRIPT"
  exit 1
fi

if [ ! -f "$CONVERTER" ]; then
  echo "ERROR: llama.cpp converter not found: $CONVERTER"
  exit 1
fi

mkdir -p "$MERGED_DIR"
mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "Merging adapter into a full model checkpoint..."
MERGE_ARGS=(
  "$MERGE_SCRIPT"
  --adapter-dir "$ADAPTER_DIR"
  --output-dir "$MERGED_DIR"
  --device-map "$DEVICE_MAP"
  --max-shard-size "$MAX_SHARD_SIZE"
)

if [ -n "$BASE_MODEL" ]; then
  MERGE_ARGS+=(--base-model "$BASE_MODEL")
fi

python "${MERGE_ARGS[@]}"

echo "Exporting merged full model to GGUF..."
python "$CONVERTER" "$MERGED_DIR" --outfile "$OUTPUT_FILE" --outtype "$OUTTYPE"

echo ""
echo "Merged GGUF export complete: $OUTPUT_FILE"