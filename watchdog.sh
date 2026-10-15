#!/bin/sh
# Tunnel watchdog. Runs next to openvpn inside each tunnel container.
#
# - Pings the VPN gateway through tun0 once a second:
#     3 misses in a row + a failed HTTP check -> reconnect now (instead of ~30 s of openvpn's ping-restart);
#     loss > LOSS_MAX %   -> switch to the next server, if the peer tunnel is healthier.
# - Rotates the tunnel on a fixed wall-clock schedule, before the SOCKS proxy's ~2 h session limit.
#   Tunnels are scheduled half a period apart, so they never reconnect at the same time.
# - Decides, together with the peer, which tunnel is active (/shared/active). The active tunnel keeps
#   the role until it goes down or hands it over before a planned reconnect - so traffic doesn't jump
#   back and forth and the public IP changes only when it has to.
# - Keeps the tunnels on different PIA servers: one account can't hold two sessions on the same server
#   If the server is already used by the peer or by the local PIA client, this tunnel moves elsewhere.
# - Publishes its state for HAProxy's agent-check (/run/agent: "ready up 100%" = active,
#   "ready up 0%" = standby, "maint" = not usable) and for the peer (/shared/<name>:
#   "<up|drain|down> <connected-at> <loss%> <server-cn>").
set -u

: "${NAME:?}" "${PEER:?}" "${PIA_SLOT:=1}" "${OVPN_PID:?}"
: "${ROTATE_PERIOD:=6000}"   # planned reconnect every 100 min (proxy drops sessions at ~120 min)
: "${ROTATE_MIN_AGE:=900}"   # skip a rotation slot if the tunnel reconnected less than 15 min ago
: "${LOSS_WINDOW:=60}"       # samples (seconds) for the loss estimate
: "${LOSS_MAX:=10}"          # % loss that triggers a server switch
: "${STUCK_AFTER:=120}"     # tunnel down this long -> regenerate config, try the next proxy
: "${BAD_TTL:=1800}"        # a server left for packet loss is avoided this long
: "${DRAIN:=5}"                # failure: seconds between "maint" and the reconnect
: "${HANDOVER_DRAIN:=30}"     # planned/loss reconnect of a WORKING tunnel: open connections finish on it              # seconds between "maint" and the reconnect, so HAProxy moves new traffic

log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S') watchdog: $*"; }

agent=maint connected=0 fails=0 samples="" last_switch=0 cn="" down_since=0
phase=$(( (PIA_SLOT - 1) * ROTATE_PERIOD / 2 ))
now=$(date +%s)
handled=$(( (now - phase) / ROTATE_PERIOD ))   # don't rotate in the slot we started in

publish() {
  printf '%s\n' "$agent" > /run/agent.tmp && mv /run/agent.tmp /run/agent
  printf '%s %s %s %s\n' "$1" "$connected" "$loss" "$cn" > "/shared/$NAME.tmp" && mv "/shared/$NAME.tmp" "/shared/$NAME"
}

peer_state() { cat "/shared/$PEER" 2>/dev/null || echo "down 0 100"; }
active() { cat /shared/active 2>/dev/null; }
client_cn() { awk '/^verify-x509-name/ {print $2; exit}' /run/pia-client/pia.ovpn 2>/dev/null; }
# servers this tunnel must not use: the peer's (if up) and the local PIA client's
# servers that had heavy loss recently (/run/bad_cns: "<cn> <until>"), avoided for BAD_TTL seconds
bad_cns() { awk -v now="$(date +%s)" '$2 > now {print $1}' /run/bad_cns 2>/dev/null; }
mark_bad() { echo "$1 $(( $(date +%s) + BAD_TTL ))" >> /run/bad_cns; }
busy_cns() { set -- $(peer_state); [ "$1" = up ] && echo "${4:-}"; client_cn; bad_cns; }
# number of region servers other than the busy ones and our own - i.e. somewhere to switch to
free_servers() { awk -v r="$PIA_REGION" -v ex=" $(busy_cns | tr '\n' ' ') $cn " '$1==r && index(ex, " " $3 " ")==0' /run/servers.live | wc -l; }
set_active() { echo "$1" > /shared/active.tmp && mv /shared/active.tmp /shared/active; log "active tunnel -> $1"; }

# reconnect REASON [drain]: with "drain" the tunnel still works - new connections go to the peer, open ones
# keep running here for HANDOVER_DRAIN s (state "drain"; vpn-gw closes them only once we are "down")
reconnect() {
  log "$1 -> reconnecting"
  mode=${2:-down}
  set -- $(peer_state)
  if [ "$(active)" = "$NAME" ] && [ "$1" = up ]; then set_active "$PEER"; else mode=down; fi   # hand over first
  agent=maint
  if [ "$mode" = drain ]; then publish drain; sleep "$HANDOVER_DRAIN"; fi
  publish down
  sleep "$DRAIN"
  # regenerate the server list without busy servers, then SIGHUP = reconnect with the re-read config
  /gen-conf.sh $(busy_cns) >/dev/null
  kill -HUP "$OVPN_PID"
  connected=0 fails=0 samples="" cn=""
}

loss=0
publish down
while kill -0 "$OVPN_PID" 2>/dev/null; do
  sleep 1
  now=$(date +%s)
  gw=$(ip route show 0.0.0.0/1 2>/dev/null | awk '/dev tun0/ {print $3; exit}')

  if [ -z "$gw" ]; then                        # tunnel not up (yet)
    connected=0 fails=0 samples="" loss=0
    agent=maint; publish down
    [ "$down_since" -gt 0 ] || down_since=$now
    if [ $(( now - down_since )) -ge "$STUCK_AFTER" ]; then
      # Stuck (dead server or proxy; openvpn alone would keep retrying the same ones): next proxy
      # from SOCKS_HOST, fresh server list without busy servers, and a reconnect right away
      # If the proxy itself answers, the servers openvpn tried did not: avoid them for BAD_TTL.
      # If it does not (proxy or the whole internet down), the servers are not to blame.
      if socat -u /dev/null "TCP:$SOCKS_IP:${SOCKS_PORT:-1080},connect-timeout=3" 2>/dev/null; then
        dead=$(awk '/^remote /{print $2}' /etc/openvpn/pia.conf | while read -r ip; do
          awk -v ip="$ip" '$2==ip {print $3; exit}' /run/servers.live; done)
        for c in $dead; do mark_bad "$c"; done
        why="no answer from: $(echo $dead)"
      else
        why="proxy $SOCKS_IP unreachable"
      fi
      next=$(echo "${SOCKS_ALL:-$SOCKS_IP}" | tr ' ' '\n' | awk -v cur="$SOCKS_IP" '{a[NR]=$0; if ($0==cur) i=NR} END {print a[i % NR + 1]}')
      if [ -n "$next" ] && [ "$next" != "$SOCKS_IP" ]; then
        ip route replace "$next/32" via "$ETH_GW" dev eth0 && SOCKS_IP=$next && export SOCKS_IP
      fi
      log "tunnel down for $(( now - down_since ))s ($why) -> reconnecting via proxy $SOCKS_IP"
      /gen-conf.sh $(busy_cns) >/dev/null
      kill -HUP "$OVPN_PID"
      down_since=$now
    fi
    continue
  fi
  down_since=0
  if [ "$connected" -eq 0 ]; then
    connected=$now
    cn=$(cat /run/server_cn 2>/dev/null)
    log "tunnel up on $cn (gateway $gw)"
    set -- $(peer_state)
    if [ "$cn" = "$(client_cn)" ]; then
      reconnect "server $cn is used by the local PIA client (same account)"; continue
    elif [ "$1" = up ] && [ "${4:-}" = "$cn" ] && [ "$2" -le "$connected" ]; then
      reconnect "server $cn is already used by $PEER (same account)"; continue
    fi
  fi

  if ping -c1 -W1 -q "$gw" >/dev/null 2>&1; then r=1 fails=0; else r=0 fails=$((fails + 1)); fi
  samples="$samples$r"
  [ ${#samples} -gt "$LOSS_WINDOW" ] && samples=${samples#?}
  lost=$(printf '%s' "$samples" | tr -d 1 | wc -c)
  loss=$(( lost * 100 / ${#samples} ))

  # The local PIA client may (re)connect to our server at any time - then one of us gets kicked
  if [ -n "$cn" ] && [ "$cn" = "$(client_cn)" ]; then
    reconnect "server $cn is now used by the local PIA client (same account)"; continue
  fi

  # 2 lost pings in a row: move traffic to a healthy peer right away (it keeps the role afterwards,
  # so this costs nothing if we recover) - shortens the blackout before the confirmed reconnect below
  if [ "$fails" -eq 2 ] && [ "$(active)" = "$NAME" ]; then
    set -- $(peer_state)
    [ "$1" = up ] && [ "${3:-100}" -lt 5 ] && { set_active "$PEER"; agent="ready up 0%"; publish up; }
  fi

  if [ "$fails" -ge 3 ]; then
    # Confirm with real traffic before acting: on a lossy link three lost pings in a row happen by chance
    if curl -s -m 3 -o /dev/null http://www.gstatic.com/generate_204; then
      fails=0
    else
      reconnect "gateway unreachable (3 pings lost, HTTP check failed)"; continue
    fi
  fi

  set -- $(peer_state); peer_up=$1 peer_loss=$3
  age=$(( now - connected ))

  if [ ${#samples} -ge "$LOSS_WINDOW" ] && [ "$loss" -gt "$LOSS_MAX" ] \
     && [ $(( now - last_switch )) -ge 300 ] && [ "$peer_up" = up ] && [ "$peer_loss" -lt "$loss" ]; then
    last_switch=$now
    if [ "$(free_servers)" -gt 0 ]; then
      mark_bad "$cn"                             # otherwise the reconnect lands on the same server again
      reconnect "packet loss ${loss}% (peer ${peer_loss}%), switching server" drain; continue
    fi
    log "packet loss ${loss}% on $cn, but no free server in $PIA_REGION to switch to (staying standby)"
    [ "$(active)" = "$NAME" ] && [ "$peer_up" = up ] && set_active "$PEER"   # let the healthier tunnel carry traffic
  fi

  slot=$(( (now - phase) / ROTATE_PERIOD ))
  if [ "$slot" -gt "$handled" ]; then
    into_slot=$(( (now - phase) % ROTATE_PERIOD ))
    if [ "$age" -lt "$ROTATE_MIN_AGE" ]; then
      handled=$slot                              # fresh connection, no need to rotate
    elif [ "$peer_up" = up ]; then
      handled=$slot
      reconnect "planned rotation (connected ${age}s, before the proxy's session limit)" drain; continue
    elif [ "$into_slot" -ge 300 ]; then
      handled=$slot                              # peer still down after 5 min: don't take both down
      log "planned rotation skipped: peer is down"
    fi                                           # else: wait up to 5 min for the peer to come up
  fi

  # Active/standby: claim the role if nobody holds it or the holder is down; otherwise stay standby
  cur=$(active)
  if [ "$cur" != "$NAME" ]; then
    if [ -z "$cur" ] && { [ "$PIA_SLOT" = 1 ] || [ "$peer_up" != up ]; }; then set_active "$NAME"
    elif [ "$cur" = "$PEER" ] && [ "$peer_up" != up ]; then set_active "$NAME"
    fi
  fi
  if [ "$(active)" = "$NAME" ]; then agent="ready up 100%"; else agent="ready up 0%"; fi
  publish up
done
