# 🛡️ AdGuard Home DNS & Ad Blocker

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

AdGuard Home is a network-wide software for blocking ads and tracking. It operates as a DNS server that re-routes tracking domains to a "blackhole", preventing your devices from connecting to those servers.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Initial Setup](#step-3--initial-setup)
- [Step 4 — Router Configuration](#step-4--router-configuration)
- [Step 5 — VPS Nginx Configuration](#step-5--vps-nginx-configuration)

---

## Architecture

AdGuard Home runs on your home server and exposes:
- **DNS (53/udp, 53/tcp):** For local devices to resolve queries.
- **Web UI (3000/tcp):** For administration (dashboard).

If you want to access the dashboard remotely, you can reverse-proxy the Web UI through Nginx on your VPS.

---

## Step 1 — DNS Record

Add a DNS record for the AdGuard dashboard:

| Subdomain | Points to |
|---|---|
| `adguard.example.com` | VPS public IP |

---

## Step 2 — Docker Compose

See [services/adguard-home/docker-compose.yml](../services/adguard-home/docker-compose.yml).

Ensure you have a `.env` file with the necessary variables (ports, paths).

---

## Step 3 — Initial Setup

When you first start the container, the AdGuard Home setup wizard will be available on port 3000.

1. Open `http://<HOME_SERVER_IP>:3000` in your browser.
2. Click **Get Started**.
3. **Listen Interfaces:**
    - **Admin Web Interface:** Set to port `3000`.
    - **DNS Server:** Set to port `53`.
4. Create your administrator account.
5. Finish the wizard.

Future access to the dashboard will be at `http://<HOME_SERVER_IP>:3000`.

---

## Step 4 — Router Configuration

To block ads on all devices in your home network:

1. Log in to your router's administration page.
2. Find the **DHCP** or **LAN** settings.
3. specific the **Primary DNS** server as your home server's local IP address (e.g., `192.168.1.100`).
4. Save settings and reconnect your devices (disable/enable Wi-Fi) to pick up the new DNS setting.

---

## Step 5 — VPS Nginx Configuration

To access the dashboard from outside your network securely:

**Upstream** (add to `services.conf`):

```nginx
upstream adguard_upstream {
    server 10.8.0.2:3000; # Your VPN IP and Web UI port
}
```

**Server Block** (add to `services.conf`):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name adguard.example.com;

    # ... SSL certificates ...

    location / {
        # Optional: Add Authelia protection
        # auth_request /authelia;
        
        proxy_pass http://adguard_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```
