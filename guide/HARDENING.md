# 🔐 Hardening Guide: Fail2ban on the VPS

> [!NOTE]
> This document is an **example template**. All IP addresses and domain names are fictional and used for illustration purposes only. Replace them with your own values.

Fail2ban monitors Nginx logs on the VPS and automatically bans IPs that show malicious behavior (brute force, repeated 401/403, etc.).

### Step 1 — Install Fail2ban

```bash
# FreeBSD
pkg install py311-fail2ban

# Enable on boot
sysrc fail2ban_enable="YES"
```

### Step 2 — Configure Jails

Create `/usr/local/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
# Ban duration: 1 hour (increase to 86400 for 24h after testing)
bantime  = 3600
# Time window to count failures
findtime = 600
# Max failures before ban
maxretry = 5
# Action: ban via PF firewall (FreeBSD)
banaction = pf
# Your IPs that should never be banned (VPN tunnel + localhost)
ignoreip = 127.0.0.1/8 10.8.0.0/24

# -------------------------------------------------------------------
# Nginx authentication failures (401/403)
# Protects: all services behind Nginx
# -------------------------------------------------------------------
[nginx-auth]
enabled  = true
port     = http,https
filter   = nginx-auth
logpath  = /var/log/nginx/access.log
maxretry = 5

# -------------------------------------------------------------------
# Bot/scanner detection (probing for wp-admin, .env, etc.)
# -------------------------------------------------------------------
[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 3
bantime  = 86400
findtime = 300
```

### Step 3 — Configure the PF Ban Action

Since the VPS runs FreeBSD with PF firewall, we need to ensure Fail2ban knows how to add/remove IPs from PF's blocklist table.

#### 1. Create the action file
Check if `/usr/local/etc/fail2ban/action.d/pf.local` exists. If not, create it:

```ini
[Definition]
actionban   = /sbin/pfctl -t fail2ban -T add <ip>
actionunban = /sbin/pfctl -t fail2ban -T delete <ip>
```

#### 2. Configure PF (the firewall)
Fail2ban needs a table named `fail2ban` in your firewall config to store blocked IPs.

Edit your PF configuration file (`/etc/pf.conf`). Here is an example incorporating the fail2ban table into your existing config:

```pf
ext_if="vtnet0"
ovpn_if="tun1"
home_ip="10.8.0.2"

web_ports = "{80 443}"
ssh_port  = "22"
ovpn_port = "1194"
# Ports from NETWORK.md (Nextcloud, Soulseek, Guacamole, qBittorrent, Jellyfin, Code, Authelia, CoolerControl, Minecraft)
home_service_ports = "{80 6080 8080 8081 8096 8443 9091 11987 25565}"

# 1. Add the fail2ban table definition here
table <fail2ban> persist
table <blocked> persist

set block-policy drop
set skip on lo
scrub in all fragment reassemble

# 2. Add the block rule early in the ruleset
block drop in quick from <fail2ban>
block in quick from <blocked>
block in all
block out all

# Allow all outbound (creates states so replies are allowed)
pass out quick keep state

# Public inbound services
pass in on $ext_if proto tcp to ($ext_if) port $web_ports keep state
pass in on $ext_if proto tcp to ($ext_if) port $ssh_port  keep state
pass in on $ext_if proto udp to ($ext_if) port $ovpn_port keep state
pass in on $ext_if inet proto icmp to ($ext_if) keep state

# Outbound to home services over VPN tunnel
pass out on $ovpn_if proto tcp to $home_ip port $home_service_ports keep state
```

#### 3. Reload PF
Apply the changes to your running firewall:

```bash
pfctl -f /etc/pf.conf
```

### Step 4 — Start & Verify

```bash
service fail2ban start

# Check status
fail2ban-client status
fail2ban-client status nginx-auth
fail2ban-client status nginx-botsearch

# View currently banned IPs
pfctl -t fail2ban -T show
```

### Step 5 — Test It

From a different machine, intentionally trigger 5+ failed requests:

```bash
for i in $(seq 1 6); do curl -s -o /dev/null -w "%{http_code}" https://code.example.com/some-fake-path; done
```

Then verify the IP was banned:

```bash
fail2ban-client status nginx-botsearch
```

### Log Monitoring Tips

```bash
# Watch bans in real-time
tail -f /var/log/fail2ban.log

# Check Nginx for suspicious activity
grep -E " (401|403|444) " /var/log/nginx/access.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
```

---

> **Next step:** Set up Authelia with YubiKey 2FA to protect all services → [AUTHELIA.md](AUTHELIA.md)

---

<p align="center">
  <a href="AUTHELIA.md">← Authelia 2FA Gateway</a> &nbsp;•&nbsp;
  <a href="../NETWORK.md">Back to Network Architecture</a>
</p>
