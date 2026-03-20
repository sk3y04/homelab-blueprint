#!/usr/bin/env bash
# --------------------------------------------------------------------------
# Set GPU power limit for inference (285W)
# --------------------------------------------------------------------------
# The RTX 3090 TDP is 350W. For 24/7 inference, 285W reduces heat and
# power consumption with minimal performance loss on quantized LLMs.
#
# Requires: nvidia-smi on the host, run as root or with sudo.
# Persistence: nvidia-smi settings reset on reboot. To persist, add this
#              script to a systemd service or /etc/rc.local.
# --------------------------------------------------------------------------
set -euo pipefail

POWER_LIMIT_W=285

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (or with sudo)."
  exit 1
fi

echo "Setting GPU power limit to ${POWER_LIMIT_W}W (inference mode)..."

# Enable persistence mode so settings survive idle periods.
nvidia-smi -pm 1

# Set power limit.
nvidia-smi -pl "$POWER_LIMIT_W"

echo ""
nvidia-smi --query-gpu=name,power.limit,power.default_power_limit --format=csv,noheader
echo ""
echo "Done. Power limit set to ${POWER_LIMIT_W}W."
echo "To persist across reboots, add this script to a systemd unit or cron @reboot."
