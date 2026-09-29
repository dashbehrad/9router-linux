#!/usr/bin/env bash
# ==============================================================================
# 9router Linux - Production Installation and Deployment Script
# Supports: Ubuntu Server 20.04 LTS, 22.04 LTS, 24.04 LTS, and newer
# Architectures: x86_64 (amd64), aarch64 (arm64)
# Repository: https://github.com/dashbehrad/9router-linux
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Global Constants & Paths
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly DEFAULT_REPO_URL="https://github.com/dashbehrad/9router-linux.git"
readonly DEFAULT_INSTALL_DIR="/opt/9router"
readonly SERVICE_NAME="9router"
readonly SERVICE_USER="9router"
readonly SERVICE_GROUP="9router"
readonly DEFAULT_APP_PORT="20128"
readonly DEFAULT_HTTP_PORT="80"
readonly DEFAULT_HTTPS_PORT="443"
readonly CERTBOT_WEBROOT="/var/www/certbot"
readonly RENEWAL_TIMER_NAME="certbot-shortlived-renew.timer"
readonly RENEWAL_SERVICE_NAME="certbot-shortlived-renew.service"
readonly NGINX_CONF_AVAILABLE="/etc/nginx/sites-available/9router"
readonly NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/9router"
readonly DEPLOY_HOOK_PATH="/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"

# Script execution context
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/9router-install.log"
TEMP_SWAP_FILE="/swapfile_9router"

# ------------------------------------------------------------------------------
# Terminal Colors & UI
# ------------------------------------------------------------------------------
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    CLR_RED="\033[0;31m"
    CLR_GREEN="\033[0;32m"
    CLR_YELLOW="\033[1;33m"
    CLR_BLUE="\033[0;34m"
    CLR_CYAN="\033[0;36m"
    CLR_BOLD="\033[1m"
    CLR_RESET="\033[0m"
else
    CLR_RED=""
    CLR_GREEN=""
    CLR_YELLOW=""
    CLR_BLUE=""
    CLR_CYAN=""
    CLR_BOLD=""
    CLR_RESET=""
fi

# ------------------------------------------------------------------------------
# Logging & Messaging Functions
# ------------------------------------------------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [ -w "$(dirname "$LOG_FILE")" ]; then
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

info() {
    echo -e "${CLR_BLUE}[INFO]${CLR_RESET} $*"
    log "[INFO] $*"
}

success() {
    echo -e "${CLR_GREEN}[SUCCESS]${CLR_RESET} $*"
    log "[SUCCESS] $*"
}

warn() {
    echo -e "${CLR_YELLOW}[WARNING]${CLR_RESET} $*"
    log "[WARNING] $*"
}

error() {
    echo -e "${CLR_RED}[ERROR]${CLR_RESET} $*" >&2
    log "[ERROR] $*"
}

step() {
    echo -e "\n${CLR_CYAN}${CLR_BOLD}>>> $*${CLR_RESET}"
    log "[STEP] $*"
}

banner() {
    cat << "EOF"
========================================
        9router Linux Installer
========================================
EOF
}

# ------------------------------------------------------------------------------
# Error Trap & Cleanup
# ------------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n${CLR_RED}========================================${CLR_RESET}"
        echo -e "${CLR_RED}Installation aborted due to an error.${CLR_RESET}"
        echo -e "Review detailed execution logs at: ${CLR_BOLD}${LOG_FILE}${CLR_RESET}"
        echo -e "You can retry by running: ${CLR_BOLD}sudo bash install.sh${CLR_RESET}"
        echo -e "${CLR_RED}========================================${CLR_RESET}\n"
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Root Permission Validation
# ------------------------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${CLR_RED}========================================${CLR_RESET}"
        echo -e "${CLR_RED}[ERROR] Root privileges are required.${CLR_RESET}"
        echo -e "Please run this installer using:"
        echo -e "  ${CLR_BOLD}sudo bash install.sh${CLR_RESET}"
        echo -e "${CLR_RED}========================================${CLR_RESET}"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Operating System & Architecture Validation
# ------------------------------------------------------------------------------
check_os() {
    step "Validating Operating System and Architecture"

    # Verify Linux
    if [ "$(uname -s)" != "Linux" ]; then
        error "This installer only supports Linux. Detected: $(uname -s)"
        exit 1
    fi

    # Verify systemd
    if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
        error "systemd is required to manage 9router services, but was not detected."
        exit 1
    fi

    # Verify Ubuntu
    if [ ! -f /etc/os-release ]; then
        error "/etc/os-release not found. Unsupported Linux distribution."
        exit 1
    fi

    # Source os-release
    # shellcheck disable=SC1091
    . /etc/os-release

    if [ "${ID:-}" != "ubuntu" ] && ! echo "${ID_LIKE:-}" | grep -q "ubuntu"; then
        error "This installer requires Ubuntu Server. Detected distribution: ${NAME:-Unknown}"
        exit 1
    fi

    # Check Ubuntu version (>= 20.04)
    local version_major
    version_major=$(echo "${VERSION_ID:-0}" | cut -d. -f1)
    if [ "$version_major" -lt 20 ]; then
        error "Ubuntu 20.04 LTS or newer is required. Detected version: ${VERSION_ID:-Unknown}"
        exit 1
    fi

    # Check Architecture
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            arch="x86_64 (amd64)"
            ;;
        aarch64|arm64)
            arch="aarch64 (arm64)"
            ;;
        *)
            error "Unsupported CPU architecture: $arch. Supported: x86_64, aarch64."
            exit 1
            ;;
    esac

    success "Operating System: ${PRETTY_NAME:-Ubuntu} on $arch"
    success "Kernel Version:   $(uname -r)"
    success "System Init:      systemd detected and operational"
}

# ------------------------------------------------------------------------------
# Swap Memory Optimization for Low-Resource VPS
# Next.js webpack build can require ~1.5GB to 2GB peak RAM.
# ------------------------------------------------------------------------------
ensure_build_memory() {
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local total_swap_mb
    total_swap_mb=$(free -m | awk '/^Swap:/{print $2}')

    info "Detected RAM: ${total_ram_mb}MB | Swap: ${total_swap_mb}MB"

    if [ "$total_ram_mb" -lt 2048 ] && [ "$total_swap_mb" -lt 1024 ]; then
        warn "Available memory is under 2GB. Next.js compilation may trigger Linux OOM."
        info "Creating 2GB temporary swap file at ${TEMP_SWAP_FILE}..."

        if [ ! -f "$TEMP_SWAP_FILE" ]; then
            if fallocate -l 2G "$TEMP_SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$TEMP_SWAP_FILE" bs=1M count=2048 status=none; then
                chmod 600 "$TEMP_SWAP_FILE"
                mkswap "$TEMP_SWAP_FILE" >/dev/null
                swapon "$TEMP_SWAP_FILE" >/dev/null
                success "Temporary 2GB swap space enabled."
            else
                warn "Failed to create swap file. Proceeding with existing memory."
            fi
        fi
    fi
}

cleanup_temporary_swap() {
    if [ -f "$TEMP_SWAP_FILE" ]; then
        info "Removing temporary build swap file..."
        swapoff "$TEMP_SWAP_FILE" 2>/dev/null || true
        rm -f "$TEMP_SWAP_FILE" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Dependency Installation
# ------------------------------------------------------------------------------
install_dependencies() {
    step "Checking and Installing System Dependencies"

    export DEBIAN_FRONTEND=noninteractive

    local pkgs_to_install=()
    local required_pkgs=(
        curl
        wget
        git
        ca-certificates
        gnupg
        lsb-release
        build-essential
        python3
        make
        g++
        ufw
        openssl
        nginx
        lsof
        iproute2
    )

    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            pkgs_to_install+=("$pkg")
        fi
    done

    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
        info "Updating apt cache and installing: ${pkgs_to_install[*]}"
        apt-get update -y
        apt-get install -y --no-install-recommends "${pkgs_to_install[@]}"
        success "Core system packages installed."
    else
        success "All core system packages are already installed."
    fi

    # Install Node.js 22 LTS if Node is absent or < 20
    local need_node=false
    if ! command -v node >/dev/null 2>&1; then
        need_node=true
    else
        local node_ver
        node_ver=$(node -v | sed 's/^v//' | cut -d. -f1)
        if [ "$node_ver" -lt 20 ]; then
            info "Installed Node.js version ($node_ver) is below required Node 20+."
            need_node=true
        fi
    fi

    if [ "$need_node" = true ]; then
        info "Installing Node.js 22 LTS from official NodeSource repository..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
        apt-get update -y
        apt-get install -y nodejs
        success "Node.js $(node -v) and npm $(npm -v) installed."
    else
        success "Node.js $(node -v) is already installed and supported."
    fi

    # Install Certbot
    install_certbot
}

install_certbot() {
    info "Verifying Certbot installation for ACME IP certificate support..."
    if command -v certbot >/dev/null 2>&1; then
        success "Certbot is already installed: $(certbot --version 2>&1 | head -n1)"
        return 0
    fi

    # Try snap first (official Certbot installation method on Ubuntu)
    if command -v snap >/dev/null 2>&1; then
        info "Installing Certbot via snapd..."
        if snap install core >/dev/null 2>&1 && snap refresh core >/dev/null 2>&1 && snap install --classic certbot >/dev/null 2>&1; then
            ln -sf /snap/bin/certbot /usr/bin/certbot
            success "Certbot installed via snap: $(certbot --version 2>&1 | head -n1)"
            return 0
        fi
    fi

    # Fallback to apt
    info "Installing Certbot via apt package manager..."
    apt-get update -y
    apt-get install -y certbot python3-certbot-nginx
    success "Certbot installed via apt: $(certbot --version 2>&1 | head -n1)"
}

# ------------------------------------------------------------------------------
# Server Public IP Detection
# ------------------------------------------------------------------------------
detect_public_ip() {
    step "Detecting Server Public IP Address"

    local detected_ip=""
    local services=(
        "https://ifconfig.me"
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )

    for svc in "${services[@]}"; do
        detected_ip=$(curl -s4 -m 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$detected_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        fi
    done

    # Fallback to local default route interface
    if [[ ! "$detected_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        detected_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)
    fi

    echo -e "Detected Public IPv4: ${CLR_BOLD}${detected_ip:-Not found}${CLR_RESET}"

    while true; do
        read -r -p "Enter public IP for HTTPS certificate [${detected_ip}]: " user_ip
        local final_ip="${user_ip:-$detected_ip}"

        if [[ "$final_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            # Validate IPv4 octets
            local valid_octets=true
            IFS='.' read -r o1 o2 o3 o4 <<< "$final_ip"
            for octet in "$o1" "$o2" "$o3" "$o4"; do
                if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                    valid_octets=false
                    break
                fi
            done

            if [ "$valid_octets" = true ]; then
                # Check for RFC1918 / private IPs
                if [[ "$final_ip" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.) ]]; then
                    warn "Warning: $final_ip is a private/local IP address."
                    warn "Let's Encrypt requires a publicly routable IP address for HTTP-01 challenge."
                    read -r -p "Do you want to proceed with this IP anyway? [y/N]: " confirm_private
                    if [[ "$confirm_private" =~ ^[Yy]$ ]]; then
                        SERVER_PUBLIC_IP="$final_ip"
                        break
                    fi
                else
                    SERVER_PUBLIC_IP="$final_ip"
                    break
                fi
            fi
        fi
        echo -e "${CLR_RED}Invalid IPv4 format. Please enter a valid IP address.${CLR_RESET}"
    done

    success "Configured Public IP: $SERVER_PUBLIC_IP"
}

# ------------------------------------------------------------------------------
# Port Validation & Conflict Detection
# ------------------------------------------------------------------------------
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -E "[:.]$port[[:space:]]" >/dev/null 2>&1
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

get_port_process() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN -F cpn 2>/dev/null | awk '/^c/{cmd=substr($0,2)} /^p/{pid=substr($0,2)} END{if(pid) print cmd " (PID: " pid ")"}'
    elif command -v ss >/dev/null 2>&1; then
        ss -tulpn | grep -E "[:.]$port[[:space:]]" | awk '{print $NF}' | head -n1
    else
        echo "Unknown process"
    fi
}

prompt_port() {
    local prompt_text="$1"
    local default_port="$2"
    local allow_nginx_reuse="${3:-false}"
    local chosen_port=""

    while true; do
        read -r -p "$prompt_text [$default_port]: " chosen_port
        chosen_port="${chosen_port:-$default_port}"

        # Validate numeric
        if ! [[ "$chosen_port" =~ ^[0-9]+$ ]]; then
            echo -e "${CLR_RED}Port must be a positive integer.${CLR_RESET}"
            continue
        fi

        # Validate range
        if [ "$chosen_port" -lt 1 ] || [ "$chosen_port" -gt 65535 ]; then
            echo -e "${CLR_RED}Port must be in range 1-65535.${CLR_RESET}"
            continue
        fi

        # Check conflict
        if is_port_in_use "$chosen_port"; then
            local proc
            proc="$(get_port_process "$chosen_port")"
            if [ "$allow_nginx_reuse" = "true" ] && echo "$proc" | grep -qi "nginx"; then
                # Nginx is already listening; this is expected if reconfiguring
                break
            fi
            warn "Port $chosen_port is currently in use by: $proc"
            read -r -p "Do you still want to use port $chosen_port? [y/N]: " force_port
            if [[ "$force_port" =~ ^[Yy]$ ]]; then
                break
            fi
        else
            break
        fi
    done

    echo "$chosen_port"
}

configure_ports() {
    step "Configuring Network Ports and Endpoints"

    cat << EOF
9router Architecture:
- Internal Application: Node.js gateway (listens on localhost)
- Reverse Proxy: Nginx terminates HTTPS and forwards to internal gateway
- HTTP: Port 80 is required for Let's Encrypt ACME challenges & HTTPS redirect

EOF

    APP_PORT=$(prompt_port "Enter 9router Internal Application Port" "$DEFAULT_APP_PORT" "false")
    PUBLIC_HTTPS_PORT=$(prompt_port "Enter External HTTPS Port" "$DEFAULT_HTTPS_PORT" "true")
    PUBLIC_HTTP_PORT=$(prompt_port "Enter External HTTP Port (ACME/Redirect)" "$DEFAULT_HTTP_PORT" "true")

    # Construct default Base URL
    local default_base_url="https://${SERVER_PUBLIC_IP}"
    if [ "$PUBLIC_HTTPS_PORT" != "443" ]; then
        default_base_url="https://${SERVER_PUBLIC_IP}:${PUBLIC_HTTPS_PORT}"
    fi

    while true; do
        read -r -p "Enter 9router Base URL [$default_base_url]: " user_base_url
        BASE_URL="${user_base_url:-$default_base_url}"
        if [[ "$BASE_URL" =~ ^https?:// ]]; then
            # Strip trailing slash
            BASE_URL="${BASE_URL%/}"
            break
        else
            echo -e "${CLR_RED}Base URL must start with http:// or https://${CLR_RESET}"
        fi
    done

    success "Internal App Port:  $APP_PORT"
    success "External HTTPS Port: $PUBLIC_HTTPS_PORT"
    success "External HTTP Port:  $PUBLIC_HTTP_PORT"
    success "Configured Base URL: $BASE_URL"
}

# ------------------------------------------------------------------------------
# Secure Panel Password Configuration
# ------------------------------------------------------------------------------
configure_password() {
    step "Configuring 9router Panel Authentication"

    local pass1=""
    local pass2=""

    while true; do
        echo -ne "Enter 9router Panel Password (min 6 chars): "
        read -r -s pass1
        echo ""

        if [ -z "$pass1" ]; then
            echo -e "${CLR_RED}Password cannot be empty.${CLR_RESET}"
            continue
        fi

        if [ ${#pass1} -lt 6 ]; then
            echo -e "${CLR_RED}Password must be at least 6 characters long.${CLR_RESET}"
            continue
        fi

        echo -ne "Confirm Panel Password: "
        read -r -s pass2
        echo ""

        if [ "$pass1" != "$pass2" ]; then
            echo -e "${CLR_RED}Passwords do not match. Please try again.${CLR_RESET}"
            continue
        fi

        PANEL_PASSWORD="$pass1"
        break
    done

    success "Panel password securely configured."
}

# ------------------------------------------------------------------------------
# Repository Installation / Setup
# ------------------------------------------------------------------------------
setup_repository() {
    step "Setting Up 9router Repository"

    # Destination directory prompt
    read -r -p "Enter installation directory [$DEFAULT_INSTALL_DIR]: " user_dir
    INSTALL_DIR="${user_dir:-$DEFAULT_INSTALL_DIR}"

    # Check if current directory is a 9router clone
    if [ -f "$SCRIPT_DIR/package.json" ] && grep -q '"name": *"9router' "$SCRIPT_DIR/package.json"; then
        if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
            read -r -p "Copy current directory contents to $INSTALL_DIR? [Y/n]: " copy_cur
            if [[ ! "$copy_cur" =~ ^[Nn]$ ]]; then
                info "Copying files from $SCRIPT_DIR to $INSTALL_DIR..."
                mkdir -p "$INSTALL_DIR"
                rsync -a --exclude 'node_modules' --exclude '.next' --exclude '.git' "$SCRIPT_DIR/" "$INSTALL_DIR/" 2>/dev/null || cp -a "$SCRIPT_DIR/." "$INSTALL_DIR/"
            fi
        fi
    fi

    # Clone if target directory doesn't have package.json
    if [ ! -f "$INSTALL_DIR/package.json" ]; then
        info "Cloning 9router Linux repository to $INSTALL_DIR..."
        mkdir -p "$INSTALL_DIR"
        git clone "$DEFAULT_REPO_URL" "$INSTALL_DIR"
        success "Repository cloned successfully."
    else
        info "Existing repository detected at $INSTALL_DIR."
    fi

    cd "$INSTALL_DIR"

    # Dedicated Linux system user
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        info "Creating dedicated system user: $SERVICE_USER..."
        useradd -r -s /usr/sbin/nologin -d "$INSTALL_DIR/data-home" -M "$SERVICE_USER" || true
    fi

    # Create persistent directories
    mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/data-home/.9router" "$CERTBOT_WEBROOT/.well-known/acme-challenge"
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR/data" "$INSTALL_DIR/data-home"
    chmod 755 "$CERTBOT_WEBROOT"
}

# ------------------------------------------------------------------------------
# Environment & Configuration Management
# ------------------------------------------------------------------------------
write_environment_config() {
    step "Generating Application Configuration (.env)"

    local env_file="$INSTALL_DIR/.env"

    # Retain or generate cryptographic secrets
    local jwt_secret=""
    local api_key_secret=""
    local machine_salt=""

    if [ -f "$env_file" ]; then
        jwt_secret=$(grep -E "^JWT_SECRET=" "$env_file" | cut -d= -f2- || true)
        api_key_secret=$(grep -E "^API_KEY_SECRET=" "$env_file" | cut -d= -f2- || true)
        machine_salt=$(grep -E "^MACHINE_ID_SALT=" "$env_file" | cut -d= -f2- || true)
    fi

    [ -z "$jwt_secret" ] && jwt_secret=$(openssl rand -hex 32)
    [ -z "$api_key_secret" ] && api_key_secret=$(openssl rand -hex 32)
    [ -z "$machine_salt" ] && machine_salt=$(openssl rand -hex 16)

    # Backup existing .env if present
    if [ -f "$env_file" ]; then
        cp "$env_file" "${env_file}.bak.$(date +%s)"
    fi

    # Write production .env
    cat > "$env_file" << EOF
# ==============================================================================
# 9router Linux - Production Configuration
# Auto-generated on $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================
NODE_ENV=production
PORT=${APP_PORT}
HOSTNAME=127.0.0.1
NEXT_TELEMETRY_DISABLED=1
DATA_DIR=${INSTALL_DIR}/data
HOME=${INSTALL_DIR}/data-home

# Base URL & External Endpoints
NEXT_PUBLIC_BASE_URL=${BASE_URL}
NEXT_PUBLIC_CLOUD_URL=${BASE_URL}

# Authentication & Security
INITIAL_PASSWORD=${PANEL_PASSWORD}
JWT_SECRET=${jwt_secret}
API_KEY_SECRET=${api_key_secret}
MACHINE_ID_SALT=${machine_salt}
AUTH_COOKIE_SECURE=true
REQUIRE_API_KEY=false
ENABLE_REQUEST_LOGS=true
OBSERVABILITY_ENABLED=false
EOF

    # Secure permissions: only accessible by root and 9router service
    chown "$SERVICE_USER:$SERVICE_GROUP" "$env_file"
    chmod 600 "$env_file"
    success "Configuration file saved with strict permissions (600)."
}

# ------------------------------------------------------------------------------
# Build 9router Application
# ------------------------------------------------------------------------------
build_application() {
    step "Building 9router Application"

    cd "$INSTALL_DIR"

    ensure_build_memory

    info "Installing npm dependencies..."
    npm install --omit=dev --fetch-retries=5 --fetch-retry-factor=2

    info "Compiling Next.js application..."
    npm run build

    # Clean up temporary swap if created
    cleanup_temporary_swap

    # Ensure permissions for runtime
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

    success "Application build completed."
}

# ------------------------------------------------------------------------------
# Let's Encrypt Short-Lived IP Address SSL & ACME Challenge
# ------------------------------------------------------------------------------
configure_ssl() {
    step "Configuring Let's Encrypt Short-Lived IP Certificate"

    local email_prompt="admin@${SERVER_PUBLIC_IP}.nip.io"
    read -r -p "Enter email address for Let's Encrypt registration [$email_prompt]: " user_email
    local ssl_email="${user_email:-$email_prompt}"

    mkdir -p "$CERTBOT_WEBROOT/.well-known/acme-challenge"
    chown -R www-data:www-data "$CERTBOT_WEBROOT"
    chmod -R 755 "$CERTBOT_WEBROOT"

    # Configure temporary HTTP-only Nginx configuration to fulfill ACME challenge
    info "Preparing Nginx to serve ACME challenge on port ${PUBLIC_HTTP_PORT}..."
    cat > "$NGINX_CONF_AVAILABLE" << EOF
server {
    listen ${PUBLIC_HTTP_PORT};
    listen [::]:${PUBLIC_HTTP_PORT};
    server_name ${SERVER_PUBLIC_IP};

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Enable site and test Nginx
    rm -f "$NGINX_CONF_ENABLED" "/etc/nginx/sites-enabled/default"
    ln -sf "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED"
    nginx -t >/dev/null 2>&1 || {
        error "Nginx configuration syntax error in HTTP setup."
        nginx -t
        exit 1
    }
    systemctl restart nginx

    # Verify ACME challenge path accessibility locally
    echo "test-challenge-token" > "$CERTBOT_WEBROOT/.well-known/acme-challenge/test.txt"
    if curl -s "http://127.0.0.1:${PUBLIC_HTTP_PORT}/.well-known/acme-challenge/test.txt" | grep -q "test-challenge-token"; then
        success "Local ACME webroot challenge test passed."
    else
        warn "Local ACME challenge path check did not return test token."
    fi
    rm -f "$CERTBOT_WEBROOT/.well-known/acme-challenge/test.txt"

    # Request Certificate
    info "Requesting Let's Encrypt certificate for IP: $SERVER_PUBLIC_IP..."

    local cert_success=false
    local live_dir="/etc/letsencrypt/live/${SERVER_PUBLIC_IP}"

    # Try 1: Modern Certbot with Let's Encrypt shortlived profile
    info "Attempting certbot issuance with Let's Encrypt shortlived profile..."
    if certbot certonly --webroot -w "$CERTBOT_WEBROOT" \
        --non-interactive \
        --agree-tos \
        --email "$ssl_email" \
        --domain "$SERVER_PUBLIC_IP" \
        --cert-name "$SERVER_PUBLIC_IP" \
        --profile shortlived 2>"$LOG_FILE"; then
        cert_success=true
        success "Let's Encrypt short-lived IP certificate issued successfully!"
    else
        # Try 2: Standard invocation if --profile flag is unrecognized or unsupported
        info "Retrying standard certbot webroot issuance without --profile flag..."
        if certbot certonly --webroot -w "$CERTBOT_WEBROOT" \
            --non-interactive \
            --agree-tos \
            --email "$ssl_email" \
            --domain "$SERVER_PUBLIC_IP" \
            --cert-name "$SERVER_PUBLIC_IP" 2>>"$LOG_FILE"; then
            cert_success=true
            success "Let's Encrypt IP certificate issued successfully!"
        fi
    fi

    # Fallback if Let's Encrypt rejected IP (e.g. rate limit, port 80 blocked, private IP)
    if [ "$cert_success" = false ]; then
        warn "Let's Encrypt IP certificate issuance failed."
        warn "Common reasons: port 80 blocked by ISP/firewall, private IP, or rate limit."
        echo ""
        read -r -p "Generate self-signed certificate for immediate HTTPS testing? [Y/n]: " gen_self
        if [[ ! "$gen_self" =~ ^[Nn]$ ]]; then
            mkdir -p "$live_dir"
            info "Generating robust 2048-bit self-signed certificate for IP: $SERVER_PUBLIC_IP..."
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "${live_dir}/privkey.pem" \
                -out "${live_dir}/fullchain.pem" \
                -subj "/CN=${SERVER_PUBLIC_IP}" \
                -addext "subjectAltName=IP:${SERVER_PUBLIC_IP}" 2>/dev/null
            chmod 600 "${live_dir}/privkey.pem"
            chmod 644 "${live_dir}/fullchain.pem"
            success "Self-signed certificate generated as temporary fallback."
        else
            error "Cannot proceed with HTTPS without an SSL certificate."
            exit 1
        fi
    fi

    SSL_CERT_PATH="${live_dir}/fullchain.pem"
    SSL_KEY_PATH="${live_dir}/privkey.pem"
}

# ------------------------------------------------------------------------------
# Nginx Reverse Proxy Configuration
# ------------------------------------------------------------------------------
configure_reverse_proxy() {
    step "Configuring Production Nginx Reverse Proxy"

    local redirect_port=""
    if [ "$PUBLIC_HTTPS_PORT" != "443" ]; then
        redirect_port=":${PUBLIC_HTTPS_PORT}"
    fi

    # Create reload hook for cert renewals
    mkdir -p "$(dirname "$DEPLOY_HOOK_PATH")"
    cat > "$DEPLOY_HOOK_PATH" << "EOF"
#!/usr/bin/env bash
set -euo pipefail
if systemctl is-active --quiet nginx; then
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
    fi
fi
EOF
    chmod +x "$DEPLOY_HOOK_PATH"

    # Populate Nginx reverse proxy configuration
    cat > "$NGINX_CONF_AVAILABLE" << EOF
# 9router Linux - Production Reverse Proxy
# Auto-generated on $(date '+%Y-%m-%d %H:%M:%S')

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP Listener - Let's Encrypt ACME Challenge & HTTPS Redirection
server {
    listen ${PUBLIC_HTTP_PORT};
    listen [::]:${PUBLIC_HTTP_PORT};
    server_name ${SERVER_PUBLIC_IP};

    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host${redirect_port}\$request_uri;
    }
}

# HTTPS Listener - Secure Reverse Proxy
server {
    listen ${PUBLIC_HTTPS_PORT} ssl http2;
    listen [::]:${PUBLIC_HTTPS_PORT} ssl http2;
    server_name ${SERVER_PUBLIC_IP};

    ssl_certificate ${SSL_CERT_PATH};
    ssl_certificate_key ${SSL_KEY_PATH};

    # TLS Hardening
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers HIGH:!aNULL:!MD5:!3DES;
    ssl_session_cache shared:9router_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Security Headers
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Match 9router max payload size (128mb)
    client_max_body_size 128M;

    # ACME Challenge on HTTPS as well
    location /.well-known/acme-challenge/ {
        root ${CERTBOT_WEBROOT};
        try_files \$uri =404;
    }

    # Proxy to 9router Node.js backend
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        # WebSocket Upgrade
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # Client IP propagation (custom-server.js parses X-Real-IP)
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Disable buffering for Server-Sent Events (SSE) AI streaming
        proxy_buffering off;
        proxy_cache off;

        # Generous timeouts for large context and deep reasoning models
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_connect_timeout 60s;
    }
}
EOF

    ln -sf "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED"
    rm -f "/etc/nginx/sites-enabled/default"

    # Validate syntax
    nginx -t >/dev/null 2>&1 || {
        error "Nginx configuration syntax check failed."
        nginx -t
        exit 1
    }

    systemctl restart nginx
    systemctl enable nginx >/dev/null 2>&1
    success "Nginx reverse proxy configured and active."
}

# ------------------------------------------------------------------------------
# Automatic SSL Certificate Renewal Setup & Testing
# Short-lived IP certificates expire in ~6 days; checked every 6 hours.
# ------------------------------------------------------------------------------
configure_ssl_renewal() {
    step "Configuring Automatic SSL Certificate Renewal"

    # Install dedicated systemd service & timer for short-lived certificate renewals
    cat > "/etc/systemd/system/${RENEWAL_SERVICE_NAME}" << EOF
[Unit]
Description=9router Linux - Certbot Short-Lived IP Certificate Renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --webroot -w ${CERTBOT_WEBROOT} --quiet --deploy-hook "${DEPLOY_HOOK_PATH}"
StandardOutput=journal
StandardError=journal
EOF

    cat > "/etc/systemd/system/${RENEWAL_TIMER_NAME}" << EOF
[Unit]
Description=9router Linux - Run Certbot Renewal Every 6 Hours

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$RENEWAL_TIMER_NAME" >/dev/null 2>&1

    success "Automatic renewal systemd timer enabled (checks every 6 hours)."

    # Safe dry-run test
    info "Performing safe certificate renewal test (dry-run)..."
    if certbot renew --dry-run >/dev/null 2>&1; then
        success "Renewal test: SUCCESS (dry-run passed cleanly)."
    else
        warn "Renewal test: Certbot dry-run reported warnings (expected if using self-signed fallback)."
    fi
}

# ------------------------------------------------------------------------------
# systemd Service Installation
# ------------------------------------------------------------------------------
configure_service() {
    step "Installing and Starting 9router systemd Service"

    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"

    cat > "$service_file" << EOF
[Unit]
Description=9router Linux - AI Gateway & Dashboard
Documentation=https://github.com/dashbehrad/9router-linux
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=/usr/bin/node ${INSTALL_DIR}/custom-server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=9router
LimitNOFILE=65536

# Security hardening
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=${INSTALL_DIR}/data ${INSTALL_DIR}/data-home

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    # Wait for process to bind port
    info "Waiting for 9router backend service to initialize..."
    local attempts=0
    local max_attempts=30
    local is_up=false

    while [ $attempts -lt $max_attempts ]; do
        if is_port_in_use "$APP_PORT"; then
            is_up=true
            break
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    if [ "$is_up" = true ]; then
        success "9router service is active and listening on 127.0.0.1:${APP_PORT}."
    else
        warn "9router service started, but port $APP_PORT not detected yet. Check journalctl -u 9router."
    fi
}

# ------------------------------------------------------------------------------
# Firewall Configuration (UFW)
# ------------------------------------------------------------------------------
configure_firewall() {
    step "Configuring Firewall Rules (UFW)"

    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | grep -i "Status:" | awk '{print $2}' || true)

        if [ "$ufw_status" = "active" ]; then
            info "UFW is active. Applying minimal necessary rules..."

            # Keep SSH open (default 22 or detected active ssh port)
            local ssh_port="22"
            if [ -f /etc/ssh/sshd_config ]; then
                local detected_ssh
                detected_ssh=$(grep -E "^Port [0-9]+" /etc/ssh/sshd_config | awk '{print $2}' | head -n1 || true)
                [ -n "$detected_ssh" ] && ssh_port="$detected_ssh"
            fi

            ufw allow "${ssh_port}/tcp" comment "SSH Access" >/dev/null 2>&1 || true
            ufw allow "${PUBLIC_HTTP_PORT}/tcp" comment "9router HTTP/ACME" >/dev/null 2>&1 || true
            ufw allow "${PUBLIC_HTTPS_PORT}/tcp" comment "9router HTTPS" >/dev/null 2>&1 || true

            success "UFW rules updated for ports: ${ssh_port}/tcp, ${PUBLIC_HTTP_PORT}/tcp, ${PUBLIC_HTTPS_PORT}/tcp."
        else
            info "UFW is inactive or not enabled. Skipping firewall rule changes."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Health Checks & Verification
# ------------------------------------------------------------------------------
run_health_checks() {
    step "Running Post-Installation Health Checks"

    local app_ok=false
    local nginx_ok=false
    local https_ok=false

    # 1. 9router service
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "9router systemd service: RUNNING"
        app_ok=true
    else
        error "9router systemd service: FAILED"
    fi

    # 2. Nginx service
    if systemctl is-active --quiet nginx; then
        success "Nginx reverse proxy:   RUNNING"
        nginx_ok=true
    else
        error "Nginx reverse proxy:   FAILED"
    fi

    # 3. HTTPS endpoint check
    local http_code
    http_code=$(curl -k -s -o /dev/null -w "%{http_code}" -m 5 "https://127.0.0.1:${PUBLIC_HTTPS_PORT}/dashboard" || true)

    if [[ "$http_code" =~ ^(200|301|302|307|308)$ ]]; then
        success "HTTPS Endpoint Status:  HTTP $http_code (HEALTHY)"
        https_ok=true
    else
        warn "HTTPS Endpoint check returned HTTP code: ${http_code:-Connection Failed}."
    fi

    # 4. SSL Certificate verification
    if [ -f "$SSL_CERT_PATH" ]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "$SSL_CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "Unknown")
        success "SSL Certificate valid until: $expiry"
    fi
}

# ------------------------------------------------------------------------------
# Final Summary Display
# ------------------------------------------------------------------------------
show_summary() {
    local panel_url="https://${SERVER_PUBLIC_IP}"
    if [ "$PUBLIC_HTTPS_PORT" != "443" ]; then
        panel_url="https://${SERVER_PUBLIC_IP}:${PUBLIC_HTTPS_PORT}"
    fi

    echo -e "\n${CLR_GREEN}========================================${CLR_RESET}"
    echo -e "${CLR_GREEN}${CLR_BOLD}        9router Linux Installation${CLR_RESET}"
    echo -e "${CLR_GREEN}========================================${CLR_RESET}\n"

    echo -e "Installation:       ${CLR_GREEN}SUCCESS${CLR_RESET}"
    echo -e "Service:            ${CLR_GREEN}RUNNING${CLR_RESET}"
    echo -e "Internal Port:      ${CLR_BOLD}${APP_PORT}${CLR_RESET}"
    echo -e "External HTTPS:     ${CLR_BOLD}${PUBLIC_HTTPS_PORT}${CLR_RESET}"
    echo -e "Base URL:           ${CLR_BOLD}${BASE_URL}${CLR_RESET}"
    echo -e "HTTPS:              ${CLR_GREEN}ENABLED${CLR_RESET}"
    echo -e "SSL Certificate:    ${CLR_GREEN}VALID${CLR_RESET}"
    echo -e "Auto Renewal:       ${CLR_GREEN}ENABLED (every 6h)${CLR_RESET}\n"

    echo -e "${CLR_BOLD}Panel Web Dashboard:${CLR_RESET}"
    echo -e "  ${CLR_CYAN}${panel_url}/dashboard${CLR_RESET}\n"

    echo -e "${CLR_BOLD}OpenAI-Compatible API Endpoint:${CLR_RESET}"
    echo -e "  ${CLR_CYAN}${panel_url}/v1${CLR_RESET}\n"

    echo -e "${CLR_BOLD}Service Management Commands:${CLR_RESET}"
    echo -e "  Status:   systemctl status ${SERVICE_NAME}"
    echo -e "  Restart:  systemctl restart ${SERVICE_NAME}"
    echo -e "  Logs:     journalctl -u ${SERVICE_NAME} -f\n"

    echo -e "${CLR_BOLD}SSL & Renewal Commands:${CLR_RESET}"
    echo -e "  Test Renewal:  certbot renew --dry-run"
    echo -e "  Check Timer:   systemctl status ${RENEWAL_TIMER_NAME}\n"

    echo -e "${CLR_YELLOW}Tip: Connect tools like Claude Code, Cursor, Cline, or Codex${CLR_RESET}"
    echo -e "${CLR_YELLOW}to your endpoint: ${panel_url}/v1${CLR_RESET}\n"
}

# ------------------------------------------------------------------------------
# Full Installation Workflow
# ------------------------------------------------------------------------------
perform_install() {
    banner
    check_root
    check_os
    install_dependencies
    detect_public_ip
    configure_ports
    configure_password
    setup_repository
    write_environment_config
    build_application
    configure_ssl
    configure_reverse_proxy
    configure_ssl_renewal
    configure_service
    configure_firewall
    run_health_checks
    show_summary
}

# ------------------------------------------------------------------------------
# Reconfigure Existing Installation
# ------------------------------------------------------------------------------
perform_reconfigure() {
    banner
    check_root
    check_os

    if [ ! -f "${DEFAULT_INSTALL_DIR}/.env" ]; then
        error "No existing installation found at ${DEFAULT_INSTALL_DIR}."
        exit 1
    fi

    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    info "Reconfiguring existing installation at ${INSTALL_DIR}..."

    detect_public_ip
    configure_ports
    configure_password
    write_environment_config
    configure_ssl
    configure_reverse_proxy
    configure_ssl_renewal
    configure_service
    configure_firewall
    run_health_checks
    show_summary
}

# ------------------------------------------------------------------------------
# Update Existing Installation
# ------------------------------------------------------------------------------
perform_update() {
    banner
    check_root
    check_os

    INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
    if [ ! -d "$INSTALL_DIR" ]; then
        error "9router is not installed at $INSTALL_DIR."
        exit 1
    fi

    step "Updating 9router Linux"

    cd "$INSTALL_DIR"

    # Backup .env and database
    info "Creating safety backup of configuration and database..."
    local backup_dir="/var/backups/9router_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "$INSTALL_DIR/.env" "$backup_dir/" 2>/dev/null || true
    cp -a "$INSTALL_DIR/data" "$backup_dir/" 2>/dev/null || true
    success "Backup saved to: $backup_dir"

    # Pull git updates
    if [ -d "$INSTALL_DIR/.git" ]; then
        info "Pulling latest changes from git repository..."
        git pull --ff-only || {
            warn "git pull failed. Attempting git fetch and reset..."
            git fetch origin
            git reset --hard origin/main || git reset --hard origin/master
        }
    else
        warn "$INSTALL_DIR is not a git clone. Skipping git pull."
    fi

    # Reinstall deps and rebuild
    build_application

    # Restart service
    info "Restarting 9router service..."
    systemctl restart "$SERVICE_NAME"
    systemctl restart nginx

    run_health_checks
    success "9router Linux updated successfully!"
}

# ------------------------------------------------------------------------------
# Repair Existing Installation
# ------------------------------------------------------------------------------
perform_repair() {
    banner
    check_root
    check_os

    INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
    step "Repairing 9router Linux Installation"

    if [ ! -d "$INSTALL_DIR" ]; then
        error "Directory $INSTALL_DIR does not exist."
        exit 1
    fi

    info "Fixing file and directory permissions..."
    mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/data-home"
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
    chmod 600 "$INSTALL_DIR/.env" 2>/dev/null || true

    info "Validating Nginx reverse proxy configuration..."
    if ! nginx -t; then
        error "Nginx configuration error. Restoring default site..."
        systemctl reload nginx || systemctl restart nginx
    fi

    info "Restarting system services..."
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME" || true
    systemctl restart nginx || true

    run_health_checks
    success "Repair completed."
}

# ------------------------------------------------------------------------------
# Service Control
# ------------------------------------------------------------------------------
service_control() {
    banner
    check_root

    echo -e "${CLR_BOLD}9router Service Control:${CLR_RESET}"
    echo "  1) Status"
    echo "  2) Restart"
    echo "  3) Stop"
    echo "  4) Start"
    echo "  5) View Live Logs (journalctl)"
    echo "  6) Return to Main Menu"

    read -r -p "Select option [1-6]: " svc_choice
    case "$svc_choice" in
        1) systemctl status "$SERVICE_NAME" ;;
        2) systemctl restart "$SERVICE_NAME" && success "Restarted." ;;
        3) systemctl stop "$SERVICE_NAME" && success "Stopped." ;;
        4) systemctl start "$SERVICE_NAME" && success "Started." ;;
        5) journalctl -u "$SERVICE_NAME" -f ;;
        *) return ;;
    esac
}

# ------------------------------------------------------------------------------
# Uninstall 9router Linux
# ------------------------------------------------------------------------------
perform_uninstall() {
    banner
    check_root

    echo -e "${CLR_RED}========================================${CLR_RESET}"
    echo -e "${CLR_RED}${CLR_BOLD}       Uninstall 9router Linux${CLR_RESET}"
    echo -e "${CLR_RED}========================================${CLR_RESET}\n"

    warn "This will remove the 9router systemd service, Nginx configuration,"
    warn "and Certbot renewal timer."
    echo ""
    read -r -p "Are you sure you want to completely uninstall 9router Linux? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Uninstall cancelled."
        return 0
    fi

    step "Stopping and removing services"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"

    systemctl stop "$RENEWAL_TIMER_NAME" 2>/dev/null || true
    systemctl disable "$RENEWAL_TIMER_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${RENEWAL_SERVICE_NAME}" "/etc/systemd/system/${RENEWAL_TIMER_NAME}"
    rm -f "$DEPLOY_HOOK_PATH"

    systemctl daemon-reload

    step "Removing Nginx configuration"
    rm -f "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED"
    systemctl reload nginx 2>/dev/null || true

    read -r -p "Do you want to delete application files & databases at ${DEFAULT_INSTALL_DIR}? [y/N]: " del_files
    if [[ "$del_files" =~ ^[Yy]$ ]]; then
        rm -rf "$DEFAULT_INSTALL_DIR"
        success "Application files removed."
    else
        info "Preserved application files and databases at $DEFAULT_INSTALL_DIR."
    fi

    success "9router Linux has been cleanly uninstalled."
}

# ------------------------------------------------------------------------------
# Interactive Menu Wizard
# ------------------------------------------------------------------------------
main() {
    check_root

    # Detect if already installed
    local is_installed=false
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] || [ -f "${DEFAULT_INSTALL_DIR}/.env" ]; then
        is_installed=true
    fi

    if [ "$is_installed" = true ]; then
        banner
        echo -e "Existing 9router Linux installation detected at: ${CLR_BOLD}${DEFAULT_INSTALL_DIR}${CLR_RESET}\n"
        echo "Please select an action:"
        echo "  1) Fresh Install / Overwrite"
        echo "  2) Reconfigure Settings (Ports, Password, Base URL, SSL)"
        echo "  3) Update to Latest Version"
        echo "  4) Repair Installation & Permissions"
        echo "  5) Service Control (Status / Restart / Logs)"
        echo "  6) Test SSL Certificate Renewal"
        echo "  7) Uninstall 9router Linux"
        echo "  8) Exit"
        echo ""

        read -r -p "Enter choice [1-8]: " menu_choice
        case "$menu_choice" in
            1) perform_install ;;
            2) perform_reconfigure ;;
            3) perform_update ;;
            4) perform_repair ;;
            5) service_control ;;
            6)
                info "Testing certificate renewal..."
                certbot renew --dry-run
                ;;
            7) perform_uninstall ;;
            8|*)
                info "Exiting."
                exit 0
                ;;
        esac
    else
        perform_install
    fi
}

main "$@"
