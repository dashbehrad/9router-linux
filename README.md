# 9router Linux

[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20|%2022.04%20|%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Architecture](https://img.shields.io/badge/Architecture-x86__64%20|%20aarch64-0078D4)](https://github.com/dashbehrad/9router-linux)
[![Node.js](https://img.shields.io/badge/Node.js-22%20LTS-339933?logo=node.js&logoColor=white)](https://nodejs.org/)
[![Nginx](https://img.shields.io/badge/Reverse%20Proxy-Nginx%20HTTP%2F2-009639?logo=nginx&logoColor=white)](https://nginx.org/)
[![SSL](https://img.shields.io/badge/SSL-Let's%20Encrypt%20IP%20Certificate-blue?logo=letsencrypt&logoColor=white)](https://letsencrypt.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**9router Linux** provides an enterprise-ready, automated Linux deployment and service orchestration layer for the **9Router** AI routing gateway and token saver on Ubuntu Server.

This repository packages a robust, production-grade Bash installer (`install.sh`), automated Let's Encrypt short-lived IP address certificate management, an optimized Nginx reverse proxy with SSE streaming support, and complete systemd service integration.

> **Panel Preservation Notice:**  
> This deployment layer strictly manages infrastructure, networking, process supervision, and HTTPS security. The existing 9router graphical web panel, dashboard UI, routes, components, and frontend features remain **100% authentic, untouched, and unredesigned**.

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [System Architecture](#system-architecture)
- [System Requirements](#system-requirements)
- [Quick Start Installation](#quick-start-installation)
- [Interactive Wizard Walkthrough](#interactive-wizard-walkthrough)
- [Let's Encrypt Short-Lived IP SSL](#lets-encrypt-short-lived-ip-ssl)
- [Reverse Proxy & Streaming Optimization](#reverse-proxy--streaming-optimization)
- [Service Management](#service-management)
- [Updating & Maintenance](#updating--maintenance)
- [Troubleshooting & Diagnostics](#troubleshooting--diagnostics)
- [Uninstalling](#uninstalling)
- [Security Model](#security-model)
- [License & Credits](#license--credits)

---

## Overview

[9Router](https://github.com/dashbehrad/9router-linux) connects modern AI development tools (such as **Claude Code**, **Cursor**, **Cline**, **Codex**, **OpenCode**, **OpenClaw**, and **Copilot**) to over 40 upstream AI providers and 100+ models. It offers intelligent fallback tiers (Subscription → Cheap → Free) and the RTK Token Saver engine to compress tool outputs and reduce token burn by 20–40%.

**9router Linux** bridges the gap between running 9Router locally and hosting it 24/7 on an Ubuntu VPS or dedicated cloud server with:

1. **Native IP-based HTTPS** without requiring a custom domain.
2. **Hardened systemd supervisor** with auto-restart and isolated permissions.
3. **Automated reverse proxy** tuned specifically for long-lived Server-Sent Events (SSE) streaming and large multi-modal context payloads.
4. **Idempotent maintenance tools** for single-command updates, backups, configuration tweaks, and repairs.

---

## Key Features

| Feature | Description |
| :--- | :--- |
| **Interactive Terminal Wizard** | Clean, colorized setup wizard supporting both interactive terminals and headless automation. |
| **Short-Lived IP SSL Certificates** | Native integration with Let's Encrypt IP certificates (~6 days / 160 hours validity) via ACME HTTP-01 webroot challenge. |
| **Autonomous Renewal** | Systemd timer (`certbot-shortlived-renew.timer`) checks every 6 hours with automated Nginx reload deploy hooks. |
| **Nginx Reverse Proxy** | Pre-configured for HTTP/2, WebSocket upgrades, disabled proxy buffering (critical for SSE streaming), and 128MB context payloads. |
| **Dedicated Linux User** | Runs under an unprivileged `9router` system user with isolated home and data directories. |
| **Swap Auto-Allocation** | Automatically creates temporary swap space on sub-2GB RAM VPS instances to prevent Out-Of-Memory (OOM) compilation crashes. |
| **Port Conflict Detection** | Scans TCP listeners (`ss`/`lsof`) before binding, alerting if ports are occupied and displaying the conflicting process. |
| **Zero UI Modification** | Preserves all dashboard designs, icons, themes, and client behaviors exactly as authored. |

---

## System Architecture

```text
 ┌───────────────────────────────────────────────────────────────┐
 │               Client Tools & Web Browsers                     │
 │   (Claude Code / Cursor / Cline / Codex / Browser Dashboard)  │
 └──────────────────────────────┬────────────────────────────────┘
                                │ HTTPS :443 (or custom port)
                                ▼
 ┌───────────────────────────────────────────────────────────────┐
 │                     Nginx Reverse Proxy                       │
 │  • Let's Encrypt Short-Lived IP Certificate (~6 days validity)│
 │  • HTTP-01 ACME Challenge: /.well-known/acme-challenge/      │
 │  • WebSocket upgrade & SSE streaming (proxy_buffering off)    │
 │  • Client IP & Host headers (X-Real-IP passed to backend)     │
 └──────────────────────────────┬────────────────────────────────┘
                                │ HTTP :20128 (Loopback only: 127.0.0.1)
                                ▼
 ┌───────────────────────────────────────────────────────────────┐
 │               9router Application (systemd)                   │
 │  • Supervised process: /usr/bin/node custom-server.js         │
 │  • Dedicated system account: 9router:9router                  │
 │  • API Gateway: /v1/* (OpenAI-compatible)                     │
 │  • Web Dashboard: /dashboard                                  │
 │  • SQLite Database: /opt/9router/data                         │
 └──────────────────────────────┬────────────────────────────────┘
                                │ Upstream APIs
                                ▼
                  40+ AI Providers & Models
      (Claude, OpenAI, Gemini, DeepSeek, Kiro, OpenCode...)
```

---

## System Requirements

### Supported Operating Systems
- **Ubuntu Server 24.04 LTS** (Noble Numbat)
- **Ubuntu Server 22.04 LTS** (Jammy Jellyfish)
- **Ubuntu Server 20.04 LTS** (Focal Fossa)
- Newer Ubuntu LTS releases

### Supported CPU Architectures
- **x86_64** (amd64)
- **aarch64** (arm64 / ARM v8+)

### Minimum Hardware
- **CPU:** 1 Core (2 Cores recommended)
- **RAM:** 1 GB (Installer automatically provisions a 2GB swap file during build if total RAM is under 2GB)
- **Storage:** 10 GB available disk space
- **Network:** Public IPv4 address with incoming port `80` (HTTP) and `443` (HTTPS) open

---

## Quick Start Installation

Log in to your Ubuntu server as `root` (or a user with `sudo` privileges) and run:

```bash
# 1. Clone the repository
git clone https://github.com/dashbehrad/9router-linux.git /opt/9router

# 2. Change to the project directory
cd /opt/9router

# 3. Launch the installer
sudo bash install.sh
```

---

## Interactive Wizard Walkthrough

When you launch `install.sh`, the interactive wizard guides you through each configuration stage:

```text
========================================
        9router Linux Installer
========================================
```

1. **Root & Environment Verification:** Validates root permissions, operating system release (Ubuntu 20.04+), CPU architecture, and systemd readiness.
2. **Public IP Detection:** Automatically queries external IP discovery services to detect your public IPv4 address and verifies that the address is publicly routable.
3. **Port Selection & Validation:**
   - **Internal Application Port:** Port for the backend Node.js process (Default: `20128`).
   - **External HTTPS Port:** Public port for encrypted traffic (Default: `443`).
   - **External HTTP Port:** Public port for ACME challenges and HTTPS redirection (Default: `80`).
   - Port conflict check automatically inspects open sockets and shows any conflicting process names.
4. **Base URL Definition:** Confirms or lets you customize the public URL (e.g., `https://YOUR_SERVER_IP`).
5. **Panel Password Configuration:** Prompts for your admin dashboard password with hidden input and confirmation. Secrets are saved into `/opt/9router/.env` with strict `600` permissions.
6. **Dependency Setup:** Automatically installs required Linux development tools, Nginx, Node.js 22 LTS, and Certbot.
7. **Application Compilation:** Executes `npm install` and `npm run build` with swap memory protection.
8. **Let's Encrypt Certificate Issuance:** Configures Nginx to serve `/.well-known/acme-challenge/`, issues the IP certificate using Certbot with the `shortlived` profile, and schedules automated renewals.
9. **Service Registration & Launch:** Installs `/etc/systemd/system/9router.service`, reloads systemd, configures UFW firewall rules, and starts all services.

---

## Let's Encrypt Short-Lived IP SSL

### Short-Lived Certificate Model
Let's Encrypt issues IP address certificates with a short validity window of **approximately 6 days (160 hours)** under the ACME `shortlived` profile. 

Because standard 90-day certificate renewal triggers (which check within 30 days of expiry) are unsuitable for 6-day certificates, **9router Linux** provides automated lifecycle management:

1. **ACME HTTP-01 Webroot:** Challenge tokens are written to `/var/www/certbot/.well-known/acme-challenge/` and served directly by Nginx on port 80.
2. **Frequent Renewal Timer:** A systemd timer (`certbot-shortlived-renew.timer`) runs every **6 hours** (`00:00, 06:00, 12:00, 18:00`) with a randomized jitter to avoid thundering-herd issues on the ACME authority.
3. **Automated Deploy Hook:** `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` tests the Nginx configuration and reloads Nginx cleanly whenever a new certificate is written.

### Testing SSL Renewal
You can simulate a renewal at any time without hitting certificate rate limits:

```bash
certbot renew --dry-run
```

Check the active timer schedule:

```bash
systemctl list-timers | grep certbot
```

---

## Reverse Proxy & Streaming Optimization

9router requires uninterrupted streaming responses for Large Language Model completions and large context uploads. The generated Nginx configuration (`/etc/nginx/sites-available/9router`) includes:

- **SSE Streaming Support:** `proxy_buffering off;` and `proxy_cache off;` prevent Nginx from caching or delaying chunks returned by upstream LLMs.
- **Extended Timeouts:** `proxy_read_timeout 600s;` and `proxy_send_timeout 600s;` prevent connection drops during long reasoning or code generation cycles.
- **Large Context Payloads:** `client_max_body_size 128M;` accommodates base64 images, file uploads, and massive conversation histories.
- **WebSocket Protocol:** Dynamic `$connection_upgrade` mapping ensures real-time UI components and terminal proxies function properly.
- **Peer IP Restoration:** Passes `X-Real-IP` and `X-Forwarded-For` from Nginx loopback, which 9router's `custom-server.js` verifies and trusts for local rate-limiting.

---

## Service Management

All 9router components are managed via standard systemd and Linux utilities:

### Service Operations
```bash
# View 9router status
systemctl status 9router

# Restart the application
systemctl restart 9router

# Stop the application
systemctl stop 9router

# Start the application
systemctl start 9router
```

### Viewing Logs
```bash
# View live application output
journalctl -u 9router -f

# View recent 100 log lines
journalctl -u 9router -n 100 --no-pager

# View Nginx access & error logs
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log

# View installer execution log
cat /var/log/9router-install.log
```

### Port Verification
```bash
# Verify internal application listener (127.0.0.1:20128)
ss -tulpn | grep 20128

# Verify external reverse proxy listeners (:80 and :443)
ss -tulpn | grep -E ':(80|443)'
```

---

## Updating & Maintenance

The installer includes a built-in maintenance menu. If 9router is already installed, running `install.sh` presents management options:

```bash
sudo bash install.sh
```

```text
Existing 9router Linux installation detected at: /opt/9router

Please select an action:
  1) Fresh Install / Overwrite
  2) Reconfigure Settings (Ports, Password, Base URL, SSL)
  3) Update to Latest Version
  4) Repair Installation & Permissions
  5) Service Control (Status / Restart / Logs)
  6) Test SSL Certificate Renewal
  7) Uninstall 9router Linux
  8) Exit
```

### Automated Updates (Option 3)
1. Creates a dated snapshot of your configuration and SQLite database in `/var/backups/9router_YYYYMMDD_HHMMSS/`.
2. Fetches and fast-forwards to the latest repository commits.
3. Installs updated dependencies and rebuilds Next.js standalone assets.
4. Restarts `9router` and `nginx` with zero configuration loss.
5. Runs post-update health checks.

---

## Troubleshooting & Diagnostics

### 1. Port 80 Blocked / Let's Encrypt Certificate Failure
- **Symptom:** Certbot reports `Connection refused` or `Timeout during connect (verification code: 400)`.
- **Cause:** Cloud provider security groups (e.g., AWS Security Group, GCP Firewall, Oracle Cloud VCN ingress rules) or local UFW are blocking incoming traffic on port 80.
- **Resolution:**
  ```bash
  # Check if UFW is allowing port 80
  sudo ufw status
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  ```
  Ensure your cloud provider's ingress rules explicitly allow TCP port 80 and 443 to the instance.

### 2. Low Memory / Build Process Killed
- **Symptom:** `npm run build` exits with `Killed` or `SIGKILL`.
- **Cause:** Linux Out-Of-Memory killer terminated the Node compiler.
- **Resolution:** The installer automatically provisions `/swapfile_9router` if RAM is below 2GB. You can also manually add swap:
  ```bash
  sudo fallocate -l 2G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  ```

### 3. Resetting Admin Panel Password
To change the admin password, update `INITIAL_PASSWORD` in `/opt/9router/.env` and restart the service:
```bash
sudo nano /opt/9router/.env
# Modify INITIAL_PASSWORD=your_new_password
sudo systemctl restart 9router
```

---

## Uninstalling

To cleanly remove 9router Linux from your server:

```bash
sudo bash install.sh
```
Select **Option 7 (Uninstall 9router Linux)**.

The uninstaller will:
- Stop and disable the `9router` systemd service.
- Remove `/etc/systemd/system/9router.service`.
- Disable and delete the Certbot short-lived renewal timer.
- Remove the Nginx reverse proxy configuration.
- Prompt whether you want to delete application files and databases or keep them for future use.

---

## Security Model

- **Unprivileged Runtime:** Application processes execute under a dedicated `9router` system user with `nologin` shell privileges.
- **Strict File Permissions:** The `/opt/9router/.env` configuration file containing passwords, JWT secrets, and API key encryption keys is locked to `chmod 600`.
- **Minimal Exposure:** The internal Node.js process binds solely to `127.0.0.1`. Only ports 80 and 443 are exposed externally through Nginx.
- **Defense in Depth:** Nginx injects `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, and modern TLS 1.2/1.3 cipher suites.

---

## License & Credits

- **Repository:** [dashbehrad/9router-linux](https://github.com/dashbehrad/9router-linux)
- **Core 9Router Project:** Created by [decolua](https://github.com/decolua/9router)
- **License:** Distributed under the [MIT License](LICENSE).
