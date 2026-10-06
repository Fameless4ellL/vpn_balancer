# vpn_balancer

A local, fault-tolerant VPN gateway built on **Private Internet Access (PIA)** and **rootless Podman**.
You connect to **one** address (a SOCKS5 or HTTP proxy), and behind it run **two independent VPN
tunnels**: an active one and a standby. If the active tunnel fails — or is about to reconnect —
traffic moves to the standby within seconds and stays there, so your public IP changes as rarely
as possible.

## Why

The PIA client keeps a single tunnel: when it drops, you lose connectivity until the client
reconnects. From some countries, direct connections to PIA are blocked, so **Multi-Hop** is required —
OpenVPN through PIA's SOCKS5 proxy. This project reproduces the same connection the PIA GUI makes
(OpenVPN UDP 853, AES-256-GCM, via SOCKS5), but as two tunnels with automatic failover:

- **Stability** — a failing tunnel or PIA server is invisible to new connections (failover in ~1–5 s);
  PIA's 2-hour proxy session limit is handled by reconnecting the tunnels in turn, ahead of time.
- **No leaks** — if a tunnel dies, its traffic is blocked instead of leaving directly with your real IP.
- **Selective** — only applications you point at the proxy use the VPN; everything else goes direct.
- **Network-wide** — the proxy can be exposed on your LAN for phones, TVs, etc.

## How it works

```
applications ──→ 127.0.0.1:1081 (SOCKS5) / :8888 (HTTP)
                          │
                 HAProxy (vpn-lb) — health checks + agent checks, all traffic to the active tunnel
                ┌─────────┴─────────┐
          vpn1 (active)       vpn2 (standby)            ← roles swap on failure / planned reconnect
          openvpn + sing-box  openvpn + sing-box
          + watchdog          + watchdog
                │                   │
          SOCKS5 proxy A      SOCKS5 proxy B            ← different PIA multi-hop proxies
                └─────────┬─────────┘
           PIA servers (different servers, same or different regions)
```

- **vpn1 / vpn2** (`Containerfile`, `entrypoint.sh`) — Alpine + OpenVPN 2.6 +
  [sing-box](https://sing-box.sagernet.org/) (SOCKS5/HTTP server for clients) + dnsmasq (DNS cache).
  Each container has a kill switch: only the SOCKS5 proxy is reachable directly, everything else
  goes through `tun0` only. DNS is resolved by PIA's DNS inside the tunnel.
- **watchdog** (`watchdog.sh`, in each tunnel container) — pings the VPN gateway every second:
  - 3 lost pings + a failed HTTP check → reconnect immediately (instead of openvpn's ~30 s timeout);
  - more than 10% loss over a minute while the other tunnel is healthier → switch to another server;
  - planned reconnect every `ROTATE_PERIOD` (100 min), before the proxy's ~2 h session limit.
    The tunnels are scheduled half a period apart, and the active one hands its role to the other
    before reconnecting, so new connections never see an outage.
  - keeps the tunnels on **different PIA servers**, and off the server of the local PIA client:
    one account can't hold two sessions on the same server (the newer session takes over the tunnel
    IP and the older one dies — they would keep kicking each other).

  The two watchdogs agree on which tunnel is **active** (a shared volume). The role moves only when
  the active tunnel fails or is about to reconnect — traffic does not jump back afterwards, so the
  public IP changes as rarely as possible.
- **vpn-lb** (`haproxy/haproxy.cfg`) — HAProxy in TCP mode. An **agent check** asks each watchdog
  every second for its state (`100%` active / `0%` standby / `maint` reconnecting), so traffic moves
  within ~1 s. A **health check** additionally exercises the whole chain
  (`GET http://www.gstatic.com/generate_204` through the tunnel) as a safety net.
- **Different proxies per tunnel** — `SOCKS_HOST` may be a hostname or a list; tunnel N uses the
  N-th address. A problem with one proxy affects only one tunnel.
- **servers.txt** — PIA server IPs taken from the PIA client's cache (`pia-servers.py`). Tunnels
  do not depend on the host's DNS. Tunnels in the
  same region start on different servers.

## Requirements

**System**
- Linux with Podman ≥ 5 (rootless, `pasta` networking) and `podman-compose`.
- The `tun` module (`/dev/net/tun`). With SELinux enforcing: `sudo setsebool -P container_use_devices=true`.
- The PIA client installed (`/opt/piavpn`) — the server list is read from its cache. The client
  itself may be disconnected.
- `python3`, `make`, `curl`.

**Account**
- PIA username/password (e.g. `p1234567`).
- PIA SOCKS5 proxy username/password (PIA account → Downloads → SOCKS5 Proxy, or the Multi-Hop
  settings in the GUI).

**Resources** (measured on the full stack: 2 tunnels + HAProxy)

| | Idle | Under load |
|---|---|---|
| RAM | ~100 MB total (vpn1/vpn2 ~21 MB each, HAProxy ~50 MB) | barely changes |
| CPU | < 1% | not measured reliably (see note below) |
| Disk | ~150 MB of images (`pia-tunnel` 111 MB, `haproxy` 39 MB) | — |

Any machine that runs Podman is enough, including a Raspberry Pi or a small VPS.

**Speed and latency** latency ~100–140 ms; a single download test gave ~24 Mbit/s. The latency floor is the ping to the proxy itself (~90–110 ms);

## Getting started

1. Credentials (the `secrets/` directory is git-ignored):
   ```sh
   mkdir -p secrets
   printf 'p1234567\nPIA_PASSWORD\n'   > secrets/pia-auth.txt
   printf 'x1234567\nSOCKS_PASSWORD\n' > secrets/socks-auth.txt
   chmod 600 secrets/*
   ```
2. Settings — copy the template and edit it (`.env` is git-ignored):
   ```sh
   cp .env.example .env
   ```
   ```ini
   VPN1_REGION=poland        # first tunnel (region id — see: make regions)
   VPN2_REGION=poland        # second; a different region also protects against a whole-region outage
   PIA_PORT=853              # PIA UDP port: 853 / 8080 / 123 / 53
   SOCKS_HOST=proxy-nl.privateinternetaccess.com  # PIA SOCKS5 proxy: hostname or IP list; tunnel N uses the N-th
   SOCKS_PORT=1080
   BIND=127.0.0.1            # 127.0.0.1 = this machine only, 0.0.0.0 = whole LAN (no password!)
   LB_SOCKS_PORT=1081
   LB_HTTP_PORT=8888
   LB_STATS_PORT=8404
   ```
3. Start:
   ```sh
   make up      # refresh servers.txt, build the image, start the stack
   make ip      # public IP via the balancer and via each tunnel
   make check   # tunnel state in HAProxy (UP/DOWN)
   ```
4. Point your applications at `socks5://127.0.0.1:1081` (prefer `socks5h` so DNS goes through the
   VPN) or `http://127.0.0.1:8888`. HAProxy stats: <http://127.0.0.1:8404>.

### UDP and whole devices: WireGuard (Discord voice, games)

The SOCKS5 and HTTP proxies carry TCP only: HAProxy works in TCP mode, and apps like Discord send
voice over UDP directly, past the proxy. For UDP and whole devices there is the **vpn-gw** container
(`gw.sh`): a WireGuard server (sing-box, userspace — no kernel module or root) that sends each
connection, TCP and **native UDP**, over SOCKS5 straight to the active tunnel, bypassing HAProxy. It
follows the watchdogs' choice of the active tunnel (`/shared/active`) within ~1 s; existing connections
are closed on a switch and reopen through the new tunnel. There is no direct outbound, so client
traffic never leaves unencrypted.

```sh
make wg-peer N=1     # client 1: creates keys, prints the config + QR code (restarts vpn-gw)
```

Import the config into the official WireGuard app (Windows/macOS/Linux/Android/iOS). All internet
traffic of the device goes through the VPN; private/LAN ranges stay direct, so SSH, printers and the
router keep working (`WG_ALLOWED="0.0.0.0/0, ::/0" make wg-peer N=…` for a full tunnel). DNS queries (to any server, port 53) are answered by the active tunnel's
dnsmasq cache, which forwards to PIA's DNS through the tunnel: a repeated lookup takes ~2 ms instead of ~100 ms.
**Per-app split (browser outside the VPN):** the WireGuard app splits by IP only. `make wg-singbox N=1`
writes `secrets/wg/peer-N.singbox.json`, a [sing-box](https://sing-box.sagernet.org/) client config for
the same client: TUN captures the device, browsers (`WG_DIRECT_APPS`, comma-separated process names)
and the LAN go direct, everything else — Discord included — through the WireGuard entry. Run it on the
client as admin/root: `sing-box run -c peer-1.singbox.json`, instead of (not together with) the WireGuard app.

Client N gets `10.13.13.(N+1)`;
the endpoint is `WG_ENDPOINT` from `.env` or this machine's LAN address, port `WG_PORT` (51820/udp,
needs `BIND=0.0.0.0`). Keys live in `secrets/wg/`; delete `peer-N.*` and run `podman restart vpn-gw`
to revoke a client.

### Commands

| Command | What it does |
|---|---|
| `make up` | refresh the server list, build and start |
| `make down` | stop and remove the containers |
| `make restart` | restart (apply changes to `.env` / code) |
| `make logs` | logs of all containers |
| `make ps` | container status |
| `make ip` | public IPs |
| `make check` | tunnel state in the balancer |
| `make regions` | PIA regions with OpenVPN UDP, sorted by latency |
| `make servers` | refresh `servers.txt` from the PIA client's cache |
| `make wg-peer N=1` | create / show WireGuard client N (config + QR) |
| `make wg-singbox N=1` | sing-box config for client N: browsers direct, the rest via WireGuard |
| `make ovpn/ca.crt` | fetch PIA's public CA certificate (done automatically by `make up`) |

### Testing failover

```sh
make ip                                                   # LB = vpn1's IP
podman exec vpn1 ip route replace blackhole <vpn1-proxy>/32  # simulate a proxy outage on vpn1
make ip                                                   # ~5 s later: LB = vpn2's IP
podman restart vpn1                                       # vpn1 comes back as standby; traffic stays on vpn2
podman logs vpn1 | grep watchdog                          # what the watchdog decided and why
```

## Monitoring (optional)

Set `MONITORING=1` in `.env` and run `make restart`: Prometheus, Alertmanager and Grafana start next to
the stack (`compose.monitoring.yml`). Extra cost: roughly 150–300 MB of RAM, well under 1% CPU.

- **Metrics** — HAProxy's built-in Prometheus exporter (`:8405`, inside the compose network only),
  scraped every 5 s. The watchdog's agent check sets each tunnel's weight, so HAProxy's state tells the
  role: `UP` + weight 100 = active, `UP` + weight 0 = standby, `MAINT` = reconnecting, `DOWN` = the
  end-to-end check fails. Recording rules turn that into `vpn:tunnel_state` (3/2/1/0).
- **Grafana** — <http://127.0.0.1:3000>, user `admin`, password in `secrets/grafana-admin.txt`
  (generated on first start). The *VPN balancer* dashboard shows the active tunnel, the state timeline
  of both tunnels, role changes, sessions, traffic and health-check timings.
- **Alerts** (`monitoring/rules.yml`) — no active tunnel (30 s), a tunnel unusable for 5 min (redundancy
  lost), role flapping (> 4 changes in 30 min; planned handovers alone give ~1 per 50 min), slow health
  checks, HAProxy metrics down. Alertmanager (<http://127.0.0.1:9093>) shows them; the Ansible playbook
  can also send them to Telegram.
- The dashboard is generated by `monitoring/grafana/dashboard.py` — edit the script, not the JSON.

## Running alongside the PIA client

The containers only talk to the SOCKS5 proxy, and that traffic bypasses the PIA client's tunnel,
so the PIA client can be either connected or disconnected. Recommendations:

- **Keep the PIA client's Kill Switch off**, otherwise it may block the containers.
- For extra safety, add `/usr/bin/pasta` to **Split Tunnel → Bypass VPN** and run `make restart`.
  `pasta` is rootless Podman's networking process: on the host, all container traffic is sent on
  its behalf.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `AUTH_FAILED` in `make logs` | PIA username/password in `secrets/pia-auth.txt` |
| `no servers for region` | region id in `.env` (`make regions`), then `make servers` |
| tunnel never comes up, no `Peer Connection Initiated` | proxy reachability: `curl --socks5 USER:PASS@proxy-nl.privateinternetaccess.com:1080 https://ipinfo.io/ip` |
| `permission denied` on `/dev/net/tun` | `sudo setsebool -P container_use_devices=true` |
| both tunnels drop at the same time | check that `SOCKS_HOST` gives each tunnel a different proxy (`podman logs vpn1 \| grep socks5`); don't run extra tunnels on the same account |
| tunnels keep reconnecting every ~30 s | two sessions of one PIA account on the same server. The watchdog avoids this; check `podman logs vpnN \| grep watchdog` and that the region has enough servers (PIA has ~3 per region; the PIA client uses one) |
| reconnects every ~2 h | expected: PIA's proxy limits a session to ~2 h (the PIA client reconnects too). The watchdog does it earlier, one tunnel at a time |

## Limitations

- PIA's proxy ends every session after ~2 h, so each tunnel reconnects every 100 min. **Long-lived
  connections** (downloads, SSH, calls) on the active tunnel break at its reconnect — new connections
  are unaffected. This is a limit of the proxy; the PIA client has the same behaviour.
- Both proxies belong to PIA: a PIA-wide proxy outage takes down both tunnels.
- Servers within one PIA region usually share a subnet/data center; to survive a region outage,
  put the backup tunnel in a different region.
- This project is not affiliated with Private Internet Access. You need your own paid PIA account;
  use it in accordance with PIA's terms of service and the laws of your country.

## License

[MIT](LICENSE). Third-party components are under their own licenses: OpenVPN (GPLv2), HAProxy
(GPLv2), sing-box (GPLv3), dnsmasq (GPLv2), Alpine Linux; `ovpn/ca.crt` (PIA's public CA certificate) is not included and is fetched by `make up`.
