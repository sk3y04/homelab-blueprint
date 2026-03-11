# ⛏️ Monero Full Node, Ledger Wallet & XMRig Mining

---


## Guide 1: Monero Full Node (`monerod`)

### 1.1 — Create System User

```bash
sudo useradd --system --shell /usr/sbin/nologin --create-home --home-dir /opt/monero monero
```

> ⚠️ If `/opt/monero` already existed before `useradd` ran, `--create-home` will **not** change its ownership. Verify and fix:
> ```bash
> sudo chown monero:monero /opt/monero
> sudo chmod 755 /opt/monero
> ```
> Without this, monerod will fail with **exit code 203/EXEC** ("Permission denied") because the `monero` user cannot traverse into its own home directory.

### 1.2 — Install Monero CLI

Rocky Linux 10 does not package Monero in base repos or EPEL. Download the official release from GitHub:

```bash
cd /tmp
MONERO_VERSION="v0.18.4.5"

# Download binary from the official source
# If this 404s, grab the exact filename from https://www.getmonero.org/downloads/#cli
curl -fSL "https://downloads.getmonero.org/cli/monero-linux-x64-${MONERO_VERSION}.tar.bz2" -o monero.tar.bz2

# Download the signed hashes file (from the monero-site GitHub repo)
# getmonero.org blocks direct curl requests — use the raw GitHub source instead
curl -fSL "https://raw.githubusercontent.com/monero-project/monero-site/master/downloads/hashes.txt" -o hashes.txt
```

⚠️ **Verify the GPG signature and SHA256 hash** — never skip this:

```bash
# Import binaryFate's key (Monero release signing key)
# Use keyserver.ubuntu.com — keys.openpgp.org strips user IDs and will fail
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92

# Verify the clearsigned hashes file (look for "Good signature")
gpg --verify hashes.txt

# Verify the downloaded binary matches the signed hash
EXPECTED_HASH=$(grep "monero-linux-x64-${MONERO_VERSION}.tar.bz2" hashes.txt | head -1 | awk '{print $1}')
echo "${EXPECTED_HASH}  monero.tar.bz2" | sha256sum -c
```

> ⚠️ `gpg --verify` must print **"Good signature from binaryFate"**. If it says "BAD signature" or the key import failed, **do not proceed**. If `sha256sum` prints `monero.tar.bz2: OK`, the binary is authentic.

If verification succeeds:

```bash
tar xjf monero.tar.bz2
sudo cp monero-x86_64-linux-gnu-${MONERO_VERSION}/monero* /opt/monero/
sudo chown -R monero:monero /opt/monero/
sudo chmod 755 /opt/monero
```

> ⚠️ The `chmod 755` on the directory itself is critical — systemd's `User=monero` must be able to traverse `/opt/monero/` to exec the binary. Without it you get **203/EXEC "Permission denied"** even though the binary has correct permissions.

### 1.3 — Create Data Directory

The Monero blockchain is ~200 GB. Use the RAID6 array or `/home` partition (390 GB) — do **not** put it on the 70 GB root:

```bash
# Option A: /home/monero/.bitmonero (390 GB /home partition)
sudo mkdir -p /home/monero/.bitmonero
sudo chown monero:monero /home/monero/.bitmonero

# Option B: RAID6 mount (if you have a mount point like /mnt/external/raid6)
# sudo mkdir -p /mnt/external/raid6/monero-blockchain
# Then pass --data-dir in the service unit
```

> ❓ Adjust the `--data-dir` path to match your actual mount point. If you have a large storage array (RAID, NAS, external drive) mounted at a custom path, Option B gives you the most headroom.

### 1.4 — Systemd Service Unit

```bash
sudo tee /etc/systemd/system/monerod.service << 'EOF'
[Unit]
Description=Monero Full Node (monerod)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=monero
Group=monero
ExecStart=/opt/monero/monerod \
    --data-dir /home/monero/.bitmonero \
    --log-file /home/monero/.bitmonero/monerod.log \
    --log-level 0 \
    --non-interactive \
    --restricted-rpc \
    --rpc-bind-ip 127.0.0.1 \
    --rpc-bind-port 18081 \
    --confirm-external-bind \
    --p2p-bind-ip 0.0.0.0 \
    --p2p-bind-port 18080 \
    --out-peers 32 \
    --in-peers 64 \
    --limit-rate-up 1048576 \
    --limit-rate-down 1048576 \
    --db-sync-mode safe:sync \
    --enforce-dns-checkpointing \
    --enable-dns-blocklist \
    --prune-blockchain

Restart=on-failure
RestartSec=30
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
LimitNOFILE=65536

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=false
ReadWritePaths=/home/monero/.bitmonero
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
```

> ⚠️ `--prune-blockchain` reduces disk usage from ~200 GB to ~70 GB. Remove this flag if you want a full archival node and have the storage.

> ⚠️ RPC is restricted to `127.0.0.1:18081` — only local processes (your wallet, XMRig) can reach it. Never bind RPC to `0.0.0.0` without authentication.

### 1.5 — Firewall Rules (firewalld)

```bash
# P2P port — allow inbound so other nodes can connect to you
sudo firewall-cmd --permanent --add-port=18080/tcp

# RPC should NOT be opened — it's localhost-only
# Reload
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

> ⚠️ If SELinux is enforcing, allow monerod to bind its ports:

```bash
sudo semanage port -a -t unreserved_port_t -p tcp 18080
sudo semanage port -a -t unreserved_port_t -p tcp 18081
```

> ❓ MISSING: If `semanage` is not installed: `sudo dnf install policycoreutils-python-utils`

### 1.6 — Enable and Start

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now monerod.service
```

### 1.7 — Check Sync Status and Tail Logs

```bash
# Sync status (query the running daemon's RPC)
curl -s http://127.0.0.1:18081/get_info | python3 -m json.tool | grep -E "height|target_height|synchronized"

# Compact one-liner: current height / target height
curl -s http://127.0.0.1:18081/get_info | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f\"Height: {d['height']}/{d['target_height']} ({d['height']/d['target_height']*100:.1f}%) — {'SYNCED' if d.get('synchronized') else 'SYNCING'}\")"

# Tail logs
tail -f /home/monero/.bitmonero/monerod.log

# Journal
journalctl -u monerod -f --no-pager
```

> ⚠️ Do **not** use `monerod status` to query a running daemon — it spawns a second process that conflicts on the RPC port. Always use `curl` against `127.0.0.1:18081`.

### 1.8 — (Optional) Add monerod to Prometheus Monitoring

Since your monitoring stack scrapes via the `172.17.0.1` Docker bridge gateway, and monerod binds RPC to `127.0.0.1:18081`, Prometheus can scrape it from the host.

Append to `services/monitoring/config/prometheus.yml`:

```yaml
  - job_name: "monerod"
    metrics_path: /get_info
    static_configs:
      - targets: ["172.17.0.1:18081"]
```

> ⚠️ `/get_info` is not a Prometheus-native endpoint. For proper metrics, consider running [monerod-exporter](https://github.com/ExcitableAardvark/monerod-prometheus-exporter) as a sidecar and scraping that instead.

---

## Guide 2: Ledger Nano S Plus + `monero-wallet-cli`

### 2.1 — Install udev Rules for Ledger

Create the `ledger` group first — needed for USB access over SSH (where `uaccess` tags don't apply):

```bash
sudo groupadd -f ledger
sudo usermod -aG ledger $(whoami)
```

Write the udev rules with `GROUP="ledger"` included:

```bash
sudo tee /etc/udev/rules.d/20-hw1.rules << 'EOF'
# Ledger Nano S+ (product ID 0005 in app mode)
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", ATTRS{idProduct}=="0005", MODE="0660", GROUP="ledger", TAG+="uaccess", TAG+="udev-acl"
# Ledger Nano S+ — bootloader and other interfaces
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", ATTRS{idProduct}=="0004", MODE="0660", GROUP="ledger", TAG+="uaccess", TAG+="udev-acl"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", ATTRS{idProduct}=="50*", MODE="0660", GROUP="ledger", TAG+="uaccess", TAG+="udev-acl"
# Ledger — generic HID (covers all Ledger devices)
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", MODE="0660", GROUP="ledger", TAG+="uaccess", TAG+="udev-acl"
KERNEL=="hidraw*", ATTRS{idVendor}=="2c97", MODE="0660", GROUP="ledger", TAG+="uaccess", TAG+="udev-acl"
EOF
```

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**Log out and back in** (or `newgrp ledger`) for group membership to take effect.

> ⚠️ The `TAG+="uaccess"` directive grants access to physically logged-in users. Over SSH, `uaccess` does **not** apply — that's why `GROUP="ledger"` is essential. Without it, the hidraw devices will be `root:root` and the wallet CLI will fail with `Unable to open device`.

### 2.2 — Verify USB Detection

Plug in the Ledger Nano S Plus:

```bash
lsusb | grep -i "2c97"
```

Expected output:

```
Bus 002 Device 004: ID 2c97:0005 Ledger Nano S+
```

If nothing appears: check cable (must be data-capable USB-C), try a different port, check `dmesg | tail -20`.

### 2.3 — Generate Wallet from Ledger Device

Create the wallet directory first (owned by your interactive user, not the `monero` service account):

```bash
sudo mkdir -p /opt/monero/wallets
sudo chown $(whoami):$(whoami) /opt/monero/wallets
sudo chmod 700 /opt/monero/wallets
```

**Prerequisites** — all four must be true before running the command:
1. Ledger is plugged in and **unlocked** (PIN entered)
2. **Monero app** is open on the Ledger (version ≥ 1.8.0 — check Ledger Live)
3. The Ledger screen shows **"Monero"** with **"Application is ready"** — if it's showing a menu or settings, back out to the idle screen
4. Inside the Monero app settings on the Ledger, **"Blind signing"** is set to **Enabled** (navigate with buttons while in the app)
5. `monerod` is running (synced or still syncing — at least reachable on `127.0.0.1:18081`)

> ⚠️ **Do NOT use `sudo`** to run the wallet command. The Ledger udev rules grant USB access to your user (via the `ledger` group), not to root. Running with `sudo` changes the HID context and causes `0x5515` device errors.

```bash
/opt/monero/monero-wallet-cli \
    --generate-from-device /opt/monero/wallets/ledger-wallet \
    --daemon-address 127.0.0.1:18081 \
    --subaddress-lookahead 3:200 \
    --restore-height 0
```

The CLI will:
1. Ask for a **new wallet password** — this encrypts the local wallet cache only (not the Ledger)
2. Prompt **"Export View Key?"** on the Ledger display — **confirm it** on the device
3. Derive subaddresses (takes 1–3 minutes with `3:200` lookahead)

> ⚠️ `--subaddress-lookahead 3:200` — the default `50:200` will take extremely long on a Ledger (hardware key derivation is slow). Use `3:200` for initial setup. You can regenerate with a higher lookahead later if you need more subaddress accounts.

> ⚠️ `--restore-height 0` — if this is a **new** wallet, set this to the current blockchain height to skip scanning all historical blocks. Check current height:
> ```bash
> curl -s http://127.0.0.1:18081/get_info | python3 -m json.tool | grep height
> ```

### 2.4 — Open Existing Ledger Wallet

```bash
/opt/monero/monero-wallet-cli \
    --wallet-file /opt/monero/wallets/ledger-wallet \
    --daemon-address 127.0.0.1:18081
```

The Ledger must be plugged in, unlocked, and with the Monero app open.

### 2.5 — Get Your Wallet Address (for XMRig)

Once inside `monero-wallet-cli`:

```
address
```

Copy the primary address (starts with `4`). You will need this for Guide 3.

### 2.6 — Common Failure Points

| Symptom | Cause | Fix |
|---|---|---|
| `Wrong Device Status: 0x5515` | Ledger not in correct state or ran with `sudo` | 1) Don't use `sudo` 2) Ensure Monero app is open and showing idle screen 3) Enable "Blind signing" in Monero app settings on Ledger |
| `Unable to open device` | USB HID permissions — hidraw device not group-accessible | Verify udev rules include `GROUP="ledger"`, user is in `ledger` group, and `ls -la /dev/hidraw*` shows `root:ledger`. Unplug/replug Ledger after rule changes. |
| `No device found` | Ledger locked / Monero app not open | Unlock Ledger, open Monero app, try again |
| `No device found` (SSH session) | `uaccess` tag doesn't apply over SSH | Add user to `ledger` group per §2.1 |
| `Transport error` | Old Monero app on Ledger | Update via Ledger Live to ≥ 1.8.0 |
| `Error opening wallet: Device not connected` | Ledger disconnected or timed out | Reconnect, reopen Monero app, retry |
| `Wallet derivation very slow` | High subaddress-lookahead value | Use `--subaddress-lookahead 3:200` |
| `Error: wallet failed to connect to daemon` | monerod not running or not synced | `systemctl status monerod`, check sync |
| `Wrong network type` | CLI defaulting to mainnet/testnet mismatch | Don't pass `--testnet` or `--stagenet` unless testing |
| SELinux blocks USB access | SELinux policy conflict | `ausearch -m avc -ts recent`, then create a local policy module or set permissive for troubleshooting |

---

## Guide 3: XMRig + MoneroOcean Mining

### 3.1 — Create System User

```bash
sudo useradd --system --shell /usr/sbin/nologin --create-home --home-dir /opt/xmrig xmrig
```

### 3.2 — Install XMRig

XMRig is not in Rocky Linux repos. Build from source for optimal performance (enables CPU-specific optimizations):

```bash
# Install build dependencies
sudo dnf install -y git cmake gcc gcc-c++ make automake libtool autoconf \
    openssl-devel hwloc-devel libmicrohttpd-devel libuv-devel libstdc++-static

# Clone and build
cd /tmp
git clone https://github.com/xmrig/xmrig.git
cd xmrig
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_HWLOC=ON
make -j$(nproc)

# Install
sudo cp xmrig /opt/xmrig/
sudo chown -R xmrig:xmrig /opt/xmrig/
sudo chmod 755 /opt/xmrig /opt/xmrig/xmrig
```

> ⚠️ Building from source with `-march=native` (default) generates CPU-specific instructions. If you move the binary to a different machine, rebuild there.

### 3.3 — Configure Hugepages

Hugepages significantly improve RandomX hash rate. Allocate 1 hugepage (2 MB) per mining thread plus overhead for the RandomX dataset:

```bash
# Enable 1280 x 2MB hugepages (2.5 GB — enough for 36 threads + RX dataset)
sudo tee /etc/sysctl.d/50-xmrig-hugepages.conf << 'EOF'
vm.nr_hugepages=1280
EOF

sudo sysctl --system
```

Verify:

```bash
grep -i hugepages /proc/meminfo
```

Expected: `HugePages_Total: 1280`, `HugePages_Free:` close to 1280.

> ⚠️ 1280 hugepages = 2560 MB. Scale this up or down based on your thread count (1 page per thread + ~1040 for the RandomX dataset). Check available RAM with `free -h` before allocating.

For 1GB hugepages (better for RandomX but requires boot parameter):

```bash
sudo grubby --update-kernel=ALL --args="hugepagesz=1G hugepages=3"
```

Then reboot. XMRig will auto-detect and prefer 1GB pages.

### 3.4 — MSR Module (Boost RandomX Performance)

The MSR (Model-Specific Register) wrmsr mod provides +10-15% hashrate on Intel CPUs:

```bash
sudo modprobe msr
echo "msr" | sudo tee /etc/modules-load.d/msr.conf
```

XMRig will attempt to write MSR registers at startup if it detects the module. The systemd unit grants the needed capability.

> ⚠️ **`FAILED TO APPLY MSR MOD, HASHRATE WILL BE LOW`** — the `xmrig` system user cannot open `/dev/cpu/*/msr` (defaults to `root:root 0600`). Fix with a udev rule granting group access:
> ```bash
> sudo groupadd -f msr
> sudo usermod -aG msr xmrig
> echo 'KERNEL=="msr[0-9]*", GROUP="msr", MODE="0660"' | sudo tee /etc/udev/rules.d/50-msr.rules
> sudo udevadm control --reload-rules && sudo udevadm trigger
> ls -la /dev/cpu/0/msr   # should show root:msr crw-rw----
> sudo systemctl restart xmrig
> ```
> After restart you will see lines like `cannot set MSR 0x00000c91` — **this is normal and harmless**. MSR `0xC91` (hardware prefetch control) is read-only on Xeon E5 v4. XMRig tries every register in the intel preset and declares success once the critical ones are written. Confirm success with:
> ```bash
> journalctl -u xmrig | grep "register values"
> # Expected: register values for "intel" preset have been set successfully
> ```
>
> If you still see `FAILED TO APPLY` after the udev fix, check kernel lockdown (`cat /sys/kernel/security/lockdown` — must show `[none]`) and SELinux denials (`sudo ausearch -m avc -ts recent | grep msr`).
>
> XMRig will mine correctly without the MSR mod — you just lose ~10-15% hashrate.

### 3.5 — XMRig Configuration

```bash
sudo tee /opt/xmrig/config.json << XMRIG_EOF
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "hw-aes": true,
        "priority": 0,
        "asm": true,
        "max-threads-hint": 75
    },
    "opencl": false,
    "cuda": false,
    "pools": [
        {
            "url": "gulf.moneroocean.stream:443",
            "user": "YOUR_WALLET_ADDRESS",
            "pass": "$(hostname)",
            "tls": true,
            "keepalive": true,
            "nicehash": false,
            "algo": null,
            "coin": null
        }
    ],
    "donate-level": 1,
    "donate-over-proxy": 1,
    "log-file": "/opt/xmrig/xmrig.log",
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
XMRIG_EOF

sudo chown xmrig:xmrig /opt/xmrig/config.json
sudo chmod 600 /opt/xmrig/config.json
```

> ⚠️ **Replace `YOUR_WALLET_ADDRESS_FROM_GUIDE_2`** with the primary address from `monero-wallet-cli` → `address` (starts with `4`).

> The `"pass"` field is the **worker name** shown on MoneroOcean dashboard. It expands to your machine's hostname at install time via `$(hostname)`.

> `"max-threads-hint": 75` uses ~27 of 36 threads, leaving headroom for Docker services. Tune up/down based on load.

> ⚠️ **Port 443 is used instead of MoneroOcean's native 10128/20128.** If your traffic routes through a VPS/firewall or restrictive network, non-standard ports may be blocked outbound. Port 443 (TLS) is almost universally allowed. MoneroOcean supports it fully.

### 3.6 — Systemd Service Unit

```bash
sudo tee /etc/systemd/system/xmrig.service << 'EOF'
[Unit]
Description=XMRig Monero Miner (MoneroOcean)
After=network-online.target monerod.service
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

# MSR access for RandomX optimization
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
```

> ⚠️ `ProtectKernelTunables=false` and `ProtectKernelModules=false` are required for MSR access. If you don't care about the +10-15% MSR boost, set both to `true` and remove the `AmbientCapabilities`/`CapabilityBoundingSet`/`ExecStartPre` lines.

### 3.7 — Firewall Rules

XMRig makes **outbound** connections to the pool — no inbound ports needed:

```bash
# Nothing to open — XMRig connects outbound to MoneroOcean
# The HTTP API binds to 0.0.0.0:18088 so the Docker-based exporter can
# reach it via 172.17.0.1 — do NOT open this port in firewalld.
# firewalld blocks it externally; only Docker bridge + localhost can reach it.
```

### 3.8 — Enable and Start

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now xmrig.service
```

### 3.9 — Verify Hash Rate and Shares

```bash
# Journal logs
journalctl -u xmrig -f --no-pager

# XMRig log file
tail -f /opt/xmrig/xmrig.log

# HTTP API (if enabled in config.json)
curl -s http://127.0.0.1:18088/1/summary | python3 -m json.tool
```

**MoneroOcean Dashboard:**

Open `https://moneroocean.stream` in a browser. Paste your wallet address in the search/dashboard field. It can take 5–10 minutes after first share for stats to appear.

### 3.10 — Add XMRig to Prometheus Monitoring

XMRig's HTTP API returns JSON, not Prometheus text format. A lightweight exporter container translates the JSON into scrapeable metrics. The exporter, Dockerfile, Prometheus scrape job, and Grafana dashboard are all pre-wired in the `services/monitoring/` tree — just rebuild and restart.

**What was added** (already committed in the blueprint):

| File | Purpose |
|---|---|
| `services/monitoring/xmrig-exporter/exporter.py` | Python exporter — queries XMRig `/1/summary`, emits Prometheus text metrics on `:9189/metrics` |
| `services/monitoring/xmrig-exporter/Dockerfile` | Alpine Python 3.12 container (no external deps) |
| `services/monitoring/config/prometheus.yml` | New `xmrig` scrape job targeting `xmrig-exporter:9189` |
| `services/monitoring/config/grafana/provisioning/dashboards/xmrig-mining.json` | Grafana dashboard — hashrate over time, shares, reject rate, pool connection, hugepage allocation |

**Exposed metrics** (all prefixed `xmrig_`):

| Metric | Type | Description |
|---|---|---|
| `xmrig_up` | gauge | `1` if XMRig API is reachable, `0` otherwise |
| `xmrig_hashrate_hashes_per_second{window}` | gauge | Hashrate — `10s`, `60s`, `15m` windows |
| `xmrig_hashrate_highest_hashes_per_second` | gauge | Peak hashrate since start |
| `xmrig_shares_good_total` | counter | Accepted shares |
| `xmrig_shares_total` | counter | Total shares (good + bad) |
| `xmrig_shares_avg_time_seconds` | gauge | Average time between shares |
| `xmrig_hashes_total` | counter | Total hashes computed |
| `xmrig_difficulty_current` | gauge | Current mining difficulty |
| `xmrig_connection_uptime_seconds` | gauge | Pool connection uptime |
| `xmrig_connection_ping_ms` | gauge | Pool RTT |
| `xmrig_connection_failures_total` | counter | Connection failures |
| `xmrig_connection_accepted_total` | counter | Pool-accepted shares |
| `xmrig_connection_rejected_total` | counter | Pool-rejected shares |
| `xmrig_uptime_seconds` | gauge | Miner process uptime |
| `xmrig_paused` | gauge | `1` if mining paused |
| `xmrig_hugepages_allocated` | gauge | Hugepages successfully allocated |
| `xmrig_hugepages_requested` | gauge | Hugepages requested |
| `xmrig_memory_resident_bytes` | gauge | Miner RSS |
| `xmrig_info{version,algo,worker_id,pool,tls}` | gauge | Build & runtime labels (constant `1`) |

**Deploy:**

```bash
cd services/monitoring

# Build the exporter image and restart the full stack
docker compose up -d --build
```

**Verify the exporter is running:**

```bash
# Health check
curl -s http://127.0.0.1:9189/health

# Raw Prometheus metrics (should show xmrig_up 1 if XMRig is running)
curl -s http://127.0.0.1:9189/metrics | head -30
```

**Verify Prometheus is scraping it:**

Open Grafana → Explore → Prometheus → query `xmrig_hashrate_hashes_per_second`. Or check targets directly:

```bash
curl -s http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/targets | python3 -m json.tool | grep xmrig
```

**Grafana dashboard:** The "XMRig Mining" dashboard auto-provisions on restart (in the "Homelab" folder). Panels include hashrate time series, share reject rate gauge, pool connection stats, and hugepage allocation.

> ⚠️ The XMRig HTTP API must be reachable from Docker. Section 3.5 binds it to `0.0.0.0:18088` — firewalld does **not** open this port, so only Docker bridge traffic and localhost can reach it. If you prefer locking it to localhost, use `network_mode: host` on the exporter container instead and change the `XMRIG_URL` to `http://127.0.0.1:18088`.

---

## Integration Checklist

Bring everything up from zero to mining in order:

1. **Install build dependencies and tools:**
   ```bash
   sudo dnf install -y git cmake gcc gcc-c++ make automake libtool autoconf \
       openssl-devel hwloc-devel libmicrohttpd-devel libuv-devel \
       libstdc++-static policycoreutils-python-utils
   ```

2. **Create system users:**
   ```bash
   sudo useradd --system --shell /usr/sbin/nologin --create-home --home-dir /opt/monero monero
   sudo useradd --system --shell /usr/sbin/nologin --create-home --home-dir /opt/xmrig xmrig
   ```

3. **Download, verify, and install Monero CLI** (Guide 1, §1.2)

4. **Create blockchain data directory** on `/home` or RAID (Guide 1, §1.3)

5. **Deploy `monerod.service`** and start sync (Guide 1, §1.4–1.6) — this takes hours/days:
   ```bash
   sudo systemctl enable --now monerod.service
   journalctl -u monerod -f
   ```

6. **Open P2P port** in firewalld (Guide 1, §1.5):
   ```bash
   sudo firewall-cmd --permanent --add-port=18080/tcp && sudo firewall-cmd --reload
   ```

7. **Wait for monerod to fully sync** — monitor with:
   ```bash
   curl -s http://127.0.0.1:18081/get_info | python3 -m json.tool | grep -E "height|target_height"
   ```

8. **Install Ledger udev rules** (Guide 2, §2.1) — can be done while monerod syncs

9. **Generate Ledger wallet** once monerod is synced (Guide 2, §2.3):
   ```bash
   /opt/monero/monero-wallet-cli \
       --generate-from-device /opt/monero/wallets/ledger-wallet \
       --daemon-address 127.0.0.1:18081 \
       --subaddress-lookahead 3:200
   ```

10. **Copy your wallet address** from `monero-wallet-cli` → `address`

11. **Build and install XMRig** (Guide 3, §3.2)

12. **Configure hugepages and MSR** (Guide 3, §3.3–3.4):
    ```bash
    sudo sysctl --system
    sudo modprobe msr
    ```

13. **Write `config.json`** with your wallet address and worker name (Guide 3, §3.5)

14. **Deploy `xmrig.service`** and start mining (Guide 3, §3.6–3.8):
    ```bash
    sudo systemctl enable --now xmrig.service
    ```

15. **Verify on MoneroOcean dashboard** — `https://moneroocean.stream` → paste wallet address

16. **Deploy xmrig-exporter** and restart the monitoring stack:
    ```bash
    cd services/monitoring && docker compose up -d --build
    ```
    Verify: `curl -s http://127.0.0.1:9189/metrics | grep xmrig_up` → should print `xmrig_up 1`.
    Open Grafana → "XMRig Mining" dashboard.
