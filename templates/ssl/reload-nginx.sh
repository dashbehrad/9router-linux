#!/usr/bin/env bash
# 9router Linux - Certbot Renewal Deploy Hook
# Automatically reloads Nginx when certificates are renewed.
set -euo pipefail

if systemctl is-active --quiet nginx; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Certificate renewed. Validating Nginx configuration..."
    if nginx -t >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reloading Nginx..."
        systemctl reload nginx
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx reloaded successfully."
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Nginx configuration test failed. Skipping reload." >&2
        exit 1
    fi
fi
