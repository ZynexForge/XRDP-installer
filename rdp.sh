#!/bin/bash

# ============================================================================
# ZynexForge: zforge-xrdp
# RDP Setup - No Systemd Edition
# Version: 10.0.0
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
echo "  ZynexForge - RDP Setup (Direct Mode)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}✗ Must be run as root${NC}"
    exit 1
fi

# Step 1: Clean up any existing XRDP
echo -e "${BLUE}[1/5] Cleaning up XRDP...${NC}"
pkill -9 xrdp 2>/dev/null || true
pkill -9 xrdp-sesman 2>/dev/null || true
pkill -9 Xvnc 2>/dev/null || true

# Remove systemd service to avoid conflicts
systemctl stop xrdp 2>/dev/null || true
systemctl disable xrdp 2>/dev/null || true
rm -f /etc/systemd/system/xrdp.service 2>/dev/null || true

# Step 2: Install fresh
echo -e "${BLUE}[2/5] Installing XRDP and desktop...${NC}"
apt-get update >/dev/null 2>&1
apt-get install -y xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal curl openssl >/dev/null 2>&1
echo -e "${GREEN}✓ Software installed${NC}"

# Step 3: Create minimal config
echo -e "${BLUE}[3/5] Creating configuration...${NC}"

# Backup old configs
mv /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak 2>/dev/null || true
mv /etc/xrdp/sesman.ini /etc/xrdp/sesman.ini.bak 2>/dev/null || true

# Create ultra-simple xrdp config
cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
port=3389
crypt_level=none

[xrdp1]
name=MyRDP
lib=libvnc.so
ip=127.0.0.1
port=-1
username=ask
password=ask
EOF

# Create simple sesman config
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

# Create start script
cat > /etc/xrdp/startwm.sh << 'EOF'
#!/bin/bash
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
. /etc/X11/Xsession
startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh

echo -e "${GREEN}✓ Configuration created${NC}"

# Step 4: Start XRDP manually
echo -e "${BLUE}[4/5] Starting XRDP services...${NC}"

# Start sesman first
/usr/sbin/xrdp-sesman --nodaemon 2>/dev/null &
SESMAN_PID=$!
sleep 2

# Start xrdp
/usr/sbin/xrdp --nodaemon 2>/dev/null &
XRDP_PID=$!
sleep 3

# Check if processes are running
if ps -p $SESMAN_PID >/dev/null && ps -p $XRDP_PID >/dev/null; then
    echo -e "${GREEN}✓ XRDP services started (PID: $XRDP_PID, Sesman: $SESMAN_PID)${NC}"
else
    echo -e "${YELLOW}⚠ Services may have issues, trying alternative method...${NC}"
    # Try direct start without --nodaemon
    xrdp-sesman 2>/dev/null &
    sleep 1
    xrdp 2>/dev/null &
    sleep 2
fi

# Create user
echo -e "${BLUE}[5/5] Creating user account...${NC}"
USERNAME="zforge_$(date +%s | tail -c 4)"
PASSWORD="Zynex@$(openssl rand -hex 3 2>/dev/null || echo "$(date +%s)")"

# Remove user if exists
userdel -r "$USERNAME" 2>/dev/null || true

# Create new user
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Add to sudo group
usermod -aG sudo "$USERNAME" 2>/dev/null || true

# Create X session
cat > "/home/$USERNAME/.xsession" << 'EOF'
#!/bin/bash
startxfce4
EOF
chmod +x "/home/$USERNAME/.xsession"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

echo -e "${GREEN}✓ User $USERNAME created${NC}"

# Get IP address
echo -e "${BLUE}Getting connection info...${NC}"
PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
LOCAL_IP=$(hostname -I | awk '{print $1}' | head -1)

if [ -n "$PUBLIC_IP" ] && [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    CONNECT_IP="$PUBLIC_IP"
    echo -e "${GREEN}✓ Public IP: $PUBLIC_IP${NC}"
else
    CONNECT_IP="$LOCAL_IP"
    echo -e "${YELLOW}✓ Local IP: $LOCAL_IP${NC}"
fi

# Check if port is listening
echo -e "${BLUE}Checking service...${NC}"
sleep 3

if lsof -i :3389 2>/dev/null | grep -q xrdp; then
    echo -e "${GREEN}✓ XRDP listening on port 3389${NC}"
elif netstat -tln 2>/dev/null | grep -q ":3389 "; then
    echo -e "${GREEN}✓ Port 3389 is listening${NC}"
elif ss -tln 2>/dev/null | grep -q ":3389 "; then
    echo -e "${GREEN}✓ Port 3389 is listening${NC}"
else
    echo -e "${YELLOW}⚠ Port 3389 not detected - trying to restart...${NC}"
    pkill xrdp 2>/dev/null || true
    sleep 1
    xrdp 2>/dev/null &
    sleep 2
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
echo "1. Open Remote Desktop Connection (Windows)"
echo "2. Enter: ${GREEN}$CONNECT_IP${NC}"
echo "3. Click Connect"
echo "4. Username: ${GREEN}$USERNAME${NC}"
echo "5. Password: ${GREEN}$PASSWORD${NC}"

echo -e "\n${YELLOW}Service Status:${NC}"
echo "XRDP Process: $(pgrep xrdp >/dev/null && echo '✓ Running' || echo '✗ Not running')"
echo "Sesman Process: $(pgrep xrdp-sesman >/dev/null && echo '✓ Running' || echo '✗ Not running')"
echo "Port 3389: $(netstat -tln 2>/dev/null | grep -q ':3389 ' && echo '✓ Listening' || echo '✗ Not found')"

if [[ $CONNECT_IP == "127."* ]] || [[ $CONNECT_IP == "192.168."* ]] || [[ $CONNECT_IP == "10."* ]]; then
    echo -e "\n${YELLOW}⚠ Local Access Only:${NC}"
    echo "Your IP ($CONNECT_IP) is local/private."
    echo "For internet access:"
    echo "1. Configure port forwarding on your router"
    echo "2. Forward port 3389 to $LOCAL_IP"
    echo "3. Use your router's public IP to connect"
fi

echo -e "\n${YELLOW}Management Commands:${NC}"
echo "Restart XRDP: pkill xrdp; sleep 1; xrdp & xrdp-sesman &"
echo "Check logs: tail -f /var/log/xrdp.log"
echo "Check sessions: netstat -tlnp | grep 3389"

echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Setup completed at $(date)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Save credentials
mkdir -p /root/.zforge
cat > /root/.zforge/rdp_credentials.txt << EOF
IP: $CONNECT_IP
Port: 3389
Username: $USERNAME
Password: $PASSWORD
Start Command: xrdp & xrdp-sesman &
EOF
chmod 600 /root/.zforge/rdp_credentials.txt
echo -e "${GREEN}✓ Credentials saved to /root/.zforge/rdp_credentials.txt${NC}"

# Create startup script
cat > /root/.zforge/start_xrdp.sh << 'EOF'
#!/bin/bash
pkill xrdp 2>/dev/null
pkill xrdp-sesman 2>/dev/null
sleep 1
xrdp-sesman 2>/dev/null &
sleep 1
xrdp 2>/dev/null &
echo "XRDP started"
EOF
chmod +x /root/.zforge/start_xrdp.sh
