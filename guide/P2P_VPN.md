# 🌐 P2P VPN — Private Internet Access & Gluetun

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

This stack routes all traffic from qBittorrent and Soulseek through a WireGuard VPN tunnel managed by Gluetun. If the VPN disconnects, the connection is killed (killswitch).

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Access and Configuration](#step-3--access-and-configuration)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)

---

## Architecture

- **VPN:** Gluetun (WireGuard)
- **Torrent Client:** qBittorrent (Port `8080`)
- **P2P Music:** Soulseek (Port `6080` / `5900`)

All services route through `gluetun` network.

---

## Step 1 — DNS Record

Add a DNS record for the Torrent Web UI:

| Subdomain | Points to |
|---|---|
| `torrent.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/p2p-gluetun/docker-compose.yml](../services/p2p-gluetun/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`WIREGUARD_PRIVATE_KEY`, `VPN_SERVICE_PROVIDER`).

---

## Step 3 — Access and Configuration

1. **qBittorrent Web UI:** Open `http://<HOME_SERVER_IP>:8080` in your browser.
2. **First Run Setup:**
   - Change temporary password (`adminadmin` usually).
   - Set download folders (`/downloads`).
   - Enable encryption (Require encryption).
   - Test connection (should show green connection icon).

3. **Soulseek Web UI (Optional):**
   - Access via `http://<HOME_SERVER_IP>:6080` (noVNC).
   - Enter your Soulseek username/password.
   - Configure shared folders (`/music`).

---

## Step 4 — VPS Nginx Configuration

To access qBittorrent securely via `torrent.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream torrent_upstream {
    server 10.8.0.2:8080; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name torrent.example.com;

    # ... SSL certificates ...

    location / {
        # Highly recommended: Add Authelia protection
        auth_request /authelia;
        
        proxy_pass http://torrent_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # Websockets for real-time updates
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```
