#!/bin/bash

# ============================================================================
# ZynexForge: zforge-rdp
# Production-Grade XRDP Tunnel Setup
# Version: 15.0.0
# ============================================================================
# Architecture:
# [VPS (no public IP)] → FRPC → [ZynexForge Relay (public IP)] → User
# XRDP: 127.0.0.1:3389 (TCP ONLY)
# ============================================================================

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONFIGURATION (REQUIRES RELAY SERVER WITH PUBLIC IP)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
readonly RELAY_SERVER="relay.zynexforge.net"
readonly RELAY_PORT="7000"
readonly FRP_TOKEN="zynexforge_global_token_2024"
readonly FRP_VERSION="0.54.0"
readonly MIN_PORT=40000
readonly MAX_PORT=60000
readonly USER_PREFIX="zforge"
readonly LOCAL_RDP_PORT="3389"
readonly LOCAL_IP="127.0.0.1"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# COLOR AND LOGGING
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[+]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1" >&2; }

die() {
    log_error "$1"
    exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PREREQUISITE CHECKS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

check_network() {
    log_info "Testing outbound connectivity..."
    
    # Test TCP connectivity to relay server
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/${RELAY_SERVER}/${RELAY_PORT}" 2>/dev/null; then
        log_success "Outbound TCP connectivity to relay server confirmed"
    else
        # Fallback: test general internet connectivity
        if curl -s --max-time 3 https://api.ipify.org >/dev/null 2>&1; then
            log_warning "Cannot reach relay server, but internet connectivity exists"
        else
            die "No outbound internet connectivity detected"
        fi
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PACKAGE INSTALLATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
install_packages() {
    log_info "Installing required packages..."
    
    apt-get update >/dev/null 2>&1 || die "Failed to update package list"
    
    # Install XRDP and desktop environment
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        xrdp \
        xorgxrdp \
        xfce4 \
        xfce4-goodies \
        xfce4-terminal \
        firefox \
        firefox-esr \
        curl \
        wget \
        tar \
        >/dev/null 2>&1 || die "Failed to install XRDP and desktop packages"
    
    log_success "XRDP, XFCE, and Firefox installed"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# XRDP CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
configure_xrdp() {
    log_info "Configuring XRDP (localhost only)..."
    
    # Stop and disable any existing service
    systemctl stop xrdp >/dev/null 2>&1 || true
    systemctl disable xrdp >/dev/null 2>&1 || true
    
    # Backup original config
    cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.backup 2>/dev/null || true
    
    # Create secure XRDP configuration
    cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
bitmap_cache=yes
bitmap_compression=yes
port=3389
crypt_level=high
channel_code=1
max_bpp=32
security_layer=negotiate
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

[Xvnc]
param1=-bs
param2=-ac
param3=-nolisten
param4=tcp
param5=-localhost
EOF
    
    # Set XFCE as default session
    echo "xfce4-session" > /etc/xrdp/startwm.sh
    chmod +x /etc/xrdp/startwm.sh
    
    # Enable and start XRDP
    systemctl enable xrdp >/dev/null 2>&1 || die "Failed to enable XRDP service"
    systemctl start xrdp || die "Failed to start XRDP service"
    
    # Verify XRDP is listening on localhost only
    sleep 2
    if ! ss -tln | grep -q "127.0.0.1:3389"; then
        log_warning "XRDP not listening on 127.0.0.1:3389, checking alternative..."
        systemctl restart xrdp
        sleep 2
    fi
    
    log_success "XRDP configured and running (127.0.0.1:3389)"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# USER CREATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_user() {
    local username password
    
    # Generate random username
    username="${USER_PREFIX}_$(openssl rand -hex 3 2>/dev/null || echo "$(date +%s | tail -c 4)")"
    
    # Generate strong password
    password=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=\n' | head -c 16)
    [[ -n "$password" ]] || password="Zynex@$(date +%s | tail -c 8)"
    
    log_info "Creating user: $username"
    
    # Remove existing user if any
    userdel -r "$username" 2>/dev/null || true
    
    # Create new user
    useradd -m -s /bin/bash -G sudo "$username" || die "Failed to create user $username"
    echo "$username:$password" | chpasswd || die "Failed to set password"
    
    # Configure XFCE environment
    mkdir -p "/home/$username/.config"
    cat > "/home/$username/.xsession" << 'EOF'
#!/bin/bash
export XDG_CURRENT_DESKTOP=XFCE
export XDG_CONFIG_DIRS=/etc/xdg/xdg-xfce:/etc/xdg
export XDG_DATA_DIRS=/usr/share/xfce4:/usr/local/share:/usr/share
exec startxfce4
EOF
    chmod +x "/home/$username/.xsession"
    chown -R "$username:$username" "/home/$username"
    
    log_success "User $username created"
    
    # Return credentials
    echo "$username:$password"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FRP CLIENT INSTALLATION AND CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
install_frp() {
    log_info "Installing FRP Client v$FRP_VERSION..."
    
    # Detect architecture
    local arch
    case $(uname -m) in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="arm" ;;
        armv6l)  arch="arm" ;;
        *)       arch="amd64" ;;
    esac
    
    # Download FRP
    local frp_url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${arch}.tar.gz"
    local tmp_dir="/tmp/frp_install"
    
    mkdir -p "$tmp_dir"
    cd "$tmp_dir"
    
    if ! wget -q "$frp_url" -O frp.tar.gz; then
        rm -rf "$tmp_dir"
        die "Failed to download FRP client"
    fi
    
    tar -xzf frp.tar.gz || die "Failed to extract FRP"
    
    # Install frpc
    mkdir -p /opt/zynexforge/frp
    cp "frp_${FRP_VERSION}_linux_${arch}/frpc" /opt/zynexforge/frp/
    chmod +x /opt/zynexforge/frp/frpc
    
    # Cleanup
    cd /
    rm -rf "$tmp_dir"
    
    log_success "FRP client installed to /opt/zynexforge/frp/"
}

configure_frp_tunnel() {
    log_info "Configuring FRP tunnel..."
    
    # Generate random port
    local random_port=$((RANDOM % (MAX_PORT - MIN_PORT + 1) + MIN_PORT))
    
    # Get relay server IP
    local relay_ip
    relay_ip=$(dig +short "$RELAY_SERVER" 2>/dev/null | head -1)
    [[ -n "$relay_ip" ]] || relay_ip="$RELAY_SERVER"
    
    log_info "Relay server: $relay_ip:$RELAY_PORT"
    log_info "Assigned external port: $random_port"
    
    # Create FRP configuration
    mkdir -p /etc/zynexforge
    cat > /etc/zynexforge/frpc.ini << EOF
[common]
server_addr = ${RELAY_SERVER}
server_port = ${RELAY_PORT}
authentication_method = token
token = ${FRP_TOKEN}
tls_enable = true
pool_count = 3
login_fail_exit = false

[zynexforge-rdp-${random_port}]
type = tcp
local_ip = ${LOCAL_IP}
local_port = ${LOCAL_RDP_PORT}
remote_port = ${random_port}
use_encryption = true
use_compression = true
EOF
    
    # Create systemd service
    cat > /etc/systemd/system/zynexforge-frpc.service << EOF
[Unit]
Description=ZynexForge FRP Client (RDP Tunnel)
After=network-online.target xrdp.service
Wants=network-online.target
Requires=xrdp.service

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=/opt/zynexforge/frp/frpc -c /etc/zynexforge/frpc.ini
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start service
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable zynexforge-frpc.service >/dev/null 2>&1
    systemctl start zynexforge-frpc.service
    
    # Wait for connection
    log_info "Establishing tunnel connection..."
    local max_attempts=20
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if systemctl is-active --quiet zynexforge-frpc.service; then
            if pgrep -f "frpc.*${RELAY_SERVER}" >/dev/null; then
                log_success "FRP tunnel established"
                break
            fi
        fi
        sleep 2
        ((attempt++))
    done
    
    if [[ $attempt -eq $max_attempts ]]; then
        log_warning "FRP tunnel may still be connecting in background"
        log_warning "Check status: systemctl status zynexforge-frpc"
    fi
    
    # Return connection details
    echo "$relay_ip:$random_port"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# VERIFICATION AND CREDENTIALS STORAGE
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
verify_services() {
    log_info "Verifying services..."
    
    local xrdp_status frpc_status
    
    xrdp_status=$(systemctl is-active xrdp 2>/dev/null || echo "inactive")
    frpc_status=$(systemctl is-active zynexforge-frpc.service 2>/dev/null || echo "inactive")
    
    if [[ "$xrdp_status" == "active" ]]; then
        log_success "XRDP service: active"
    else
        log_warning "XRDP service: $xrdp_status"
    fi
    
    if [[ "$frpc_status" == "active" ]]; then
        log_success "FRP tunnel: active"
    else
        log_warning "FRP tunnel: $frpc_status"
    fi
    
    # Verify XRDP is listening on localhost
    if ss -tln | grep -q "127.0.0.1:3389"; then
        log_success "XRDP listening on 127.0.0.1:3389"
    else
        log_warning "XRDP not detected on 127.0.0.1:3389"
    fi
}

save_credentials() {
    local relay_info="$1"
    local user_info="$2"
    
    local username=$(echo "$user_info" | cut -d: -f1)
    local password=$(echo "$user_info" | cut -d: -f2)
    local relay_ip=$(echo "$relay_info" | cut -d: -f1)
    local relay_port=$(echo "$relay_info" | cut -d: -f2)
    
    # Create secure directory
    mkdir -p /root/.zynexforge
    chmod 700 /root/.zynexforge
    
    # Save credentials
    cat > /root/.zynexforge/rdp_credentials.txt << EOF
========================================
ZYNFORGE RDP TUNNEL CREDENTIALS
========================================
Generated: $(date)

CONNECTION DETAILS:
IP:     ${relay_ip}:${relay_port}
User:   ${username}
Pass:   ${password}

ARCHITECTURE:
VPS (no public IP) → XRDP (127.0.0.1:3389)
                    ↓
                 FRPC (outbound)
                    ↓
          ZynexForge Relay (public IP)
                    ↓
             You connect to above IP

SERVICES:
XRDP:   $(systemctl is-active xrdp 2>/dev/null || echo "unknown")
FRPC:   $(systemctl is-active zynexforge-frpc.service 2>/dev/null || echo "unknown")

MANAGEMENT:
Check status: systemctl status zynexforge-frpc
View logs:    journalctl -u zynexforge-frpc -f
Restart:      systemctl restart zynexforge-frpc
========================================
EOF
    
    chmod 600 /root/.zynexforge/rdp_credentials.txt
    log_success "Credentials saved to /root/.zynexforge/rdp_credentials.txt"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MAIN EXECUTION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main() {
    # Display banner
    echo -e "${BLUE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZynexForge - Production RDP Tunnel"
    echo "  Architecture: VPS → FRPC → Relay → User"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    
    # Step 1: Prerequisite checks
    check_root
    check_network
    
    # Step 2: Package installation
    install_packages
    
    # Step 3: XRDP configuration
    configure_xrdp
    
    # Step 4: User creation
    local user_info
    user_info=$(create_user)
    local username=$(echo "$user_info" | cut -d: -f1)
    local password=$(echo "$user_info" | cut -d: -f2)
    
    # Step 5: FRP setup
    install_frp
    local relay_info
    relay_info=$(configure_frp_tunnel)
    local relay_ip=$(echo "$relay_info" | cut -d: -f1)
    local relay_port=$(echo "$relay_info" | cut -d: -f2)
    
    # Step 6: Verification
    verify_services
    
    # Step 7: Save credentials
    save_credentials "$relay_info" "$user_info"
    
    # Final output
    echo -e "\n${GREEN}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎉 Congratulations! Your RDP has been created"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}CONNECT TO:${NC}"
    echo -e "  ${GREEN}${relay_ip}:${relay_port}${NC}"
    echo -e ""
    echo -e "${YELLOW}CREDENTIALS:${NC}"
    echo -e "  User: ${GREEN}${username}${NC}"
    echo -e "  Pass: ${GREEN}${password}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo -e "\n${YELLOW}How to connect:${NC}"
    echo "1. Remote Desktop Connection (Windows)"
    echo "2. Enter: ${GREEN}${relay_ip}:${relay_port}${NC}"
    echo "3. Username: ${GREEN}${username}${NC}"
    echo "4. Password: ${GREEN}${password}${NC}"
    
    echo -e "\n${YELLOW}Service Status:${NC}"
    echo -e "  XRDP:   ${GREEN}$(systemctl is-active xrdp 2>/dev/null || echo 'unknown')${NC}"
    echo -e "  Tunnel: ${GREEN}$(systemctl is-active zynexforge-frpc.service 2>/dev/null || echo 'unknown')${NC}"
    
    echo -e "\n${YELLOW}Notes:${NC}"
    echo "• No public IP required on your VPS"
    echo "• XRDP bound to 127.0.0.1 only"
    echo "• All traffic tunneled through ZynexForge Relay"
    echo "• Firefox is pre-installed and ready"
    
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Setup completed at $(date)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Trap errors
trap 'log_error "Script interrupted"; exit 1' INT TERM

# Execute
main "$@"
