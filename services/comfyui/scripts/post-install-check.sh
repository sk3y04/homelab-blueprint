#!/usr/bin/env bash
# --------------------------------------------------------------------------
# ComfyUI — Post-Installation Validation
# --------------------------------------------------------------------------
# Checks that ComfyUI is running correctly with GPU access, Manager
# is installed, and key directories are in place.
#
# Usage: ./scripts/post-install-check.sh
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
# shellcheck source=/dev/null
source .env
set +a

DATA_DIR="${COMFYUI_DATA_DIR:-/opt/comfyui/data}"
PORT="${COMFYUI_PORT:-8188}"
FAIL=0

echo "=== ComfyUI — Post-Installation Check ==="
echo ""

# ── Container status ─────────────────────────────────────────────────────
echo "── Container Status ──"
status=$(docker inspect --format='{{.State.Health.Status}}' comfyui 2>/dev/null || echo "not-found")
case "$status" in
  healthy)   echo "  ✓ comfyui: healthy" ;;
  unhealthy) echo "  ✗ comfyui: UNHEALTHY"; FAIL=1 ;;
  starting)  echo "  … comfyui: still starting (wait and re-run)" ;;
  *)         echo "  ✗ comfyui: ${status}"; FAIL=1 ;;
esac
echo ""

# ── GPU access ───────────────────────────────────────────────────────────
echo "── GPU Access ──"
if docker exec comfyui nvidia-smi &>/dev/null; then
  gpu_name=$(docker exec comfyui nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  gpu_mem=$(docker exec comfyui nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
  echo "  ✓ GPU: ${gpu_name} (${gpu_mem})"
else
  echo "  ✗ nvidia-smi failed inside container"
  FAIL=1
fi
echo ""

# ── ComfyUI API ──────────────────────────────────────────────────────────
echo "── ComfyUI API ──"
if curl -sf "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; then
  echo "  ✓ API responding on :${PORT}"
  # Try to extract device info
  docker exec comfyui python -c "
import urllib.request, json
data = json.load(urllib.request.urlopen('http://localhost:8188/system_stats'))
for d in data.get('devices', []):
    name = d.get('name', 'unknown')
    vram = d.get('vram_total', 0) / (1024**3)
    vram_free = d.get('vram_free', 0) / (1024**3)
    print(f'    {name}: {vram:.1f} GB total, {vram_free:.1f} GB free')
" 2>/dev/null || echo "    (could not parse device info)"
else
  echo "  ✗ API not responding on :${PORT}"
  FAIL=1
fi
echo ""

# ── ComfyUI Manager ─────────────────────────────────────────────────────
echo "── ComfyUI Manager ──"
if [ -d "${DATA_DIR}/custom_nodes/ComfyUI-Manager" ]; then
  echo "  ✓ Installed"
else
  echo "  ✗ NOT found in custom_nodes/"
  FAIL=1
fi
echo ""

# ── Custom nodes ─────────────────────────────────────────────────────────
echo "── Custom Nodes ──"
node_count=$(find "${DATA_DIR}/custom_nodes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
echo "  Installed: ${node_count} node(s)"
for d in "${DATA_DIR}/custom_nodes"/*/; do
  [ -d "$d" ] || continue
  echo "    - $(basename "$d")"
done
echo ""

# ── Model directories ───────────────────────────────────────────────────
echo "── Model Directories ──"
for subdir in checkpoints clip clip_vision controlnet diffusion_models embeddings loras text_encoders unet upscale_models vae; do
  dir="${DATA_DIR}/models/${subdir}"
  if [ -d "$dir" ]; then
    count=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
    printf "  ✓ models/%-20s (%d files)\n" "${subdir}/" "$count"
  else
    printf "  ✗ models/%-20s MISSING\n" "${subdir}/"
    FAIL=1
  fi
done
echo ""

# ── xformers ─────────────────────────────────────────────────────────────
echo "── Optimizations ──"
xf_version=$(docker exec comfyui python -c "import xformers; print(xformers.__version__)" 2>/dev/null || echo "")
if [ -n "$xf_version" ]; then
  echo "  ✓ xformers ${xf_version}"
else
  echo "  ⚠ xformers not available (ComfyUI will use PyTorch attention)"
fi

torch_version=$(docker exec comfyui python -c "import torch; print(torch.__version__)" 2>/dev/null || echo "")
if [ -n "$torch_version" ]; then
  echo "  ✓ PyTorch ${torch_version}"
fi

cuda_available=$(docker exec comfyui python -c "import torch; print(torch.cuda.is_available())" 2>/dev/null || echo "")
if [ "$cuda_available" = "True" ]; then
  cuda_version=$(docker exec comfyui python -c "import torch; print(torch.version.cuda)" 2>/dev/null || echo "")
  echo "  ✓ CUDA ${cuda_version} available"
else
  echo "  ✗ CUDA not available to PyTorch"
  FAIL=1
fi
echo ""

# ── Disk space ───────────────────────────────────────────────────────────
echo "── Disk Space ──"
df -h "${DATA_DIR}" 2>/dev/null | tail -1 | awk '{printf "  Data dir: %s used / %s total (%s free)\n", $3, $2, $4}'
echo ""

# ── Result ───────────────────────────────────────────────────────────────
if [ "$FAIL" -eq 0 ]; then
  echo "═══ ALL CHECKS PASSED ═══"
else
  echo "═══ SOME CHECKS FAILED — review output above ═══"
fi
exit "$FAIL"
