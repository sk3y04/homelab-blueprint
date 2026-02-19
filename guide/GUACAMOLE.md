# 🖥️ Guacamole — Clientless Remote Desktop

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

Apache Guacamole is a clientless remote desktop gateway. It supports standard protocols like VNC, RDP, and SSH.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Initial Configuration](#step-3--initial-configuration)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)
- [Step 5 — Connection Setup](#step-5--connection-setup)

---

## Architecture

Run Guacamole with `guacd` (proxy) and `postgres` (database).

- **Web UI:** Port `8080` (HTTP) - Use HTTPS behind a reverse proxy.
- **Database:** PostgreSQL (Port 5432)

---

## Step 1 — DNS Record

Add a DNS record for the Guacamole gateway:

| Subdomain | Points to |
|---|---|
| `guac.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/guacamole/docker-compose.yml](../services/guacamole/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`POSTGRES_PASSWORD`).

The `initdb.sql` file in `init/` will initialize the database schema on first run.

---

## Step 3 — Initial Configuration

1. **Access Web UI:** Open `http://<HOME_SERVER_IP>:8080/guacamole` in your browser.
2. **First Login:**
   - **Username:** `guacadmin`
   - **Password:** `guacadmin`
3. **Change Password:** Immediately go to **Settings -> Preferences** and change your password.
4. **Create Users:** Add other users as needed.

---

## Step 4 — VPS Nginx Configuration

To access Guacamole securely via `guac.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream guacamole_upstream {
    server 10.8.0.2:8080; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name guac.example.com;

    # ... SSL certificates ...

    location / {
        # Highly recommended: Add Authelia protection (TOTP/WebAuthn)
        auth_request /authelia;
        
        proxy_pass http://guacamole_upstream/guacamole/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # Websocket support for clipboard/audio/video streaming
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

---

## Step 5 — Connection Setup

1. **Create Connection:** Go to **Settings -> Connections -> New Connection**.
2. **Name:** E.g., "Windows 11 VM".
3. **Protocol:** RDP / VNC / SSH.
4. **Parameters:** Enter the IP address, port, username, and password of the remote machine.
5. **Save:** The connection will appear on your home screen.
