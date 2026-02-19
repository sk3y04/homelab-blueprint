# 🛡️ Authelia Authentication Gateway with YubiKey 2FA

> [!NOTE]
> This document is an **example template**. All domain names, IP addresses, and service details are fictional and used for illustration purposes only. Replace them with your own values.

Authelia adds a centralized authentication portal with **two-factor authentication** (TOTP + YubiKey/WebAuthn) in front of all services. It runs as a Docker container on the home server and is protected by Nginx on the VPS, just like all other services.

---

## Table of Contents

- [Architecture](#architecture)
- [Step 1 — DNS Record](#step-1--dns-record)
- [Step 2 — Docker Compose](#step-2--docker-compose)
- [Step 3 — Authelia Configuration](#step-3--authelia-configuration)
- [Step 4 — Create Users](#step-4--create-users)
- [Step 5 — Start Authelia](#step-5--start-authelia)
- [Step 6 — VPS Nginx Configuration](#step-6--vps-nginx-configuration)
- [Step 7 — Protect Each Service](#step-7--protect-each-service)
- [Step 8 — Obtain the TLS Certificate](#step-8--obtain-the-tls-certificate)
- [Step 9 — Reload & Test](#step-9--reload--test)
- [Step 10 — Register YubiKey (WebAuthn)](#step-10--register-yubikey-webauthn)
- [Step 11 — Register TOTP (Backup)](#step-11--register-totp-backup)
- [Recommended Access Policies](#recommended-access-policies)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
Browser → VPS Nginx → checks auth with Authelia (auth_request)
                     ↓ (if not authenticated)
                     → redirect to auth.example.com login page
                     ↓ (if authenticated + 2FA passed)
                     → proxy_pass to actual service
```

Authelia supports multiple second-factor methods. This guide configures **WebAuthn** (YubiKey) as the primary 2FA method with **TOTP** as a backup:

| Method | Device | Use Case |
|---|---|---|
| **WebAuthn** | YubiKey 5, Security Key NFC, etc. | Primary 2FA — tap your key to authenticate |
| **TOTP** | Aegis, Bitwarden Authenticator, etc. | Backup 2FA — in case you don't have your YubiKey |

---

## Step 1 — DNS Record

Add a DNS record for the Authelia portal:

| Subdomain | Points to |
|---|---|
| `auth.example.com` | VPS public IP (same as all others) |

---

## Step 2 — Docker Compose

See [services/authelia/docker-compose.yml](../services/authelia/docker-compose.yml).

---

## Step 3 — Authelia Configuration

1. Copy [services/authelia/config/configuration.example.yml](../services/authelia/config/configuration.example.yml) to `services/authelia/config/configuration.yml` and edit it to match your environment.
2. Copy [services/authelia/.env.example](../services/authelia/.env.example) to `services/authelia/.env`.

### Generate secrets

See comments in [services/authelia/.env.example](../services/authelia/.env.example) for instructions on generating secrets.

---

## Step 4 — Create Users

Copy [services/authelia/config/users_database.example.yml](../services/authelia/config/users_database.example.yml) to `services/authelia/config/users_database.yml`.

See comments in the file for instructions on generating password hashes.

---

## Step 5 — Start Authelia

```bash
cd services/authelia && docker compose up -d
```

Verify it's running:

```bash
curl -s http://10.8.0.2:9091/api/health
# Should return: {"status":"OK"}
```

---

## Step 6 — VPS Nginx Configuration

Add the Authelia upstream and server blocks to `services.conf`:

**Upstream** (add with the other upstreams):

```nginx
upstream authelia_upstream {
    server 10.8.0.2:9091;
    keepalive 8;
}
```

**HTTP block** (add with the other HTTP server blocks):

```nginx
# Authelia HTTP
server {
    listen 80;
    server_name auth.example.com;

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

**HTTPS block for the Authelia portal itself:**

```nginx
# Authelia Portal HTTPS
server {
    listen 443 ssl;
    http2 on;
    server_name auth.example.com;

    ssl_certificate     /usr/local/etc/letsencrypt/live/auth.example.com/fullchain.pem;
    ssl_certificate_key /usr/local/etc/letsencrypt/live/auth.example.com/privkey.pem;

    # ... (same TLS settings as other server blocks) ...

    location / {
        proxy_pass http://authelia_upstream;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
```

---

## Step 7 — Protect Each Service

For every HTTPS server block you want to protect, add the `auth_request` directives. Here is **Code Server** as an example:

```nginx
# Code-server HTTPS (PROTECTED)
server {
    listen 443 ssl;
    http2 on;
    server_name code.example.com;

    # ... (SSL settings unchanged) ...

    # Authelia verification endpoint
    location /authelia {
        internal;
        proxy_pass http://authelia_upstream/api/authz/auth-request;
        proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header X-Forwarded-Method $request_method;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-URI $request_uri;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Content-Length "";
        proxy_set_header Connection "";
        proxy_pass_request_body off;
    }

    location / {
        # ── Authelia gate ──
        auth_request /authelia;
        auth_request_set $user $upstream_http_remote_user;
        auth_request_set $groups $upstream_http_remote_groups;
        auth_request_set $name $upstream_http_remote_name;
        auth_request_set $email $upstream_http_remote_email;

        # If not authenticated, redirect to Authelia login
        error_page 401 =302 https://auth.example.com/?rd=$scheme://$http_host$request_uri;

        # Forward auth info to the backend
        proxy_set_header Remote-User $user;
        proxy_set_header Remote-Groups $groups;

        # ── Normal proxy settings (unchanged) ──
        proxy_pass http://code_upstream;
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
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
    }
}
```

Repeat for each service you want protected (`cloud.example.com`, `torrent.example.com`, `vm.example.com`, `soulseek.example.com`). Jellyfin is **not** protected by Authelia — it handles its own authentication natively, so its Nginx block is a plain reverse proxy without `auth_request`.

---

## Step 8 — Obtain the TLS Certificate

```bash
certbot certonly --webroot -w /usr/local/www -d auth.example.com
```

---

## Step 9 — Reload & Test

```bash
nginx -t && service nginx reload
```

Visit any protected service (e.g. `https://code.example.com`). You should be redirected to `https://auth.example.com` where you log in with your credentials.

---

## Step 10 — Register YubiKey (WebAuthn)

This is the primary 2FA method. After registering your YubiKey, you'll tap it each time you log in to a `two_factor` service.

### Prerequisites

- A **WebAuthn-compatible security key** (YubiKey 5, YubiKey Security Key, SoloKey, etc.)
- A browser that supports WebAuthn (all modern browsers do)
- Your YubiKey must support **FIDO2/WebAuthn** (YubiKey 5 series and newer)

### Register the key

1. Open `https://auth.example.com` in your browser
2. Log in with your username and password
3. You'll land on the **second factor selection** page
4. Click **Register WebAuthn Credential** (or the security key icon)
5. If using the `filesystem` notifier, check `services/authelia/config/notification.txt` for the registration confirmation link — open it in your browser
6. Your browser will prompt you to insert and **tap your YubiKey**
7. If your key supports a PIN, you may be asked to enter it (depends on the `user_verification` setting)
8. Give the credential a name (e.g. "YubiKey 5 NFC - Primary")
9. Done — your YubiKey is now registered

### Testing

1. Open a new incognito/private window
2. Visit a `two_factor` protected service (e.g. `https://code.example.com`)
3. You'll be redirected to `https://auth.example.com`
4. Enter your username and password
5. You'll be prompted to **tap your YubiKey**
6. After the tap, you're redirected to the service

> [!TIP]
> You can register **multiple WebAuthn credentials** — for example a primary YubiKey and a backup key stored in a safe location. Repeat the registration process for each key.

---

## Step 11 — Register TOTP (Backup)

TOTP serves as a fallback if you don't have your YubiKey available.

1. Log in to `https://auth.example.com`
2. Navigate to **Settings** or the 2FA registration page
3. Choose **TOTP / One-Time Password**
4. If using the `filesystem` notifier, check `services/authelia/config/notification.txt` for the registration link
5. Scan the QR code with an authenticator app (Aegis, Bitwarden Authenticator, etc.)
6. Enter the 6-digit code to confirm registration

> [!IMPORTANT]
> **Save your TOTP recovery codes** in a secure location (password manager, printed in a safe). If you lose both your YubiKey and TOTP device, you'll need to manually reset 2FA in the Authelia database.

### Switching between methods at login

When prompted for 2FA, Authelia defaults to WebAuthn (YubiKey). If you need to use TOTP instead:

1. On the 2FA prompt screen, click **Use another method**
2. Select **One-Time Password**
3. Enter the 6-digit code from your authenticator app

---

## Recommended Access Policies

| Service | Policy | Rationale |
|---|---|---|
| Jellyfin | `bypass` | Jellyfin handles its own authentication; Authelia interferes with its API |
| Nextcloud | `two_factor` | Sensitive files; full 2FA required |
| Code Server | `two_factor` | Full shell access to the server |
| qBittorrent | `two_factor` | Prevents unauthorized downloads |
| Guacamole | `two_factor` | Remote desktop = full system access |
| Soulseek | `two_factor` | Network-facing P2P client |

---

## Troubleshooting

### WebAuthn registration doesn't start

- Ensure you're accessing Authelia over **HTTPS** — WebAuthn requires a secure context
- Check that your browser supports WebAuthn (Chrome, Firefox, Edge, Safari all do)
- Verify the YubiKey is inserted properly and the USB contact is clean

### "NotAllowedError" during YubiKey tap

- The browser timed out waiting for the tap — try again and tap sooner
- Another browser tab may be competing for the security key — close other tabs
- On Linux, ensure your user has permission to access USB HID devices:
  ```bash
  # Add a udev rule for FIDO devices (if not already present)
  echo 'KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1050", MODE="0660", GROUP="plugdev"' | sudo tee /etc/udev/rules.d/70-yubikey.rules
  sudo udevadm control --reload-rules
  ```

### Lost YubiKey — recovery with TOTP

If you've registered TOTP as a backup, simply select **One-Time Password** at the 2FA prompt. If you have no second factor available, you'll need to reset 2FA from the server:

```bash
# Remove all WebAuthn credentials for a user
docker exec authelia authelia storage user webauthn delete --user johndoe

# Remove TOTP credential for a user
docker exec authelia authelia storage user totp delete --user johndoe
```

The user will be prompted to re-register 2FA on their next login.

### Authelia returns 401 but the user is logged in

- Check that the `auth_request` location in Nginx is forwarding the correct headers
- Verify the `session.cookies[].domain` in Authelia config matches your actual domain
- Ensure cookies are not being blocked by the browser (third-party cookie restrictions)

### Check Authelia logs

```bash
docker logs -f authelia
```

---

<p align="center">
  <a href="NGINX.md">← Nginx Reverse Proxy</a> &nbsp;•&nbsp;
  <strong>Next:</strong> <a href="HARDENING.md">VPS Hardening →</a>
</p>
