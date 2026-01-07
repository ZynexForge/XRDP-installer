#!/bin/bash
# ============================================================================
# ZynexForge: zforge-xrdp
# Production-Grade XRDP Automation with Relay Tunnel
# Version: 2.5.1
# ============================================================================

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
readonly USER_PREFIX="zforge"
readonly XRDP_LOCAL_PORT=3389
readonly XRDP_LOCAL_IP="127.0.0.1"
readonly RELAY_SERVER="relay.zynexforge.net"
readonly RELAY_PORT=2222
readonly TUNNEL_USER="zforge_tunnel"
readonly TUNNEL_DIR="/opt/zforge-tunnel"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# UTILITIES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
die() { 
    echo "Error: $1" >&2
    exit 1
}

validate_root() { 
    [[ $EUID -eq 0 ]] || die "Must be run as root"
}

check_dependencies() {
    for cmd in ssh systemctl curl openssl useradd chpasswd; do
        if ! command -v "$cmd" &>/dev/null; then
            die "Missing: $cmd"
        fi
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CORE FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
generate_random_username() {
    local random_suffix
    random_suffix=$(openssl rand -hex 3 2>/dev/null || echo "user")
    echo "${USER_PREFIX}_${random_suffix}"
}

generate_strong_password() {
    openssl rand -base64 24 2>/dev/null | tr -d '/+=\n' || echo "ZynexForge@$(date +%s)"
}

create_linux_user() {
    local username="$1"
    local password="$2"
    
    if ! id "$username" &>/dev/null; then
        useradd -m -s /bin/bash -G sudo "$username" || die "Failed to create user"
        mkdir -p /home/"$username"/.config
        cat > /home/"$username"/.xsession << 'EOF'
#!/bin/bash
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
EOF
        chmod +x /home/"$username"/.xsession
        chown -R "$username":"$username" /home/"$username"
    fi
    echo "$username:$password" | chpasswd || die "Failed to set password"
}

install_xrdp() {
    if ! systemctl is-active --quiet xrdp; then
        apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            xrdp xorgxrdp xfce4 xfce4-goodies xfce4-terminal >/dev/null 2>&1 || die "Failed to install XRDP"
        
        cat > /etc/xrdp/xrdp.ini << 'EOF'
[globals]
port=3389
crypt_level=high
ip=127.0.0.1

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
        systemctl restart xrdp >/dev/null 2>&1
    fi
}

setup_tunnel_systemd() {
    if ! id "$TUNNEL_USER" &>/dev/null; then
        useradd -r -m -d "$TUNNEL_DIR" -s /bin/bash "$TUNNEL_USER" 2>/dev/null || true
    fi
    
    mkdir -p "$TUNNEL_DIR/.ssh"
    chown -R "$TUNNEL_USER":"$TUNNEL_USER" "$TUNNEL_DIR" 2>/dev/null || true
    
    if [[ ! -f "$TUNNEL_DIR/.ssh/id_rsa" ]]; then
        ssh-keygen -t rsa -b 4096 -f "$TUNNEL_DIR/.ssh/id_rsa" -N "" -q >/dev/null 2>&1
        chmod 700 "$TUNNEL_DIR/.ssh" 2>/dev/null || true
        chmod 600 "$TUNNEL_DIR/.ssh/id_rsa" 2>/dev/null || true
    fi
    
    cat > /etc/systemd/system/zforge-tunnel.service << EOF
[Unit]
Description=ZynexForge XRDP Tunnel
After=network.target

[Service]
Type=simple
User=$TUNNEL_USER
ExecStart=/usr/bin/ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -N -T -R *:3389:127.0.0.1:3389 $RELAY_SERVER -p $RELAY_PORT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable zforge-tunnel.service >/dev/null 2>&1
    systemctl restart zforge-tunnel.service >/dev/null 2>&1
    
    # Wait for tunnel
    for i in {1..10}; do
        if pgrep -f "ssh.*$RELAY_SERVER.*3389" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
}

get_relay_public_ip() {
    local relay_ip=""
    
    # Try multiple methods to get IP
    if command -v getent &>/dev/null; then
        relay_ip=$(getent ahosts "$RELAY_SERVER" 2>/dev/null | grep STREAM | awk '{print $1}' | head -1)
    fi
    
    if [[ -z "$relay_ip" ]] && command -v host &>/dev/null; then
        relay_ip=$(host "$RELAY_SERVER" 2>/dev/null | grep "has address" | awk '{print $NF}' | head -1)
    fi
    
    if [[ -z "$relay_ip" ]] && command -v ping &>/dev/null; then
        relay_ip=$(ping -c 1 -W 1 "$RELAY_SERVER" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    if [[ -z "$relay_ip" ]] && command -v nslookup &>/dev/null; then
        relay_ip=$(nslookup "$RELAY_SERVER" 2>/dev/null | grep Address | tail -1 | awk '{print $2}')
    fi
    
    [[ -z "$relay_ip" ]] && relay_ip="$RELAY_SERVER"
    echo "$relay_ip"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MAIN EXECUTION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main() {
    validate_root
    check_dependencies
    
    # Update silently
    apt-get update -qq >/dev/null 2>&1 || true
    
    local username
    local password
    local relay_ip
    
    username=$(generate_random_username)
    password=$(generate_strong_password)
    
    create_linux_user "$username" "$password"
    install_xrdp
    setup_tunnel_systemd
    relay_ip=$(get_relay_public_ip)
    
    # FINAL OUTPUT
    echo -e "\n\033[1;32m🎉 Congratulations! Your RDP has been created\033[0m\n"
    echo -e "\033[1;37mIP     : \033[1;33m$relay_ip:3389\033[0m"
    echo -e "\033[1;37mUSER   : \033[1;33m$username\033[0m"
    echo -e "\033[1;37mPASS   : \033[1;33m$password\033[0m\n"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
