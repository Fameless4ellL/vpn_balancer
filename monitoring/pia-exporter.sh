#!/bin/sh
# Prometheus metrics for the PIA client's server list (data.json), which gen-conf.sh builds the tunnel
# configs from. The PIA daemon rewrites the file regularly; when the daemon stops or the file can't be
# read, gen-conf.sh silently keeps using an old list. Runs in the pia-exporter container
# (compose.monitoring.yml) with /opt/piavpn/etc mounted read-only at /run/pia-etc.
#   pia-exporter.sh        - listen on :9101
#   pia-exporter.sh scrape - answer one HTTP request on stdin/stdout (called by socat)
set -u

F=/run/pia-etc/data.json

if [ "${1:-}" != scrape ]; then
  echo "pia-exporter: serving $F metrics on :9101, regions: $PIA_REGIONS"
  # stderr dropped: Prometheus may close the connection before socat is done
  exec socat TCP-LISTEN:9101,fork,reuseaddr SYSTEM:'sh /pia-exporter.sh scrape' 2>/dev/null
fi

# read the request up to the empty line, then answer whatever the path
while read -r line; do case "$line" in ''|"$(printf '\r')") break ;; esac; done

metrics() {
  echo '# HELP pia_data_json_readable 1 if the PIA client'"'"'s data.json can be read.'
  echo '# TYPE pia_data_json_readable gauge'
  if [ ! -r "$F" ]; then echo 'pia_data_json_readable 0'; return; fi
  echo 'pia_data_json_readable 1'
  echo '# HELP pia_data_json_mtime_seconds Last time the PIA daemon rewrote data.json.'
  echo '# TYPE pia_data_json_mtime_seconds gauge'
  echo "pia_data_json_mtime_seconds $(stat -c %Y "$F")"
  # the same filter as gen-conf.sh: 0 here = gen-conf.sh falls back to the old servers.txt or fails
  echo '# HELP pia_region_servers OpenVPN UDP servers of a configured region in data.json.'
  echo '# TYPE pia_region_servers gauge'
  servers=$(jq -r '.cachedModernRegionsList.regions[] | select(.offline | not) | .id as $r
    | (.servers.ovpnudp // [])[] | $r' "$F" 2>/dev/null)
  for r in $(echo "$PIA_REGIONS" | tr ' ' '\n' | sort -u); do
    echo "pia_region_servers{region=\"$r\"} $(echo "$servers" | grep -cx "$r")"
  done
}

body=$(metrics)
printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: %s\r\n\r\n%s\n' \
  "$(( ${#body} + 1 ))" "$body"
