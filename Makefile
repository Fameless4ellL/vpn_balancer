-include .env
# MONITORING=1 in .env adds Prometheus + Alertmanager + Grafana (compose.monitoring.yml)
MONITORING_ON := $(filter 1,$(MONITORING))
COMPOSE := podman-compose -f compose.yml $(if $(MONITORING_ON),-f compose.monitoring.yml)

.PHONY: up down restart logs ps ip check regions servers

up: .env servers ovpn/ca.crt $(if $(MONITORING_ON),secrets/grafana-admin.txt secrets/telegram-bot-token.txt)
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart: down up

logs:
	$(COMPOSE) logs -f --tail=50

ps:
	podman ps --filter name=vpn --format 'table {{.Names}}\t{{.Status}}'

# Public IP via the balancer and via each tunnel separately
ip:
	@printf 'LB socks5 : '; curl -s -m 15 --socks5-hostname 127.0.0.1:$(LB_SOCKS_PORT) https://ipinfo.io/ip; echo
	@printf 'LB http   : '; curl -s -m 15 -x http://127.0.0.1:$(LB_HTTP_PORT) https://ipinfo.io/ip; echo
	@for u in vpn1 vpn2; do printf '%-9s: ' $$u; podman exec $$u curl -s -m 15 https://ipinfo.io/ip; echo; done

# Refresh the PIA server list (IPs come from the PIA client's cache, no DNS)
servers:
	@python3 pia-servers.py

# HAProxy pool state
check:
	@curl -s 'http://127.0.0.1:$(LB_STATS_PORT)/;csv' | awk -F, '$$2!="FRONTEND" && $$2!="BACKEND" && NR>1 {print $$1, $$2, $$18}'

# PIA regions with OpenVPN UDP, sorted by latency (from the PIA client's data)
regions:
	@python3 -c 'import json;d=json.load(open("/opt/piavpn/etc/data.json"));L=d["cachedModernRegionsList"]["regions"];lat=d["modernLatencies"];[print(f"{r[\"id\"]:25} {int(lat.get(r[\"id\"],0)):4}ms  {r[\"name\"]}") for r in sorted(L,key=lambda r:lat.get(r["id"],9e9)) if not r.get("offline") and r["servers"].get("ovpnudp")]' | head -30

.env:
	cp .env.example .env
	@echo "created .env from .env.example — review it and run make up again" && false

# PIA's public CA certificate: from the local PIA client, otherwise from PIA's official config bundle
ovpn/ca.crt:
	@mkdir -p ovpn
	@if [ -r /opt/piavpn/var/pia.ovpn ]; then \
		sed -n '/<ca>/,/<\/ca>/p' /opt/piavpn/var/pia.ovpn | sed '1d;$$d' > $@; \
	else \
		curl -fsSL -o /tmp/pia-openvpn.zip https://www.privateinternetaccess.com/openvpn/openvpn-strong.zip && \
		unzip -p /tmp/pia-openvpn.zip ca.rsa.4096.crt > $@; \
	fi
	@openssl x509 -in $@ -noout -subject >/dev/null && echo "$@: $$(openssl x509 -in $@ -noout -fingerprint -sha256)"

secrets/grafana-admin.txt:
	@mkdir -p secrets && chmod 700 secrets
	@openssl rand -base64 18 | tr -d '\n' > $@ && chmod 644 $@
	@echo "$@: generated Grafana admin password (user: admin)"

secrets/telegram-bot-token.txt:
	@mkdir -p secrets && chmod 700 secrets
	@touch $@ && chmod 644 $@
