#!/bin/bash

# ============================================================================
# ZynexForge: zforge-rdp
# Production XRDP Tunnel Setup
# Version: 18.0.0
# ============================================================================

set -e

# Configuration
RELAY_SERVER=$(curl -s https://api.ipify.org || echo "your-vps-public-ip")
RELAY_PORT="7000"
FRP_TOKEN="zynexforge_global_token_2024"
FRP_VERSION="0.54.0"
MIN_PORT=40000
MAX_PORT=60000
USER_PREFIX="zforge"
LOCAL_RDP_PORT="3389"
LOCAL_IP="127.0.0.1"

# Banner
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ZynexForge - RDP Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Must be run as root"
    exit 1
fi

echo "[1/7] Updating package list..."
apt-get update >/dev/null 2>&1 || true

echo "[2/7] Installing XRDP..."
apt-get install -y xrdp >/dev/null 2>&1 || echo "Installing XRDP..."

echo "[3/7] Installing desktop environment..."
apt-get install -y xfce4 xfce4-terminal firefox >/dev/null 2>&1 || echo "Installing desktop..."

echo "[4/7] Configuring XRDP (localhost only)..."

# Stop XRDP
systemctl stop xrdp >/dev/null 2>&1 || true

# Create config
cat > /etc/xrdp/xrdp.ini << EOF
[globals]
port=3389

[xrdp1]
name=sesman-Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=-1
EOF

echo "startxfce4" > /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

# Start XRDP
systemctl start xrdp 2>/dev/null || xrdp &

echo "✓ XRDP configured on 127.0.0.1:3389"

echo "[5/7] Creating user..."
USERNAME="${USER_PREFIX}_$(date +%s | tail -c 4)"
PASSWORD="Zynex@$(date +%s | tail -c 6)"

# Create user
useradd -m -s /bin/bash "$USERNAME" 2>/dev/null || true
echo "$USERNAME:$PASSWORD" | chpasswd 2>/dev/null || true

# X session
cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/bash
startxfce4
EOF
chmod +x "/home/$USERNAME/.xsession"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

echo "✓ User created: $USERNAME"

echo "[6/7] Setting up FRP tunnel..."

# Install FRP client
ARCH=$(uname -m)
case $ARCH in
    x86_64) FRP_ARCH="amd64" ;;
    aarch64) FRP_ARCH="arm64" ;;
    *) FRP_ARCH="amd64" ;;
esac

cd /tmp
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
wget -q "$FRP_URL" -O frp.tar.gz
tar -xzf frp.tar.gz
cd frp_${FRP_VERSION}_linux_${FRP_ARCH}
mkdir -p /opt/zynexforge
cp frpc /opt/zynexforge/
chmod +x /opt/zynexforge/frpc
cd / && rm -rf /tmp/frp*

# Generate random port
RANDOM_PORT=$((MIN_PORT + RANDOM % 1000))

echo "Relay Server: $RELAY_SERVER"
echo "External Port: $RANDOM_PORT"

# Create FRP config
cat > /etc/zynexforge.ini << EOF
[common]
server_addr = ${RELAY_SERVER}
server_port = ${RELAY_PORT}
token = ${FRP_TOKEN}

[rdp]
type = tcp
local_ip = ${LOCAL_IP}
local_port = ${LOCAL_RDP_PORT}
remote_port = ${RANDOM_PORT}
EOF

# Create service
cat > /etc/systemd/system/zynexforge.service << EOF
[Unit]
Description=ZynexForge RDP Tunnel
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=/opt/zynexforge/frpc -c /etc/zynexforge.ini

[Install]
WantedBy=multi-user.target
EOF

# Start service
systemctl daemon-reload
systemctl enable zynexforge.service
systemctl start zynexforge.service

echo "✓ FRP tunnel configured"

echo "[7/7] Finalizing setup..."
sleep 3

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Congratulations! Your RDP has been created"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "IP     : ${RELAY_SERVER}:${RANDOM_PORT}"
echo "USER   : ${USERNAME}"
echo "PASS   : ${PASSWORD}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "How to connect:"
echo "1. Remote Desktop Connection"
echo "2. Enter: ${RELAY_SERVER}:${RANDOM_PORT}"
echo "3. Username: ${USERNAME}"
echo "4. Password: ${PASSWORD}"

echo ""
echo "Service Status:"
echo "XRDP: $(systemctl is-active xrdp 2>/dev/null || echo 'unknown')"
echo "Tunnel: $(systemctl is-active zynexforge.service 2>/dev/null || echo 'unknown')"

# Save credentials
mkdir -p /root/.zynexforge
cat > /root/.zynexforge/credentials.txt << EOF
IP: ${RELAY_SERVER}:${RANDOM_PORT}
User: ${USERNAME}
Pass: ${PASSWORD}
Date: $(date)
EOF
chmod 600 /root/.zynexforge/credentials.txt

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Setup completed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
