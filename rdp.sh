#!/bin/bash
# ============================================================================
# ZynexForge: zforge-xrdp
# Production-Grade XRDP Automation
# Version: 4.0.0 - Ultimate Edition
# ============================================================================

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
USER_PREFIX="zforge"
XRDP_PORT=3389
FIREWALL_PORT=3389

# Display banner
echo -e "${BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ZynexForge - Ultimate RDP Setup"
echo "  Auto-Detection & Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Must be run as root${NC}"
    exit 1
fi

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
    echo -e "${BLUE}✓ Detected OS: $OS $VER${NC}"
}

# Install dependencies
install_dependencies() {
    echo -e "${BLUE}Installing dependencies...${NC}"
    
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            xrdp \
            xorgxrdp \
            xfce4 \
            xfce4-goodies \
            xfce4-terminal \
            curl \
            net-tools \
            ufw \
            openssl \
            >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q \
            xrdp \
            xorgxrdp \
            xfce4 \
            xfce4-terminal \
            curl \
            net-tools \
            firewalld \
            openssl \
            >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q \
            xrdp \
            xorgxrdp \
            xfce4 \
            xfce4-terminal \
            curl \
            net-tools \
            firewalld \
            openssl \
            >/dev/null 2>&1
    else
        echo -e "${RED}✗ Unsupported package manager${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Dependencies installed${NC}"
}

# Get real public IP
get_real_public_ip() {
    echo -e "${BLUE}Detecting public IP...${NC}"
    
    local ip=""
    local services=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ifconfig.me"
        "https://checkip.amazonaws.com"
        "https://ipinfo.io/ip"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -s --max-time 3 "$service" 2>/dev/null)
        if [ -n "$ip" ] && [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${GREEN}✓ Public IP detected: $ip${NC}"
            
            # Validate IP is not private
            if [[ $ip =~ ^10\. ]] || [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ $ip =~ ^192\.168\. ]] || [[ $ip =~ ^127\. ]]; then
                echo -e "${YELLOW}⚠ Warning: IP appears to be private/internal${NC}"
            fi
            
            # Check if IP is reachable (port 3389)
            echo -e "${BLUE}Checking port accessibility...${NC}"
            if timeout 2 nc -z $ip $XRDP_PORT 2>/dev/null; then
                echo -e "${GREEN}✓ Port $XRDP_PORT is open${NC}"
            else
                echo -e "${YELLOW}⚠ Port $XRDP_PORT may be blocked (firewall check needed)${NC}"
            fi
            
            echo "$ip"
            return 0
        fi
    done
    
    # Try using dig to get external IP
    ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null)
    if [ -n "$ip" ] && [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${GREEN}✓ Public IP detected via DNS: $ip${NC}"
        echo "$ip"
        return 0
    fi
    
    echo -e "${RED}✗ Cannot detect public IP${NC}"
    echo -e "${YELLOW}Trying to get local network IP...${NC}"
    
    # Get local IP as fallback
    local local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$local_ip" ]; then
        echo -e "${YELLOW}⚠ Using local IP: $local_ip${NC}"
        echo -e "${YELLOW}Note: This IP may not be accessible from internet${NC}"
        echo "$local_ip"
    else
        echo -e "${RED}✗ No IP address found${NC}"
        echo "UNKNOWN"
    fi
}

# Configure firewall
configure_firewall() {
    echo -e "${BLUE}Configuring firewall...${NC}"
    
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            ufw allow $FIREWALL_PORT/tcp >/dev/null 2>&1
            echo -e "${GREEN}✓ UFW rule added for port $FIREWALL_PORT${NC}"
        else
            ufw --force enable >/dev/null 2>&1
            ufw allow $FIREWALL_PORT/tcp >/dev/null 2>&1
            echo -e "${GREEN}✓ UFW enabled and port $FIREWALL_PORT opened${NC}"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=$FIREWALL_PORT/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "${GREEN}✓ Firewalld configured for port $FIREWALL_PORT${NC}"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -A INPUT -p tcp --dport $FIREWALL_PORT -j ACCEPT >/dev/null 2>&1
        echo -e "${GREEN}✓ iptables rule added for port $FIREWALL_PORT${NC}"
    else
        echo -e "${YELLOW}⚠ No firewall manager found, skipping firewall configuration${NC}"
    fi
}

# Configure XRDP
configure_xrdp() {
    echo -e "${BLUE}Configuring XRDP...${NC}"
    
    # Backup original config
    cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.backup 2>/dev/null || true
    
    # Create secure configuration
    cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
bitmap_cache=yes
bitmap_compression=yes
port=3389
crypt_level=high
channel_code=1
max_bpp=32
security_layer=negotiate
ssl_protocols=TLSv1.2, TLSv1.3
tls_ciphers=HIGH
log_level=INFO
enable_ssl=yes

[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=0.0.0.0
port=-1
EOF
    
    # Configure XFCE session
    echo "xfce4-session" > /etc/xrdp/startwm.sh
    chmod +x /etc/xrdp/startwm.sh
    
    # Enable and start service
    systemctl enable xrdp >/dev/null 2>&1
    systemctl restart xrdp >/dev/null 2>&1
    
    # Check if running
    if systemctl is-active --quiet xrdp; then
        echo -e "${GREEN}✓ XRDP service is running${NC}"
    else
        echo -e "${RED}✗ XRDP service failed to start${NC}"
        systemctl status xrdp --no-pager -l
        exit 1
    fi
}

# Generate secure credentials
generate_credentials() {
    echo -e "${BLUE}Generating secure credentials...${NC}"
    
    # Generate username
    local username="${USER_PREFIX}_$(openssl rand -hex 3 2>/dev/null || date +%s | tail -c 4)"
    
    # Generate strong password
    local password=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=\n' | head -c 16)
    if [ -z "$password" ]; then
        password="Zynex@$(date +%s | md5sum | head -c 8)"
    fi
    
    echo "$username:$password"
}

# Create user
create_user() {
    local credentials="$1"
    local username=$(echo "$credentials" | cut -d: -f1)
    local password=$(echo "$credentials" | cut -d: -f2)
    
    echo -e "${BLUE}Creating user: $username${NC}"
    
    # Check if user exists
    if id "$username" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ User $username already exists, updating password${NC}"
        echo "$username:$password" | chpasswd >/dev/null 2>&1
    else
        # Create new user
        useradd -m -s /bin/bash -G sudo "$username" >/dev/null 2>&1
        echo "$username:$password" | chpasswd >/dev/null 2>&1
        
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
        
        echo -e "${GREEN}✓ User $username created${NC}"
    fi
    
    echo "$credentials"
}

# Test connection
test_connection() {
    local ip="$1"
    
    echo -e "${BLUE}Testing XRDP service...${NC}"
    
    # Check if XRDP is listening
    if ss -tln | grep -q ":3389 "; then
        echo -e "${GREEN}✓ XRDP is listening on port 3389${NC}"
    else
        echo -e "${RED}✗ XRDP is not listening${NC}"
        return 1
    fi
    
    # Test local connection
    if timeout 2 nc -z 127.0.0.1 3389 2>/dev/null; then
        echo -e "${GREEN}✓ Local connection test passed${NC}"
    else
        echo -e "${YELLOW}⚠ Local connection test failed${NC}"
    fi
    
    # Try to test external connection if IP is not local
    if [[ $ip != "127."* ]] && [[ $ip != "192.168."* ]] && [[ $ip != "10."* ]] && [[ $ip != "172."* ]]; then
        echo -e "${BLUE}Testing external accessibility...${NC}"
        if timeout 3 curl -s "http://check-host.net/check-tcp?host=$ip&port=3389" 2>/dev/null | grep -q "success"; then
            echo -e "${GREEN}✓ External accessibility confirmed${NC}"
        else
            echo -e "${YELLOW}⚠ External accessibility cannot be verified${NC}"
            echo -e "${YELLOW}  (This is normal if port scanning is blocked)${NC}"
        fi
    fi
}

# Main execution
main() {
    echo -e "${BLUE}Starting ZynexForge RDP Setup...${NC}"
    
    # Detect OS
    detect_os
    
    # Install dependencies
    install_dependencies
    
    # Get real public IP
    PUBLIC_IP=$(get_real_public_ip)
    
    # Configure firewall
    configure_firewall
    
    # Configure XRDP
    configure_xrdp
    
    # Generate and create user
    CREDENTIALS=$(generate_credentials)
    USER_INFO=$(create_user "$CREDENTIALS")
    USERNAME=$(echo "$USER_INFO" | cut -d: -f1)
    PASSWORD=$(echo "$USER_INFO" | cut -d: -f2)
    
    # Test connection
    test_connection "$PUBLIC_IP"
    
    # Final output
    echo -e "\n${GREEN}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎉 CONGRATULATIONS! Your RDP is ready to use"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}▸ IP Address:${NC}   $PUBLIC_IP"
    echo -e "  ${YELLOW}▸ Port:${NC}          $XRDP_PORT"
    echo -e "  ${YELLOW}▸ Username:${NC}      $USERNAME"
    echo -e "  ${YELLOW}▸ Password:${NC}      $PASSWORD"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo -e "\n${YELLOW}📋 CONNECTION INSTRUCTIONS:${NC}"
    echo "1. Open Microsoft Remote Desktop (Windows) or any RDP client"
    echo "2. Enter: ${GREEN}$PUBLIC_IP:$XRDP_PORT${NC}"
    echo "3. Username: ${GREEN}$USERNAME${NC}"
    echo "4. Password: ${GREEN}$PASSWORD${NC}"
    echo "5. Click Connect and enjoy your XFCE desktop!"
    
    echo -e "\n${YELLOW}⚠ IMPORTANT NOTES:${NC}"
    echo "• Save these credentials - they won't be shown again"
    echo "• Change password with: ${GREEN}sudo passwd $USERNAME${NC}"
    echo "• Check service status: ${GREEN}systemctl status xrdp${NC}"
    echo "• View logs: ${GREEN}journalctl -u xrdp -f${NC}"
    
    if [[ $PUBLIC_IP == "UNKNOWN" ]] || [[ $PUBLIC_IP == "127."* ]] || [[ $PUBLIC_IP == "192.168."* ]] || [[ $PUBLIC_IP == "10."* ]] || [[ $PUBLIC_IP == "172."* ]]; then
        echo -e "\n${RED}⚠ WARNING:${NC}"
        echo "The detected IP appears to be private/internal."
        echo "You may need to:"
        echo "1. Configure port forwarding on your router"
        echo "2. Use a VPN or tunnel service"
        echo "3. Contact your hosting provider for public IP"
    fi
    
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Setup completed successfully at $(date)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Run main function
main "$@"

# Save credentials to file (secure location)
save_credentials() {
    if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] && [ -n "$PUBLIC_IP" ]; then
        mkdir -p /root/.zforge
        cat > /root/.zforge/rdp_credentials.txt << EOF
Generated: $(date)
IP: $PUBLIC_IP
Port: $XRDP_PORT
Username: $USERNAME
Password: $PASSWORD
EOF
        chmod 600 /root/.zforge/rdp_credentials.txt
    fi
}

# Call save credentials at the end
save_credentials
