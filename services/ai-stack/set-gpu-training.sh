#!/usr/bin/env bash
# --------------------------------------------------------------------------
# Set GPU power limit for training / LoRA fine-tuning (350W)
# --------------------------------------------------------------------------
# Restores the RTX 3090 to its full 350W TDP for maximum performance
# during LoRA training or other compute-intensive tasks.
#
# After training, switch back to inference mode:
#   sudo ./set-gpu-inference.sh
#
# Requires: nvidia-smi on the host, run as root or with sudo.
# --------------------------------------------------------------------------
set -euo pipefail

POWER_LIMIT_W=350

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (or with sudo)."
  exit 1
fi

echo "Setting GPU power limit to ${POWER_LIMIT_W}W (training mode)..."

# Enable persistence mode.
nvidia-smi -pm 1

# Set power limit to full TDP.
nvidia-smi -pl "$POWER_LIMIT_W"

echo ""
nvidia-smi --query-gpu=name,power.limit,power.default_power_limit --format=csv,noheader
echo ""
echo "Done. Power limit set to ${POWER_LIMIT_W}W (full TDP)."
echo "Remember to switch back after training:  sudo ./set-gpu-inference.sh"
