#!/bin/bash

# ==========================================
# Script Name: Multi-GRE Tunnel & Port Forwarder
# Version: 3.0 (MTU 1450 & MSS 1410 Clamping)
# Description: Automated GRE Tunnel Setup (1 IR to 1 or 2 Kharej Servers)
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

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}   WELCOME TO MULTI-GRE TUNNEL AUTO-CONFIGURATOR    ${NC}"
echo -e "${CYAN}=====================================================${NC}"

if [ "$NON_INTERACTIVE" = false ]; then
    echo -e "${BLUE}Noe Arasaye Tunnel ro entekhab konid:${NC}"
    echo "1) 1 Server IRAN -> 1 Server KHAREJ (Tak Server)"
    echo "2) 1 Server IRAN -> 2 Server KHAREJ (Do Server)"
    read -p "Entekhab (1 ya 2): " MODE
    if [[ "$MODE" != "1" && "$MODE" != "2" ]]; then echo -e "${RED}Entekhab na-motabar!${NC}"; exit 1; fi

    echo -e "${YELLOW}Lotfan IP Server IRAN ro vared konid:${NC}"
    read -p "-> " IP_IRAN
    if [[ -z "$IP_IRAN" ]]; then exit 1; fi

    echo -e "${YELLOW}Lotfan IP Server KHAREJ 1 ro vared konid:${NC}"
    read -p "-> " IP_KHAREJ_1
    if [[ -z "$IP_KHAREJ_1" ]]; then exit 1; fi

    if [[ "$MODE" == "2" ]]; then
        echo -e "${YELLOW}Lotfan IP Server KHAREJ 2 ro vared konid:${NC}"
        read -p "-> " IP_KHAREJ_2
        if [[ -z "$IP_KHAREJ_2" ]]; then exit 1; fi
    fi


    MTU=1450
    MSS=1410
    echo -e "${YELLOW}MTU pishfarz 1450 va MSS pishfarz 1410 ast. Aya mikhahid anha ro taghyir dehid? (y/N):${NC}"
    read -p "-> " CHOOSE_CUSTOM_SETTINGS
    if [[ "$CHOOSE_CUSTOM_SETTINGS" =~ ^[Yy]$ ]]; then
        read -p "-> MTU (Pishfarz 1450): " CUSTOM_MTU
        MTU=${CUSTOM_MTU:-1450}
        read -p "-> MSS Clamp (Pishfarz 1410): " CUSTOM_MSS
        MSS=${CUSTOM_MSS:-1410}
    fi

    if [[ "$MODE" == "1" ]]; then
        echo -e "${YELLOW}Port haye mored nazar baraye forward be Kharej 1 (pishfarz: 80,443 - ba ',' joda konid):${NC}"
        read -p "-> " PORTS_KHAREJ_1
        PORTS_KHAREJ_1=${PORTS_KHAREJ_1:-"80,443"}
    else
        echo -e "${YELLOW}Port haye mored nazar baraye Server KHAREJ 1 (مثلا 443):${NC}"
        read -p "-> " PORTS_KHAREJ_1
        echo -e "${YELLOW}Port haye mored nazar baraye Server KHAREJ 2 (مثلا 8443):${NC}"
        read -p "-> " PORTS_KHAREJ_2
    fi

    echo -e "${BLUE}In server kodom ast?\n1) Server IRAN\n2) Server KHAREJ 1\n3) Server KHAREJ 2${NC}"
    read -p "Entekhab konid (1, 2 ya 3): " SERVER_ROLE
fi

cleanup_existing_gre() {
    for tunnel in gre1 gre2; do
        if ip tunnel show | grep -q "$tunnel"; then
            echo -e "${YELLOW}[!] Tunnel $tunnel az ghabl mikhad pak beshe...${NC}"
            ip link set "$tunnel" down 2>/dev/null
            ip tunnel del "$tunnel" 2>/dev/null
        fi
    done

    iptables -t mangle -F FORWARD 2>/dev/null
}

# ----------------- SERVER IRAN -----------------
if [[ "$SERVER_ROLE" == "1" ]]; then
    echo -e "${GREEN}[+] Shorooe tanzimate Server IRAN...${NC}"
    cleanup_existing_gre

    GATEWAY_IP=$(ip -4 route list 0/0 | grep -v 'gre' | grep -v 'tun' | awk '{print $3}' | head -n 1)
    INTERFACE=$(ip -4 route list 0/0 | grep -v 'gre' | grep -v 'tun' | awk '{print $5}' | head -n 1)

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    iptables -t nat -F PREROUTING 2>/dev/null

    
    ip tunnel add gre1 mode gre remote "$IP_KHAREJ_1" local "$IP_IRAN" ttl 225
    ip addr add 10.10.0.2/30 dev gre1
    ip link set gre1 up
    ip link set gre1 mtu "$MTU"
    ip route del "$IP_KHAREJ_1" 2>/dev/null
    ip route add "$IP_KHAREJ_1" via "$GATEWAY_IP" dev "$INTERFACE" onlink

    
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre1 -j TCPMSS --set-mss "$MSS"

    IFS=',' read -ra ADDR1 <<< "$PORTS_KHAREJ_1"
    for PORT in "${ADDR1[@]}"; do
        PORT=$(echo "$PORT" | xargs)
        if [[ ! -z "$PORT" ]]; then
            echo -e "${CYAN}[*] Forwarding Port $PORT -> KHAREJ 1 (10.10.0.1)${NC}"
            iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination 10.10.0.1:"$PORT"
            iptables -t nat -A PREROUTING -p udp --dport "$PORT" -j DNAT --to-destination 10.10.0.1:"$PORT"
        fi
    done
    iptables -t nat -A POSTROUTING -o gre1 -j MASQUERADE

    
    if [[ "$MODE" == "2" ]]; then
        ip tunnel add gre2 mode gre remote "$IP_KHAREJ_2" local "$IP_IRAN" ttl 225
        ip addr add 10.20.0.2/30 dev gre2
        ip link set gre2 up
        ip link set gre2 mtu "$MTU"
        ip route del "$IP_KHAREJ_2" 2>/dev/null
        ip route add "$IP_KHAREJ_2" via "$GATEWAY_IP" dev "$INTERFACE" onlink

    
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre2 -j TCPMSS --set-mss "$MSS"

        IFS=',' read -ra ADDR2 <<< "$PORTS_KHAREJ_2"
        for PORT in "${ADDR2[@]}"; do
            PORT=$(echo "$PORT" | xargs)
            if [[ ! -z "$PORT" ]]; then
                echo -e "${CYAN}[*] Forwarding Port $PORT -> KHAREJ 2 (10.20.0.1)${NC}"
                iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination 10.20.0.1:"$PORT"
                iptables -t nat -A PREROUTING -p udp --dport "$PORT" -j DNAT --to-destination 10.20.0.1:"$PORT"
            fi
        done
        iptables -t nat -A POSTROUTING -o gre2 -j MASQUERADE
    fi

    echo -e "${GREEN}[V] Server IRAN ba movafaghriat tanzim shod.${NC}"

# ----------------- SERVER KHAREJ 1 -----------------
elif [[ "$SERVER_ROLE" == "2" ]]; then
    echo -e "${GREEN}[+] Shorooe tanzimate Server KHAREJ 1...${NC}"
    cleanup_existing_gre

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    ip tunnel add gre1 mode gre remote "$IP_IRAN" local "$IP_KHAREJ_1" ttl 225
    ip addr add 10.10.0.1/30 dev gre1
    ip link set gre1 up
    ip link set gre1 mtu "$MTU"

    iptables -A INPUT -i gre1 -j ACCEPT
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre1 -j TCPMSS --set-mss "$MSS"
    iptables -t nat -A POSTROUTING -s 10.10.0.0/30 -j MASQUERADE 2>/dev/null

    echo -e "${GREEN}[V] Server KHAREJ 1 ba movafaghriat tanzim shod.${NC}"

# ----------------- SERVER KHAREJ 2 -----------------
elif [[ "$SERVER_ROLE" == "3" ]]; then
    echo -e "${GREEN}[+] Shorooe tanzimate Server KHAREJ 2...${NC}"
    cleanup_existing_gre

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    ip tunnel add gre2 mode gre remote "$IP_IRAN" local "$IP_KHAREJ_2" ttl 225
    ip addr add 10.20.0.1/30 dev gre2
    ip link set gre2 up
    ip link set gre2 mtu "$MTU"

    iptables -A INPUT -i gre2 -j ACCEPT
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre2 -j TCPMSS --set-mss "$MSS"
    iptables -t nat -A POSTROUTING -s 10.20.0.0/30 -j MASQUERADE 2>/dev/null

    echo -e "${GREEN}[V] Server KHAREJ 2 ba movafaghriat tanzim shod.${NC}"
fi

# --- SYSTEMD SERVICE SECTION ---
if [ "$NON_INTERACTIVE" = false ]; then
    echo -e "\nAya mikhahid Service Systemd sakhte/apdate shavad? (y/N):"
    read -p "-> " CREATE_SERVICE

    if [[ "$CREATE_SERVICE" =~ ^[Yy]$ ]]; then
        cat <<EOF > "$CONFIG_FILE"
MODE="$MODE"
IP_IRAN="$IP_IRAN"
IP_KHAREJ_1="$IP_KHAREJ_1"
IP_KHAREJ_2="$IP_KHAREJ_2"
MTU="$MTU"
MSS="$MSS"
PORTS_KHAREJ_1="$PORTS_KHAREJ_1"
PORTS_KHAREJ_2="$PORTS_KHAREJ_2"
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
