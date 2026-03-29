#!/usr/bin/env bash
# --------------------------------------------------------------------------
# AI Stack — Bootstrap llama.cpp for LoRA GGUF Export
# --------------------------------------------------------------------------
# Usage:
#   ./scripts/bootstrap_llama_cpp.sh
#   ./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp
#   ./scripts/bootstrap_llama_cpp.sh --repo-ref master
#   ./scripts/bootstrap_llama_cpp.sh --repo-url /srv/git/llama.cpp
#   ./scripts/bootstrap_llama_cpp.sh --build-tools --cuda
# --------------------------------------------------------------------------
set -euo pipefail

usage() {
  cat <<'EOF'
AI Stack — Bootstrap llama.cpp for LoRA GGUF Export

Usage:
  ./scripts/bootstrap_llama_cpp.sh
  ./scripts/bootstrap_llama_cpp.sh --install-dir /opt/llama.cpp
  ./scripts/bootstrap_llama_cpp.sh --repo-ref master
  ./scripts/bootstrap_llama_cpp.sh --repo-url /srv/git/llama.cpp
  ./scripts/bootstrap_llama_cpp.sh --build-tools --cpu-only
  ./scripts/bootstrap_llama_cpp.sh --build-tools --cuda

Environment overrides:
  LLAMA_CPP_DIR       Install path for the local checkout
  LLAMA_CPP_REPO_URL  Alternate git source for llama.cpp

Notes:
  By default this script prepares the Python conversion tooling only.
  Use --build-tools if you also need native llama.cpp binaries.
EOF
}

INSTALL_DIR="${LLAMA_CPP_DIR:-/opt/llama.cpp}"
REPO_URL="${LLAMA_CPP_REPO_URL:-https://github.com/ggml-org/llama.cpp.git}"
REPO_REF="master"
BUILD_TOOLS=0
BUILD_BACKEND="cpu"

print_clone_help() {
  local error_output="$1"

  echo ""
  echo "Bootstrap failed while accessing: $REPO_URL"

  case "$error_output" in
    *"Could not resolve host:"*)
      echo "The host running this script cannot resolve the git remote hostname."
      echo "Fix DNS or outbound network access first, or rerun with a reachable mirror/local clone:"
      echo "  ./scripts/bootstrap_llama_cpp.sh --repo-url /path/to/llama.cpp-mirror"
      echo "  LLAMA_CPP_REPO_URL=ssh://git@your-git-host/llama.cpp.git ./scripts/bootstrap_llama_cpp.sh"
      ;;
    *"Connection timed out"*|*"Failed to connect to"*|*"Network is unreachable"*)
      echo "The host can resolve the git remote, but it cannot reach it over the network."
      echo "Check outbound firewall, proxy, or routing rules, or use --repo-url with an internal mirror."
      ;;
    *)
      echo "Review the git error above and verify the remote is reachable from this host."
      ;;
  esac
}

run_git() {
  local output

  if ! output=$("$@" 2>&1); then
    echo "$output"
    print_clone_help "$output"
    exit 1
  fi

  if [ -n "$output" ]; then
    echo "$output"
  fi
}

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
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --build-tools)
      BUILD_TOOLS=1
      shift
      ;;
    --cpu-only)
      BUILD_BACKEND="cpu"
      shift
      ;;
    --cuda)
      BUILD_BACKEND="cuda"
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

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required."
  exit 1
fi

if ! command -v python >/dev/null 2>&1; then
  echo "ERROR: python is required."
  exit 1
fi

if [ "$BUILD_TOOLS" -eq 1 ] && ! command -v cmake >/dev/null 2>&1; then
  echo "ERROR: cmake is required when --build-tools is used."
  exit 1
fi

mkdir -p "$(dirname "$INSTALL_DIR")"

if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing llama.cpp checkout at $INSTALL_DIR"
  run_git git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_REF"
  run_git git -C "$INSTALL_DIR" checkout FETCH_HEAD
else
  echo "Cloning llama.cpp into $INSTALL_DIR"
  run_git git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
fi

echo "Installing Python requirements for conversion helpers"
python -m pip install -r "$INSTALL_DIR/requirements/requirements-convert_hf_to_gguf.txt"

if [ "$BUILD_TOOLS" -eq 0 ]; then
  echo ""
  echo "Skipping native llama.cpp build."
  echo "The GGUF conversion helper is ready for export_persona_adapter.sh."
  echo "Use --build-tools if you also need native llama.cpp binaries."
  echo "llama.cpp is ready at: $INSTALL_DIR"
  echo "Converter path: $INSTALL_DIR/convert_lora_to_gguf.py"
  exit 0
fi

if [ "$BUILD_BACKEND" = "cuda" ]; then
  CUDA_COMPILER="${CUDACXX:-}"

  if [ -z "$CUDA_COMPILER" ] && command -v nvcc >/dev/null 2>&1; then
    CUDA_COMPILER="$(command -v nvcc)"
  fi

  if [ -z "$CUDA_COMPILER" ]; then
    echo "ERROR: --build-tools --cuda requires a working CUDA compiler."
    echo "Set CUDACXX to nvcc, add nvcc to PATH, or use --build-tools --cpu-only."
    exit 1
  fi

  echo "Configuring llama.cpp with CUDA support"
  cmake -S "$INSTALL_DIR" -B "$INSTALL_DIR/build" -DGGML_CUDA=ON -DCMAKE_CUDA_COMPILER="$CUDA_COMPILER"
else
  echo "Configuring llama.cpp with CPU-only support"
  cmake -S "$INSTALL_DIR" -B "$INSTALL_DIR/build" -DGGML_CUDA=OFF
fi

echo "Building llama.cpp tools"
cmake --build "$INSTALL_DIR/build" -j

echo ""
echo "llama.cpp is ready at: $INSTALL_DIR"
echo "Converter path: $INSTALL_DIR/convert_lora_to_gguf.py"