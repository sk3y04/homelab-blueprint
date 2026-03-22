# -------------------------------------------------------------------------
# ComfyUI — GPU-Accelerated Image & Video Generation
# -------------------------------------------------------------------------
# Single-stage build to preserve ability to pip install inside the
# running container (required by ComfyUI Manager and custom nodes).
#
# Build:
#   docker compose build
#   docker compose build --build-arg COMFYUI_VERSION=v0.3.10
#
# The image embeds ComfyUI core only.  Models, custom_nodes, input,
# output, and user directories are bind-mounted at runtime so they
# survive image rebuilds.
# -------------------------------------------------------------------------

ARG PYTORCH_IMAGE=pytorch/pytorch:2.10.0-cuda13.0-cudnn9-runtime
FROM ${PYTORCH_IMAGE}

# Prevent interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# System dependencies required by ComfyUI core and common custom nodes
# (opencv, ffmpeg for video workflows, GL libs for image processing,
# and build tools for Python packages with native extensions such as
# insightface used by some custom nodes).
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
        git \
    pkg-config \
    python3-dev \
        wget \
        curl \
        ffmpeg \
    libgl1 \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender1 \
        libgomp1 \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Clone ComfyUI — pinnable via build arg
ARG COMFYUI_VERSION=master
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /app \
    && cd /app \
    && if [ "${COMFYUI_VERSION}" != "master" ]; then git checkout "${COMFYUI_VERSION}"; fi

WORKDIR /app

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Install Python dependencies into an isolated virtualenv so Ubuntu's
# externally managed system Python does not block pip installs.
RUN python3 -m venv "${VIRTUAL_ENV}" \
    && pip install --no-cache-dir --upgrade pip setuptools wheel Cython

# Install ComfyUI Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Install xformers — stable and recommended for RTX 3090 (Ampere / sm_86).
# Provides memory-efficient attention, significant VRAM savings and speedup.
RUN pip install --no-cache-dir xformers

# Pre-create directories that will be overridden by bind mounts.
# Ensures the container can start even without mounts for quick testing.
RUN mkdir -p /app/models /app/custom_nodes /app/input /app/output /app/user

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8188

ENTRYPOINT ["/entrypoint.sh"]
