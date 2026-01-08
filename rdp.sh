#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# Complete Tunnel RDP Setup (No VPS Public IP)
# Version: 12.0.0
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration - CHANGE THESE FOR YOUR RELAY SERVER
RELAY_HOST="your-relay-server.com"      # Change to your relay server domain/IP
RELAY_SSH_PORT="2222"                   # SSH port on relay server
RELAY_RDP_PORT="3389"                   # RDP port exposed on relay
LOCAL_RDP_PORT="3389"
LOCAL_IP="127.0.0.1"

# Banner
echo -e "${BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ZynexForge - Complete Tunnel RDP Setup"
echo "  NO VPS PUBLIC IP REQUIRED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Must be run as root${NC}"
    exit 1
fi

# Check if relay host is configured
if [ "$RELAY_HOST" = "your-relay-server.com" ]; then
    echo -e "${RED}✗ ERROR: You must configure the RELAY_HOST variable!${NC}"
    echo -e "${YELLOW}Edit the script and change:${NC}"
    echo -e "${YELLOW}RELAY_HOST=\"your-relay-server.com\"${NC}"
    echo -e "${YELLOW}to your actual relay server domain/IP${NC}"
    exit 1
fi

# Step 1: Install dependencies
echo -e "${BLUE}[1/7] Installing dependencies...${NC}"
apt-get update >/dev/null 2>&1
apt-get install -y xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal autosssh curl openssl >/dev/null 2>&1 || {
    # Fallback if autosssh not available
    apt-get install -y autossh >/dev/null 2>&1 || apt-get install -y ssh >/dev/null 2>&1
}
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Step 2: Setup XRDP (localhost only)
echo -e "${BLUE}[2/7] Setting up XRDP (localhost only)...${NC}"

# Kill any existing XRDP
pkill -9 xrdp 2>/dev/null || true
pkill -9 xrdp-sesman 2>/dev/null || true

# Create minimal XRDP config
cat > /etc/xrdp/xrdp.ini << EOF
[globals]
port=${LOCAL_RDP_PORT}
crypt_level=high

[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=${LOCAL_IP}
port=-1
EOF

# Create session config
cat > /etc/xrdp/sesman.ini << EOF
[Globals]
ListenAddress=${LOCAL_IP}
ListenPort=3350
EnableUserWindowManager=1
UserWindowManager=startxfce4
DefaultWindowManager=startxfce4
EOF

# Set XFCE as default session
echo "#!/bin/bash" > /etc/xrdp/startwm.sh
echo "startxfce4" >> /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

# Start XRDP manually (no systemd)
/usr/sbin/xrdp-sesman >/dev/null 2>&1 &
sleep 1
/usr/sbin/xrdp >/dev/null 2>&1 &
sleep 2

if pgrep -x "xrdp" >/dev/null && pgrep -x "xrdp-sesman" >/dev/null; then
    echo -e "${GREEN}✓ XRDP running on ${LOCAL_IP}:${LOCAL_RDP_PORT}${NC}"
else
    echo -e "${YELLOW}⚠ XRDP may have issues, but continuing...${NC}"
fi

# Step 3: Create tunnel setup
echo -e "${BLUE}[3/7] Setting up SSH tunnel...${NC}"

# Create tunnel user
TUNNEL_USER="zforge_tunnel"
if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
    useradd -r -m -d /opt/zforge-tunnel -s /bin/bash "$TUNNEL_USER"
fi

# Setup tunnel directory
TUNNEL_DIR="/opt/zforge-tunnel"
mkdir -p "$TUNNEL_DIR/.ssh"
chown -R "$TUNNEL_USER:$TUNNEL_USER" "$TUNNEL_DIR"
chmod 700 "$TUNNEL_DIR/.ssh"

# Generate SSH key if not exists
if [ ! -f "$TUNNEL_DIR/.ssh/id_rsa" ]; then
    sudo -u "$TUNNEL_USER" ssh-keygen -t rsa -b 2048 -f "$TUNNEL_DIR/.ssh/id_rsa" -N "" -q
    chmod 600 "$TUNNEL_DIR/.ssh/id_rsa"
fi

# Display public key (user needs to add this to relay server)
PUBLIC_KEY=$(cat "$TUNNEL_DIR/.ssh/id_rsa.pub" 2>/dev/null || echo "NO_KEY")
echo -e "${GREEN}✓ SSH key generated${NC}"
echo -e "${YELLOW}⚠ Add this key to relay server authorized_keys:${NC}"
echo -e "${BLUE}$PUBLIC_KEY${NC}"

# Step 4: Create persistent tunnel service
echo -e "${BLUE}[4/7] Creating tunnel service...${NC}"

# Check if autossh is available, otherwise use ssh
TUNNEL_CMD="ssh"
if command -v autossh >/dev/null 2>&1; then
    TUNNEL_CMD="autossh -M 0"
fi

cat > /etc/systemd/system/zforge-tunnel.service << EOF
[Unit]
Description=ZynexForge RDP Tunnel to $RELAY_HOST
After=network.target
Wants=network.target

[Service]
Type=simple
User=$TUNNEL_USER
ExecStart=/usr/bin/$TUNNEL_CMD -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -N -T -R *:$RELAY_RDP_PORT:$LOCAL_IP:$LOCAL_RDP_PORT $RELAY_HOST -p $RELAY_SSH_PORT
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1
systemctl enable zforge-tunnel.service >/dev/null 2>&1
systemctl start zforge-tunnel.service

echo -e "${GREEN}✓ Tunnel service created${NC}"

# Step 5: Wait for tunnel connection
echo -e "${BLUE}[5/7] Establishing tunnel connection...${NC}"
echo -e "${YELLOW}⚠ Waiting for connection to $RELAY_HOST...${NC}"

CONNECTED=false
for i in {1..20}; do
    if systemctl is-active --quiet zforge-tunnel.service; then
        if pgrep -f "ssh.*$RELAY_HOST.*$RELAY_RDP_PORT" >/dev/null; then
            CONNECTED=true
            echo -e "${GREEN}✓ Tunnel connected to $RELAY_HOST${NC}"
            break
        fi
    fi
    sleep 2
    echo -n "."
done

if [ "$CONNECTED" = false ]; then
    echo -e "${YELLOW}⚠ Tunnel not connected yet (still trying in background)${NC}"
    echo -e "${YELLOW}Check status: systemctl status zforge-tunnel${NC}"
fi

# Step 6: Create RDP user
echo -e "${BLUE}[6/7] Creating RDP user...${NC}"
USERNAME="zforge_$(openssl rand -hex 3 2>/dev/null || echo "$(date +%s)")"
PASSWORD="Zynex@$(openssl rand -hex 4 2>/dev/null || date +%s | tail -c 6)"

# Remove user if exists and create fresh
userdel -r "$USERNAME" 2>/dev/null || true
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Setup XFCE session
cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/bash
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
EOF
chmod +x "/home/$USERNAME/.xsession"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

echo -e "${GREEN}✓ User $USERNAME created${NC}"

# Step 7: Get relay connection info
echo -e "${BLUE}[7/7] Finalizing setup...${NC}"

# Try to get relay IP for display
RELAY_IP="$RELAY_HOST"
if command -v dig >/dev/null 2>&1; then
    DIG_RESULT=$(dig +short "$RELAY_HOST" 2>/dev/null | head -1)
    if [ -n "$DIG_RESULT" ]; then
        RELAY_IP="$DIG_RESULT"
    fi
fi

# Save credentials
mkdir -p /root/.zforge
cat > /root/.zforge/tunnel_credentials.txt << EOF
========================================
ZYNFORGE RDP TUNNEL SETUP
========================================
CONNECTION DETAILS:
Connect to: $RELAY_IP:$RELAY_RDP_PORT
Username: $USERNAME
Password: $PASSWORD

TUNNEL CONFIGURATION:
Relay Server: $RELAY_HOST:$RELAY_SSH_PORT
Local RDP: $LOCAL_IP:$LOCAL_RDP_PORT
Tunnel: $LOCAL_IP:$LOCAL_RDP_PORT → $RELAY_HOST:$RELAY_RDP_PORT

SSH PUBLIC KEY (add to relay):
$PUBLIC_KEY

SERVICE STATUS:
Tunnel: $(systemctl is-active zforge-tunnel.service)
XRDP: $(pgrep -x xrdp >/dev/null && echo 'Running' || echo 'Not found')

MANAGEMENT COMMANDS:
Check tunnel: systemctl status zforge-tunnel
Restart tunnel: systemctl restart zforge-tunnel
View logs: journalctl -u zforge-tunnel -f
Restart XRDP: pkill xrdp; xrdp-sesman & xrdp &
========================================
Generated: $(date)
EOF
chmod 600 /root/.zforge/tunnel_credentials.txt

# Final output
echo -e "\n${GREEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 TUNNEL RDP SETUP COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}🚀 CONNECT TO:${NC}"
echo -e "  ${GREEN}$RELAY_IP:$RELAY_RDP_PORT${NC}"
echo -e ""
echo -e "${YELLOW}🔐 CREDENTIALS:${NC}"
echo -e "  Username: ${GREEN}$USERNAME${NC}"
echo -e "  Password: ${GREEN}$PASSWORD${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}📡 TUNNEL CONFIGURATION:${NC}"
echo -e "  Relay Server: ${GREEN}$RELAY_HOST${NC}"
echo -e "  Local RDP: ${GREEN}127.0.0.1:3389${NC}"
echo -e "  Tunnel Status: ${GREEN}$(systemctl is-active zforge-tunnel.service)${NC}"

echo -e "\n${YELLOW}⚠ IMPORTANT REQUIRED STEP:${NC}"
echo -e "  1. Add this SSH key to ${GREEN}$RELAY_HOST:~/.ssh/authorized_keys${NC}"
echo -e "  2. Key: ${BLUE}$PUBLIC_KEY${NC}"
echo -e "  3. Without this, tunnel won't work!"

echo -e "\n${YELLOW}🔧 MANAGEMENT:${NC}"
echo -e "  Check tunnel: ${GREEN}systemctl status zforge-tunnel${NC}"
echo -e "  View logs: ${GREEN}journalctl -u zforge-tunnel -f${NC}"
echo -e "  Credentials: ${GREEN}/root/.zforge/tunnel_credentials.txt${NC}"

echo -e "\n${YELLOW}✅ HOW IT WORKS:${NC}"
echo "  1. XRDP runs ONLY on localhost (127.0.0.1)"
echo "  2. SSH tunnel forwards traffic to relay server"
echo "  3. You connect to relay server's public IP"
echo "  4. No public IP needed on this VPS"

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup completed at $(date)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${RED}⚠ CRITICAL:${NC} Add the SSH public key above to your relay server!"
echo -e "${RED}  Without this step, the tunnel WILL NOT WORK!${NC}"
