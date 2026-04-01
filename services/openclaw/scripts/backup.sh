#!/usr/bin/env bash
# --------------------------------------------------------------------------
# OpenClaw — Backup
# --------------------------------------------------------------------------
# Creates a timestamped tarball of OpenClaw config, workspace, and logs
# in the configured backup directory.
#
# Usage: ./backup.sh
#        ./backup.sh --data-only    # skip logs
# --------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Copy .env.example and configure it:"
  echo "  cp .env.example .env"
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

BACKUP_DIR="${OPENCLAW_BACKUP_DIR:-/home/skey/raid6/openclaw/backups}"
DATA_DIR="${OPENCLAW_DATA_DIR:-/home/skey/raid6/openclaw/data}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/home/skey/raid6/openclaw/workspace}"
LOG_DIR="${OPENCLAW_LOG_DIR:-/home/skey/raid6/openclaw/logs}"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
ARCHIVE="${BACKUP_DIR}/openclaw-backup-${TIMESTAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

INCLUDE_LOGS=true
if [[ "${1:-}" == "--data-only" ]]; then
  INCLUDE_LOGS=false
fi

echo "=== OpenClaw Backup ==="
echo "  Timestamp: ${TIMESTAMP}"
echo "  Target:    ${ARCHIVE}"
echo ""

# Build list of directories to back up.
DIRS=()
if [ -d "$DATA_DIR" ]; then
  DIRS+=("$DATA_DIR")
  echo "  ✓ Data:      ${DATA_DIR}"
else
  echo "  ✗ Data dir not found: ${DATA_DIR}"
fi

if [ -d "$WORKSPACE_DIR" ]; then
  DIRS+=("$WORKSPACE_DIR")
  echo "  ✓ Workspace: ${WORKSPACE_DIR}"
else
  echo "  ✗ Workspace dir not found: ${WORKSPACE_DIR}"
fi

if [ "$INCLUDE_LOGS" = true ] && [ -d "$LOG_DIR" ]; then
  DIRS+=("$LOG_DIR")
  echo "  ✓ Logs:      ${LOG_DIR}"
fi

if [ ${#DIRS[@]} -eq 0 ]; then
  echo ""
  echo "ERROR: No directories to back up."
  exit 1
fi

echo ""
echo "Creating archive..."
tar czf "$ARCHIVE" "${DIRS[@]}"

SIZE=$(du -sh "$ARCHIVE" | cut -f1)
echo "  ✓ Backup complete: ${ARCHIVE} (${SIZE})"

# Clean up backups older than 30 days.
OLD_COUNT=$(find "$BACKUP_DIR" -name "openclaw-backup-*.tar.gz" -mtime +30 | wc -l)
if [ "$OLD_COUNT" -gt 0 ]; then
  echo ""
  echo "Cleaning up ${OLD_COUNT} backup(s) older than 30 days..."
  find "$BACKUP_DIR" -name "openclaw-backup-*.tar.gz" -mtime +30 -delete
  echo "  ✓ Cleanup complete."
fi
