# 🧑‍💻 Code Server — Remote VS Code Environment

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

Code Server provides a complete Visual Studio Code environment accessible through your web browser, allowing you to develop from anywhere on any device.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Access and Configuration](#step-3--access-and-configuration)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)

---

## Architecture

Code Server runs on your home server and exposes:
- **Web UI:** Port `8443` (HTTP/HTTPS) - Use HTTPS behind a reverse proxy.

---

## Step 1 — DNS Record

Add a DNS record for the Code Server:

| Subdomain | Points to |
|---|---|
| `code.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/code-server/docker-compose.yml](../services/code-server/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`PASSWORD`, `DEFAULT_WORKSPACE`, paths).

---

## Step 3 — Access and Configuration

1. **Initial Access:**
   Open `http://<HOME_SERVER_IP>:8443` in your browser.
   To bypass SSL warning (self-signed cert), proceed despite the warning.

2. **Login:**
   Use the password set in your `.config/code-server/config.yaml` or directly provided as an environment variable in `docker-compose.yml` (`PASSWORD`).

3. **Workspace:**
   Your mounted workspace folder (`/config/workspace`) is available.

---

## Step 4 — VPS Nginx Configuration

To access Code Server securely via `code.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream code_upstream {
    server 10.8.0.2:8443; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name code.example.com;

    # ... SSL certificates ...

    location / {
        # Recommended: Add Authelia protection for security
        auth_request /authelia;

        proxy_pass http://code_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # Websocket support for terminal functionality
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```
