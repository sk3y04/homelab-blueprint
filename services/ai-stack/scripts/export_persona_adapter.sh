#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Export Persona LoRA Adapter to GGUF
# --------------------------------------------------------------------------
# Usage:
#   ./scripts/export_persona_adapter.sh \
#     --adapter-dir /opt/ai-stack/data/training/runs/persona-v1-qwen35-9b \
#     --output-file /opt/ai-stack/data/training/exports/persona-adapter.gguf \
#     --base-model Qwen/Qwen3.5-9B \
#     --base-model /models/Qwen3.5-9B \
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

Notes:
  --base-model may be either:
    - a local base model directory containing config/tokenizer files
    - a Hugging Face repo ID such as Qwen/Qwen3.5-9B

  When a repo ID is provided, this script downloads only the base model metadata
  needed by llama.cpp into the local Hugging Face cache and passes that resolved
  snapshot path to convert_lora_to_gguf.py.
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

if ! command -v python >/dev/null 2>&1; then
  echo "ERROR: python is required."
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

resolve_base_model() {
  local base_model="$1"

  if [ -d "$base_model" ]; then
    printf '%s\n' "$base_model"
    return 0
  fi

  case "$base_model" in
    */*)
      echo "Resolving base model metadata from Hugging Face Hub: $base_model" >&2
      python - "$base_model" <<'PY'
import sys

try:
    from huggingface_hub import snapshot_download
except ImportError as exc:
    raise SystemExit(
        "huggingface_hub is required to resolve remote base models. "
        "Install it with: python -m pip install huggingface_hub"
    ) from exc

repo_id = sys.argv[1]
allow_patterns = [
    "*.json",
    "*.model",
    "*.tiktoken",
    "*.txt",
    "tokenizer.*",
    "spiece.model",
]

snapshot_path = snapshot_download(repo_id=repo_id, allow_patterns=allow_patterns)
print(snapshot_path)
PY
      ;;
    *)
      echo "ERROR: --base-model must be an existing directory or a Hugging Face repo ID like owner/name." >&2
      return 1
      ;;
  esac
}

mkdir -p "$(dirname "$OUTPUT_FILE")"

if ! RESOLVED_BASE_MODEL="$(resolve_base_model "$BASE_MODEL")"; then
  echo "ERROR: Failed to resolve base model metadata for: $BASE_MODEL"
  echo "Pass a local model directory or ensure the Hugging Face repo is reachable."
  exit 1
fi

echo "Exporting persona adapter to GGUF..."
echo "  Adapter:    $ADAPTER_DIR"
echo "  Output:     $OUTPUT_FILE"
echo "  Base model: $BASE_MODEL"
echo "  Resolved:   $RESOLVED_BASE_MODEL"
echo "  llama.cpp:  $LLAMA_CPP_DIR"

python "$CONVERTER" \
  --base "$RESOLVED_BASE_MODEL" \
  "$ADAPTER_DIR" \
  --outfile "$OUTPUT_FILE"

echo ""
echo "Export complete: $OUTPUT_FILE"