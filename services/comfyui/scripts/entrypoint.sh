#!/usr/bin/env bash
# --------------------------------------------------------------------------
# ComfyUI — Container Entrypoint
# --------------------------------------------------------------------------
# Runs on every container start.  Ensures model subdirectories exist,
# ComfyUI Manager is present in the bind-mounted custom_nodes, and
# custom node dependencies are installed before starting ComfyUI.
# --------------------------------------------------------------------------
set -euo pipefail

CUSTOM_NODES_DIR="/app/custom_nodes"
MANAGER_DIR="${CUSTOM_NODES_DIR}/ComfyUI-Manager"

clone_repo() {
  local repo_url="$1"
  local target_dir="$2"
  local label="$3"

  if timeout 180 git clone --depth 1 "$repo_url" "$target_dir"; then
    return 0
  fi

  echo "[entrypoint] WARNING: Failed to clone ${label}; continuing without it"
  rm -rf "$target_dir"
  return 1
}

# ── Ensure model subdirectories exist ────────────────────────────────────
echo "[entrypoint] Ensuring model subdirectories..."
mkdir -p /app/models/{checkpoints,clip,clip_vision,controlnet,diffusion_models,embeddings,loras,text_encoders,unet,upscale_models,vae}

# ── Ensure ComfyUI Manager is installed ──────────────────────────────────
if [ ! -d "${MANAGER_DIR}" ]; then
  echo "[entrypoint] ComfyUI Manager not found — cloning..."
  clone_repo "https://github.com/ltdrdata/ComfyUI-Manager.git" "${MANAGER_DIR}" "ComfyUI Manager" || true
fi

# Install Manager dependencies if present
if [ -f "${MANAGER_DIR}/requirements.txt" ]; then
  echo "[entrypoint] Installing ComfyUI Manager dependencies..."
  pip install --no-cache-dir -r "${MANAGER_DIR}/requirements.txt" 2>/dev/null || true
fi

# ── Install requirements for any custom nodes ────────────────────────────
echo "[entrypoint] Checking custom node dependencies..."
for req in "${CUSTOM_NODES_DIR}"/*/requirements.txt; do
  [ -f "$req" ] || continue
  node_name=$(basename "$(dirname "$req")")
  # Skip Manager — already handled above
  [ "$node_name" = "ComfyUI-Manager" ] && continue
  echo "[entrypoint]   Installing deps for ${node_name}..."
  pip install --no-cache-dir -r "$req" 2>/dev/null \
    || echo "[entrypoint]   WARNING: Failed to install some deps for ${node_name}"
done

# ── Apply extra model paths if config exists ─────────────────────────────
EXTRA_PATHS_ARG=""
if [ -f /app/config/extra_model_paths.yaml ]; then
  EXTRA_PATHS_ARG="--extra-model-paths-config /app/config/extra_model_paths.yaml"
  echo "[entrypoint] Using extra model paths from /app/config/extra_model_paths.yaml"
fi

# ── Start ComfyUI ────────────────────────────────────────────────────────
echo "[entrypoint] Starting ComfyUI..."
echo "[entrypoint]   CLI args: --listen 0.0.0.0 --port 8188 ${COMFYUI_EXTRA_ARGS:-} ${EXTRA_PATHS_ARG}"

# shellcheck disable=SC2086
exec python main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  ${COMFYUI_EXTRA_ARGS:-} \
  ${EXTRA_PATHS_ARG}
