#!/bin/sh
# Writes /etc/openvpn/pia.conf. Usage: gen-conf.sh [CN ...]
# Servers whose certificate CN is listed are left out: the same PIA account must not hold two sessions
# on one server (the newer session takes the tunnel IP and the older one stops working). If every
# server of the region is excluded, all of them are used anyway.
set -eu

# region servers "ip cn", rotated by PIA_SLOT so tunnels in the same region start on different servers
all=$(awk -v r="$PIA_REGION" '$1==r {print $2, $3}' /run/servers.txt)
n=$(echo "$all" | grep -c .) || true
[ "$n" -gt 0 ] || { echo "no servers for region '$PIA_REGION' in servers.txt" >&2; exit 1; }
all=$(echo "$all" | awk -v k=$(( (PIA_SLOT - 1) % n )) -v n="$n" '{a[NR-1]=$0} END {for (i=0;i<n;i++) print a[(i+k)%n]}')

use=$(echo "$all" | awk -v ex=" $* " 'index(ex, " " $2 " ") == 0')
[ -n "$use" ] || use=$all

{
  cat <<EOF
client
dev tun0
proto udp
EOF
  echo "$use" | while read -r ip cn; do echo "remote $ip $PIA_PORT"; done
  cat <<EOF
nobind
persist-key
socks-proxy $SOCKS_IP $SOCKS_PORT /run/secrets/socks-auth.txt
auth-user-pass /run/secrets/pia-auth.txt
auth-nocache
ca /etc/openvpn/ca.crt
remote-cert-tls server
tls-client
# record the server's CN (for the watchdog's same-server check)
script-security 2
tls-verify /tls-verify.sh
data-ciphers AES-256-GCM
disable-dco
redirect-gateway def1
pull-filter ignore "dhcp-option DNS "
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
# Own timers, like the PIA client (the server pushes ping-restart 60 - a dead tunnel would hang for a minute)
pull-filter ignore "ping "
pull-filter ignore "ping-restart "
ping 5
ping-restart 30
connect-timeout 30
server-poll-timeout 20
sndbuf 262144
rcvbuf 262144
verb 3
EOF
} > /etc/openvpn/pia.conf

echo "PIA $PIA_REGION servers (in order): $(echo "$use" | awk '{printf "%s(%s) ", $2, $1}')via socks5 $SOCKS_IP:$SOCKS_PORT${*:+, excluding: $*}"
