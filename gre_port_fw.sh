#!/bin/bash

# ==========================================
# Script Name: GRE Tunnel & Port Forwarder
# Version: 2.1 (FIXED IPTABLES LOOPS)
# Description: Automated GRE Tunnel Setup between IR and Kharej
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_FILE="/etc/gre_tunnel.conf"
SCRIPT_PATH=$(readlink -f "$0")

if [[ "$1" == "--debug" ]]; then
    set -x 
    echo -e "${YELLOW}[DEBUG] Mode active.${NC}"
fi

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Lotfan ba dasteresi ROOT ejra konid!${NC}"
  exit 1
fi

if [[ "$1" == "--daemon" ]]; then
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        NON_INTERACTIVE=true
    else
        echo "Config file not found!"
        exit 1
    fi
else
    NON_INTERACTIVE=false
fi

echo -e "${CYAN}===============================================${NC}"
echo -e "${CYAN}     WELCOME TO GRE TUNNEL AUTO-CONFIGURATOR    ${NC}"
echo -e "${CYAN}===============================================${NC}"

if [ "$NON_INTERACTIVE" = false ]; then
    echo -e "${YELLOW}Lotfan IP Server IRAN ro vared konid:${NC}"
    read -p "-> " IP_IRAN
    if [[ -z "$IP_IRAN" ]]; then exit 1; fi

    echo -e "${YELLOW}Lotfan IP Server KHAREJ ro vared konid:${NC}"
    read -p "-> " IP_KHAREJ
    if [[ -z "$IP_KHAREJ" ]]; then exit 1; fi

    echo -e "${YELLOW}MTU pishfarz 1340 ast. Aya mikhahid an ro taghyir dehid? (y/N):${NC}"
    read -p "-> " CHOOSE_MTU
    MTU=1340
    if [[ "$CHOOSE_MTU" =~ ^[Yy]$ ]]; then
        read -p "-> MTU: " MTU
    fi

    echo -e "${YELLOW}Port haye mored nazar baraye forward (pishfarz: 80,443 - ba ',' joda konid):${NC}"
    read -p "-> " INPUT_PORTS
    if [[ -z "$INPUT_PORTS" ]]; then
        PORTS_STR="80,443"
    else
        PORTS_STR="$INPUT_PORTS"
    fi

    echo -e "${BLUE}In server kodom ast?\n1) Server IRAN\n2) Server KHAREJ${NC}"
    read -p "Entekhab konid (1 ya 2): " SERVER_ROLE
fi

cleanup_existing_gre() {
    if ip tunnel show | grep -q "gre1"; then
        echo -e "${YELLOW}[!] Tunnel gre1 az ghabl mikhad pak beshe...${NC}"
        ip link set gre1 down 2>/dev/null
        ip tunnel del gre1 2>/dev/null
    fi
}

if [[ "$SERVER_ROLE" == "1" ]]; then
    echo -e "${GREEN}[+] Shorooe tanzimate Server IRAN...${NC}"
    cleanup_existing_gre

    GATEWAY_IP=$(ip -4 route list 0/0 | grep -v 'gre' | grep -v 'tun' | awk '{print $3}' | head -n 1)
    INTERFACE=$(ip -4 route list 0/0 | grep -v 'gre' | grep -v 'tun' | awk '{print $5}' | head -n 1)

    ip tunnel add gre1 mode gre remote "$IP_KHAREJ" local "$IP_IRAN" ttl 225
    ip addr add 10.10.0.2/30 dev gre1
    ip link set gre1 up
    ip link set gre1 mtu "$MTU"

    ip route del "$IP_KHAREJ" 2>/dev/null
    ip route add "$IP_KHAREJ" via "$GATEWAY_IP" dev "$INTERFACE" onlink

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    iptables -t nat -F PREROUTING 2>/dev/null

    IFS=',' read -ra ADDR <<< "$PORTS_STR"
    for PORT in "${ADDR[@]}"; do
        PORT=$(echo "$PORT" | xargs) 
        if [[ ! -z "$PORT" ]]; then
            echo -e "${CYAN}[*] Adding IPTABLES Rule for Port: $PORT${NC}"
            iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination 10.10.0.1:"$PORT"
            iptables -t nat -A PREROUTING -p udp --dport "$PORT" -j DNAT --to-destination 10.10.0.1:"$PORT"
        fi
    done
    
    iptables -t nat -A POSTROUTING -o gre1 -j MASQUERADE

    echo -e "${GREEN}[V] Server IRAN ba movafaghriat tanzim shod.${NC}"

elif [[ "$SERVER_ROLE" == "2" ]]; then
    echo -e "${GREEN}[+] Shorooe tanzimate Server KHAREJ...${NC}"
    cleanup_existing_gre

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    ip tunnel add gre1 mode gre remote "$IP_IRAN" local "$IP_KHAREJ" ttl 225
    ip addr add 10.10.0.1/30 dev gre1
    ip link set gre1 up
    ip link set gre1 mtu "$MTU"

    iptables -A INPUT -i gre1 -j ACCEPT
    iptables -t nat -A POSTROUTING -s 10.10.0.0/30 -j MASQUERADE 2>/dev/null

    echo -e "${GREEN}[V] Server KHAREJ ba movafaghriat tanzim shod.${NC}"
fi

# --- SYSTEMD SERVICE SECTION ---
if [ "$NON_INTERACTIVE" = false ]; then
    echo -e "\nAya mikhahid Service Systemd sakhte/apdate shavad? (y/N):"
    read -p "-> " CREATE_SERVICE

    if [[ "$CREATE_SERVICE" =~ ^[Yy]$ ]]; then
        cat <<EOF > "$CONFIG_FILE"
IP_IRAN="$IP_IRAN"
IP_KHAREJ="$IP_KHAREJ"
MTU="$MTU"
PORTS_STR="$PORTS_STR"
SERVER_ROLE="$SERVER_ROLE"
EOF

        cat <<EOF > /etc/systemd/system/gre-tunnel.service
[Unit]
Description=GRE Tunnel and Port Forwarding Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_PATH --daemon
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable gre-tunnel.service >/dev/null 2>&1
        echo -e "${GREEN}[V] Service Systemd updated va active shod!${NC}"
    fi
fi
