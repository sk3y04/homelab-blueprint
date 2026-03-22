# ComfyUI — GPU-Accelerated Image & Video Generation

Node-based workflow editor for Stable Diffusion, FLUX, WAN 2.1, and other
diffusion models. Runs on an NVIDIA RTX 3090 24 GB via Docker Compose with
full GPU passthrough, persistent storage, and a staged bootstrap workflow.

```
                  ┌────────────────┐
You ──► browser ──┤   ComfyUI      │
                  │   :8188        │──── RTX 3090 (24 GB)
                  └────────────────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
         models/    custom_nodes/  output/
       (persistent bind mounts on host)
```

## Table of Contents

1. [Architecture](#architecture)
2. [Project Tree](#project-tree)
3. [Prerequisites](#prerequisites)
4. [Bootstrap Workflow](#bootstrap-workflow)
5. [GPU Coexistence with Ollama](#gpu-coexistence-with-ollama)
6. [Custom Nodes Strategy](#custom-nodes-strategy)
7. [Model Strategy for RTX 3090](#model-strategy-for-rtx-3090)
8. [Optimization Matrix](#optimization-matrix-for-rtx-3090)
9. [Validation Checklist](#validation-checklist)
10. [Maintenance & Operations](#maintenance--operations)
11. [Rollback Procedures](#rollback-procedures)
12. [Troubleshooting](#troubleshooting)

---

## Architecture

### What runs where

| Layer | Component | Purpose |
|-------|-----------|---------|
| **Host** | NVIDIA driver, CUDA toolkit, Container Toolkit, Docker | Bare minimum on host. |
| **Container** | `comfyui` | ComfyUI web UI + inference backend with GPU passthrough. |
| **Bind mounts** | models, custom_nodes, input, output, user, cache | All persistent data on the host filesystem. |

### What stays outside ComfyUI

| Component | Location | Why separate |
|-----------|----------|--------------|
| Ollama + Open WebUI | `services/ai-stack/` | Text LLM inference — different workload, shared GPU. |
| DCGM Exporter | `services/ai-stack/` | GPU metrics already exported by the AI stack. |
| Prometheus + Grafana | `services/monitoring/` | Centralized monitoring — no duplication. |
| Nginx reverse proxy | `vps/nginx/` | TLS termination happens on the VPS. |

### Network layout

```
┌─── comfyui network (bridge) ─────────────────────────────────┐
│  comfyui:8188                                                 │
└───────────────────────────────────────────────────────────────┘
         │
     └── Host port (all host interfaces):
               :8188   ComfyUI Web UI + API
```

ComfyUI runs on its own bridge network.  It does **not** need to join the
`ai-stack` or `monitoring` networks — it has no API dependencies on Ollama
and GPU metrics are already scraped by the DCGM exporter in the AI stack.

### Persistent storage layout

All data under `$COMFYUI_DATA_DIR` (default `/opt/comfyui/data`):

```
/opt/comfyui/data/
├── models/               # Checkpoints, LoRAs, VAEs, CLIP, ControlNet, etc.
│   ├── checkpoints/      #   SDXL / SD1.5 full checkpoints
│   ├── clip/             #   CLIP text encoders
│   ├── clip_vision/      #   CLIP vision models (IP-Adapter, etc.)
│   ├── controlnet/       #   ControlNet models
│   ├── diffusion_models/ #   FLUX, WAN diffusion transformer weights
│   ├── embeddings/       #   Textual inversion embeddings
│   ├── loras/            #   LoRA adapters
│   ├── text_encoders/    #   T5, CLIP-L, CLIP-G standalone encoders
│   ├── unet/             #   Standalone UNet weights (legacy FLUX format)
│   ├── upscale_models/   #   ESRGAN, SwinIR, etc.
│   └── vae/              #   VAE decoders
├── custom_nodes/         # ComfyUI Manager + all custom nodes
├── input/                # Input images for img2img, ControlNet, etc.
├── output/               # Generated images and videos
├── user/                 # ComfyUI user settings and saved workflows
└── cache/
    ├── huggingface/      # HuggingFace Hub model cache
    └── pip/              # pip cache (speeds up node dependency installs)
```

---

## Project Tree

```
services/comfyui/
├── docker-compose.yml          # Compose definition — single ComfyUI service
├── .env.example                # Environment template — copy to .env
├── Dockerfile                  # Builds ComfyUI on pytorch/CUDA base
├── .dockerignore               # Keeps build context clean
├── scripts/
│   ├── entrypoint.sh           # Container entrypoint — Manager bootstrap + start
│   ├── init.sh                 # First-run: dirs, build, start, health check
│   ├── start.sh                # Start the ComfyUI container
│   ├── stop.sh                 # Stop the ComfyUI container
│   ├── update.sh               # Rebuild image and/or update custom nodes
│   ├── backup.sh               # Backup workflows, user data, node manifest
│   ├── install-custom-nodes.sh # Install curated custom nodes
│   └── post-install-check.sh   # Validate GPU, API, Manager, models
└── config/
    └── extra_model_paths.example.yaml  # Optional shared model directories
```

---

## Prerequisites

| Requirement | Why |
|-------------|-----|
| Rocky Linux 10.x | Host OS. |
| NVIDIA driver compatible with your selected CUDA runtime | Must support the PyTorch base image chosen in `PYTORCH_IMAGE`. |
| NVIDIA Container Toolkit | Passes the GPU into Docker containers. |
| Docker Engine 24+ with Compose v2 | Container runtime. |
| 100+ GB free disk space | Models, outputs, cache. 200+ GB comfortable. |

If you already have the AI stack running (`services/ai-stack`), the driver,
Container Toolkit, and Docker are already installed.  No additional host
setup is needed.

---

## Bootstrap Workflow

### Stage 1 — Initialize

```bash
cd services/comfyui
chmod +x scripts/*.sh
./scripts/init.sh
```

This will:
1. Copy `.env.example` → `.env`
2. Verify the NVIDIA runtime works in Docker
3. Create all data directories under `/opt/comfyui/data/`
4. Build the Docker image (ComfyUI + xformers on PyTorch/CUDA base)
5. Start the container
6. Wait for the health check to pass

### Stage 2 — Verify the UI

Open `http://<host-ip>:8188` in your browser.  You should see the ComfyUI
node editor from the host itself or any client on the same LAN.  The default
workflow will fail because no models are loaded yet — this is expected.

### Stage 3 — Install custom nodes

```bash
./scripts/install-custom-nodes.sh         # core set
# or
./scripts/install-custom-nodes.sh --all   # core + optional

# Restart to load new nodes
docker compose restart comfyui
```

### Stage 4 — Place models

Download models and place them in the appropriate directories.  See
[Model Strategy](#model-strategy-for-rtx-3090) below for recommended
models and folder targets.

### Stage 5 — Validate

```bash
./scripts/post-install-check.sh
```

Verifies: container health, GPU visibility, API response, Manager presence,
xformers, model directories, and disk space.

### Stage 6 — Start generating

Load a workflow in the UI (or use the default) and queue a prompt.
ComfyUI Manager (gear icon in the UI) can install additional nodes
and download models directly from the web interface.

---

## GPU Coexistence with Ollama

Both ComfyUI and Ollama (`services/ai-stack`) claim the RTX 3090's 24 GB
VRAM.  They can coexist but require awareness:

| Workload | VRAM Usage | Can run alongside Ollama? |
|----------|-----------|--------------------------|
| SDXL generation | ~7 GB | Yes — stop large Ollama models first, or use ≤7B models. |
| SDXL + ControlNet | ~10 GB | Maybe — depends on loaded Ollama model size. |
| FLUX (GGUF Q4) | ~12-16 GB | Unlikely — stop Ollama or use very small models. |
| FLUX (fp16) | ~22-24 GB | No — stop Ollama entirely. |
| WAN 2.1 video (480p) | ~18-22 GB | No — stop Ollama entirely. |

### Strategy

**Option A: Stop Ollama before heavy ComfyUI work**
```bash
cd ../ai-stack && ./stop.sh ollama
cd ../comfyui && ./scripts/start.sh
# ... generate images/video ...
cd ../comfyui && ./scripts/stop.sh
cd ../ai-stack && ./start.sh ollama
```

**Option B: Run both with small models**

Keep Ollama loaded with a ≤7B model (~4 GB VRAM) and use SDXL in ComfyUI
(~7 GB).  Total: ~11 GB, leaving headroom.

**Option C: Use `--force-fp16` and `--dont-upcast-attention`**

Set in `.env`:
```
COMFYUI_EXTRA_ARGS=--force-fp16 --dont-upcast-attention
```
Reduces ComfyUI VRAM usage slightly but does not eliminate the constraint.

---

## Custom Nodes Strategy

### Tier 1 — Core Recommended

Installed by `./scripts/install-custom-nodes.sh`.  Well-maintained, widely
used, safe on all setups.

| Node | Purpose | Repo |
|------|---------|------|
| ComfyUI-Manager | Node management, dependency installer, model downloader | `ltdrdata/ComfyUI-Manager` |
| ComfyUI-Impact-Pack | Detailers, segmentation, SAM, SEGS | `ltdrdata/ComfyUI-Impact-Pack` |
| ComfyUI-Inspire-Pack | Additional workflow utilities | `ltdrdata/ComfyUI-Inspire-Pack` |
| ComfyUI_essentials | Essential utility nodes | `cubiq/ComfyUI_essentials` |
| ComfyUI-Custom-Scripts | UI improvements, auto-arrange, image feed | `pythongosssss/ComfyUI-Custom-Scripts` |
| rgthree-comfy | Workflow quality-of-life (reroute, bookmark, mute) | `rgthree/rgthree-comfy` |
| was-node-suite | Large utility node pack | `WASasquatch/was-node-suite-comfyui` |
| comfyui_controlnet_aux | ControlNet preprocessors (OpenPose, depth, etc.) | `Fannovel16/comfyui_controlnet_aux` |

> ComfyUI-Manager is installed automatically by the container entrypoint.
> The other core nodes are installed by the script.

### Tier 2 — Optional

Installed by `./scripts/install-custom-nodes.sh --all`.  Useful for
specific workflows.

| Node | Purpose | Repo |
|------|---------|------|
| ComfyUI-VideoHelperSuite | Video loading, saving, combining | `Kosinkadink/ComfyUI-VideoHelperSuite` |
| ComfyUI-AnimateDiff-Evolved | AnimateDiff animation workflows | `Kosinkadink/ComfyUI-AnimateDiff-Evolved` |
| ComfyUI-KJNodes | Utility nodes from kijai | `kijai/ComfyUI-KJNodes` |
| ComfyUI_Comfyroll | Additional utility/formatting nodes | `Suzie1/ComfyUI_Comfyroll_CustomNodes` |
| comfy_mtb | Math, transform, batch utilities | `melMass/comfy_mtb` |

### Tier 3 — High Risk / Version-Sensitive

**Do NOT install automatically.**  These require manual testing and may
break with PyTorch, CUDA, or ComfyUI updates.

| Node | Risk | Notes |
|------|------|-------|
| SageAttention nodes | **Not compatible** | Requires RTX 50xx (Blackwell) hardware. Will not work on RTX 3090. |
| Custom CUDA kernel nodes | **High** | May fail to compile against the container's CUDA version. |
| Triton-dependent nodes | **Medium** | Triton versions must match PyTorch exactly. |
| Nodes with pinned torch versions | **Medium** | May conflict with the base image's PyTorch. |

### Tier 4 — Not Recommended

| Category | Why |
|----------|-----|
| RTX 50xx-specific optimizations | Hardware not present. |
| Nodes that patch ComfyUI internals | Break on core updates. |
| Unmaintained nodes (no commits in 6+ months) | Likely incompatible. |

### Node verification workflow

Before installing any node not in the curated list:
1. Check the GitHub repo — look for recent commits, open issues, Python version requirements.
2. Install into a test directory first:
   ```bash
   cd /opt/comfyui/data/custom_nodes
   git clone <repo_url>
   docker compose restart comfyui
   docker compose logs -f comfyui   # watch for import errors
   ```
3. If it breaks, remove and restart:
   ```bash
   rm -rf /opt/comfyui/data/custom_nodes/<broken-node>
   docker compose restart comfyui
   ```

---

## Model Strategy for RTX 3090

### Folder targets and recommended model categories

Download models from their official sources (HuggingFace, Civitai, etc.)
and place them in the corresponding directory.  ComfyUI auto-discovers
models by folder.

> **Important:** Do not download models from unverified sources.  Always
> verify checksums when provided by the model author.

#### SDXL (Stable Diffusion XL)

| Directory | What goes here | VRAM | Notes |
|-----------|---------------|------|-------|
| `models/checkpoints/` | SDXL 1.0 base, SDXL refiners, community fine-tunes | ~7 GB | Primary workhorse for image generation. |
| `models/vae/` | SDXL VAE (sdxl_vae.safetensors) | ~0.3 GB | Use the official SDXL VAE or fp16 variant. |
| `models/loras/` | SDXL LoRA adapters | ~50-500 MB each | Style, character, concept LoRAs. |
| `models/controlnet/` | SDXL ControlNet models | ~2.5 GB each | Canny, depth, pose (search for "sdxl controlnet" on HuggingFace). |
| `models/embeddings/` | Textual inversions | ~10-100 KB each | Negative embeddings, style embeddings. |

#### FLUX

| Directory | What goes here | VRAM | Notes |
|-----------|---------------|------|-------|
| `models/diffusion_models/` | FLUX.1-dev / FLUX.1-schnell (fp16 or GGUF) | 12-24 GB | **GGUF Q4-Q5 recommended** for RTX 3090 — full fp16 uses nearly all 24 GB. |
| `models/text_encoders/` | CLIP-L + T5-XXL text encoders | ~10 GB (T5-XXL fp16) | T5-XXL GGUF (Q4/Q5/Q8) saves significant VRAM. |
| `models/clip/` | CLIP-L for FLUX | ~0.5 GB | Often bundled with text_encoders. |
| `models/vae/` | FLUX VAE (ae.safetensors) | ~0.3 GB | FLUX uses its own VAE. |
| `models/loras/` | FLUX LoRAs | ~100-500 MB each | Fewer available than SDXL, growing ecosystem. |

> **FLUX on 24 GB:** Full fp16 is tight.  Prefer GGUF quantized variants
> (Q4_K_S through Q8_0) from HuggingFace.  With GGUF Q5 diffusion model +
> GGUF Q5 T5-XXL, total VRAM usage is ~14-16 GB — very comfortable.

#### WAN 2.1 (Video Generation)

| Directory | What goes here | VRAM | Notes |
|-----------|---------------|------|-------|
| `models/diffusion_models/` | WAN 2.1 diffusion transformer | ~15-30 GB | The 14B model may not fit in 24 GB at fp16. Use the 1.3B or fp8/GGUF variant. |
| `models/text_encoders/` | UMT5-XXL / mT5 text encoder | ~10 GB | GGUF quantized recommended if available. |
| `models/clip/` | CLIP model for WAN | ~0.5 GB | Check WAN 2.1 docs for exact requirements. |
| `models/vae/` | WAN 2.1 VAE | ~0.3 GB | WAN-specific VAE. |

> **WAN 2.1 on 24 GB:** The 1.3B parameter model generates 480p video and
> fits comfortably.  The 14B model requires aggressive quantization (fp8 or
> GGUF Q4) or offloading.  Use `--force-fp16 --dont-upcast-attention` and
> the `ComfyUI-KJNodes` model offloading if attempting 14B.

#### Qwen-VL (Vision-Language)

Qwen-VL is a vision-language model primarily used for image understanding
and captioning within ComfyUI workflows (not direct image generation).

| Directory | What goes here | Notes |
|-----------|---------------|-------|
| `models/checkpoints/` or via HuggingFace cache | Qwen2-VL variants | Loaded through custom nodes (Florence2, Qwen-VL nodes). |

> These models are typically loaded via HuggingFace `transformers` and
> cached in `cache/huggingface/`.  Install the relevant custom node and
> it will handle the download.

#### Upscalers

| Directory | What goes here | VRAM | Notes |
|-----------|---------------|------|-------|
| `models/upscale_models/` | RealESRGAN, SwinIR, 4x-UltraSharp | ~0.1-0.5 GB | Low VRAM usage. Multiple can be kept. |

#### General model discovery

1. **HuggingFace:** Search by model type.  Look for `.safetensors` format.
2. **Civitai:** Community fine-tunes, LoRAs, embeddings.  Verify licenses.
3. **ComfyUI Manager:** The Manager UI can search and download some models directly.
4. **Official model pages:** FLUX on Black Forest Labs HF, WAN on Alibaba's repos.

### Model placement verification

After placing models, verify ComfyUI finds them:
1. Restart ComfyUI: `docker compose restart comfyui`
2. In the UI, the model loader nodes should list your models in their dropdowns.
3. Or check the API: `curl http://<host-ip>:8188/object_info` (search for your model name).

---

## Optimization Matrix for RTX 3090

The RTX 3090 is Ampere architecture (compute capability 8.6 / sm_86).

| Optimization | Status | Rationale |
|-------------|--------|-----------|
| **xformers** | **Recommended** — installed by default | Stable, well-tested memory-efficient attention for Ampere. Significant VRAM savings (~20-30%) and speedup. Auto-detected by ComfyUI. |
| **fp16** | **Recommended** | Native Ampere support. Most models and workflows default to fp16. Use `--force-fp16` for models that try to use fp32. |
| **bf16** | **Optional** | Ampere supports bf16 natively. Slightly less precision than fp16 but better dynamic range. Some newer models (FLUX, WAN) may prefer it. Safe to use. |
| **torch.compile** | **Optional** | Can speed up repeated operations by 10-30% after initial compilation. Adds 30-60s startup overhead per workflow. Set via `--use-pytorch-cross-attention` is NOT the same thing — torch.compile is separate. Worth trying for batch work. |
| **triton** | **Optional** — do not install by default | Can accelerate some custom attention kernels. Version must match PyTorch exactly. If xformers works, triton adds little benefit. Install only if a specific node requires it. |
| **flash-attn** | **Optional** — redundant with xformers | Flash Attention provides similar benefits to xformers. Ampere supports it. However, xformers is more mature in the ComfyUI ecosystem. Install only if a workflow specifically requires flash-attn instead of xformers. |
| **fp8 (e4m3fn / e5m2)** | **Not recommended** | RTX 3090 lacks native FP8 tensor core support (requires Ada Lovelace / RTX 40xx+). Software FP8 emulation provides no speedup and may cause quality loss. |
| **SageAttention** | **Not compatible** | Requires RTX 50xx (Blackwell) hardware features. Will fail on RTX 3090. |
| **--dont-upcast-attention** | **Recommended for large models** | Prevents ComfyUI from upcasting attention to fp32. Saves VRAM at the cost of minimal quality difference. Very useful when running FLUX or WAN. |
| **--use-split-cross-attention** | **Situational** | Slower than xformers but uses less peak VRAM. Use only if you get OOM errors with xformers on very large models. |

### Recommended `.env` for balanced performance

```env
COMFYUI_EXTRA_ARGS=--preview-method auto
```

### Recommended `.env` for maximum VRAM savings

```env
COMFYUI_EXTRA_ARGS=--force-fp16 --dont-upcast-attention --preview-method auto
```

---

## Validation Checklist

Run `./scripts/post-install-check.sh` to verify automatically, or check
manually:

- [ ] Container `comfyui` is running and healthy
- [ ] `nvidia-smi` works inside the container and shows RTX 3090
- [ ] ComfyUI API responds at `http://<host-ip>:8188/system_stats`
- [ ] GPU is listed in system_stats with ~24 GB VRAM
- [ ] ComfyUI-Manager is present in `custom_nodes/`
- [ ] xformers is importable inside the container
- [ ] PyTorch reports CUDA available (`torch.cuda.is_available() == True`)
- [ ] All model subdirectories exist under `models/`
- [ ] At least one checkpoint is placed in `models/checkpoints/` (for testing)
- [ ] UI loads in browser at `http://<host-ip>:8188`
- [ ] A test generation completes successfully with the checkpoint
- [ ] Output images appear in `/opt/comfyui/data/output/`
- [ ] Logs show no Python import errors: `docker compose logs comfyui | grep -i error`

---

## Maintenance & Operations

### Update ComfyUI core

```bash
cd services/comfyui
./scripts/update.sh
```

This rebuilds the Docker image with the latest ComfyUI core (or the
version pinned in `COMFYUI_VERSION`) and restarts the container.  Custom
nodes and models are preserved because they are on bind mounts.

To pin a specific version before updating:
```bash
# Edit .env
COMFYUI_VERSION=v0.3.10
# Then rebuild
./scripts/update.sh
```

### Update custom nodes

```bash
./scripts/update.sh --nodes        # update nodes + rebuild image
./scripts/update.sh --nodes-only   # update nodes only, no image rebuild
```

This runs `git pull --ff-only` on each custom node.  If a node has local
changes, the pull will fail safely and report the node name.

### Update a single custom node

```bash
cd /opt/comfyui/data/custom_nodes/<node-name>
git pull
cd /path/to/services/comfyui
docker compose restart comfyui
```

### Backup

```bash
./scripts/backup.sh                    # user data, outputs, node manifest
./scripts/backup.sh --include-models   # also include models (large!)
```

Creates a timestamped tarball in `/opt/comfyui/data/backups/`.

The backup includes:
- `user/` — saved workflows, settings
- `output/` — generated images and videos
- `input/` — uploaded input images
- `custom_nodes_manifest.txt` — list of installed nodes with git URLs and commit hashes

Models are excluded by default (they can be re-downloaded).

### Scheduled backups

Add to crontab:
```bash
crontab -e
# Weekly backup at 3 AM Sunday
0 3 * * 0 /path/to/services/comfyui/scripts/backup.sh
```

---

## Rollback Procedures

### A custom node breaks ComfyUI

**Symptoms:** ComfyUI won't start, import errors in logs, UI fails to load.

```bash
# 1. Identify the bad node from logs
docker compose logs comfyui 2>&1 | grep -i "error\|traceback\|import"

# 2. Remove the broken node
rm -rf /opt/comfyui/data/custom_nodes/<broken-node-name>

# 3. Restart
docker compose restart comfyui

# 4. Verify
./scripts/post-install-check.sh
```

### A ComfyUI core update breaks things

```bash
# 1. Pin to the last known good version
# Edit .env:
COMFYUI_VERSION=<last-good-tag-or-commit>

# 2. Rebuild
./scripts/update.sh

# 3. Verify
./scripts/post-install-check.sh
```

To find the last good commit/tag:
```bash
# Check ComfyUI releases
# https://github.com/comfyanonymous/ComfyUI/releases
```

### Restore from backup

```bash
# Stop ComfyUI
./scripts/stop.sh

# Restore user data
tar -xzf /opt/comfyui/data/backups/comfyui_backup_YYYYMMDD_HHMMSS.tar.gz \
    -C /opt/comfyui/data/

# Restore custom nodes from manifest
while IFS='|' read -r name url rev branch; do
  if [ ! -d "/opt/comfyui/data/custom_nodes/$name" ]; then
    git clone "$url" "/opt/comfyui/data/custom_nodes/$name"
    git -C "/opt/comfyui/data/custom_nodes/$name" checkout "$rev" 2>/dev/null || true
  fi
done < /opt/comfyui/data/custom_nodes_manifest.txt

# Start
./scripts/start.sh
```

### Roll back a custom node to a previous version

```bash
cd /opt/comfyui/data/custom_nodes/<node-name>

# See recent commits
git log --oneline -10

# Check out a specific commit
git checkout <commit-hash>

# Restart
cd /path/to/services/comfyui
docker compose restart comfyui
```

---

## Troubleshooting

### Container won't start — "NVIDIA driver not found"

```bash
# Verify host driver
nvidia-smi

# Verify container toolkit against the configured PyTorch base image
docker run --rm --gpus all pytorch/pytorch:2.10.0-cuda13.0-cudnn9-runtime \
  python -c "import torch; print(torch.cuda.is_available())"

# If toolkit is missing, install it:
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
sudo dnf install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### Container starts but GPU shows 0 MB VRAM free

Another process is using all VRAM (likely Ollama with a large model).

```bash
# Check what's using the GPU
nvidia-smi

# Stop Ollama if needed
cd ../ai-stack && ./stop.sh ollama
```

### ComfyUI starts but UI shows "connection refused"

Port binding issue.  Check:
```bash
docker compose ps
# Verify port is 0.0.0.0:8188->8188 or :::8188->8188
docker compose logs comfyui | grep "listen"
```

### "Module not found" errors for custom nodes

Custom node dependencies missing.  The entrypoint installs them
automatically, but some may fail:

```bash
# Check logs for the specific error
docker compose logs comfyui | grep -i "module"

# Manually install inside the container
docker exec -it comfyui pip install <missing-module>

# Or reinstall all node dependencies by restarting
docker compose restart comfyui
```

### OOM (Out of Memory) during generation

```bash
# Add VRAM-saving flags
# Edit .env:
COMFYUI_EXTRA_ARGS=--force-fp16 --dont-upcast-attention

# Restart
docker compose restart comfyui
```

If still OOM:
- Use smaller models (GGUF quantized instead of fp16)
- Use `--use-split-cross-attention` (slower but lower peak VRAM)
- Reduce image resolution
- Stop Ollama and other GPU consumers

### Build fails — network timeout during git clone

Docker build needs internet access to clone ComfyUI and install pip packages.

```bash
# Retry the build
docker compose build --no-cache

# If behind a proxy, configure Docker:
# https://docs.docker.com/engine/daemon/proxy/
```

### Custom node installation fails in install-custom-nodes.sh

```bash
# Verify the URL is accessible
git ls-remote https://github.com/<owner>/<repo>.git

# Clone manually to see the error
git clone https://github.com/<owner>/<repo>.git /tmp/test-node

# If the repo was renamed or removed, check ComfyUI Manager
# for the current URL, or search GitHub.
```
