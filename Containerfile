# One tunnel = openvpn (PIA via SOCKS5 multi-hop) + sing-box (SOCKS5/HTTP proxy for clients).
# The same image runs vpn-gw (gw.sh): the WireGuard entry with native UDP.
FROM ghcr.io/sagernet/sing-box:latest AS singbox

FROM docker.io/library/alpine:3.22
RUN apk add --no-cache openvpn iproute2 curl dnsmasq socat libqrencode-tools
COPY --from=singbox /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY ovpn/ca.crt /etc/openvpn/ca.crt
COPY entrypoint.sh watchdog.sh gen-conf.sh tls-verify.sh gw.sh /
RUN chmod +x /entrypoint.sh /watchdog.sh /gen-conf.sh /tls-verify.sh /gw.sh
HEALTHCHECK --interval=10s --timeout=8s --start-period=40s --retries=3 \
  CMD ip link show tun0 >/dev/null 2>&1 && curl -sf -m 6 -o /dev/null http://www.gstatic.com/generate_204
ENTRYPOINT ["/entrypoint.sh"]
