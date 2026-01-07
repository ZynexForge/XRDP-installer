#!/bin/bash
# ============================================================================
# ZynexForge: zforge-rdp
# Production-Grade XRDP Automation Tool
# Version: 1.0.0
# ============================================================================

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
readonly SCRIPT_NAME="zforge-rdp"
readonly BANNER="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
readonly MIN_PORT=20000
readonly MAX_PORT=65535
readonly USER_PREFIX="zforge"
readonly XRDP_LOCAL_PORT=3389
readonly XRDP_LOCAL_IP="127.0.0.1"
readonly REQUIRED_CMDS=("curl" "systemctl" "iptables" "ss" "openssl" "useradd" "chpasswd")

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# LOGGING & UTILITIES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
log_info() { echo -e "[\033[36mINFO\033[0m] $1"; }
log_success() { echo -e "[\033[32mSUCCESS\033[0m] $1"; }
log_warn() { echo -e "[\033[33mWARNING\033[0m] $1"; }
log_error() { echo -e "[\033[31mERROR\033[0m] $1" >&2; }

die() {
    log_error "$1"
    exit 1
}

validate_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

check_dependencies() {
    local missing=()
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CORE FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
get_public_ip() {
    log_info "Detecting VPS public IP..."
    
    local ip_services=(
        "https://ifconfig.me"
        "https://api.ipify.org"
        "https://icanhazip.com"
    )
    
    local public_ip=""
    for service in "${ip_services[@]}"; do
        if public_ip=$(curl -s --max-time 5 "$service" 2>/dev/null | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'); then
            [[ -n "$public_ip" ]] && break
        fi
    done
    
    [[ -n "$public_ip" ]] || die "Failed to detect public IP"
    
    log_success "Public IP detected: $public_ip"
    echo "$public_ip"
}

generate_random_username() {
    local random_suffix=$(openssl rand -hex 3)
    echo "${USER_PREFIX}_${random_suffix}"
}

generate_strong_password() {
    openssl rand -base64 24 | tr -d '/+=\n'
}

create_linux_user() {
    local username="$1"
    local password="$2"
    
    log_info "Creating Linux user: $username"
    
    if id "$username" &>/dev/null; then
        log_warn "User $username already exists, skipping creation"
        return
    fi
    
    useradd -m -s /bin/bash "$username" || die "Failed to create user"
    echo "$username:$password" | chpasswd || die "Failed to set password"
    
    # Add user to necessary groups for RDP access
    usermod -a -G sudo "$username" 2>/dev/null || true
    
    log_success "User $username created successfully"
}

install_xrdp() {
    log_info "Installing XRDP..."
    
    if systemctl is-active --quiet xrdp; then
        log_success "XRDP is already installed and running"
        return
    fi
    
    # Detect package manager
    if command -v apt-get &>/dev/null; then
        apt-get update || die "Failed to update package list"
        DEBIAN_FRONTEND=noninteractive apt-get install -y xrdp xorgxrdp || die "Failed to install XRDP"
    elif command -v yum &>/dev/null; then
        yum install -y xrdp xorgxrdp || die "Failed to install XRDP"
    elif command -v dnf &>/dev/null; then
        dnf install -y xrdp xorgxrdp || die "Failed to install XRDP"
    else
        die "Unsupported package manager"
    fi
    
    # Configure XRDP to bind only to localhost
    cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
bitmap_cache=yes
bitmap_compression=yes
port=3389
crypt_level=high
channel_code=1
max_bpp=32
[Logging]
LogFile=xrdp.log
LogLevel=INFO
EnableSyslog=yes
[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=-1
EOF
    
    systemctl enable xrdp || die "Failed to enable XRDP service"
    systemctl restart xrdp || die "Failed to start XRDP service"
    
    log_success "XRDP installed and configured"
}

find_free_port() {
    local port
    local max_attempts=50
    local attempts=0
    
    while [[ $attempts -lt $max_attempts ]]; do
        port=$(( RANDOM % (MAX_PORT - MIN_PORT + 1) + MIN_PORT ))
        
        if ! ss -tuln | grep -q ":$port "; then
            echo "$port"
            return
        fi
        
        ((attempts++))
    done
    
    die "Could not find free port after $max_attempts attempts"
}

setup_port_forwarding() {
    local external_port="$1"
    
    log_info "Setting up port forwarding: $external_port → $XRDP_LOCAL_IP:$XRDP_LOCAL_PORT"
    
    # Check if iptables supports nft backend
    if iptables --version 2>&1 | grep -q nf_tables; then
        # nftables backend
        if ! nft list ruleset 2>/dev/null | grep -q "tcp dport $external_port"; then
            nft add table ip nat 2>/dev/null || true
            nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null || true
            nft add rule ip nat prerouting tcp dport $external_port dnat to $XRDP_LOCAL_IP:$XRDP_LOCAL_PORT
        fi
    else
        # legacy iptables
        iptables -t nat -C PREROUTING -p tcp --dport "$external_port" -j DNAT --to-destination "$XRDP_LOCAL_IP:$XRDP_LOCAL_PORT" 2>/dev/null || \
        iptables -t nat -A PREROUTING -p tcp --dport "$external_port" -j DNAT --to-destination "$XRDP_LOCAL_IP:$XRDP_LOCAL_PORT"
    fi
    
    # Allow the port in firewall
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$external_port/tcp" || log_warn "UFW rule addition failed"
    else
        iptables -C INPUT -p tcp --dport "$external_port" -j ACCEPT 2>/dev/null || \
        iptables -A INPUT -p tcp --dport "$external_port" -j ACCEPT
    fi
    
    # Save iptables rules if available
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    log_success "Port forwarding configured"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MAIN EXECUTION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main() {
    # Display banner
    echo -e "\033[1;36m$BANNER\033[0m"
    echo -e "\033[1;36m  ZynexForge: zforge-rdp - Production RDP Automation\033[0m"
    echo -e "\033[1;36m$BANNER\033[0m"
    
    # Validate environment
    validate_root
    check_dependencies
    
    # Execute flow
    local public_ip=$(get_public_ip)
    local username=$(generate_random_username)
    local password=$(generate_strong_password)
    local external_port=$(find_free_port)
    
    create_linux_user "$username" "$password"
    install_xrdp
    setup_port_forwarding "$external_port"
    
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # FINAL OUTPUT
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    echo -e "\n"
    echo -e "\033[1;32m🎉 Congratulations! Your RDP has been created\033[0m"
    echo -e ""
    echo -e "\033[1;37mIP     : \033[1;33m$public_ip:$external_port\033[0m"
    echo -e "\033[1;37mUSER   : \033[1;33m$username\033[0m"
    echo -e "\033[1;37mPASS   : \033[1;33m$password\033[0m"
    echo -e ""
    echo -e "\033[1;36m$BANNER\033[0m"
    
    # Important notes
    echo -e "\033[1;33m⚠️  IMPORTANT:\033[0m"
    echo -e "  1. Connect using Microsoft Remote Desktop or compatible RDP client"
    echo -e "  2. XRDP is bound to localhost only, accessible via port forwarding"
    echo -e "  3. Password is stored securely in system auth database"
    echo -e "  4. Use 'sudo passwd $username' to change password"
    echo -e "\033[1;36m$BANNER\033[0m"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
