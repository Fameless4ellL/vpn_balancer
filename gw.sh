#!/bin/sh
# WireGuard entry (vpn-gw): whole-device VPN for other machines, UDP included (Discord voice, games).
# sing-box terminates WireGuard in userspace (no kernel module, no NET_ADMIN) and sends each connection
# - TCP and native UDP - over SOCKS5 to the ACTIVE tunnel (vpn1/vpn2), bypassing HAProxy (TCP only).
# The active tunnel is the one the watchdogs agreed on (/shared/active); on a switch, existing
# connections are closed so they reopen through the new tunnel.
# Kill switch: there is no direct outbound - client traffic leaves only through a tunnel.
# DNS: any query to port 53 goes to 127.0.0.1 *inside the active tunnel* - its dnsmasq cache (-> PIA DNS),
# the same cache the proxies use, so a repeated lookup costs a LAN round trip instead of ~100 ms.
#
#   gw.sh          - run the gateway (container entrypoint)
#   gw.sh peer N   - create client N (if missing) and print its WireGuard config + QR code
set -eu

: "${WG_PORT:=51820}" "${WG_MTU:=1280}" "${WG_NET:=10.13.13}" "${WG_DNS:=10.0.0.243}"
# What clients send into the tunnel: everything except private/LAN ranges (10/8, 172.16/12, 192.168/16,
# 100.64/10, link-local, multicast; IPv6 ULA/link-local), so the client's LAN - SSH to this machine,
# printers, the router - stays reachable directly. PIA's DNS (10.0.0.243) is added back.
# WG_ALLOWED="0.0.0.0/0, ::/0" = full tunnel (LAN unreachable while connected).
: "${WG_ALLOWED:=0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/3, 96.0.0.0/6, 100.0.0.0/10, 100.128.0.0/9, 101.0.0.0/8, 102.0.0.0/7, 104.0.0.0/5, 112.0.0.0/5, 120.0.0.0/6, 124.0.0.0/7, 126.0.0.0/8, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/8, 169.0.0.0/9, 169.128.0.0/10, 169.192.0.0/11, 169.224.0.0/12, 169.240.0.0/13, 169.248.0.0/14, 169.252.0.0/15, 169.255.0.0/16, 170.0.0.0/7, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 240.0.0.0/4, 10.0.0.243/32, ::/1, 8000::/2, c000::/3, e000::/4, f000::/5, f800::/6, fe00::/9, fec0::/10}"
umask 077
K=/run/secrets/wg   # server.key, peer-N.key / peer-N.pub (client N gets $WG_NET.(N+1))

keypair() { sing-box generate wg-keypair | awk -v f="$1" '/PrivateKey/ {print $2 > f ".key"} /PublicKey/ {print $2 > f ".pub"}'; }
pubkey()  { cat "$1.pub"; }

[ -s "$K/server.key" ] || keypair "$K/server"

if [ "${1:-}" = peer ]; then
  n=${2:?usage: gw.sh peer N}
  [ -s "$K/peer-$n.key" ] || keypair "$K/peer-$n"
  conf="[Interface]
PrivateKey = $(cat "$K/peer-$n.key")
Address = $WG_NET.$((n + 1))/32
DNS = $WG_DNS
MTU = $WG_MTU

[Peer]
PublicKey = $(pubkey "$K/server")
Endpoint = ${WG_ENDPOINT:?WG_ENDPOINT is not set}:$WG_PORT
AllowedIPs = $WG_ALLOWED
PersistentKeepalive = 25"
  printf '%s\n' "$conf"
  printf '%s\n' "$conf" | qrencode -t ansiutf8
  exit
fi

# sing-box client config for client N: TUN captures the whole device, but the programs listed in
# WG_DIRECT_APPS (comma-separated; browsers by default; names for Windows, Linux and macOS) and the LAN go direct,
# everything else - Discord included - goes through the WireGuard entry. Needs admin/root (TUN).
if [ "${1:-}" = singbox ]; then
  n=${2:?usage: gw.sh singbox N}
  [ -s "$K/peer-$n.key" ] || keypair "$K/peer-$n"
  : "${WG_DIRECT_APPS:=chrome.exe, firefox.exe, msedge.exe, brave.exe, opera.exe, browser.exe, zen.exe, vivaldi.exe, chrome, chromium, chromium-browser, firefox, firefox-bin, brave, zen, zen-bin, vivaldi-bin, opera, msedge, Google Chrome, Firefox, Safari, Brave Browser, Microsoft Edge}"
  apps=$(printf '%s\n' "$WG_DIRECT_APPS" | tr ',' '\n' | sed 's/^ *//; s/ *$//; /^$/d; s/.*/"&"/' | paste -sd, | sed 's/,/, /g')
  cat <<JSON
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [
      { "type": "udp", "tag": "vpn-dns", "server": "$WG_DNS", "detour": "vpn" },
      { "type": "local", "tag": "local" }
    ],
    "final": "vpn-dns",
    "strategy": "ipv4_only"
  },
  "endpoints": [{
    "type": "wireguard", "tag": "vpn", "mtu": $WG_MTU,
    "address": ["$WG_NET.$((n + 1))/32"],
    "private_key": "$(cat "$K/peer-$n.key")",
    "peers": [{
      "address": "${WG_ENDPOINT:?WG_ENDPOINT is not set}", "port": $WG_PORT,
      "public_key": "$(pubkey "$K/server")",
      "allowed_ips": ["0.0.0.0/0"], "persistent_keepalive_interval": 25
    }]
  }],
  "inbounds": [{
    "type": "tun", "tag": "tun",
    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    "mtu": 1400, "auto_route": true, "strict_route": true, "stack": "mixed"
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "process_name": [$apps], "outbound": "direct" },
      { "ip_is_private": true, "outbound": "direct" },
      { "ip_version": 6, "action": "reject" }
    ],
    "final": "vpn",
    "auto_detect_interface": true,
    "find_process": true,
    "default_domain_resolver": "local"
  }
}
JSON
  exit
fi

peers=$(for f in "$K"/peer-*.pub; do
  [ -e "$f" ] || continue
  n=${f##*/peer-}; n=${n%.pub}
  printf ',\n        { "public_key": "%s", "allowed_ips": ["%s.%s/32"] }' "$(cat "$f")" "$WG_NET" $((n + 1))
done)
[ -n "$peers" ] || echo "vpn-gw: no clients yet - create one with: make wg-peer N=1" >&2

cat > /etc/sing-box.json <<JSON
{
  "log": { "level": "warn" },
  "dns": { "servers": [{ "type": "local", "tag": "local" }] },
  "endpoints": [{
    "type": "wireguard", "tag": "wg", "system": false, "mtu": $WG_MTU,
    "address": ["$WG_NET.1/24"], "listen_port": $WG_PORT,
    "private_key": "$(cat "$K/server.key")",
    "peers": [${peers#,}
    ]
  }],
  "outbounds": [
    { "type": "selector", "tag": "tunnel", "outbounds": ["vpn1", "vpn2"], "interrupt_exist_connections": true },
    { "type": "socks", "tag": "vpn1", "server": "vpn1", "server_port": 1080 },
    { "type": "socks", "tag": "vpn2", "server": "vpn2", "server_port": 1080 }
  ],
  "route": {
    "rules": [
      { "port": 53, "action": "route-options", "override_address": "127.0.0.1" }
    ],
    "final": "tunnel", "default_domain_resolver": "local"
  },
  "experimental": { "clash_api": { "external_controller": "127.0.0.1:9090" } }
}
JSON
sing-box check -c /etc/sing-box.json
sing-box run -c /etc/sing-box.json &
PID=$!
trap 'kill -TERM "$PID" 2>/dev/null' TERM INT

# Follow the watchdogs' choice of the active tunnel
cur=
while kill -0 "$PID" 2>/dev/null; do
  a=$(cat /shared/active 2>/dev/null || true)
  if [ -n "$a" ] && [ "$a" != "$cur" ] \
     && curl -sf -m 2 -X PUT -d "{\"name\":\"$a\"}" http://127.0.0.1:9090/proxies/tunnel; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%S') vpn-gw: active tunnel -> $a"
    cur=$a
  fi
  sleep 1
done
wait "$PID"
