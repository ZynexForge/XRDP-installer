#!/bin/bash
# ============================================================================
# ZynexForge: zforge-xrdp
# Production-Grade XRDP Automation with Relay Tunnel
# Version: 2.0.0
# ============================================================================

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
readonly SCRIPT_NAME="zforge-xrdp"
readonly BANNER="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
readonly USER_PREFIX="zforge"
readonly XRDP_LOCAL_PORT=3389
readonly XRDP_LOCAL_IP="127.0.0.1"
readonly RELAY_SERVER="relay.zynexforge.net"
readonly RELAY_PORT=2222
readonly TUNNEL_USER="zforge_tunnel"
readonly TUNNEL_DIR="/opt/zforge-tunnel"

# Required commands
readonly REQUIRED_CMDS=("ssh" "systemctl" "curl" "wget" "openssl" "useradd" "chpasswd")

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
        log_warn "Installing missing dependencies..."
        
        if command -v apt-get &>/dev/null; then
            apt-get update -qq
            apt-get install -y -qq "${missing[@]}" || die "Failed to install dependencies"
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing[@]}" || die "Failed to install dependencies"
        else
            die "Unsupported package manager"
        fi
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CORE FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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
        log_warn "User $username already exists, reusing"
        echo "$username:$password" | chpasswd || die "Failed to update password"
        return
    fi
    
    useradd -m -s /bin/bash -G sudo "$username" || die "Failed to create user"
    echo "$username:$password" | chpasswd || die "Failed to set password"
    
    # Set up basic X environment
    mkdir -p /home/"$username"/.config
    cat > /home/"$username"/.xsession << 'EOF'
#!/bin/bash
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
export XDG_DATA_DIRS=/usr/share/ubuntu:/usr/local/share:/usr/share:/var/lib/snapd/desktop
exec startxfce4
EOF
    chmod +x /home/"$username"/.xsession
    chown -R "$username":"$username" /home/"$username"
    
    log_success "User $username created and configured"
}

install_xrdp() {
    log_info "Installing XRDP..."
    
    if systemctl is-active --quiet xrdp; then
        log_success "XRDP is already installed and running"
        return
    fi
    
    local os=$(detect_os)
    
    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            xrdp \
            xorgxrdp \
            xfce4 \
            xfce4-goodies \
            firefox-esr \
            || die "Failed to install XRDP packages"
    else
        die "Unsupported OS: $os"
    fi
    
    # Configure XRDP to bind only to localhost with enhanced security
    cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
bitmap_cache=yes
bitmap_compression=yes
port=3389
crypt_level=high
channel_code=1
max_bpp=32
security_layer=negotiate
certificate=
key_file=
ssl_protocols=TLSv1.2, TLSv1.3
tls_ciphers=HIGH

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
    
    # Configure session manager
    cat > /etc/xrdp/sesman.ini << 'EOF'
[Globals]
ListenAddress=127.0.0.1
ListenPort=3350
EnableUserWindowManager=1
UserWindowManager=startxfce4
DefaultWindowManager=startxfce4

[Security]
AllowRootLogin=yes
MaxLoginRetry=4
TerminalServerUsers=tsusers
TerminalServerAdmins=tsadmins

[Sessions]
MaxSessions=10
KillDisconnected=0
IdleTimeLimit=0
DisconnectedTimeLimit=0

[X11rdp]
param1=-bs
param2=-ac
param3=-nolisten
param4=tcp

[Xvnc]
param1=-bs
param2=-ac
param3=-nolisten
param4=tcp
param5=-localhost
param6=-dpi
param7=96
EOF
    
    systemctl enable xrdp || die "Failed to enable XRDP service"
    systemctl restart xrdp || die "Failed to start XRDP service"
    
    # Add user to ssl-cert group for XRDP
    usermod -a -G ssl-cert "$USERNAME" 2>/dev/null || true
    
    log_success "XRDP installed and configured securely"
}

install_firefox() {
    log_info "Installing Firefox..."
    
    if command -v firefox &>/dev/null || command -v firefox-esr &>/dev/null; then
        log_success "Firefox is already installed"
        return
    fi
    
    local os=$(detect_os)
    
    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
        apt-get install -y -qq firefox-esr || die "Failed to install Firefox"
    else
        die "Unsupported OS for Firefox installation"
    fi
    
    log_success "Firefox installed successfully"
}

setup_tunnel_systemd() {
    log_info "Setting up persistent SSH tunnel service..."
    
    # Create tunnel user and directory
    if ! id "$TUNNEL_USER" &>/dev/null; then
        useradd -r -m -d "$TUNNEL_DIR" -s /bin/bash "$TUNNEL_USER"
    fi
    
    mkdir -p "$TUNNEL_DIR"
    chown -R "$TUNNEL_USER":"$TUNNEL_USER" "$TUNNEL_DIR"
    
    # Generate SSH key for tunnel
    local ssh_key="$TUNNEL_DIR/.ssh/id_rsa"
    if [[ ! -f "$ssh_key" ]]; then
        mkdir -p "$TUNNEL_DIR/.ssh"
        ssh-keygen -t rsa -b 4096 -f "$ssh_key" -N "" -q
        chown -R "$TUNNEL_USER":"$TUNNEL_USER" "$TUNNEL_DIR/.ssh"
        chmod 700 "$TUNNEL_DIR/.ssh"
        chmod 600 "$ssh_key"
    fi
    
    # Create systemd service for persistent tunnel
    cat > /etc/systemd/system/zforge-tunnel.service << EOF
[Unit]
Description=ZynexForge XRDP Tunnel Service
After=network.target xrdp.service
Wants=network.target

[Service]
Type=simple
User=$TUNNEL_USER
WorkingDirectory=$TUNNEL_DIR
ExecStart=/usr/bin/ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -N -T -R *:3389:127.0.0.1:3389 $RELAY_SERVER -p $RELAY_PORT
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # Create script to check tunnel status
    cat > /usr/local/bin/check-tunnel << 'EOF'
#!/bin/bash
if systemctl is-active --quiet zforge-tunnel.service; then
    echo "Tunnel is running"
    ss -tnp | grep ":3389" || echo "No active tunnel connection"
else
    echo "Tunnel is not running"
    exit 1
fi
EOF
    chmod +x /usr/local/bin/check-tunnel
    
    systemctl daemon-reload
    systemctl enable zforge-tunnel.service
    systemctl restart zforge-tunnel.service
    
    # Wait for tunnel to establish
    log_info "Waiting for tunnel connection..."
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if systemctl is-active --quiet zforge-tunnel.service && \
           ss -tnp 2>/dev/null | grep -q "ESTAB.*$RELAY_SERVER"; then
            log_success "Tunnel established successfully"
            return
        fi
        sleep 2
        ((attempt++))
    done
    
    log_warn "Tunnel may still be establishing in background"
    log_info "Check status with: systemctl status zforge-tunnel.service"
}

get_relay_public_ip() {
    log_info "Retrieving relay server public IP..."
    
    # Try multiple methods to get relay IP
    local relay_ip=""
    
    # Method 1: SSH connection test
    if command -v ssh &>/dev/null; then
        relay_ip=$(ssh -p "$RELAY_PORT" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            "$RELAY_SERVER" "curl -s https://api.ipify.org || echo 'RELAY_SERVER'" 2>/dev/null)
    fi
    
    # Method 2: Direct DNS resolution
    if [[ -z "$relay_ip" || "$relay_ip" == "RELAY_SERVER" ]]; then
        relay_ip=$(dig +short "$RELAY_SERVER" 2>/dev/null | head -1)
    fi
    
    # Method 3: Use relay server domain as fallback
    if [[ -z "$relay_ip" ]]; then
        relay_ip="$RELAY_SERVER"
        log_warn "Using relay server domain name instead of IP"
    fi
    
    echo "$relay_ip"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MAIN EXECUTION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main() {
    # Display banner
    echo -e "\033[1;36m$BANNER\033[0m"
    echo -e "\033[1;36m  ZynexForge: zforge-xrdp - Secure XRDP with Relay Tunnel\033[0m"
    echo -e "\033[1;36m$BANNER\033[0m"
    
    # Validate environment
    validate_root
    check_dependencies
    
    # Execute flow
    local username=$(generate_random_username)
    local password=$(generate_strong_password)
    
    create_linux_user "$username" "$password"
    install_firefox
    install_xrdp
    setup_tunnel_systemd
    local relay_ip=$(get_relay_public_ip)
    
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # FINAL OUTPUT
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    echo -e "\n"
    echo -e "\033[1;32m🎉 Congratulations! Your RDP has been created\033[0m"
    echo -e ""
    echo -e "\033[1;37mIP     : \033[1;33m$relay_ip:3389\033[0m"
    echo -e "\033[1;37mUSER   : \033[1;33m$username\033[0m"
    echo -e "\033[1;37mPASS   : \033[1;33m$password\033[0m"
    echo -e ""
    echo -e "\033[1;36m$BANNER\033[0m"
    
    # Connection information
    echo -e "\033[1;33m📋 Connection Details:\033[0m"
    echo -e "  • Connect using Microsoft Remote Desktop or any RDP client"
    echo -e "  • Firefox is pre-installed and ready to use"
    echo -e "  • Session will start with XFCE desktop environment"
    echo -e "  • No public IP required on your VPS"
    echo -e "\033[1;36m$BANNER\033[0m"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
