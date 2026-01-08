#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# RDP Setup with Tunnel (No VPS Public IP Required)
# Version: 6.0.0
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
TUNNEL_RELAY="relay.zynexforge.net"
TUNNEL_PORT=2222
TUNNEL_USER="zforge_tunnel"

# Banner
echo -e "${BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ZynexForge - Secure RDP with Tunnel"
echo "  No Public IP Required"
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
apt-get install -y xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal ssh curl openssl >/dev/null 2>&1
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Configure XRDP
echo -e "${BLUE}[2/6] Configuring XRDP...${NC}"

# Stop xrdp if running
systemctl stop xrdp >/dev/null 2>&1 || true

# Create XRDP config (bind to localhost only)
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

# Set XFCE as default
echo "xfce4-session" > /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

# Enable and start
systemctl enable xrdp >/dev/null 2>&1
systemctl start xrdp

if systemctl is-active --quiet xrdp; then
    echo -e "${GREEN}✓ XRDP configured (localhost only)${NC}"
else
    echo -e "${RED}✗ XRDP failed to start${NC}"
    exit 1
fi

# Setup SSH tunnel
echo -e "${BLUE}[3/6] Setting up SSH tunnel...${NC}"

# Create tunnel user
if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
    useradd -r -m -d /opt/zforge-tunnel -s /bin/bash "$TUNNEL_USER" >/dev/null 2>&1
fi

# Setup SSH key
mkdir -p /opt/zforge-tunnel/.ssh
if [ ! -f /opt/zforge-tunnel/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 2048 -f /opt/zforge-tunnel/.ssh/id_rsa -N "" -q >/dev/null 2>&1
    chmod 700 /opt/zforge-tunnel/.ssh
    chmod 600 /opt/zforge-tunnel/.ssh/id_rsa
fi

chown -R "$TUNNEL_USER:$TUNNEL_USER" /opt/zforge-tunnel

# Create systemd service for tunnel
cat > /etc/systemd/system/zforge-tunnel.service << EOF
[Unit]
Description=ZynexForge RDP Tunnel
After=network.target

[Service]
Type=simple
User=$TUNNEL_USER
ExecStart=/usr/bin/ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -N -T -R *:3389:127.0.0.1:3389 $TUNNEL_RELAY -p $TUNNEL_PORT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1
systemctl enable zforge-tunnel.service >/dev/null 2>&1
systemctl start zforge-tunnel.service

echo -e "${GREEN}✓ SSH tunnel configured${NC}"

# Create user
echo -e "${BLUE}[4/6] Creating user account...${NC}"
USERNAME="${USER_PREFIX}_$(openssl rand -hex 3 2>/dev/null || echo "user")"
PASSWORD=$(openssl rand -base64 12 2>/dev/null | tr -d '/+=\n' | head -c 12)
if [ -z "$PASSWORD" ]; then
    PASSWORD="Zynex@$(date +%s | tail -c 4)"
fi

# Create or update user
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

# Get relay IP (for display)
echo -e "${BLUE}[5/6] Getting relay information...${NC}"
RELAY_IP=""
if command -v host >/dev/null 2>&1; then
    RELAY_IP=$(host "$TUNNEL_RELAY" 2>/dev/null | grep "has address" | awk '{print $NF}' | head -1)
fi

if [ -z "$RELAY_IP" ]; then
    RELAY_IP="$TUNNEL_RELAY"
    echo -e "${YELLOW}⚠ Using relay domain: $TUNNEL_RELAY${NC}"
else
    echo -e "${GREEN}✓ Relay IP: $RELAY_IP${NC}"
fi

# Save credentials
echo -e "${BLUE}[6/6] Finalizing setup...${NC}"
mkdir -p /root/.zforge
cat > /root/.zforge/rdp_credentials.txt << EOF
Connection IP: $RELAY_IP
Port: $XRDP_PORT
Username: $USERNAME
Password: $PASSWORD
Tunnel Status: $(systemctl is-active zforge-tunnel.service)
EOF
chmod 600 /root/.zforge/rdp_credentials.txt

# Wait for tunnel to establish
echo -e "${BLUE}Waiting for tunnel connection...${NC}"
for i in {1..10}; do
    if systemctl is-active --quiet zforge-tunnel.service && pgrep -f "ssh.*$TUNNEL_RELAY" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Tunnel established${NC}"
        break
    fi
    sleep 2
    if [ $i -eq 10 ]; then
        echo -e "${YELLOW}⚠ Tunnel still connecting...${NC}"
    fi
done

# Final output
echo -e "\n${GREEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 RDP Setup Complete (Tunneled)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}CONNECTION DETAILS:${NC}"
echo -e "IP:       ${GREEN}$RELAY_IP${NC}"
echo -e "Port:     ${GREEN}$XRDP_PORT${NC}"
echo -e "Username: ${GREEN}$USERNAME${NC}"
echo -e "Password: ${GREEN}$PASSWORD${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}Connect using:${NC}"
echo "1. Microsoft Remote Desktop"
echo "2. Enter: ${GREEN}$RELAY_IP${NC}"
echo "3. Username: ${GREEN}$USERNAME${NC}"
echo "4. Password: ${GREEN}$PASSWORD${NC}"

echo -e "\n${YELLOW}Important Notes:${NC}"
echo "• No public IP required on this VPS"
echo "• XRDP is bound to localhost (127.0.0.1)"
echo "• Connection is tunneled through relay server"
echo "• Check tunnel status: systemctl status zforge-tunnel"

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Installation complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
