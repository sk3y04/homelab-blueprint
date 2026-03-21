#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Bootstrap llama.cpp for LoRA GGUF Export
# --------------------------------------------------------------------------
# Usage:
#   ./scripts/bootstrap_llama_cpp.sh
#   ./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp
#   ./scripts/bootstrap_llama_cpp.sh --repo-ref master
# --------------------------------------------------------------------------
set -euo pipefail

usage() {
  cat <<'EOF'
AI Stack — Bootstrap llama.cpp for LoRA GGUF Export

Usage:
  ./scripts/bootstrap_llama_cpp.sh
  ./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp
  ./scripts/bootstrap_llama_cpp.sh --repo-ref master
EOF
}

INSTALL_DIR="${LLAMA_CPP_DIR:-/opt/llama.cpp}"
REPO_URL="https://github.com/ggml-org/llama.cpp.git"
REPO_REF="master"

while [ $# -gt 0 ]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --repo-ref)
      REPO_REF="$2"
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

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required."
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "ERROR: cmake is required."
  exit 1
fi

if ! command -v python >/dev/null 2>&1; then
  echo "ERROR: python is required."
  exit 1
fi

mkdir -p "$(dirname "$INSTALL_DIR")"

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing llama.cpp checkout at $INSTALL_DIR"
  git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_REF"
  git -C "$INSTALL_DIR" checkout FETCH_HEAD
else
  echo "Cloning llama.cpp into $INSTALL_DIR"
  git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
fi

echo "Installing Python requirements for conversion helpers"
python -m pip install -r "$INSTALL_DIR/requirements/requirements-convert_hf_to_gguf.txt"

echo "Configuring llama.cpp"
cmake -S "$INSTALL_DIR" -B "$INSTALL_DIR/build" -DGGML_CUDA=ON

echo "Building llama.cpp tools"
cmake --build "$INSTALL_DIR/build" -j

echo ""
echo "llama.cpp is ready at: $INSTALL_DIR"
echo "Converter path: $INSTALL_DIR/convert_lora_to_gguf.py"