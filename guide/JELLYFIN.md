# 📡 Jellyfin — Media Server

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

Jellyfin is a Free Software Media System that puts you in control of managing and streaming your media.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Access and Configuration](#step-3--access-and-configuration)
- [Step 4 — VPS Nginx Configuration](#step-4--vps-nginx-configuration)

---

## Architecture

Run Jellyfin with hardware transcoding.

- **Web UI:** Port `8096` (HTTP) - Use HTTPS behind a reverse proxy.
- **Hardware Acceleration:** `/dev/dri` (GPU pass-through)

---

## Step 1 — DNS Record

Add a DNS record for the Jellyfin instance:

| Subdomain | Points to |
|---|---|
| `jellyfin.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/jellyfin/docker-compose.yml](../services/jellyfin/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (`JELLYFIN_HTTP_PORT`, `MEDIA_ROOT_DIR`).

---

## Step 3 — Access and Configuration

1. **Access Web UI:** Open `http://<HOME_SERVER_IP>:8096` in your browser.
2. **First Run Setup:**
   - Create admin username/password.
   - Add media libraries (Movies, TV Shows, Music).
   - Enable hardware transcoding in **Dashboard -> Playback -> Transcoding** settings.
   - Configure language and country.

---

## Step 4 — VPS Nginx Configuration

To access Jellyfin securely via `jellyfin.example.com`:

**Upstream** (add to `services.conf`):

```nginx
upstream jellyfin_upstream {
    server 10.8.0.2:8096; # Your VPN IP and port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name jellyfin.example.com;

    # ... SSL certificates ...
    
    # Increase upload size limit for direct streaming/uploads
    client_main_body_size 10G; 

    location / {
        # Jellyfin does NOT support Authelia well for API calls (apps/Kodi)
        # Use Jellyfin's built-in authentication instead.

        proxy_pass http://jellyfin_upstream;
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
