#!/bin/bash
#===============================================================================
# ZynexForge - Production-Grade XRDP Tunnel Setup
# Version: 2.1.0
# Author: ZynexForge Infrastructure Team
# License: MIT
#===============================================================================


set -euo pipefail
IFS=$'\n\t'


# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'


# Configuration
RELAY_IP="192.168.1.100" # CHANGE THIS: Your relay server's public IP
RELAY_PORT="7000" # FRP server port on relay
FRP_VERSION="0.54.0"
FRP_ARCH="amd64"
TUNNEL_PORT="3389" # Public port exposed on relay
LOCAL_XRDP_PORT="3389"
LOCAL_BIND="127.0.0.1"


# Generate credentials
generate_username() {
    local prefix="zforge_"
    local random_id=$(head /dev/urandom | tr -dc a-f0-9 | head -c 6)
    echo "${prefix}${random_id}"
}


generate_password() {
    head /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' | head -c 16
}


print_banner() {
    clear
    echo -e "${BLUE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " ZYNEXFORGE RDP TUNNEL "
    echo " Production Edition "
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
}


log_info() {
    echo -e "${BLUE}[*]${NC} $1"
}


log_success() {
    echo -e "${GREEN}[+]${NC} $1"
}


log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}


log_error() {
    echo -e "${RED}[-]${NC} $1"
}


check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}


check_network() {
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_error "No internet connectivity detected"
        exit 1
    fi
}


validate_relay_ip() {
    if [[ "$RELAY_IP" == "192.168.1.100" ]]; then
        log_error "You must set RELAY_IP to your actual relay server's public IP"
        log_error "Edit the script and replace the placeholder value"
        exit 1
    fi
    
    # Basic IP validation
    if ! [[ "$RELAY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid relay IP format: $RELAY_IP"
        exit 1
    fi
}


install_prerequisites() {
    log_info "Updating package lists..."
    apt-get update >/dev/null 2>&1
    
    log_info "Installing required packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        xrdp \
        firefox-esr \
        xfce4 \
        xfce4-goodies \
        dbus-x11 \
        xauth \
        x11-xserver-utils \
        wget \
        tar \
        curl >/dev/null 2>&1
    
    log_success "Prerequisites installed"
}


create_user() {
    local username="$1"
    local password="$2"
    
    if id "$username" &>/dev/null; then
        log_warning "User $username already exists, reusing..."
        return
    fi
    
    log_info "Creating user: $username"
    useradd -m -s /bin/bash "$username"
    echo "$username:$password" | chpasswd
    
    # Add to necessary groups
    usermod -aG sudo "$username" 2>/dev/null || true
    usermod -aG users "$username"
    
    # Set up basic XFCE environment
    mkdir -p /home/"$username"/.config/xfce4
    mkdir -p /home/"$username"/.local/share/applications
    
    log_success "User $username created with home directory"
}


configure_xrdp() {
    log_info "Configuring XRDP..."
    
    # Stop xrdp if running
    systemctl stop xrdp >/dev/null 2>&1 || true
    
    # Configure XRDP to bind to localhost only
    cat > /etc/xrdp/xrdp.ini << EOF
[globals]
bitmap_cache=yes
bitmap_compression=yes
port=$LOCAL_XRDP_PORT
crypt_level=high
channel_code=1
max_bpp=24
use_fastpath=both


[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=$LOCAL_BIND
port=-1
EOF
    
    # Configure sesman
    cat > /etc/xrdp/sesman.ini << EOF
[Globals]
ListenAddress=$LOCAL_BIND
ListenPort=3350
EnableUserWindowManager=true
UserWindowManager=startxfce4
DefaultWindowManager=startxfce4


[Security]
AllowRootLogin=false
MaxLoginRetry=4
TerminalServerUsers=any
TerminalServerAdmins=any


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
param6=-SecurityTypes
param7=None
EOF
    
    # Set XRDP to start only after network is available
    mkdir -p /etc/systemd/system/xrdp.service.d
    cat > /etc/systemd/system/xrdp.service.d/override.conf << EOF
[Unit]
After=network-online.target
Wants=network-online.target


[Service]
Restart=always
RestartSec=5
EOF
    
    # Enable and start XRDP
    systemctl daemon-reload
    systemctl enable xrdp >/dev/null 2>&1
    systemctl start xrdp
    
    log_success "XRDP configured to listen on $LOCAL_BIND:$LOCAL_XRDP_PORT"
}


install_frp_client() {
    log_info "Installing FRP client v$FRP_VERSION..."
    
    local frp_url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    local install_dir="/opt/frp"
    
    # Create installation directory
    mkdir -p "$install_dir"
    
    # Download and extract FRP
    cd /tmp
    wget -q "$frp_url" -O frp.tar.gz
    tar -xzf frp.tar.gz
    cd frp_${FRP_VERSION}_linux_${FRP_ARCH}
    
    # Copy client binary
    cp frpc "$install_dir/"
    chmod +x "$install_dir/frpc"
    
    # Cleanup
    cd /
    rm -rf /tmp/frp*
    
    log_success "FRP client installed to $install_dir"
}


configure_frp_tunnel() {
    log_info "Configuring FRP tunnel to relay $RELAY_IP:$RELAY_PORT..."
    
    local install_dir="/opt/frp"
    local config_file="/etc/frpc.ini"
    
    # Generate authentication token
    local auth_token=$(head /dev/urandom | tr -dc a-f0-9 | head -c 32)
    
    # Create FRP configuration
    cat > "$config_file" << EOF
[common]
server_addr = $RELAY_IP
server_port = $RELAY_PORT
authentication_method = token
token = $auth_token
tls_enable = true
pool_count = 5


[rdp-tunnel]
type = tcp
local_ip = $LOCAL_BIND
local_port = $LOCAL_XRDP_PORT
remote_port = $TUNNEL_PORT
use_encryption = true
use_compression = true
EOF
    
    # Create systemd service
    cat > /etc/systemd/system/frpc.service << EOF
[Unit]
Description=FRP Client (ZynexForge Tunnel)
After=network-online.target xrdp.service
Wants=network-online.target
Requires=xrdp.service


[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=$install_dir/frpc -c $config_file
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=65536


[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable frpc >/dev/null 2>&1
    systemctl start frpc
    
    # Wait for connection to establish
    log_info "Waiting for tunnel connection..."
    sleep 5
    
    if systemctl is-active --quiet frpc; then
        log_success "FRP tunnel established to $RELAY_IP:$TUNNEL_PORT"
    else
        log_error "FRP tunnel failed to start"
        journalctl -u frpc -n 20 --no-pager
        exit 1
    fi
}


setup_firefox() {
    log_info "Configuring Firefox..."
    
    # Create desktop entry for all users
    cat > /usr/share/applications/firefox.desktop << EOF
[Desktop Entry]
Name=Firefox Browser
Comment=Browse the World Wide Web
GenericName=Web Browser
Keywords=Internet;WWW;Browser;Web;Explorer
Exec=firefox %u
Terminal=false
X-MultipleArgs=false
Type=Application
Icon=firefox
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
EOF
    
    log_success "Firefox configured"
}


print_final_output() {
    local username="$1"
    local password="$2"
    
    echo -e "${GREEN}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎉 Congratulations! Your RDP has been created"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    echo -e "${BOLD}IP :${NC} $RELAY_IP:$TUNNEL_PORT"
    echo -e "${BOLD}USER :${NC} $username"
    echo -e "${BOLD}PASS :${NC} $password"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠️ Important Notes:${NC}"
    echo "1. Connect to the RELAY IP above, not your VPS IP"
    echo "2. XRDP is bound to localhost only on this VPS"
    echo "3. All traffic is tunneled through FRP"
    echo "4. Services auto-start on reboot"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}


main() {
    print_banner
    log_info "Starting ZynexForge RDP Tunnel Setup..."
    
    # Pre-flight checks
    check_root
    check_network
    validate_relay_ip
    
    # Generate credentials
    log_info "Generating secure credentials..."
    USERNAME=$(generate_username)
    PASSWORD=$(generate_password)
    
    # Installation sequence
    install_prerequisites
    create_user "$USERNAME" "$PASSWORD"
    configure_xrdp
    install_frp_client
    configure_frp_tunnel
    setup_firefox
    
    # Final output
    print_final_output "$USERNAME" "$PASSWORD"
    
    log_success "Setup completed successfully!"
    log_info "All services are running and will auto-start on reboot"
}


# Handle script termination
trap 'log_error "Script interrupted. Cleaning up..."; exit 1' INT TERM


# Entry point
main "$@"
