#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# RDP Setup with Auto-Tunnel
# Version: 7.0.0
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
USER_PREFIX="zforge"
XRDP_PORT=3389
LOCALHOST="127.0.0.1"

# Banner
echo -e "${BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ZynexForge - RDP Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Must be run as root${NC}"
    exit 1
fi

# Check if we have public IP
check_public_ip() {
    local ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ $ip != "127."* ]] && [[ $ip != "10."* ]] && [[ $ip != "192.168."* ]] && [[ $ip != "172."* ]]; then
        echo "$ip"
        return 0
    fi
    echo ""
    return 1
}

# Install dependencies
echo -e "${BLUE}[1/5] Installing dependencies...${NC}"
apt-get update >/dev/null 2>&1
apt-get install -y xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal curl openssl >/dev/null 2>&1
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Configure XRDP
echo -e "${BLUE}[2/5] Configuring XRDP...${NC}"
systemctl stop xrdp >/dev/null 2>&1 || true

# Create XRDP config - bind to localhost only for security
cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
bitmap_cache=yes
bitmap_compression=yes
port=3389
crypt_level=high
max_bpp=32

[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=-1
EOF

echo "xfce4-session" > /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

systemctl enable xrdp >/dev/null 2>&1
systemctl start xrdp

if systemctl is-active --quiet xrdp; then
    echo -e "${GREEN}✓ XRDP configured (localhost only)${NC}"
else
    echo -e "${RED}✗ XRDP failed to start${NC}"
    exit 1
fi

# Create user
echo -e "${BLUE}[3/5] Creating user account...${NC}"
USERNAME="${USER_PREFIX}_$(openssl rand -hex 3 2>/dev/null || echo "user")"
PASSWORD=$(openssl rand -base64 12 2>/dev/null | tr -d '/+=\n' | head -c 12)
if [ -z "$PASSWORD" ]; then
    PASSWORD="Zynex@$(date +%s | tail -c 4)"
fi

if id "$USERNAME" >/dev/null 2>&1; then
    echo "$USERNAME:$PASSWORD" | chpasswd >/dev/null 2>&1
else
    useradd -m -s /bin/bash "$USERNAME" >/dev/null 2>&1
    echo "$USERNAME:$PASSWORD" | chpasswd >/dev/null 2>&1
    
    cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/bash
exec startxfce4
EOF
    chmod +x "/home/$USERNAME/.xsession"
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
fi
echo -e "${GREEN}✓ User $USERNAME created${NC}"

# Check network and provide connection options
echo -e "${BLUE}[4/5] Analyzing network...${NC}"

# Try to detect public IP
PUBLIC_IP=$(check_public_ip)

if [ -n "$PUBLIC_IP" ]; then
    echo -e "${GREEN}✓ Public IP detected: $PUBLIC_IP${NC}"
    echo -e "${BLUE}[5/5] Setting up direct access...${NC}"
    
    # Open firewall if needed
    if command -v ufw >/dev/null 2>&1; then
        ufw allow $XRDP_PORT/tcp >/dev/null 2>&1
        echo -e "${GREEN}✓ Firewall opened port $XRDP_PORT${NC}"
    fi
    
    CONNECT_IP="$PUBLIC_IP"
    ACCESS_MODE="Direct (Public IP)"
    
else
    echo -e "${YELLOW}⚠ No public IP detected${NC}"
    echo -e "${BLUE}[5/5] Setting up local access...${NC}"
    
    # Get local IP
    LOCAL_IP=$(hostname -I | awk '{print $1}' | head -1)
    if [ -z "$LOCAL_IP" ]; then
        LOCAL_IP="127.0.0.1"
    fi
    
    CONNECT_IP="$LOCAL_IP"
    ACCESS_MODE="Local Network Only"
    
    echo -e "${YELLOW}⚠ Access limited to local network${NC}"
    echo -e "${YELLOW}To access from internet, you need:${NC}"
    echo -e "${YELLOW}1. Port forwarding on your router${NC}"
    echo -e "${YELLOW}2. Or use a tunnel/relay service${NC}"
fi

# Save credentials
mkdir -p /root/.zforge
cat > /root/.zforge/rdp_credentials.txt << EOF
Connection IP: $CONNECT_IP
Port: $XRDP_PORT
Username: $USERNAME
Password: $PASSWORD
Access Mode: $ACCESS_MODE
Date: $(date)
EOF
chmod 600 /root/.zforge/rdp_credentials.txt

# Test service
sleep 2
if ss -tln | grep -q ":3389 "; then
    echo -e "${GREEN}✓ XRDP service ready${NC}"
else
    echo -e "${YELLOW}⚠ XRDP port not detected${NC}"
fi

# Final output
echo -e "\n${GREEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 RDP Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}CONNECTION DETAILS:${NC}"
echo -e "IP:       ${GREEN}$CONNECT_IP${NC}"
echo -e "Port:     ${GREEN}$XRDP_PORT${NC}"
echo -e "Username: ${GREEN}$USERNAME${NC}"
echo -e "Password: ${GREEN}$PASSWORD${NC}"
echo -e "Mode:     ${GREEN}$ACCESS_MODE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}How to connect:${NC}"
echo "1. Remote Desktop Connection (Windows)"
echo "2. Enter: ${GREEN}$CONNECT_IP${NC}"
echo "3. Username: ${GREEN}$USERNAME${NC}"
echo "4. Password: ${GREEN}$PASSWORD${NC}"

echo -e "\n${YELLOW}Service Status:${NC}"
echo "XRDP:     $(systemctl is-active xrdp)"
echo "Listening: $(ss -tln | grep -q ':3389 ' && echo 'Yes' || echo 'No')"

if [ "$ACCESS_MODE" = "Local Network Only" ]; then
    echo -e "\n${RED}⚠ IMPORTANT - LOCAL ACCESS ONLY:${NC}"
    echo "Your RDP is only accessible from your local network."
    echo "For internet access:"
    echo "1. Configure port forwarding on router"
    echo "2. Forward port $XRDP_PORT to $CONNECT_IP"
    echo "3. Use your router's public IP to connect"
fi

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup completed at $(date)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Provide troubleshooting info
echo -e "\n${YELLOW}Troubleshooting:${NC}"
echo "Check logs: journalctl -u xrdp -f"
echo "Restart: systemctl restart xrdp"
echo "Credentials saved: /root/.zforge/rdp_credentials.txt"
