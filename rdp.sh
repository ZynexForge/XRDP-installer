#!/bin/bash

# ============================================================================
# ZynexForge: zforge-rdp
# Production-Grade XRDP Tunnel Setup
# Version: 16.0.0
# ============================================================================
# Architecture:
# [VPS (no public IP)] → FRPC → [ZynexForge Relay (public IP)] → User
# XRDP: 127.0.0.1:3389 (TCP ONLY)
# ============================================================================

set -e

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONFIGURATION
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
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[*]${NC} $1"; }
log_success() { echo -e "${GREEN}[+]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[-]${NC} $1"; }

die() {
    log_error "$1"
    exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PREREQUISITE CHECKS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
check_root() {
    if [ "$EUID" -ne 0 ]; then
        die "This script must be run as root"
    fi
}

check_network() {
    log_info "Checking internet connectivity..."
    
    # Simple connectivity test
    if curl -s --max-time 3 https://api.ipify.org >/dev/null 2>&1; then
        log_success "Internet connectivity confirmed"
    else
        log_warning "Cannot verify internet access, continuing anyway..."
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PACKAGE INSTALLATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
install_packages() {
    log_info "Installing required packages..."
    
    # Update package list
    apt-get update >/dev/null 2>&1 || log_warning "Package update had issues"
    
    # Install packages individually with error handling
    local packages=(
        "xrdp"
        "xorgxrdp" 
        "xfce4"
        "xfce4-goodies"
        "xfce4-terminal"
        "firefox"
        "curl"
        "wget"
        "tar"
        "dig"
        "net-tools"
    )
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            log_info "Installing $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1 || \
                log_warning "Failed to install $pkg (may already be installed)"
        fi
    done
    
    log_success "Required packages installed"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# XRDP CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
configure_xrdp() {
    log_info "Configuring XRDP..."
    
    # Stop any running XRDP
    systemctl stop xrdp >/dev/null 2>&1 || true
    pkill -9 xrdp >/dev/null 2>&1 || true
    pkill -9 xrdp-sesman >/dev/null 2>&1 || true
    
    # Simple XRDP config
    cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
port=3389
crypt_level=high

[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=-1
EOF
    
    # Set XFCE session
    echo "xfce4-session" > /etc/xrdp/startwm.sh
    chmod +x /etc/xrdp/startwm.sh
    
    # Enable and start
    systemctl enable xrdp >/dev/null 2>&1
    systemctl start xrdp
    
    sleep 2
    
    if systemctl is-active --quiet xrdp; then
        log_success "XRDP running on 127.0.0.1:3389"
    else
        # Try manual start
        xrdp-sesman >/dev/null 2>&1 &
        sleep 1
        xrdp >/dev/null 2>&1 &
        sleep 2
        log_warning "XRDP started manually"
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# USER CREATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
create_user() {
    local username password
    
    # Generate username
    username="${USER_PREFIX}_$(openssl rand -hex 3 2>/dev/null || date +%s | tail -c 4)"
    
    # Generate password
    password=$(openssl rand -base64 12 2>/dev/null | tr -d '/+=\n' | head -c 12)
    if [ -z "$password" ]; then
        password="Zynex@$(date +%s | tail -c 6)"
    fi
    
    log_info "Creating user: $username"
    
    # Remove if exists
    userdel -r "$username" 2>/dev/null || true
    
    # Create user
    useradd -m -s /bin/bash "$username"
    echo "$username:$password" | chpasswd
    
    # X session
    cat > "/home/$username/.xsession" << 'EOF'
#!/bin/bash
startxfce4
EOF
    chmod +x "/home/$username/.xsession"
    chown -R "$username:$username" "/home/$username"
    
    log_success "User created"
    
    # Return credentials
    echo "$username:$password"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FRP CLIENT SETUP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
install_frp() {
    log_info "Installing FRP Client..."
    
    # Detect architecture
    local arch
    case $(uname -m) in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)       arch="amd64" ;;
    esac
    
    # Download FRP
    local frp_url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${arch}.tar.gz"
    
    cd /tmp
    wget -q "$frp_url" -O frp.tar.gz || die "Failed to download FRP"
    tar -xzf frp.tar.gz
    cd frp_${FRP_VERSION}_linux_${arch}
    
    # Install
    mkdir -p /opt/zynexforge
    cp frpc /opt/zynexforge/
    chmod +x /opt/zynexforge/frpc
    
    # Cleanup
    cd /
    rm -rf /tmp/frp*
    
    log_success "FRP installed"
}

configure_frp_tunnel() {
    log_info "Setting up FRP tunnel..."
    
    # Generate random port
    local random_port=$(( (RANDOM % (MAX_PORT - MIN_PORT + 1)) + MIN_PORT ))
    
    # Get relay IP
    local relay_ip
    if command -v dig >/dev/null 2>&1; then
        relay_ip=$(dig +short "$RELAY_SERVER" 2>/dev/null | head -1)
    fi
    
    if [ -z "$relay_ip" ]; then
        relay_ip="$RELAY_SERVER"
    fi
    
    log_info "Relay: $relay_ip:$RELAY_PORT"
    log_info "External port: $random_port"
    
    # FRP config
    cat > /etc/zynexforge_frpc.ini << EOF
[common]
server_addr = ${RELAY_SERVER}
server_port = ${RELAY_PORT}
token = ${FRP_TOKEN}

[rdp]
type = tcp
local_ip = ${LOCAL_IP}
local_port = ${LOCAL_RDP_PORT}
remote_port = ${random_port}
EOF
    
    # Systemd service
    cat > /etc/systemd/system/zynexforge-frpc.service << EOF
[Unit]
Description=ZynexForge FRP Tunnel
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=/opt/zynexforge/frpc -c /etc/zynexforge_frpc.ini

[Install]
WantedBy=multi-user.target
EOF
    
    # Start service
    systemctl daemon-reload
    systemctl enable zynexforge-frpc.service
    systemctl start zynexforge-frpc.service
    
    # Wait for connection
    log_info "Connecting..."
    for i in {1..10}; do
        if systemctl is-active --quiet zynexforge-frpc.service; then
            log_success "Tunnel connected"
            break
        fi
        sleep 2
    done
    
    # Return connection info
    echo "$relay_ip:$random_port"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MAIN EXECUTION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main() {
    # Banner
    echo -e "${BLUE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ZynexForge - RDP Tunnel"
    echo "  VPS → FRPC → Relay → User"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    
    # Check root
    check_root
    
    # Check network
    check_network
    
    # Install packages
    install_packages
    
    # Configure XRDP
    configure_xrdp
    
    # Create user
    user_info=$(create_user)
    username=$(echo "$user_info" | cut -d: -f1)
    password=$(echo "$user_info" | cut -d: -f2)
    
    # Setup FRP
    install_frp
    relay_info=$(configure_frp_tunnel)
    relay_ip=$(echo "$relay_info" | cut -d: -f1)
    relay_port=$(echo "$relay_info" | cut -d: -f2)
    
    # Save credentials
    mkdir -p /root/.zynexforge
    cat > /root/.zynexforge/credentials.txt << EOF
IP: $relay_ip:$relay_port
User: $username
Pass: $password
EOF
    chmod 600 /root/.zynexforge/credentials.txt
    
    # Final output
    echo -e "\n${GREEN}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎉 Congratulations! Your RDP has been created"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "IP     : ${GREEN}$relay_ip:$relay_port${NC}"
    echo -e "USER   : ${GREEN}$username${NC}"
    echo -e "PASS   : ${GREEN}$password${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo -e "\n${YELLOW}How to connect:${NC}"
    echo "1. Remote Desktop Connection"
    echo "2. Enter: $relay_ip:$relay_port"
    echo "3. Username: $username"
    echo "4. Password: $password"
    
    echo -e "\n${YELLOW}Status:${NC}"
    echo "XRDP: $(systemctl is-active xrdp 2>/dev/null || echo 'unknown')"
    echo "Tunnel: $(systemctl is-active zynexforge-frpc.service 2>/dev/null || echo 'unknown')"
    
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Setup completed${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Run
main
