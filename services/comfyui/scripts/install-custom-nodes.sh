#!/usr/bin/env bash
# --------------------------------------------------------------------------
# ComfyUI — Install Curated Custom Nodes
# --------------------------------------------------------------------------
# Clones a set of well-known, maintained custom nodes into the
# custom_nodes directory.  Run once after initial setup.
#
# Usage:
#   ./scripts/install-custom-nodes.sh            # install core set
#   ./scripts/install-custom-nodes.sh --all      # install core + optional
#   ./scripts/install-custom-nodes.sh --list     # list available nodes
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=/dev/null
source ./scripts/load-env.sh
load_dotenv .env

CUSTOM_NODES_DIR="${COMFYUI_DATA_DIR:-/opt/comfyui/data}/custom_nodes"

# ╔════════════════════════════════════════════════════════════════════════╗
# ║  CORE RECOMMENDED NODES                                              ║
# ║  Well-maintained, widely used, safe on all setups.                   ║
# ╚════════════════════════════════════════════════════════════════════════╝
CORE_NODES=(
  "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
  "https://github.com/ltdrdata/ComfyUI-Inspire-Pack.git"
  "https://github.com/cubiq/ComfyUI_essentials.git"
  "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
  "https://github.com/rgthree/rgthree-comfy.git"
  "https://github.com/WASasquatch/was-node-suite-comfyui.git"
  "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
)

# ╔════════════════════════════════════════════════════════════════════════╗
# ║  OPTIONAL NODES                                                       ║
# ║  Useful for specific workflows (video, animation, utilities).        ║
# ║  Install if you need their features.                                  ║
# ╚════════════════════════════════════════════════════════════════════════╝
OPTIONAL_NODES=(
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
  "https://github.com/Kosinkadink/ComfyUI-AnimateDiff-Evolved.git"
  "https://github.com/kijai/ComfyUI-KJNodes.git"
  "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git"
  "https://github.com/melMass/comfy_mtb.git"
)

# ╔════════════════════════════════════════════════════════════════════════╗
# ║  HIGH-RISK / VERSION-SENSITIVE NODES — NOT INSTALLED BY THIS SCRIPT  ║
# ║                                                                       ║
# ║  - SageAttention nodes:        RTX 50xx (Blackwell) only.            ║
# ║  - Custom CUDA kernel nodes:   May break with PyTorch/CUDA updates.  ║
# ║  - Triton-dependent nodes:     Version-sensitive, test in isolation. ║
# ║                                                                       ║
# ║  If you need these, install manually and test before committing:     ║
# ║    cd $COMFYUI_DATA_DIR/custom_nodes                                 ║
# ║    git clone <repo_url>                                               ║
# ║    docker compose restart comfyui                                     ║
# ║    docker compose logs -f comfyui   # watch for errors               ║
# ╚════════════════════════════════════════════════════════════════════════╝

# ── Print available nodes ────────────────────────────────────────────────
print_list() {
  echo "=== Core Recommended Nodes ==="
  for url in "${CORE_NODES[@]}"; do
    name=$(basename "$url" .git)
    echo "  ✓ ${name}"
    echo "    ${url}"
  done
  echo ""
  echo "=== Optional Nodes ==="
  for url in "${OPTIONAL_NODES[@]}"; do
    name=$(basename "$url" .git)
    echo "  ○ ${name}"
    echo "    ${url}"
  done
  echo ""
  echo "=== Auto-Installed (via entrypoint) ==="
  echo "  ✓ ComfyUI-Manager"
  echo "    https://github.com/ltdrdata/ComfyUI-Manager.git"
  echo ""
  echo "=== HIGH RISK / NOT RECOMMENDED for RTX 3090 ==="
  echo "  ✗ SageAttention nodes — requires RTX 50xx (Blackwell)"
  echo "  ⚠ Custom CUDA kernel nodes — may break with updates"
  echo "  ⚠ Triton-compiled nodes — version-sensitive"
}

# ── Clone a node if not already present ──────────────────────────────────
install_node() {
  local url="$1"
  local name
  name=$(basename "$url" .git)
  local target="${CUSTOM_NODES_DIR}/${name}"

  if [ -d "$target" ]; then
    echo "  ✓ ${name} — already installed."
    return 0
  fi

  echo -n "  ↓ ${name} — cloning... "
  if git clone --depth 1 "$url" "$target" 2>/dev/null; then
    echo "done."
  else
    echo "FAILED."
    echo "    Verify URL: ${url}"
    return 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--list" ]; then
  print_list
  exit 0
fi

echo "=== ComfyUI — Custom Node Installation ==="
echo ""
echo "Target: ${CUSTOM_NODES_DIR}"
echo ""

mkdir -p "$CUSTOM_NODES_DIR"

echo "── Core nodes ──"
fail_count=0
for url in "${CORE_NODES[@]}"; do
  install_node "$url" || ((fail_count++))
done
echo ""

if [ "${1:-}" = "--all" ]; then
  echo "── Optional nodes ──"
  for url in "${OPTIONAL_NODES[@]}"; do
    install_node "$url" || ((fail_count++))
  done
  echo ""
fi

# ── Summary ──────────────────────────────────────────────────────────────
installed=$(find "$CUSTOM_NODES_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
echo "── Summary ──"
echo "  Total installed nodes: ${installed}"
echo "  Failed this run:       ${fail_count}"
echo ""

if [ "$fail_count" -gt 0 ]; then
  echo "⚠ Some nodes failed to install. Verify the URLs listed above."
  echo ""
fi

echo "Next steps:"
echo "  1. Restart ComfyUI to load new nodes:"
echo "     docker compose restart comfyui"
echo "  2. Open the UI — ComfyUI Manager can install additional dependencies."
echo "  3. Run validation: ./scripts/post-install-check.sh"
