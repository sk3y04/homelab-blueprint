#!/usr/bin/env bash
# --------------------------------------------------------------------------
# ComfyUI — First-Run Initialization
# --------------------------------------------------------------------------
# Creates data directories, copies .env template, builds the Docker
# image, and starts ComfyUI for the first time.
#
# Usage: ./scripts/init.sh
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== ComfyUI — First-Run Initialization ==="
echo ""

# ── Step 1: Environment file ────────────────────────────────────────────
if [ ! -f .env ]; then
  echo "Step 1: Creating .env from .env.example..."
  cp .env.example .env
  echo "  ✓ Created .env — review and edit if needed."
else
  echo "Step 1: .env already exists — skipping."
fi
echo ""

# Load environment
set -a
# shellcheck source=/dev/null
source .env
set +a

DATA_DIR="${COMFYUI_DATA_DIR:-/opt/comfyui/data}"
PYTORCH_IMAGE="${PYTORCH_IMAGE:-pytorch/pytorch:2.10.0-cuda13.0-cudnn9-runtime}"

# ── Step 2: Verify NVIDIA runtime ───────────────────────────────────────
echo "Step 2: Verifying NVIDIA Container Toolkit..."
if docker run --rm --gpus all "$PYTORCH_IMAGE" python -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" &>/dev/null; then
  echo "  ✓ NVIDIA runtime works."
else
  echo "  ✗ NVIDIA GPU not accessible in Docker."
  echo "    Tested image: ${PYTORCH_IMAGE}"
  echo "    Install the NVIDIA Container Toolkit first."
  echo "    See: guide/COMFYUI.md § Prerequisites"
  exit 1
fi
echo ""

# ── Step 3: Create data directories ────────────────────────────────────
echo "Step 3: Creating data directories under ${DATA_DIR}..."
mkdir -p "${DATA_DIR}"/{models/{checkpoints,clip,clip_vision,controlnet,diffusion_models,embeddings,loras,text_encoders,unet,upscale_models,vae},custom_nodes,input,output,user,cache/{huggingface,pip}}
echo "  ✓ Directories created."
echo ""

# ── Step 4: Build Docker image ──────────────────────────────────────────
echo "Step 4: Building ComfyUI Docker image (this takes a few minutes)..."
docker compose build
echo "  ✓ Image built."
echo ""

# ── Step 5: Start container ─────────────────────────────────────────────
echo "Step 5: Starting ComfyUI..."
docker compose up -d
echo "  ✓ Container started."
echo ""

# ── Step 6: Wait for health check ───────────────────────────────────────
echo "Step 6: Waiting for ComfyUI to become healthy (up to 3 minutes)..."
healthy=false
for i in $(seq 1 36); do
  status=$(docker inspect --format='{{.State.Health.Status}}' comfyui 2>/dev/null || echo "not-found")
  if [ "$status" = "healthy" ]; then
    healthy=true
    break
  fi
  printf "  Attempt %d/36: %s\n" "$i" "$status"
  sleep 5
done

if $healthy; then
  echo "  ✓ ComfyUI is healthy!"
else
  echo "  ⚠ ComfyUI did not become healthy within 3 minutes."
  echo "    This is normal on first start (Manager installation takes time)."
  echo "    Check logs: docker compose logs -f comfyui"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────
echo "=== Initialization Complete ==="
echo ""
echo "  UI:              http://127.0.0.1:${COMFYUI_PORT:-8188}"
echo "  Data directory:  ${DATA_DIR}"
echo "  Logs:            docker compose logs -f comfyui"
echo ""
echo "Next steps:"
echo "  1. Open the UI in your browser and verify it loads."
echo "  2. Install custom nodes:  ./scripts/install-custom-nodes.sh"
echo "  3. Place models in:       ${DATA_DIR}/models/"
echo "  4. Run validation:        ./scripts/post-install-check.sh"
echo ""
echo "See guide/COMFYUI.md for model download instructions and workflows."
