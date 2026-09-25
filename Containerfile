# One tunnel = openvpn (PIA via SOCKS5 multi-hop) + gost (HTTP/SOCKS5 proxy for clients)
FROM docker.io/gogost/gost:latest AS gost

FROM docker.io/library/alpine:3.22
RUN apk add --no-cache openvpn iproute2 curl dnsmasq
COPY --from=gost /bin/gost /usr/local/bin/gost
COPY ovpn/ca.crt /etc/openvpn/ca.crt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
HEALTHCHECK --interval=10s --timeout=8s --start-period=40s --retries=3 \
  CMD ip link show tun0 >/dev/null 2>&1 && curl -sf -m 6 -o /dev/null http://www.gstatic.com/generate_204
ENTRYPOINT ["/entrypoint.sh"]
