#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# Install required packages
apt-get update
apt-get install -y dnsmasq iptables iptables-persistent dhcpcd5

# Get interface names
read -p "Enter WAN interface name: " WAN_IF
read -p "Enter LAN interface name: " LAN_IF

# Get network configuration from user
read -p "Enter network address: " NETWORK_ADDR
read -p "Enter network mask: " MASK
read -p "Enter DHCP range start: " DHCP_START
read -p "Enter DHCP range end: " DHCP_END
read -p "Enter lease time in hours: " LEASE_TIME

# Extract base IP for router
ROUTER_IP=$(echo $NETWORK_ADDR | sed 's/\([0-9]\+\.[0-9]\+\.[0-9]\+\.\)[0-9]\+/\11/')

# Configure dhcpcd
cat > /etc/dhcpcd.conf << EOL
interface $WAN_IF

interface $LAN_IF
static ip_address=$ROUTER_IP/$MASK
EOL

# Configure dnsmasq
cat > /etc/dnsmasq.conf << EOL
interface=$LAN_IF
dhcp-range=$DHCP_START,$DHCP_END,${LEASE_TIME}h
dhcp-option=option:router,$ROUTER_IP
bind-interfaces
no-resolv
resolv-file=/etc/resolv.conf
EOL

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-router.conf
sysctl -p /etc/sysctl.d/99-router.conf

# Configure firewall
# Flush existing rules
iptables -F
iptables -t nat -F

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# SSH on both interfaces
iptables -A INPUT -i $WAN_IF -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -i $LAN_IF -p tcp --dport 22 -j ACCEPT

# DNS and DHCP only on LAN
iptables -A INPUT -i $LAN_IF -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i $LAN_IF -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -i $LAN_IF -p udp --dport 67:68 -j ACCEPT

# Allow forwarding between interfaces
iptables -A FORWARD -i $LAN_IF -o $WAN_IF -j ACCEPT

# NAT
iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE

# Save iptables rules
netfilter-persistent save

# Restart services
systemctl restart dhcpcd
systemctl restart dnsmasq

echo "Router configuration complete. Please check the following:"
echo "1. Router IP: $ROUTER_IP/$MASK"
echo "2. DHCP Range: $DHCP_START to $DHCP_END"
echo "3. WAN Interface: $WAN_IF"
echo "4. LAN Interface: $LAN_IF"
echo "5. Services status:"
systemctl status dhcpcd | grep Active
systemctl status dnsmasq | grep Active
