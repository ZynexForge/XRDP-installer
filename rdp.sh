#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# Complete FRP Tunnel Setup with Automatic Relay
# Version: 14.0.0
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
FRP_SERVER="frp.zynexforge.net"        # Automatic relay server
FRP_SERVER_PORT="7000"                  # FRP server port
FRP_VERSION="0.54.0"                    # FRP version
LOCAL_RDP_PORT="3389"
LOCAL_IP="127.0.0.1"

# Banner
echo -e "${BLUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ZynexForge - Automatic FRP Tunnel RDP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"
echo -e "${YELLOW}Architecture:${NC}"
echo -e "  Your VPS → ${GREEN}ZynexForge Relay Server${NC} → You"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Must be run as root${NC}"
    exit 1
fi

# Step 1: Install XRDP dependencies
echo -e "${BLUE}[1/6] Installing XRDP and desktop...${NC}"
apt-get update >/dev/null 2>&1
apt-get install -y xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal curl wget tar >/dev/null 2>&1
echo -e "${GREEN}✓ XRDP installed${NC}"

# Step 2: Configure XRDP (localhost only)
echo -e "${BLUE}[2/6] Configuring XRDP (127.0.0.1 only)...${NC}"

# Kill existing XRDP
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

# Start XRDP manually
/usr/sbin/xrdp-sesman >/dev/null 2>&1 &
sleep 1
/usr/sbin/xrdp >/dev/null 2>&1 &
sleep 2

if pgrep -x "xrdp" >/dev/null; then
    echo -e "${GREEN}✓ XRDP running on ${LOCAL_IP}:${LOCAL_RDP_PORT}${NC}"
else
    echo -e "${YELLOW}⚠ XRDP startup issue (continuing anyway)${NC}"
fi

# Step 3: Install FRP Client
echo -e "${BLUE}[3/6] Installing FRP Client (v${FRP_VERSION})...${NC}"

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64) FRP_ARCH="amd64" ;;
    aarch64) FRP_ARCH="arm64" ;;
    armv7l) FRP_ARCH="arm" ;;
    *) FRP_ARCH="amd64" ;;
esac

# Download FRP
cd /tmp
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
wget -q "$FRP_URL" -O frp.tar.gz
tar -xzf frp.tar.gz
cd frp_${FRP_VERSION}_linux_${FRP_ARCH}

# Install frpc
mkdir -p /opt/frp
cp frpc /opt/frp/
chmod +x /opt/frp/frpc

# Cleanup
cd / && rm -rf /tmp/frp*
echo -e "${GREEN}✓ FRP Client installed${NC}"

# Step 4: Generate random external port and configure FRP
echo -e "${BLUE}[4/6] Setting up FRP tunnel...${NC}"

# Generate random port between 45000-45999
RANDOM_PORT=$((45000 + RANDOM % 1000))
TOKEN=$(echo "zynexforge-$(date +%s)-$(hostname)" | md5sum | cut -c1-16)

# Get FRP server IP
echo -e "${YELLOW}Resolving relay server...${NC}"
FRP_SERVER_IP=""
if command -v dig >/dev/null 2>&1; then
    FRP_SERVER_IP=$(dig +short "$FRP_SERVER" 2>/dev/null | head -1)
fi

if [ -z "$FRP_SERVER_IP" ]; then
    FRP_SERVER_IP="$FRP_SERVER"
    echo -e "${YELLOW}Using domain: $FRP_SERVER${NC}"
else
    echo -e "${GREEN}✓ Relay IP: $FRP_SERVER_IP${NC}"
fi

echo -e "${YELLOW}External Port: ${RANDOM_PORT}${NC}"

# Generate FRP config with authentication
mkdir -p /etc/frp
cat > /etc/frp/frpc.ini << EOF
[common]
server_addr = ${FRP_SERVER}
server_port = ${FRP_SERVER_PORT}
authentication_method = token
authentication_timeout = 900
token = ${TOKEN}
tls_enable = true
tls_cert_file = 
tls_key_file = 
tls_trusted_ca_file = 
disable_custom_tls_first_byte = false
pool_count = 5

[zynexforge-rdp-${RANDOM_PORT}]
type = tcp
local_ip = ${LOCAL_IP}
local_port = ${LOCAL_RDP_PORT}
remote_port = ${RANDOM_PORT}
use_encryption = true
use_compression = true
EOF

# Create systemd service for FRP
cat > /etc/systemd/system/zynexforge-frpc.service << EOF
[Unit]
Description=ZynexForge FRP Client (RDP Tunnel)
After=network.target
Wants=network.target

[Service]
Type=simple
Restart=always
RestartSec=5
User=root
ExecStart=/opt/frp/frpc -c /etc/frp/frpc.ini
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=4096
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1
systemctl enable zynexforge-frpc.service >/dev/null 2>&1
systemctl start zynexforge-frpc.service

echo -e "${GREEN}✓ FRP tunnel configured${NC}"

# Step 5: Create RDP user
echo -e "${BLUE}[5/6] Creating RDP user...${NC}"
USERNAME="zforge_$(date +%s | tail -c 4)"
PASSWORD="Zynex@$(openssl rand -hex 4 2>/dev/null || date +%s | tail -c 6)"

# Create user
useradd -m -s /bin/bash "$USERNAME" 2>/dev/null || true
echo "$USERNAME:$PASSWORD" | chpasswd 2>/dev/null || true

# Setup XFCE session
cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/bash
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
EOF
chmod +x "/home/$USERNAME/.xsession"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

echo -e "${GREEN}✓ User ${USERNAME} created${NC}"

# Step 6: Wait for FRP connection and finalize
echo -e "${BLUE}[6/6] Establishing tunnel connection...${NC}"

echo -e "${YELLOW}Connecting to ZynexForge Relay...${NC}"
CONNECTED=false
for i in {1..20}; do
    if systemctl is-active --quiet zynexforge-frpc.service; then
        if pgrep -f "frpc.*${FRP_SERVER}" >/dev/null; then
            CONNECTED=true
            echo -e "${GREEN}✓ Tunnel connected successfully${NC}"
            break
        fi
    fi
    sleep 2
    echo -n "."
done

if [ "$CONNECTED" = false ]; then
    echo -e "${YELLOW}⚠ Tunnel still connecting in background...${NC}"
    echo -e "${YELLOW}Check: systemctl status zynexforge-frpc${NC}"
fi

# Get final connection IP
FINAL_IP="$FRP_SERVER_IP"
if [ -z "$FINAL_IP" ] || [[ "$FINAL_IP" == "$FRP_SERVER" ]]; then
    # Try to get actual IP for user
    FINAL_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "$FRP_SERVER")
fi

# Save credentials
mkdir -p /root/.zforge
cat > /root/.zforge/frp_tunnel.txt << EOF
========================================
ZYNFORGE AUTOMATIC FRP RDP TUNNEL
========================================
🎉 CONNECTION READY 🎉

CONNECT TO:
${FINAL_IP}:${RANDOM_PORT}

CREDENTIALS:
Username: ${USERNAME}
Password: ${PASSWORD}

ARCHITECTURE:
┌─────────────────────────────────────┐
│ Your VPS (no public IP needed)      │
│   XRDP → 127.0.0.1:3389            │
│   FRPC → outbound only              │
│          │                          │
│          │ (OUTBOUND TCP)           │
│          ▼                          │
│ ZynexForge Relay (public IP)        │
│   FRPS port: ${FRP_SERVER_PORT}                │
│   Open port: ${RANDOM_PORT}                    │
│          │                          │
│          ▼                          │
│ You connect → ${FINAL_IP}:${RANDOM_PORT} │
└─────────────────────────────────────┘

TUNNEL DETAILS:
Relay Server: ${FRP_SERVER}:${FRP_SERVER_PORT}
Local RDP: ${LOCAL_IP}:${LOCAL_RDP_PORT}
Remote Port: ${RANDOM_PORT}
Token: ${TOKEN}

STATUS:
FRP Tunnel: $(systemctl is-active zynexforge-frpc.service)
XRDP: $(pgrep -x xrdp >/dev/null && echo 'Running' || echo 'Not found')

MANAGEMENT:
Check tunnel: systemctl status zynexforge-frpc
View logs: journalctl -u zynexforge-frpc -f
Restart: systemctl restart zynexforge-frpc
Stop: systemctl stop zynexforge-frpc
========================================
Generated: $(date)
EOF
chmod 600 /root/.zforge/frp_tunnel.txt

# Final output
echo -e "\n${GREEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 AUTOMATIC TUNNEL RDP SETUP COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}🚀 CONNECT NOW:${NC}"
echo -e "  ${GREEN}${FINAL_IP}:${RANDOM_PORT}${NC}"
echo -e ""
echo -e "${YELLOW}🔐 CREDENTIALS:${NC}"
echo -e "  Username: ${GREEN}${USERNAME}${NC}"
echo -e "  Password: ${GREEN}${PASSWORD}${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}📡 TUNNEL STATUS:${NC}"
echo -e "  Relay Server: ${GREEN}${FRP_SERVER}${NC}"
echo -e "  Tunnel Port: ${GREEN}${RANDOM_PORT}${NC}"
echo -e "  Service: ${GREEN}$(systemctl is-active zynexforge-frpc.service)${NC}"

echo -e "\n${YELLOW}🔧 HOW TO CONNECT:${NC}"
echo "  1. Open Remote Desktop Connection (Windows)"
echo "  2. Enter: ${GREEN}${FINAL_IP}:${RANDOM_PORT}${NC}"
echo "  3. Username: ${GREEN}${USERNAME}${NC}"
echo "  4. Password: ${GREEN}${PASSWORD}${NC}"
echo "  5. Click Connect"

echo -e "\n${YELLOW}✅ ARCHITECTURE SUMMARY:${NC}"
echo "  ┌─────────────────────────────┐"
echo "  │ Your VPS (no public IP)     │"
echo "  │   ↓ XRDP (127.0.0.1:3389)   │"
echo "  │   ↓ FRPC (outbound only)    │"
echo "  │          │                   │"
echo "  │          └──▶ ZynexForge    │"
echo "  │               Relay Server  │"
echo "  │          │                   │"
echo "  │          └──▶ You connect   │"
echo "  └─────────────────────────────┘"

echo -e "\n${YELLOW}⚡ QUICK COMMANDS:${NC}"
echo -e "  Status:  ${GREEN}systemctl status zynexforge-frpc${NC}"
echo -e "  Logs:    ${GREEN}journalctl -u zynexforge-frpc -f${NC}"
echo -e "  Restart: ${GREEN}systemctl restart zynexforge-frpc${NC}"
echo -e "  Info:    ${GREEN}cat /root/.zforge/frp_tunnel.txt${NC}"

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup completed at $(date)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}📝 Credentials saved: /root/.zforge/frp_tunnel.txt${NC}"
echo -e "${YELLOW}⚠ Keep this information secure!${NC}"
