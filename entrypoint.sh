#!/bin/sh
# Brings up openvpn to PIA through the SOCKS5 proxy (like Multi-Hop in the PIA GUI) and gost on top of the tunnel.
# Kill switch: only the SOCKS5 proxy is reachable directly (eth0); everything else goes through tun0 only,
# otherwise ENETUNREACH. A dead tunnel does not leak - it fails the health check instead.
set -eu

: "${PIA_REGION:?}" "${PIA_SLOT:=1}" "${PIA_PORT:=853}" "${SOCKS_HOST:?}" "${SOCKS_PORT:=1080}" "${PIA_DNS:=10.0.0.243}"

# SOCKS_HOST may list several proxies (IPs or hostnames, space/comma separated); tunnel N takes the
# N-th address, so tunnels don't share one proxy - a proxy failure or session reset hits only one of them.
SOCKS_IPS=$(for h in $(echo "$SOCKS_HOST" | tr ',' ' '); do getent ahostsv4 "$h" | awk '{print $1}' | sort -u; done | awk '!seen[$0]++')
M=$(echo "$SOCKS_IPS" | grep -c .) || true
[ "$M" -gt 0 ] || { echo "cannot resolve $SOCKS_HOST" >&2; exit 1; }
SOCKS_IP=$(echo "$SOCKS_IPS" | sed -n "$(( (PIA_SLOT - 1) % M + 1 ))p")

GW=$(ip route show default | awk '{print $3; exit}')
ip route replace "$SOCKS_IP/32" via "$GW" dev eth0
ip route del default
ip route add unreachable default
# DNS: local cache (dnsmasq) -> PIA DNS through the tunnel. A repeated lookup costs 0 ms instead of ~1 RTT.
# timeout:1 - a lost DNS UDP packet costs 1 s instead of 5 (otherwise the health check nears its timeout)
dnsmasq --no-resolv --no-hosts --server="$PIA_DNS" --listen-address=127.0.0.1 --bind-interfaces \
  --cache-size=10000 --min-cache-ttl=300 --user=root
printf 'nameserver 127.0.0.1\noptions timeout:1 attempts:3\n' > /etc/resolv.conf

# openvpn config (server list, proxy, options). The watchdog re-runs it to move off a busy server.
export PIA_REGION PIA_SLOT PIA_PORT SOCKS_IP SOCKS_PORT
peer_cn=$(awk '$1=="up" {print $4}' "/shared/${PEER:-none}" 2>/dev/null || true)
client_cn=$(awk '/^verify-x509-name/ {print $2; exit}' /run/pia-client/pia.ovpn 2>/dev/null || true)
/gen-conf.sh $peer_cn $client_cn
gost -L "http://:8888" -L "socks5://:1080" &

# HAProxy agent-check: replies with the watchdog's verdict ("ready up" / "maint")
echo maint > /run/agent
socat TCP-LISTEN:9999,fork,reuseaddr SYSTEM:'cat /run/agent' &

openvpn --config /etc/openvpn/pia.conf &
OVPN_PID=$!
OVPN_PID=$OVPN_PID /watchdog.sh &

# openvpn is the main process: if it exits, the container exits and is restarted (restart: always)
trap 'kill -TERM "$OVPN_PID" 2>/dev/null' TERM INT
wait "$OVPN_PID"
