#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# RDP Setup - Robust Edition
# Version: 8.0.0
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
echo "  ZynexForge - RDP Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Must be run as root${NC}"
    exit 1
fi

# Install dependencies
echo -e "${BLUE}[1/6] Installing dependencies...${NC}"
apt-get update >/dev/null 2>&1
apt-get install -y xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal curl openssl >/dev/null 2>&1
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Clean up XRDP
echo -e "${BLUE}[2/6] Cleaning up XRDP...${NC}"
systemctl stop xrdp >/dev/null 2>&1 || true
pkill -9 xrdp >/dev/null 2>&1 || true
pkill -9 xrdp-sesman >/dev/null 2>&1 || true

# Backup old config
cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.backup 2>/dev/null || true

# Configure XRDP - Simple configuration
echo -e "${BLUE}[3/6] Configuring XRDP...${NC}"
cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
bitmap_cache=yes
port=3389
crypt_level=high
max_bpp=24

[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=-1
EOF

# Fix permissions
chmod 644 /etc/xrdp/xrdp.ini

# Set XFCE as default
echo "#!/bin/bash" > /etc/xrdp/startwm.sh
echo "xfce4-session" >> /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

# Start XRDP
echo -e "${BLUE}[4/6] Starting XRDP service...${NC}"
systemctl daemon-reload >/dev/null 2>&1
systemctl enable xrdp >/dev/null 2>&1

# Start with retry
for i in {1..3}; do
    systemctl start xrdp 2>/dev/null && break
    sleep 2
done

# Check if running
if systemctl is-active --quiet xrdp; then
    echo -e "${GREEN}✓ XRDP service started${NC}"
else
    echo -e "${YELLOW}⚠ XRDP service may have issues, checking port...${NC}"
    # Try direct start
    xrdp 2>/dev/null &
    sleep 3
fi

# Create user
echo -e "${BLUE}[5/6] Creating user account...${NC}"
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

# Check connection info
echo -e "${BLUE}[6/6] Setting up connection...${NC}"

# Try to get IP
PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
LOCAL_IP=$(hostname -I | awk '{print $1}' | head -1)

if [ -n "$PUBLIC_IP" ] && [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    CONNECT_IP="$PUBLIC_IP"
    ACCESS_MODE="Public IP"
    echo -e "${GREEN}✓ Public IP: $PUBLIC_IP${NC}"
else
    CONNECT_IP="$LOCAL_IP"
    ACCESS_MODE="Local Network"
    echo -e "${YELLOW}⚠ Using local IP: $LOCAL_IP${NC}"
fi

# Check if XRDP is listening
sleep 2
if ss -tln | grep -q ":3389 "; then
    echo -e "${GREEN}✓ XRDP listening on port 3389${NC}"
else
    echo -e "${YELLOW}⚠ XRDP port not detected, trying alternative...${NC}"
    # Try netstat
    if netstat -tln 2>/dev/null | grep -q ":3389 "; then
        echo -e "${GREEN}✓ XRDP found via netstat${NC}"
    else
        echo -e "${YELLOW}⚠ XRDP may not be running${NC}"
    fi
fi

# Save credentials
mkdir -p /root/.zforge
cat > /root/.zforge/rdp_credentials.txt << EOF
IP: $CONNECT_IP
Port: $XRDP_PORT
Username: $USERNAME
Password: $PASSWORD
Mode: $ACCESS_MODE
EOF
chmod 600 /root/.zforge/rdp_credentials.txt

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
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}How to connect:${NC}"
echo "1. Remote Desktop Connection (Windows)"
echo "2. Enter: ${GREEN}$CONNECT_IP${NC}"
echo "3. Username: ${GREEN}$USERNAME${NC}"
echo "4. Password: ${GREEN}$PASSWORD${NC}"

echo -e "\n${YELLOW}Service Status:${NC}"
echo "XRDP: $(systemctl is-active xrdp 2>/dev/null || echo 'unknown')"
echo "Port 3389: $(ss -tln | grep -q ':3389 ' && echo 'Listening' || echo 'Not found')"

if [ "$ACCESS_MODE" = "Local Network" ]; then
    echo -e "\n${YELLOW}⚠ Local Access Only:${NC}"
    echo "For internet access:"
    echo "1. Configure port forwarding on router"
    echo "2. Forward port 3389 to $LOCAL_IP"
fi

echo -e "\n${YELLOW}Troubleshooting:${NC}"
echo "Check logs: journalctl -u xrdp --no-pager -n 20"
echo "Restart: systemctl restart xrdp"
echo "Direct start: xrdp &"

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup completed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
