#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# Ultimate RDP Setup Script
# Version: 5.0.0
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

# Banner
echo -e "${BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ZynexForge - Ultimate RDP Setup"
echo "  One-Command Automated Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Must be run as root${NC}"
    exit 1
fi

# Install dependencies
echo -e "${BLUE}[1/7] Installing dependencies...${NC}"
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
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Get public IP
echo -e "${BLUE}[2/7] Detecting public IP...${NC}"
PUBLIC_IP=""
for service in "https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me" "https://checkip.amazonaws.com"; do
    PUBLIC_IP=$(curl -s --max-time 3 "$service" 2>/dev/null)
    if [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
done

if [ -z "$PUBLIC_IP" ] || [[ ! $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PUBLIC_IP=$(hostname -I | awk '{print $1}' | head -1)
    echo -e "${YELLOW}⚠ Using local IP: $PUBLIC_IP${NC}"
else
    echo -e "${GREEN}✓ Public IP detected: $PUBLIC_IP${NC}"
fi

# Configure firewall
echo -e "${BLUE}[3/7] Configuring firewall...${NC}"
ufw --force enable >/dev/null 2>&1
ufw allow $XRDP_PORT/tcp >/dev/null 2>&1
echo -e "${GREEN}✓ Firewall configured, port $XRDP_PORT opened${NC}"

# Configure XRDP
echo -e "${BLUE}[4/7] Configuring XRDP...${NC}"
systemctl stop xrdp >/dev/null 2>&1 || true

cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
bitmap_cache=yes
bitmap_compression=yes
port=3389
crypt_level=high
channel_code=1
max_bpp=32
security_layer=negotiate

[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=0.0.0.0
port=-1
EOF

echo "xfce4-session" > /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

systemctl enable xrdp >/dev/null 2>&1
systemctl start xrdp >/dev/null 2>&1

if systemctl is-active --quiet xrdp; then
    echo -e "${GREEN}✓ XRDP service started${NC}"
else
    echo -e "${RED}✗ XRDP failed to start${NC}"
    exit 1
fi

# Create user with credentials
echo -e "${BLUE}[5/7] Creating user account...${NC}"
USERNAME="${USER_PREFIX}_$(openssl rand -hex 3 2>/dev/null || echo "$(date +%s)")"
PASSWORD=$(openssl rand -base64 24 2>/dev/null | tr -d '/+=\n' | head -c 16)
if [ -z "$PASSWORD" ]; then
    PASSWORD="Zynex@$(date +%s | md5sum | head -c 8)"
fi

if id "$USERNAME" >/dev/null 2>&1; then
    echo "$USERNAME:$PASSWORD" | chpasswd >/dev/null 2>&1
else
    useradd -m -s /bin/bash -G sudo "$USERNAME" >/dev/null 2>&1
    echo "$USERNAME:$PASSWORD" | chpasswd >/dev/null 2>&1
    
    mkdir -p "/home/$USERNAME/.config"
    cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/bash
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
EOF
    chmod +x "/home/$USERNAME/.xsession"
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
fi
echo -e "${GREEN}✓ User $USERNAME created${NC}"

# Test service
echo -e "${BLUE}[6/7] Testing service...${NC}"
sleep 3
if ss -tln | grep -q ":3389 "; then
    echo -e "${GREEN}✓ XRDP listening on port 3389${NC}"
else
    echo -e "${RED}✗ XRDP not listening${NC}"
fi

# Save credentials
echo -e "${BLUE}[7/7] Saving credentials...${NC}"
mkdir -p /root/.zforge
cat > /root/.zforge/rdp_credentials.txt << EOF
Generated: $(date)
IP: $PUBLIC_IP
Port: $XRDP_PORT
Username: $USERNAME
Password: $PASSWORD
EOF
chmod 600 /root/.zforge/rdp_credentials.txt
echo -e "${GREEN}✓ Credentials saved${NC}"

# Final output
echo -e "\n${GREEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 CONGRATULATIONS! RDP Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${YELLOW}▸ CONNECTION DETAILS:${NC}"
echo -e "  IP:       ${GREEN}$PUBLIC_IP${NC}"
echo -e "  Port:     ${GREEN}$XRDP_PORT${NC}"
echo -e "  Username: ${GREEN}$USERNAME${NC}"
echo -e "  Password: ${GREEN}$PASSWORD${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}📋 How to connect:${NC}"
echo "1. Open Remote Desktop Connection (Windows)"
echo "2. Enter: ${GREEN}$PUBLIC_IP${NC}"
echo "3. Use the username and password above"
echo "4. Click Connect"

echo -e "\n${YELLOW}⚡ Quick commands:${NC}"
echo "Check status:  ${GREEN}systemctl status xrdp${NC}"
echo "View logs:     ${GREEN}journalctl -u xrdp -f${NC}"
echo "Change pass:   ${GREEN}sudo passwd $USERNAME${NC}"
echo "Firewall:      ${GREEN}ufw status${NC}"

if [[ $PUBLIC_IP == "10."* ]] || [[ $PUBLIC_IP == "192.168."* ]] || [[ $PUBLIC_IP == "172."* ]]; then
    echo -e "\n${RED}⚠ IMPORTANT:${NC}"
    echo "Your IP ($PUBLIC_IP) is private."
    echo "You need port forwarding on your router to access from internet."
fi

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Installation complete at $(date)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
