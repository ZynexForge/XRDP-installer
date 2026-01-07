#!/bin/bash
# ============================================================================
# ZynexForge: zforge-xrdp
# Production-Grade XRDP Automation with Relay Tunnel
# Version: 2.3.0
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
readonly REQUIRED_CMDS=("ssh" "systemctl" "curl" "openssl" "useradd" "chpasswd")

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
    
    # Set up XFCE environment
    mkdir -p /home/"$username"/.config
    cat > /home/"$username"/.xsession << 'EOF'
#!/bin/bash
export XDG_CURRENT_DESKTOP=XFCE
export XDG_CONFIG_DIRS=/etc/xdg/xdg-xfce:/etc/xdg
export XDG_DATA_DIRS=/usr/share/xfce4:/usr/local/share:/usr/share
exec startxfce4
EOF
    chmod +x /home/"$username"/.xsession
    chown -R "$username":"$username" /home/"$username"
    
    log_success "User $username created and configured"
}

install_xrdp() {
    log_info "Installing XRDP and desktop environment..."
    
    if systemctl is-active --quiet xrdp; then
        log_success "XRDP is already installed and running"
        return
    fi
    
    local os=$(detect_os)
    
    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
        apt-get update -qq
        
        # Install XRDP and XFCE desktop environment
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            xrdp \
            xorgxrdp \
            xfce4 \
            xfce4-goodies \
            xfce4-terminal \
            || die "Failed to install XRDP packages"
            
        # Additional XFCE components for better experience
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            xfce4-panel \
            xfce4-session \
            xfce4-settings \
            xfce4-appfinder \
            xfdesktop4 \
            xfwm4 \
            thunar \
            || log_warn "Some XFCE components failed to install"
            
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
    
    # Ensure XRDP uses XFCE for all users
    echo "xfce4-session" > /etc/xrdp/startwm.sh
    chmod +x /etc/xrdp/startwm.sh
    
    systemctl enable xrdp || die "Failed to enable XRDP service"
    systemctl restart xrdp || die "Failed to start XRDP service"
    
    log_success "XRDP installed and configured securely"
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
ExecStart=/usr/bin/ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -N -T -R *:3389:127.0.0.1:3389 $RELAY_SERVER -p $RELAY_PORT
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable zforge-tunnel.service
    
    # Start the tunnel service
    systemctl restart zforge-tunnel.service
    
    # Wait for tunnel to establish
    log_info "Establishing tunnel connection..."
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if systemctl is-active --quiet zforge-tunnel.service; then
            # Check if SSH process is running
            if pgrep -f "ssh.*$RELAY_SERVER.*3389" >/dev/null; then
                log_success "Tunnel established successfully"
                return
            fi
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
    
    # Method 1: Try to resolve domain
    if command -v dig &>/dev/null; then
        relay_ip=$(dig +short "$RELAY_SERVER" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    fi
    
    # Method 2: Try nslookup
    if [[ -z "$relay_ip" ]] && command -v nslookup &>/dev/null; then
        relay_ip=$(nslookup "$RELAY_SERVER" 2>/dev/null | grep -E 'Address: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}' | head -1)
    fi
    
    # Method 3: Try getent
    if [[ -z "$relay_ip" ]] && command -v getent &>/dev/null; then
        relay_ip=$(getent ahosts "$RELAY_SERVER" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $1}' | head -1)
    fi
    
    # Method 4: Try ping (just for resolution)
    if [[ -z "$relay_ip" ]] && command -v ping &>/dev/null; then
        relay_ip=$(ping -c 1 -W 1 "$RELAY_SERVER" 2>/dev/null | grep -E 'PING [a-zA-Z0-9.-]+ \([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\)' | sed -E 's/.*\(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\).*/\1/')
    fi
    
    # Method 5: Use curl to external service if domain doesn't resolve
    if [[ -z "$relay_ip" ]]; then
        relay_ip=$(curl -s --max-time 5 "https://api.ipify.org" 2>/dev/null || echo "")
        if [[ -n "$relay_ip" ]]; then
            log_warn "Could not resolve relay domain, using detected public IP: $relay_ip"
        fi
    fi
    
    # Final fallback
    if [[ -z "$relay_ip" ]]; then
        relay_ip="$RELAY_SERVER"
        log_warn "Using relay server domain name: $RELAY_SERVER"
    else
        log_success "Relay IP resolved: $relay_ip"
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
    
    # Update package lists first
    log_info "Updating system packages..."
    apt-get update -qq || log_warn "Package update had issues"
    
    check_dependencies
    
    # Execute flow
    local username=$(generate_random_username)
    local password=$(generate_strong_password)
    
    create_linux_user "$username" "$password"
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
    
    # Service status
    echo -e "\033[1;33m⚡ Service Status:\033[0m"
    echo -e "  XRDP: $(systemctl is-active xrdp.service)"
    echo -e "  Tunnel: $(systemctl is-active zforge-tunnel.service)"
    echo -e "\033[1;36m$BANNER\033[0m"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
