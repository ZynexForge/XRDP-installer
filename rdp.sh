#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# RDP Setup - Fix Edition
# Version: 9.0.0
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Fix XRDP installation
echo -e "${BLUE}[1/5] Fixing XRDP installation...${NC}"

# Kill any running xrdp processes
pkill -9 xrdp 2>/dev/null || true
pkill -9 xrdp-sesman 2>/dev/null || true

# Remove and reinstall xrdp
apt-get remove --purge -y xrdp xorgxrdp 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Install fresh
apt-get update >/dev/null 2>&1
apt-get install -y xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal curl openssl >/dev/null 2>&1
echo -e "${GREEN}✓ XRDP reinstalled${NC}"

# Configure XRDP properly
echo -e "${BLUE}[2/5] Configuring XRDP...${NC}"

# Create minimal config
cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
bitmap_cache=yes
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

# Fix sesman config
cat > /etc/xrdp/sesman.ini << 'EOF'
[Globals]
ListenAddress=127.0.0.1
ListenPort=3350
EnableUserWindowManager=1
UserWindowManager=startxfce4
DefaultWindowManager=startxfce4

[Security]
AllowRootLogin=yes
MaxLoginRetry=4

[Sessions]
MaxSessions=10
KillDisconnected=0
IdleTimeLimit=0
DisconnectedTimeLimit=0
EOF

# Set XFCE session
echo "#!/bin/sh" > /etc/xrdp/startwm.sh
echo "unset DBUS_SESSION_BUS_ADDRESS" >> /etc/xrdp/startwm.sh
echo "unset XDG_RUNTIME_DIR" >> /etc/xrdp/startwm.sh
echo "export XDG_CURRENT_DESKTOP=XFCE" >> /etc/xrdp/startwm.sh
echo "startxfce4" >> /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

# Start XRDP manually first
echo -e "${BLUE}[3/5] Starting XRDP...${NC}"

# Stop systemd service if it exists
systemctl stop xrdp 2>/dev/null || true
systemctl disable xrdp 2>/dev/null || true

# Start xrdp in background
xrdp 2>/dev/null &
xrdp-sesman 2>/dev/null &

sleep 3

# Check if running
if pgrep -x "xrdp" >/dev/null && pgrep -x "xrdp-sesman" >/dev/null; then
    echo -e "${GREEN}✓ XRDP processes running${NC}"
else
    echo -e "${YELLOW}⚠ XRDP processes not found, trying alternative...${NC}"
    # Try to start manually
    /usr/sbin/xrdp 2>/dev/null &
    /usr/sbin/xrdp-sesman 2>/dev/null &
    sleep 2
fi

# Create user
echo -e "${BLUE}[4/5] Creating user account...${NC}"
USERNAME="zforge_$(openssl rand -hex 3 2>/dev/null || echo "$(date +%s)")"
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
startxfce4
EOF
chmod +x "/home/$USERNAME/.xsession"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

echo -e "${GREEN}✓ User $USERNAME created${NC}"

# Get IP
echo -e "${BLUE}[5/5] Getting connection info...${NC}"
PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
LOCAL_IP=$(hostname -I | awk '{print $1}' | head -1)

if [ -n "$PUBLIC_IP" ] && [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    CONNECT_IP="$PUBLIC_IP"
    echo -e "${GREEN}✓ Public IP: $PUBLIC_IP${NC}"
else
    CONNECT_IP="$LOCAL_IP"
    echo -e "${YELLOW}✓ Local IP: $LOCAL_IP${NC}"
fi

# Check port
sleep 2
if netstat -tln 2>/dev/null | grep -q ":3389 "; then
    echo -e "${GREEN}✓ Port 3389 is listening${NC}"
elif ss -tln 2>/dev/null | grep -q ":3389 "; then
    echo -e "${GREEN}✓ Port 3389 is listening${NC}"
else
    echo -e "${YELLOW}⚠ Port 3389 not detected${NC}"
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
echo -e "Port:     ${GREEN}3389${NC}"
echo -e "Username: ${GREEN}$USERNAME${NC}"
echo -e "Password: ${GREEN}$PASSWORD${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}How to connect:${NC}"
echo "1. Remote Desktop Connection (Windows)"
echo "2. Enter: ${GREEN}$CONNECT_IP${NC}"
echo "3. Username: ${GREEN}$USERNAME${NC}"
echo "4. Password: ${GREEN}$PASSWORD${NC}"

echo -e "\n${YELLOW}Status:${NC}"
echo "XRDP Process: $(pgrep -x "xrdp" >/dev/null && echo 'Running' || echo 'Not running')"
echo "Sesman Process: $(pgrep -x "xrdp-sesman" >/dev/null && echo 'Running' || echo 'Not running')"

if [[ $CONNECT_IP == "127."* ]] || [[ $CONNECT_IP == "192.168."* ]] || [[ $CONNECT_IP == "10."* ]]; then
    echo -e "\n${YELLOW}⚠ Local Network Only:${NC}"
    echo "To access from internet, configure port forwarding on your router."
    echo "Forward port 3389 to: $LOCAL_IP"
fi

echo -e "\n${YELLOW}Troubleshooting commands:${NC}"
echo "Check processes: ps aux | grep xrdp"
echo "Check port: netstat -tlnp | grep 3389"
echo "Restart XRDP: pkill xrdp; xrdp & xrdp-sesman &"

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup completed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Save credentials
mkdir -p /root/.zforge
cat > /root/.zforge/rdp_credentials.txt << EOF
IP: $CONNECT_IP
Port: 3389
Username: $USERNAME
Password: $PASSWORD
EOF
chmod 600 /root/.zforge/rdp_credentials.txt
