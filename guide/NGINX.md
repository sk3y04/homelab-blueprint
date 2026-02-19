# ⚙️ Nginx Reverse Proxy Setup Guide (FreeBSD VPS)

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

This guide walks through setting up Nginx as a reverse proxy on a FreeBSD VPS, terminating TLS for all home server services and proxying traffic through an OpenVPN tunnel. It is based on the configuration files tracked in [`nginx/`](../nginx/).

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1 — Install Nginx](#step-1--install-nginx)
- [Step 2 — Install Certbot](#step-2--install-certbot)
- [Step 3 — Create the Directory Structure](#step-3--create-the-directory-structure)
- [Step 4 — Deploy nginx.conf](#step-4--deploy-nginxconf)
- [Step 5 — Deploy services.conf](#step-5--deploy-servicesconf)
- [Step 6 — Obtain TLS Certificates](#step-6--obtain-tls-certificates)
- [Step 7 — Open Firewall Ports](#step-7--open-firewall-ports)
- [Step 8 — Test & Start](#step-8--test--start)
- [Step 9 — Certificate Auto-Renewal](#step-9--certificate-auto-renewal)
- [Configuration Reference](#configuration-reference)
- [Adding a New Service](#adding-a-new-service)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before starting, ensure you have:

- A **FreeBSD VPS** with a static public IP address
- **DNS records** pointing your subdomains to the VPS IP (see [NETWORK.md → Domain Mapping](../NETWORK.md#-domain-mapping))
- A working **OpenVPN tunnel** between the VPS (`10.8.0.1`) and your home server (`10.8.0.2`)
- **Root/sudo access** on the VPS

Verify the tunnel is up before proceeding:

```bash
ping -c 3 10.8.0.2
```

---

## Step 1 — Install Nginx

Install Nginx from FreeBSD packages:

```bash
pkg install nginx
```

Enable it to start on boot:

```bash
sysrc nginx_enable="YES"
```

---

## Step 2 — Install Certbot

Install Certbot for Let's Encrypt certificate management:

```bash
pkg install py311-certbot
```

Create the webroot directory that Certbot will use for HTTP-01 challenges:

```bash
mkdir -p /usr/local/www/.well-known/acme-challenge
```

---

## Step 3 — Create the Directory Structure

Nginx on FreeBSD uses `/usr/local/etc/nginx/` as its configuration root. Set up the modular layout:

```bash
mkdir -p /usr/local/etc/nginx/conf.d
mkdir -p /var/log/nginx
```

The final structure will look like this:

```
/usr/local/etc/nginx/
├── nginx.conf              # Main config: workers, stream module, http block
└── conf.d/
    └── services.conf       # All upstream definitions + server blocks
```

---

## Step 4 — Deploy nginx.conf

Copy the main configuration file to the VPS. This file configures:

- **Dynamic module loading** for the `stream` module (TCP proxying)
- **Worker processes** set to `auto` (matches CPU cores)
- **Gzip compression** for text-based responses
- **WebSocket upgrade map** shared across all server blocks
- **Stream block** for Minecraft TCP proxying
- **Include directive** to load `conf.d/*.conf`

```bash
cp nginx.conf /usr/local/etc/nginx/nginx.conf
```

Or create it manually — the reference file is tracked at [`vps/nginx/nginx.conf`](../vps/nginx/nginx.conf).

### Key settings explained

| Setting | Value | Why |
|---|---|---|
| `worker_connections` | `4096` | Handles many concurrent connections for media streaming |
| `keepalive_timeout` | `65` | Keeps connections open for quick subsequent requests |
| `tcp_nopush` / `tcp_nodelay` | `on` | Optimizes packet delivery for proxied responses |
| `gzip_comp_level` | `5` | Good balance between CPU usage and compression ratio |
| `load_module ... ngx_stream_module.so` | — | Required for Minecraft TCP proxying |

### Stream block (Minecraft)

The `stream` block in `nginx.conf` handles Minecraft's raw TCP protocol at layer 4:

```nginx
stream {
    upstream minecraft_upstream {
        server 10.8.0.2:25565;
    }

    server {
        listen 25565;
        proxy_pass minecraft_upstream;
        proxy_connect_timeout 10s;
        proxy_timeout 600s;     # 10 min idle timeout
    }
}
```

> [!IMPORTANT]
> The `stream` module must be loaded as a dynamic module on FreeBSD. If you get `unknown directive "stream"`, ensure the `load_module` line is present at the **top** of `nginx.conf`, before any other blocks.

---

## Step 5 — Deploy services.conf

Copy the services configuration:

```bash
cp services.conf /usr/local/etc/nginx/conf.d/services.conf
```

The reference file is tracked at [`vps/nginx/conf.d/services.conf`](../vps/nginx/conf.d/services.conf).

This file contains three sections:

### 1. Upstream Definitions

Each service on the home server is defined as an upstream pointing to the tunnel IP `10.8.0.2`:

| Upstream | Target | `keepalive` |
|---|---|---|
| `jellyfin_upstream` | `10.8.0.2:8096` | 16 |
| `nextcloud_upstream` | `10.8.0.2:80` | 16 |
| `code_upstream` | `10.8.0.2:8443` | 8 |
| `torrent_upstream` | `10.8.0.2:8081` | 8 |
| `guac_upstream` | `10.8.0.2:8080` | 8 |
| `soulseek_upstream` | `10.8.0.2:6080` | 8 |

> Higher `keepalive` values for Jellyfin and Nextcloud reflect their heavier traffic patterns (streaming, large file transfers).

### 2. HTTP Server Blocks (Port 80)

Every subdomain has an HTTP server block that does exactly two things:

1. **Serves ACME challenges** at `/.well-known/acme-challenge/` for Let's Encrypt renewal.
2. **Redirects everything else** to HTTPS with a `301`.

### 3. HTTPS Server Blocks (Port 443)

Each HTTPS block includes:

- **TLS termination** with per-domain Let's Encrypt certificates
- **Hardened TLS settings** (TLSv1.2+, ECDHE ciphers, OCSP stapling, HSTS)
- **Security headers** (X-Frame-Options, X-Content-Type-Options, X-XSS-Protection)
- **Reverse proxy directives** forwarding to the upstream via the VPN tunnel

### Service-specific settings

| Service | Special Configuration |
|---|---|
| **Jellyfin** | `proxy_buffering off` for smooth media streaming; WebSocket support |
| **Nextcloud** | `client_max_body_size 20G`; timeouts extended to `3600s` for large uploads; RainLoop data path denied |
| **Code Server** | Timeouts extended to `3600s` for long-lived sessions; WebSocket support critical |
| **qBittorrent** | Standard proxy with `600s` timeouts |
| **Guacamole** | `proxy_buffering off` for low-latency remote desktop; WebSocket support required |

---

## Step 6 — Obtain TLS Certificates

> [!IMPORTANT]
> Before requesting certificates, Nginx must be running with the port 80 HTTP blocks active so Certbot can complete the HTTP-01 challenge. Start Nginx with a temporary config or comment out the HTTPS blocks first.

### First-time certificate setup

Start Nginx temporarily (HTTPS blocks will fail without certs, so comment them out first):

```bash
# Edit services.conf — comment out all "listen 443" server blocks temporarily
nginx -t && service nginx start
```

Request certificates for each subdomain:

```bash
certbot certonly --webroot -w /usr/local/www -d jellyfin.example.com
certbot certonly --webroot -w /usr/local/www -d cloud.example.com
certbot certonly --webroot -w /usr/local/www -d code.example.com
certbot certonly --webroot -w /usr/local/www -d torrent.example.com
certbot certonly --webroot -w /usr/local/www -d vm.example.com
certbot certonly --webroot -w /usr/local/www -d soulseek.example.com
```

Certificates will be saved to:

```
/usr/local/etc/letsencrypt/live/<domain>/
├── fullchain.pem    # Certificate + intermediates (ssl_certificate)
├── privkey.pem      # Private key (ssl_certificate_key)
└── chain.pem        # Intermediate chain (ssl_trusted_certificate for OCSP)
```

### Re-enable the HTTPS blocks

Uncomment the HTTPS server blocks in `services.conf`, then reload:

```bash
nginx -t && service nginx reload
```

---

## Step 7 — Open Firewall Ports

If you're using PF (see [vps/pf.conf](../vps/pf.conf)), ensure ports 80, 443, and 25565 are open:

```pf
web_ports = "{80 443}"

# Allow HTTP/HTTPS traffic
pass in on $ext_if proto tcp to ($ext_if) port $web_ports keep state

# Allow Minecraft TCP (if applicable)
pass in on $ext_if proto tcp to ($ext_if) port 25565 keep state
```

Reload PF after changes:

```bash
pfctl -f /etc/pf.conf
```

---

## Step 8 — Test & Start

### Validate the configuration

Always test before reloading:

```bash
nginx -t
```

Expected output:

```
nginx: the configuration file /usr/local/etc/nginx/nginx.conf syntax is ok
nginx: configuration file /usr/local/etc/nginx/nginx.conf test is successful
```

### Start or reload Nginx

```bash
# First time
service nginx start

# After config changes
service nginx reload
```

### Verify each service

```bash
# Check that HTTPS is working and the certificate is valid
curl -I https://jellyfin.example.com
curl -I https://cloud.example.com
curl -I https://code.example.com
curl -I https://torrent.example.com
curl -I https://vm.example.com

# Check Minecraft TCP proxy
nc -zv <VPS_PUBLIC_IP> 25565
```

---

## Step 9 — Certificate Auto-Renewal

Certbot does not auto-renew by default on FreeBSD. Add a cron job:

```bash
crontab -e
```

Add the following line to attempt renewal twice daily and reload Nginx on success:

```cron
0 3,15 * * * /usr/local/bin/certbot renew --quiet --deploy-hook "service nginx reload"
```

Verify the renewal process works:

```bash
certbot renew --dry-run
```

---

## Configuration Reference

### Files in this repository

| File | Purpose | VPS Path |
|---|---|---|
| [`vps/nginx/nginx.conf`](../vps/nginx/nginx.conf) | Main Nginx config | `/usr/local/etc/nginx/nginx.conf` |
| [`vps/nginx/conf.d/services.conf`](../vps/nginx/conf.d/services.conf) | Upstreams + server blocks | `/usr/local/etc/nginx/conf.d/services.conf` |
| [`vps/pf.conf`](../vps/pf.conf) | PF firewall config (reference) | `/etc/pf.conf` |

### Proxy headers (applied to every service)

Every HTTPS server block forwards the following headers to the backend:

| Header | Value | Purpose |
|---|---|---|
| `Host` | `$host` | Preserves the original hostname |
| `X-Real-IP` | `$remote_addr` | Client's real IP address |
| `X-Forwarded-For` | `$proxy_add_x_forwarded_for` | Full proxy chain |
| `X-Forwarded-Proto` | `https` | Tells the backend TLS is terminated |
| `X-Forwarded-Host` | `$host` | Original host header |
| `X-Forwarded-Ssl` | `on` | SSL indicator |
| `Upgrade` | `$http_upgrade` | WebSocket upgrade header |
| `Connection` | `$connection_upgrade` | WebSocket connection handling |

---

## Adding a New Service

To expose a new service through the reverse proxy:

### 1. Add the upstream

In `services.conf`, add a new upstream block:

```nginx
upstream myservice_upstream {
    server 10.8.0.2:<PORT>;
    keepalive 8;
}
```

### 2. Add the HTTP server block

```nginx
server {
    listen 80;
    server_name myservice.example.com;

    location ^~ /.well-known/acme-challenge/ {
        root /usr/local/www;
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
```

### 3. Obtain the certificate

```bash
nginx -t && service nginx reload
certbot certonly --webroot -w /usr/local/www -d myservice.example.com
```

### 4. Add the HTTPS server block

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name myservice.example.com;

    ssl_certificate     /usr/local/etc/letsencrypt/live/myservice.example.com/fullchain.pem;
    ssl_certificate_key /usr/local/etc/letsencrypt/live/myservice.example.com/privkey.pem;

    # TLS settings (copy from any existing HTTPS block)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';

    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /usr/local/etc/letsencrypt/live/myservice.example.com/chain.pem;
    resolver 1.1.1.1 1.0.0.1 valid=300s;
    resolver_timeout 5s;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        proxy_pass http://myservice_upstream;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Ssl on;

        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
    }
}
```

### 5. Update PF (if applicable)

Add the new port to `home_service_ports` in `/etc/pf.conf` and reload:

```bash
pfctl -f /etc/pf.conf
```

### 6. Reload Nginx

```bash
nginx -t && service nginx reload
```

---

## Troubleshooting

### Common issues

| Problem | Cause | Fix |
|---|---|---|
| `unknown directive "stream"` | Stream module not loaded | Add `load_module /usr/local/libexec/nginx/ngx_stream_module.so;` to the top of `nginx.conf` |
| `502 Bad Gateway` | Home server unreachable via tunnel | Check OpenVPN: `ping 10.8.0.2`; verify the Docker container is running |
| `SSL: error` on startup | Certificate files missing | Run `certbot certonly` for the domain; ensure paths match `ssl_certificate` directives |
| WebSocket disconnects | Missing upgrade headers | Ensure `Upgrade` and `Connection` headers are set; check the `map` block exists in `nginx.conf` |
| Nextcloud upload fails | Body size limit too small | Verify `client_max_body_size 20G;` is in the Nextcloud server block |
| Certbot renewal fails | Port 80 blocked or Nginx down | Check PF allows port 80; ensure Nginx is running; verify ACME location block exists |

### Useful commands

```bash
# Test config before reloading
nginx -t

# Reload without downtime
service nginx reload

# Watch access log in real-time
tail -f /var/log/nginx/access.log

# Watch error log
tail -f /var/log/nginx/error.log

# Check which processes are listening
sockstat -4 -l | grep nginx

# Verify certificate expiry
openssl s_client -connect jellyfin.example.com:443 -servername jellyfin.example.com </dev/null 2>/dev/null | openssl x509 -noout -dates
```

---

<p align="center">
  <a href="../NETWORK.md">← Network Architecture</a> &nbsp;•&nbsp;
  <strong>Next:</strong> <a href="AUTHELIA.md">Authelia 2FA Gateway →</a>
</p>
