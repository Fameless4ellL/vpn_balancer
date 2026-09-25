#!/bin/sh
# Brings up openvpn to PIA through the SOCKS5 proxy (like Multi-Hop in the PIA GUI) and gost on top of the tunnel.
# Kill switch: only the SOCKS5 proxy is reachable directly (eth0); everything else goes through tun0 only,
# otherwise ENETUNREACH. A dead tunnel does not leak - it fails the health check instead.
set -eu

: "${PIA_REGION:?}" "${PIA_SLOT:=1}" "${PIA_PORT:=853}" "${SOCKS_HOST:?}" "${SOCKS_PORT:=1080}" "${PIA_DNS:=10.0.0.243}"

# Region server IPs come from servers.txt (make servers), no DNS needed. The list is rotated by PIA_SLOT
# so tunnels in the same region start on different servers.
PIA_IPS=$(awk -v r="$PIA_REGION" '$1==r {print $2}' /run/servers.txt)
N=$(echo "$PIA_IPS" | grep -c .) || true
[ "$N" -gt 0 ] || { echo "no servers for region '$PIA_REGION' in servers.txt" >&2; exit 1; }
PIA_IPS=$(echo "$PIA_IPS" | awk -v k=$(( (PIA_SLOT - 1) % N )) -v n="$N" '{a[NR-1]=$0} END {for (i=0;i<n;i++) print a[(i+k)%n]}')
SOCKS_IP=$(getent ahostsv4 "$SOCKS_HOST" | awk '{print $1; exit}')
[ -n "$SOCKS_IP" ] || { echo "cannot resolve $SOCKS_HOST" >&2; exit 1; }

GW=$(ip route show default | awk '{print $3; exit}')
ip route replace "$SOCKS_IP/32" via "$GW" dev eth0
ip route del default
ip route add unreachable default
# DNS: local cache (dnsmasq) -> PIA DNS through the tunnel. A repeated lookup costs 0 ms instead of ~1 RTT.
# timeout:1 - a lost DNS UDP packet costs 1 s instead of 5 (otherwise the health check nears its timeout)
dnsmasq --no-resolv --no-hosts --server="$PIA_DNS" --listen-address=127.0.0.1 --bind-interfaces \
  --cache-size=10000 --min-cache-ttl=300 --user=root
printf 'nameserver 127.0.0.1\noptions timeout:1 attempts:3\n' > /etc/resolv.conf

{
  cat <<EOF
client
dev tun0
proto udp
EOF
  for ip in $PIA_IPS; do echo "remote $ip $PIA_PORT"; done
  cat <<EOF
nobind
persist-key
socks-proxy $SOCKS_IP $SOCKS_PORT /run/secrets/socks-auth.txt
auth-user-pass /run/secrets/pia-auth.txt
auth-nocache
ca /etc/openvpn/ca.crt
remote-cert-tls server
tls-client
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

echo "PIA $PIA_REGION servers (in order): $(echo $PIA_IPS) port $PIA_PORT via socks5 $SOCKS_IP:$SOCKS_PORT"
gost -L "http://:8888" -L "socks5://:1080" &
# openvpn is the main process: if it exits, the container restarts (restart: always)
exec openvpn --config /etc/openvpn/pia.conf
