#!/usr/bin/env bash
# ==========================================================================
# setup.sh — Automated XMRig + MoneroOcean mining setup for Ubuntu 24.04
# ==========================================================================
# Builds XMRig from source, configures hugepages + MSR, writes the pool
# config, installs a hardened systemd service, and starts mining.
#
# Usage:
#   sudo ./setup.sh <WALLET_ADDRESS> [WORKER_NAME] [MAX_THREADS_HINT]
#
# Arguments:
#   WALLET_ADDRESS     Monero wallet address (starts with 4, ~95 chars)  [required]
#   WORKER_NAME        Worker name shown on MoneroOcean dashboard        [default: $(hostname)]
#   MAX_THREADS_HINT   Percentage of CPU threads to use (1-100)          [default: 75]
#
# What this script does (idempotent — safe to re-run):
#   1. Installs build dependencies via apt-get
#   2. Creates a dedicated 'xmrig' system user
#   3. Clones XMRig from GitHub and builds with CPU-native optimisations
#   4. Configures 2 MB hugepages (sysctl) and loads the MSR kernel module
#   5. Creates an MSR udev rule so the xmrig user can apply the RandomX boost
#   6. Writes /opt/xmrig/config.json pointed at MoneroOcean (TLS, port 443)
#   7. Installs and enables a hardened systemd service unit
#   8. Starts mining
#
# After running:
#   - Check logs:       journalctl -u xmrig -f --no-pager
#   - Check hashrate:   curl -s http://127.0.0.1:18088/1/summary | python3 -m json.tool
#   - MoneroOcean:      https://moneroocean.stream  → paste your wallet address
#   - Grafana metrics:  cd services/monitoring && docker compose up -d --build
# ==========================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Logging helpers ───────────────────────────────────────────────────────
info()  { echo -e "  ${GREEN}$1${NC}  $2"; }
warn()  { echo -e "  ${YELLOW}$1${NC}  $2"; }
err()   { echo -e "  ${RED}$1${NC}  $2"; }
step()  { echo -e "\n${CYAN}── $1 ──${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "ERROR" "This script must be run as root (sudo ./setup.sh ...)"
    exit 1
fi

# ── OS check ──────────────────────────────────────────────────────────────
if [[ ! -f /etc/os-release ]]; then
    err "ERROR" "/etc/os-release not found — cannot verify OS"
    exit 1
fi
source /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
    warn "WARN" "This script targets Ubuntu 24.04 but detected: ${PRETTY_NAME}"
    warn "WARN" "Continuing anyway — package names may differ on other distros"
fi

# ── Arguments ─────────────────────────────────────────────────────────────
WALLET_ADDRESS="${1:-}"
WORKER_NAME="${2:-$(hostname)}"
MAX_THREADS_HINT="${3:-75}"

if [[ -z "${WALLET_ADDRESS}" ]]; then
    echo ""
    err "ERROR" "Missing required argument: WALLET_ADDRESS"
    echo ""
    echo "Usage:"
    echo "  sudo ./setup.sh <WALLET_ADDRESS> [WORKER_NAME] [MAX_THREADS_HINT]"
    echo ""
    echo "Example:"
    echo "  sudo ./setup.sh 4XXXXXX...your95charaddress...XXXXX homelab 75"
    echo ""
    exit 1
fi

# Validate wallet address format (Monero mainnet primary addresses start with 4, ~95 chars)
if [[ ! "${WALLET_ADDRESS}" =~ ^4[0-9A-Za-z]{93,}$ ]]; then
    warn "WARN" "Wallet address does not match expected Monero mainnet format (starts with 4, ~95 chars)"
    read -rp "         Continue anyway? [y/N] " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Validate thread hint is numeric and in range
if [[ ! "${MAX_THREADS_HINT}" =~ ^[0-9]+$ ]] || (( MAX_THREADS_HINT < 1 || MAX_THREADS_HINT > 100 )); then
    err "ERROR" "MAX_THREADS_HINT must be a number between 1 and 100 (got: ${MAX_THREADS_HINT})"
    exit 1
fi

INSTALL_DIR="/opt/xmrig"
BUILD_DIR="/tmp/xmrig-build"

echo ""
echo "⛏️  XMRig + MoneroOcean — Automated Setup"
echo "=========================================="
echo "  Wallet:     ${WALLET_ADDRESS:0:12}...${WALLET_ADDRESS: -8}"
echo "  Worker:     ${WORKER_NAME}"
echo "  Threads:    ${MAX_THREADS_HINT}%"
echo "  Pool:       gulf.moneroocean.stream:443 (TLS)"
echo "  Install:    ${INSTALL_DIR}"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# 1. Install build dependencies
# ══════════════════════════════════════════════════════════════════════════
step "1/7  Installing build dependencies"

apt-get update -qq

PACKAGES=(
    git cmake gcc g++ make automake libtool autoconf
    libssl-dev libhwloc-dev libmicrohttpd-dev libuv1-dev
    curl
)

# Check which packages are already installed
MISSING=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "${pkg}" &>/dev/null; then
        MISSING+=("${pkg}")
    fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    info "SKIP" "All build dependencies already installed"
else
    info "INSTALL" "${MISSING[*]}"
    apt-get install -y -qq "${MISSING[@]}"
fi

# ══════════════════════════════════════════════════════════════════════════
# 2. Create system user
# ══════════════════════════════════════════════════════════════════════════
step "2/7  Creating xmrig system user"

if id xmrig &>/dev/null; then
    info "SKIP" "User 'xmrig' already exists"
else
    useradd --system --shell /usr/sbin/nologin --create-home --home-dir "${INSTALL_DIR}" xmrig
    info "CREATE" "System user 'xmrig' with home ${INSTALL_DIR}"
fi

# Ensure directory exists with correct ownership regardless
mkdir -p "${INSTALL_DIR}"
chown xmrig:xmrig "${INSTALL_DIR}"
chmod 755 "${INSTALL_DIR}"

# ══════════════════════════════════════════════════════════════════════════
# 3. Build and install XMRig
# ══════════════════════════════════════════════════════════════════════════
step "3/7  Building XMRig from source"

if [[ -x "${INSTALL_DIR}/xmrig" ]]; then
    EXISTING_VERSION=$("${INSTALL_DIR}/xmrig" --version 2>/dev/null | head -1 || echo "unknown")
    warn "SKIP" "XMRig binary already exists at ${INSTALL_DIR}/xmrig (${EXISTING_VERSION})"
    warn "     " "To rebuild, remove it first: rm ${INSTALL_DIR}/xmrig"
else
    # Clean build directory
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    info "CLONE" "https://github.com/xmrig/xmrig.git → ${BUILD_DIR}/xmrig"
    git clone --depth 1 https://github.com/xmrig/xmrig.git "${BUILD_DIR}/xmrig"

    info "BUILD" "cmake + make -j$(nproc) (this may take a few minutes)"
    mkdir -p "${BUILD_DIR}/xmrig/build"
    cd "${BUILD_DIR}/xmrig/build"
    cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON > /dev/null 2>&1
    make -j"$(nproc)"

    # Install binary
    cp "${BUILD_DIR}/xmrig/build/xmrig" "${INSTALL_DIR}/xmrig"
    chown xmrig:xmrig "${INSTALL_DIR}/xmrig"
    chmod 755 "${INSTALL_DIR}/xmrig"
    info "INSTALL" "${INSTALL_DIR}/xmrig"

    # Cleanup build artifacts
    rm -rf "${BUILD_DIR}"
    info "CLEAN" "Removed build directory"
fi

# ══════════════════════════════════════════════════════════════════════════
# 4. Configure hugepages
# ══════════════════════════════════════════════════════════════════════════
step "4/7  Configuring hugepages + MSR"

# Calculate hugepages: 1 per mining thread (2 MB each) + RandomX dataset (~256 pages)
# Use 1280 as a safe default for up to 36 threads — auto-detects actual thread count
HUGEPAGES_CONF="/etc/sysctl.d/50-xmrig-hugepages.conf"
NPROC=$(nproc)
# RandomX dataset = 2080 MB → 1040 hugepages; + 1 per thread; + some overhead
HP_COUNT=$(( 1040 + NPROC + 16 ))

if [[ -f "${HUGEPAGES_CONF}" ]]; then
    CURRENT_HP=$(grep -oP 'vm.nr_hugepages=\K[0-9]+' "${HUGEPAGES_CONF}" 2>/dev/null || echo "0")
    if (( CURRENT_HP >= HP_COUNT )); then
        info "SKIP" "${HUGEPAGES_CONF} already configured (${CURRENT_HP} pages)"
    else
        echo "vm.nr_hugepages=${HP_COUNT}" > "${HUGEPAGES_CONF}"
        info "UPDATE" "${HUGEPAGES_CONF} → ${HP_COUNT} pages (${NPROC} CPUs detected)"
    fi
else
    echo "vm.nr_hugepages=${HP_COUNT}" > "${HUGEPAGES_CONF}"
    info "CREATE" "${HUGEPAGES_CONF} → ${HP_COUNT} pages (${NPROC} CPUs detected)"
fi

sysctl --system > /dev/null 2>&1
HP_ACTUAL=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
info "OK" "HugePages_Total: ${HP_ACTUAL} ($(( HP_ACTUAL * 2 )) MB)"

# ── MSR module ────────────────────────────────────────────────────────────
MSR_CONF="/etc/modules-load.d/msr.conf"
if [[ -f "${MSR_CONF}" ]]; then
    info "SKIP" "${MSR_CONF} already exists"
else
    echo "msr" > "${MSR_CONF}"
    info "CREATE" "${MSR_CONF}"
fi

modprobe msr 2>/dev/null || warn "WARN" "Could not load MSR module (may not be available on this kernel)"

# ── MSR udev rule (group access for xmrig user) ──────────────────────────
UDEV_MSR="/etc/udev/rules.d/50-msr.rules"

groupadd -f msr
if id -nG xmrig 2>/dev/null | grep -qw msr; then
    info "SKIP" "User 'xmrig' already in 'msr' group"
else
    usermod -aG msr xmrig
    info "CREATE" "Added 'xmrig' to 'msr' group"
fi

if [[ -f "${UDEV_MSR}" ]]; then
    info "SKIP" "${UDEV_MSR} already exists"
else
    echo 'KERNEL=="msr[0-9]*", GROUP="msr", MODE="0660"' > "${UDEV_MSR}"
    udevadm control --reload-rules
    udevadm trigger
    info "CREATE" "${UDEV_MSR} → /dev/cpu/*/msr readable by msr group"
fi

# ── Kernel lockdown warning (Ubuntu 24.04 + Secure Boot) ─────────────────
LOCKDOWN=$(cat /sys/kernel/security/lockdown 2>/dev/null || echo "unknown")
if [[ "${LOCKDOWN}" == *"[integrity]"* ]] || [[ "${LOCKDOWN}" == *"[confidentiality]"* ]]; then
    warn "WARN" "Kernel lockdown is active: ${LOCKDOWN}"
    warn "     " "MSR writes will be blocked → ~10-15% lower hashrate."
    warn "     " "To disable: add 'lockdown=none' to GRUB_CMDLINE_LINUX in /etc/default/grub"
    warn "     " "then run 'update-grub && reboot'. Only do this if you understand the risk."
fi

# ══════════════════════════════════════════════════════════════════════════
# 5. Write XMRig configuration
# ══════════════════════════════════════════════════════════════════════════
step "5/7  Writing XMRig configuration"

CONFIG_FILE="${INSTALL_DIR}/config.json"

if [[ -f "${CONFIG_FILE}" ]]; then
    # Back up existing config before overwriting
    BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${CONFIG_FILE}" "${BACKUP}"
    warn "BACKUP" "Existing config saved to ${BACKUP}"
fi

cat > "${CONFIG_FILE}" <<EOF
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "hw-aes": true,
        "priority": 0,
        "asm": true,
        "max-threads-hint": ${MAX_THREADS_HINT}
    },
    "opencl": false,
    "cuda": false,
    "pools": [
        {
            "url": "gulf.moneroocean.stream:443",
            "user": "${WALLET_ADDRESS}",
            "pass": "${WORKER_NAME}",
            "tls": true,
            "keepalive": true,
            "nicehash": false,
            "algo": null,
            "coin": null
        }
    ],
    "donate-level": 1,
    "donate-over-proxy": 1,
    "log-file": "${INSTALL_DIR}/xmrig.log",
    "print-time": 60,
    "retries": 5,
    "retry-pause": 5,
    "health-print-time": 60,
    "colors": true,
    "randomx": {
        "init": -1,
        "init-avx2": -1,
        "mode": "auto",
        "1gb-pages": true,
        "rdmsr": true,
        "wrmsr": true,
        "cache_qos": true,
        "numa": true
    },
    "http": {
        "enabled": true,
        "host": "0.0.0.0",
        "port": 18088,
        "access-token": null,
        "restricted": true
    }
}
EOF

chown xmrig:xmrig "${CONFIG_FILE}"
chmod 600 "${CONFIG_FILE}"
info "CREATE" "${CONFIG_FILE}"

# ══════════════════════════════════════════════════════════════════════════
# 6. Install systemd service unit
# ══════════════════════════════════════════════════════════════════════════
step "6/7  Installing systemd service"

UNIT_FILE="/etc/systemd/system/xmrig.service"

cat > "${UNIT_FILE}" << 'EOF'
[Unit]
Description=XMRig Monero Miner (MoneroOcean)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xmrig
Group=xmrig
ExecStart=/opt/xmrig/xmrig --config /opt/xmrig/config.json
Restart=on-failure
RestartSec=15
Nice=19
CPUSchedulingPolicy=batch

# MSR access for RandomX optimisation
ExecStartPre=/bin/sh -c '/usr/sbin/modprobe msr 2>/dev/null; exit 0'
AmbientCapabilities=CAP_SYS_RAWIO
CapabilityBoundingSet=CAP_SYS_RAWIO

# Hugepages
LimitMEMLOCK=infinity

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=xmrig

# Hardening
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/opt/xmrig
PrivateTmp=true
ProtectKernelModules=false
ProtectKernelTunables=false

[Install]
WantedBy=multi-user.target
EOF

info "CREATE" "${UNIT_FILE}"
systemctl daemon-reload

# ══════════════════════════════════════════════════════════════════════════
# 7. Enable and start
# ══════════════════════════════════════════════════════════════════════════
step "7/7  Starting XMRig"

# If already running, restart to pick up new config
if systemctl is-active --quiet xmrig.service; then
    systemctl restart xmrig.service
    info "RESTART" "xmrig.service (picked up new config)"
else
    systemctl enable --now xmrig.service
    info "START" "xmrig.service enabled and started"
fi

# Brief pause then check if it's still running
sleep 3
if systemctl is-active --quiet xmrig.service; then
    info "OK" "xmrig.service is running"
else
    err "FAIL" "xmrig.service failed to start — check: journalctl -u xmrig -n 50 --no-pager"
fi

# ══════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "=========================================="
echo -e "${GREEN}✅ XMRig setup complete!${NC}"
echo ""
echo "Verify mining:"
echo "  journalctl -u xmrig -f --no-pager"
echo "  tail -f ${INSTALL_DIR}/xmrig.log"
echo "  curl -s http://127.0.0.1:18088/1/summary | python3 -m json.tool"
echo ""
echo "MoneroOcean dashboard:"
echo "  https://moneroocean.stream → paste your wallet address"
echo "  (shares may take 5-10 minutes to appear)"
echo ""
echo "Service management:"
echo "  sudo systemctl stop xmrig       # stop mining"
echo "  sudo systemctl start xmrig      # start mining"
echo "  sudo systemctl restart xmrig    # restart (after config change)"
echo "  sudo systemctl status xmrig     # quick status"
echo ""
echo "Optional — enable Prometheus/Grafana monitoring:"
echo "  cd services/monitoring && docker compose up -d --build"
echo "  curl -s http://127.0.0.1:9189/metrics | grep xmrig_up"
echo ""
echo "Optional — 1 GB hugepages (better RandomX performance, requires reboot):"
echo "  Edit /etc/default/grub → add to GRUB_CMDLINE_LINUX: hugepagesz=1G hugepages=3"
echo "  sudo update-grub && sudo reboot"
echo ""
