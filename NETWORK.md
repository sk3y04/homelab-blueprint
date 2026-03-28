# 🌐 Network Architecture & Remote Access

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

This document describes a network workflow for exposing self-hosted services running on a home server to the internet — without revealing the home IP address.

---

## 📐 Architecture Overview

```
                         ┌─────────────────────────────────────┐
                         │            INTERNET                 │
                         └──────────────┬──────────────────────┘
                                        │
                                        ▼
                         ┌──────────────────────────────────┐
                         │     FreeBSD VPS (Public IP)       │
                         │                                   │
                         │   ┌───────────────────────────┐   │
                         │   │  Nginx Reverse Proxy       │   │
                         │   │  *.example.com → 10.8.0.2  │   │
                         │   │  Let's Encrypt TLS         │   │
                         │   └────────────┬──────────────┘   │
                         │                │                   │
                         │   ┌────────────▼──────────────┐   │
                         │   │  OpenVPN Tunnel            │   │
                         │   │  VPS: 10.8.0.1             │   │
                         │   └────────────┬──────────────┘   │
                         └────────────────┼──────────────────┘
                                          │ Encrypted tunnel
                                          │
                         ┌────────────────┼──────────────────┐
                         │   ┌────────────▼──────────────┐   │
                         │   │  OpenVPN Client            │   │
                         │   │  Home Server: 10.8.0.2     │   │
                         │   └────────────┬──────────────┘   │
                         │                │                   │
                         │     Home Server (Docker Host)      │
                         │                                    │
                         │   ┌──────────┐  ┌──────────────┐  │
                         │   │ Jellyfin │  │  Nextcloud    │  │
                         │   │  :8096   │  │   :80         │  │
                         │   ├──────────┤  ├──────────────┤  │
                         │   │  Code    │  │  qBittorrent  │  │
                         │   │  :8443   │  │   :8081       │  │
                         │   ├──────────┤  ├──────────────┤  │
                         │   │Guacamole │  │  Soulseek     │  │
                         │   │  :8080   │  │   :6080       │  │
                         │   ├──────────┤  ├──────────────┤  │
                         │   │Minecraft │  │ CoolerControl │  │
                         │   │ :25565   │  │  :11987       │  │
                         │   ├──────────┤  ├──────────────┤  │
                         │   │ AdGuard  │  │   Synapse     │  │
                         │   │  :53/3000│  │    :8008      │  │
                         │   ├──────────┤  ├──────────────┤  │
                         │   │ Element  │  │  Grafana      │  │
                         │   │  :8088   │  │   :3100       │  │
                         │   ├──────────┤  ├──────────────┤  │
                         │   │ BentoPDF │  │  Trilium      │  │
                         │   │  :8084   │  │   :8085       │  │
                         │   ├──────────┤  ├──────────────┤  │
                         │   │Pinchflat │  │              │  │
                         │   │  :8945   │  │              │  │
                         │   └──────────┘  └──────────────┘  │
                         │     Home Network (Hidden IP)       │
                         └────────────────────────────────────┘
```

The core idea: **the home server's public IP is never exposed**. All inbound traffic arrives at the VPS, which terminates TLS and forwards requests through an OpenVPN tunnel to the home server's Docker services.

---

## 🔑 Key Components

### 1. FreeBSD VPS — Public Entry Point

The VPS acts as the public-facing gateway. It runs:

- **Nginx** — Reverse proxy with TLS termination
- **OpenVPN Server** — Maintains a persistent encrypted tunnel to the home server

The VPS has a static public IP. DNS records for `*.example.com` point to this IP.

### 2. OpenVPN Tunnel

A site-to-site VPN connects the VPS and home server over an encrypted tunnel:

| Node | Tunnel IP |
|---|---|
| VPS (server) | `10.8.0.1` |
| Home Server (client) | `10.8.0.2` |

All reverse proxy traffic is routed through this `10.8.0.0/24` subnet. The home server's real IP never appears in any public-facing connection.

### 3. Nginx Reverse Proxy (on VPS)

Nginx runs natively on the FreeBSD VPS (not in Docker). It handles:

- **TLS termination** with Let's Encrypt certificates
- **HTTP → HTTPS redirection** for all services
- **ACME challenge** serving for automated certificate renewal
- **WebSocket upgrades** for services that need them (Jellyfin, Code Server, Guacamole, Pinchflat)
- **TCP stream proxying** for non-HTTP protocols (Minecraft)

### 4. Home Server — Docker Host

All application services run as Docker containers on the home server. Each service binds to a port on the host, reachable from the VPS via the tunnel IP `10.8.0.2`.

---

## 🌍 Domain Mapping

All services are exposed as subdomains under `example.com`, each with its own Let's Encrypt certificate:

| Subdomain | Service | Upstream (via tunnel) | Protocol |
|---|---|---|---|
| `jellyfin.example.com` | Jellyfin | `10.8.0.2:8096` | HTTPS (HTTP/2) |
| `pinchflat.example.com` | Pinchflat | `10.8.0.2:8945` | HTTPS (HTTP/2) |
| `cloud.example.com` | Nextcloud | `10.8.0.2:80` | HTTPS (HTTP/2) |
| `code.example.com` | Code Server | `10.8.0.2:8443` | HTTPS (HTTP/2) |
| `torrent.example.com` | qBittorrent | `10.8.0.2:8081` | HTTPS (HTTP/2) |
| `vm.example.com` | Apache Guacamole | `10.8.0.2:8080` | HTTPS (HTTP/2) |
| `soulseek.example.com` | Soulseek (noVNC) | `10.8.0.2:6080` | HTTPS (HTTP/2) |
| `adguard.example.com` | AdGuard Home | `10.8.0.2:3000` | HTTPS (HTTP/2) |
| `matrix.example.com` | Matrix Synapse | `10.8.0.2:8008` | HTTPS (HTTP/2) |
| `element.example.com` | Element Web | `10.8.0.2:8088` | HTTPS (HTTP/2) |
| `auth.example.com` | Authelia | `10.8.0.2:9091` | HTTPS (HTTP/2) |
| `grafana.example.com` | Grafana | `10.8.0.2:3100` | HTTPS (HTTP/2) |
| `pdf.example.com` | BentoPDF | `10.8.0.2:8084` | HTTPS (HTTP/2) |
| `notes.example.com` | TriliumNext Notes | `10.8.0.2:8085` | HTTPS (HTTP/2) |
| `example.com` | .well-known delegation | (static JSON) | HTTPS (HTTP/2) |
| — | Minecraft Server | `10.8.0.2:25565` | TCP (stream) |

> [!NOTE]
> Soulseek does not currently have an HTTPS server block — only the HTTP→HTTPS redirect and the upstream are defined. The Minecraft server uses Nginx's `stream` module for raw TCP proxying on port `25565`, since it is not an HTTP-based protocol.

---

## 🔒 TLS & Security Configuration

Every HTTPS server block enforces a hardened TLS configuration:

| Setting | Value |
|---|---|
| **Protocols** | TLSv1.2, TLSv1.3 |
| **Cipher preference** | Server-side |
| **Ciphers** | ECDHE + AES-GCM / CHACHA20-POLY1305 (forward secrecy) |
| **Session cache** | Shared, 10 MB, 10 min timeout |
| **Session tickets** | Disabled |
| **OCSP stapling** | Enabled with verification |
| **HSTS** | `max-age=31536000; includeSubDomains` |
| **X-Frame-Options** | `SAMEORIGIN` |
| **X-Content-Type-Options** | `nosniff` |
| **X-XSS-Protection** | `1; mode=block` |
| **DNS resolver** | Cloudflare (`1.1.1.1`, `1.0.0.1`) |
| **Certificates** | Let's Encrypt (auto-renewed via ACME HTTP-01 challenge) |

Certificate files are stored at `/usr/local/etc/letsencrypt/live/<domain>/` on the VPS.

---

## ⚙️ Service-Specific Proxy Notes

### Jellyfin
- Proxy buffering disabled for smooth media streaming.
- WebSocket support for real-time playback status.

### Nextcloud
- `client_max_body_size` set to **20 GB** to support large file uploads.
- `client_body_timeout` and proxy timeouts extended to **3600s** for long uploads.
- RainLoop data directory explicitly denied.

### Code Server
- WebSocket support is critical for the interactive terminal and editor.
- Extended timeouts (3600s) for long-lived sessions.

### Pinchflat
- WebSocket support is required for real-time UI updates.
- Prefer Pinchflat's built-in HTTP Basic Auth when the app is internet-facing.
- If you expose podcast / RSS feed endpoints, do not place blanket reverse-proxy auth in front of those routes unless you explicitly exempt them.

### qBittorrent
- Standard reverse proxy with 600s timeouts.

### Apache Guacamole
- WebSocket support required for remote desktop streams (RDP/VNC/SSH).
- Proxy buffering disabled for low-latency screen rendering.
- Served at `vm.example.com` — a short, memorable subdomain for remote VM access.

### Minecraft
- Proxied via Nginx's **`stream` module** (layer 4 TCP), not the HTTP module.
- Connects directly to `10.8.0.2:25565` with a 600s idle timeout.
- Exposed on the VPS's public IP at port `25565`.

### Matrix Synapse
- **`.well-known` delegation** on the base domain (`example.com`) allows Matrix IDs to be `@user:example.com` while the server runs at `matrix.example.com`.
- `/_matrix` and `/_synapse/client` are publicly accessible (no Authelia) — required for federation and client connections.
- `/_synapse/admin` is gated behind Authelia 2FA.
- `client_max_body_size` set to **50 MB** for media uploads.
- WebSocket support for real-time sync.

### Element Web
- Static SPA served by the `vectorim/element-web` container.
- Protected by Authelia 2FA (login required before accessing the chat client).
- Configured via `config.json` to point at the local Synapse homeserver.

### Grafana (Monitoring)
- WebSocket support for Grafana Live real-time streaming.
- Protected by Authelia 2FA.
- Grafana auth proxy enabled — the `Remote-User` header from Authelia provides SSO.
- Prometheus, Loki, and Node Exporter are **not** reverse-proxied — they are bound to `127.0.0.1` on the home server and only reachable by Grafana on the internal Docker network.

### TriliumNext Notes
- WebSocket support required for real-time sync with desktop clients and live note updates.
- Protected by Authelia 2FA.
- Embedded SQLite database — no external DB service needed, all data in a single directory.
- Desktop client sync connects via the same HTTPS endpoint; Authelia may require browser-based auth before sync starts.

---

## 🔄 Request Flow

A typical HTTPS request follows this path:

```
User's Browser
      │
      ▼
DNS resolves jellyfin.example.com → VPS public IP
      │
      ▼
VPS Nginx (port 443)
  ├─ TLS handshake (Let's Encrypt cert)
  ├─ HTTP/2 negotiation
  ├─ Adds X-Forwarded-For, X-Forwarded-Proto headers
  └─ proxy_pass → http://10.8.0.2:8096
            │
            ▼
      OpenVPN tunnel (encrypted)
            │
            ▼
Home Server (10.8.0.2)
  └─ Docker container: Jellyfin on port 8096
            │
            ▼
      Response travels back the same path
```

For Minecraft, the flow is similar but at the TCP layer — Nginx's `stream` module passes raw TCP packets without HTTP processing.

---

## 📂 Nginx Configuration Files

The Nginx configuration on the VPS is split into modular files:

```
/usr/local/etc/nginx/
├── nginx.conf              # Main config: workers, stream module, http block
└── conf.d/
    └── services.conf       # All upstream definitions + server blocks
```

Copies of these files are tracked in this repository under [`nginx/`](nginx/).

For a step-by-step guide on installing and configuring Nginx on FreeBSD, see the [Nginx Setup Guide](guide/NGINX.md).

---

## 🛡️ Privacy & Security Benefits

| Benefit | How |
|---|---|
| **Home IP hidden** | All DNS points to VPS; home server is never directly reachable |
| **Encrypted tunnel** | All VPS ↔ home traffic travels through OpenVPN |
| **TLS everywhere** | All HTTP traffic redirected to HTTPS; strong cipher suite |
| **No open home ports** | Home firewall can block all inbound; only outbound VPN connection needed |
| **P2P traffic isolated** | Torrent/Soulseek traffic additionally routed through a separate WireGuard VPN (Gluetun) |

---

## 🔐 Hardening Guide

For a detailed guide on securing the VPS with Fail2ban and setting up Authelia relative to this network architecture, please refer to the dedicated [Hardening Guide](guide/HARDENING.md).

---

<p align="center">
  <strong>Next:</strong> <a href="guide/NGINX.md">Nginx Reverse Proxy Setup →</a>
</p>