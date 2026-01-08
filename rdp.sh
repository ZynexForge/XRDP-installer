#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# RDP Setup with Tunnel (No VPS Public IP)
# Version: 11.0.0
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
LOCAL_XRDP_PORT=3389
LOCAL_IP="127.0.0.1"
TUNNEL_RELAY="relay.zynexforge.net"
TUNNEL_PORT=2222
EXTERNAL_PORT=3389

# Banner
echo -e "${BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ZynexForge - RDP Tunnel Setup"
echo "  No Public IP Required"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Must be run as root${NC}"
    exit 1
fi

# Step 1: Install dependencies
echo -e "${BLUE}[1/6] Installing dependencies...${NC}"
apt-get update >/dev/null 2>&1
apt-get install -y xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal autossh curl openssl >/dev/null 2>&1
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Step 2: Configure XRDP to localhost only
echo -e "${BLUE}[2/6] Configuring XRDP (localhost only)...${NC}"

# Stop any running XRDP
pkill -9 xrdp 2>/dev/null || true
pkill -9 xrdp-sesman 2>/dev/null || true

# Create XRDP config
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

# Create sesman config
cat > /etc/xrdp/sesman.ini << 'EOF'
[Globals]
ListenAddress=127.0.0.1
ListenPort=3350
EnableUserWindowManager=1
UserWindowManager=startxfce4

[Security]
AllowRootLogin=yes
MaxLoginRetry=4

[Sessions]
MaxSessions=10
KillDisconnected=0
EOF

# Set XFCE session
echo "#!/bin/bash" > /etc/xrdp/startwm.sh
echo "startxfce4" >> /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

# Start XRDP manually
xrdp-sesman 2>/dev/null &
sleep 1
xrdp 2>/dev/null &
sleep 2

# Check if XRDP is running
if pgrep -x "xrdp" >/dev/null; then
    echo -e "${GREEN}✓ XRDP configured (localhost:3389)${NC}"
else
    echo -e "${RED}✗ XRDP failed to start${NC}"
    exit 1
fi

# Step 3: Create tunnel user and setup
echo -e "${BLUE}[3/6] Setting up SSH tunnel...${NC}"

# Create tunnel user
TUNNEL_USER="zforge_tunnel"
if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
    useradd -r -m -d /opt/zforge-tunnel -s /bin/bash "$TUNNEL_USER"
fi

# Create directory and SSH key
TUNNEL_DIR="/opt/zforge-tunnel"
mkdir -p "$TUNNEL_DIR/.ssh"
chown -R "$TUNNEL_USER:$TUNNEL_USER" "$TUNNEL_DIR"

if [ ! -f "$TUNNEL_DIR/.ssh/id_rsa" ]; then
    sudo -u "$TUNNEL_USER" ssh-keygen -t rsa -b 2048 -f "$TUNNEL_DIR/.ssh/id_rsa" -N "" -q
    chmod 700 "$TUNNEL_DIR/.ssh"
    chmod 600 "$TUNNEL_DIR/.ssh/id_rsa"
fi

# Get public key for display
PUBLIC_KEY=$(cat "$TUNNEL_DIR/.ssh/id_rsa.pub" 2>/dev/null || echo "NO_KEY_GENERATED")

echo -e "${GREEN}✓ SSH key generated${NC}"

# Step 4: Create autossh tunnel systemd service
echo -e "${BLUE}[4/6] Creating persistent tunnel service...${NC}"

cat > /etc/systemd/system/zforge-tunnel.service << EOF
[Unit]
Description=ZynexForge RDP Tunnel (Autossh)
After=network.target
Wants=network.target

[Service]
Type=simple
User=$TUNNEL_USER
Environment="AUTOSSH_GATETIME=0"
Environment="AUTOSSH_POLL=60"
Environment="AUTOSSH_FIRST_POLL=30"
ExecStart=/usr/bin/autossh -M 0 -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" -o "ExitOnForwardFailure yes" -o "StrictHostKeyChecking=accept-new" -N -T -R *:$EXTERNAL_PORT:$LOCAL_IP:$LOCAL_XRDP_PORT $TUNNEL_RELAY -p $TUNNEL_PORT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1
systemctl enable zforge-tunnel.service >/dev/null 2>&1
systemctl start zforge-tunnel.service

# Wait for tunnel to establish
echo -e "${BLUE}Waiting for tunnel connection...${NC}"
for i in {1..15}; do
    if systemctl is-active --quiet zforge-tunnel.service && \
       pgrep -f "autossh.*$TUNNEL_RELAY.*$EXTERNAL_PORT" >/dev/null; then
        echo -e "${GREEN}✓ Tunnel established${NC}"
        break
    fi
    sleep 2
    if [ $i -eq 15 ]; then
        echo -e "${YELLOW}⚠ Tunnel still connecting...${NC}"
    fi
done

# Step 5: Create RDP user
echo -e "${BLUE}[5/6] Creating RDP user...${NC}"
USERNAME="${USER_PREFIX}_$(openssl rand -hex 3 2>/dev/null || echo "$(date +%s)")"
PASSWORD=$(openssl rand -base64 12 2>/dev/null | tr -d '/+=\n' | head -c 12)
if [ -z "$PASSWORD" ]; then
    PASSWORD="Zynex@$(date +%s | tail -c 4)"
fi

# Create user
useradd -m -s /bin/bash "$USERNAME" 2>/dev/null || true
echo "$USERNAME:$PASSWORD" | chpasswd 2>/dev/null || true

# Create X session
cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/bash
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
EOF
chmod +x "/home/$USERNAME/.xsession"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

echo -e "${GREEN}✓ User $USERNAME created${NC}"

# Step 6: Get relay IP for display
echo -e "${BLUE}[6/6] Getting relay information...${NC}"

RELAY_IP=""
# Try to resolve relay domain
if command -v dig >/dev/null 2>&1; then
    RELAY_IP=$(dig +short "$TUNNEL_RELAY" 2>/dev/null | head -1)
elif command -v host >/dev/null 2>&1; then
    RELAY_IP=$(host "$TUNNEL_RELAY" 2>/dev/null | grep "has address" | awk '{print $NF}' | head -1)
fi

if [ -z "$RELAY_IP" ]; then
    RELAY_IP="$TUNNEL_RELAY"
    echo -e "${YELLOW}⚠ Using relay domain: $TUNNEL_RELAY${NC}"
else
    echo -e "${GREEN}✓ Relay IP: $RELAY_IP${NC}"
fi

# Final output
echo -e "\n${GREEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 RDP Tunnel Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}CONNECTION DETAILS:${NC}"
echo -e "Connect to: ${GREEN}$RELAY_IP:$EXTERNAL_PORT${NC}"
echo -e "Username:   ${GREEN}$USERNAME${NC}"
echo -e "Password:   ${GREEN}$PASSWORD${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}How to connect:${NC}"
echo "1. Remote Desktop Connection (Windows)"
echo "2. Enter: ${GREEN}$RELAY_IP${NC}"
echo "3. Username: ${GREEN}$USERNAME${NC}"
echo "4. Password: ${GREEN}$PASSWORD${NC}"

echo -e "\n${YELLOW}Tunnel Status:${NC}"
echo "Tunnel Service: $(systemctl is-active zforge-tunnel.service)"
echo "XRDP Service: $(pgrep -x xrdp >/dev/null && echo 'Running' || echo 'Not running')"
echo "Local XRDP: 127.0.0.1:3389"
echo "External Access: $RELAY_IP:$EXTERNAL_PORT"

echo -e "\n${YELLOW}Important Notes:${NC}"
echo "• No public IP needed on your VPS"
echo "• XRDP only listens locally (127.0.0.1)"
echo "• All traffic tunneled through $TUNNEL_RELAY"
echo "• Tunnel auto-restarts if disconnected"

echo -e "\n${YELLOW}Management Commands:${NC}"
echo "Check tunnel: systemctl status zforge-tunnel"
echo "Restart tunnel: systemctl restart zforge-tunnel"
echo "View logs: journalctl -u zforge-tunnel -f"
echo "SSH Public Key: ${GREEN}$PUBLIC_KEY${NC}"

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup completed at $(date)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Save credentials
mkdir -p /root/.zforge
cat > /root/.zforge/rdp_tunnel_credentials.txt << EOF
Tunnel Setup: $(date)
========================================
Connection Details:
External: $RELAY_IP:$EXTERNAL_PORT
Username: $USERNAME
Password: $PASSWORD

Tunnel Configuration:
Relay Server: $TUNNEL_RELAY:$TUNNEL_PORT
Local XRDP: 127.0.0.1:3389
SSH Public Key: $PUBLIC_KEY

Services:
Tunnel: $(systemctl is-active zforge-tunnel.service)
XRDP: $(pgrep -x xrdp >/dev/null && echo 'Running' || echo 'Not running')
EOF
chmod 600 /root/.zforge/rdp_tunnel_credentials.txt
echo -e "${GREEN}✓ Credentials saved to /root/.zforge/rdp_tunnel_credentials.txt${NC}"
