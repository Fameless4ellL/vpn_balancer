# Generates the Grafana dashboard: python3 monitoring/grafana/dashboard.py monitoring/grafana/dashboards/vpn.json
import json
import sys

DS = {"type": "prometheus", "uid": "prometheus"}
TUNNEL_COLORS = {"vpn1": "#3987e5", "vpn2": "#d95926"}
GOOD, WARN, CRIT, NEUTRAL = "green", "#e0a400", "red", "#8a8a85"


def tunnel_overrides():
    return [
        {
            "matcher": {"id": "byName", "options": n},
            "properties": [
                {"id": "color", "value": {"mode": "fixed", "fixedColor": c}}
            ],
        }
        for n, c in TUNNEL_COLORS.items()
    ]


pid = 0


def panel(kind, title, x, y, w, h, targets, desc="", **extra):
    global pid
    pid += 1
    p = {
        "id": pid,
        "type": kind,
        "title": title,
        "description": desc,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [
            dict(refId=chr(65 + i), datasource=DS, **t) for i, t in enumerate(targets)
        ],
    }
    p.update(extra)
    return p


def stat(
    title,
    x,
    expr,
    desc,
    unit="none",
    thresholds=None,
    legend="",
    text_mode="value",
    decimals=None,
    no_value=None,
):
    defaults = {
        "unit": unit,
        "color": {
            "mode": "thresholds" if thresholds else "fixed",
            "fixedColor": "text",
        },
        "thresholds": {
            "mode": "absolute",
            "steps": thresholds or [{"color": "text", "value": None}],
        },
    }
    if decimals is not None:
        defaults["decimals"] = decimals
    if no_value:
        defaults["noValue"] = no_value
    return panel(
        "stat",
        title,
        x,
        0,
        4,
        4,
        [{"expr": expr, "legendFormat": legend, "instant": True}],
        desc,
        fieldConfig={"defaults": defaults, "overrides": []},
        options={
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "value" if thresholds else "none",
            "graphMode": "none",
            "textMode": text_mode,
            "justifyMode": "center",
            "orientation": "auto",
        },
    )


def timeseries(
    title, x, y, w, targets, desc, unit, draw="line", decimals=None, interval=None
):
    defaults = {
        "unit": unit,
        "min": 0,
        "color": {"mode": "palette-classic"},
        "custom": {
            "drawStyle": draw,
            "lineWidth": 2,
            "fillOpacity": 0 if draw == "line" else 80,
            "showPoints": "never",
            "spanNulls": False,
            "axisSoftMin": 0,
            "gradientMode": "none",
            "barAlignment": 0,
        },
    }
    if decimals is not None:
        defaults["decimals"] = decimals
    extra = {"interval": interval} if interval else {}
    return panel(
        "timeseries",
        title,
        x,
        y,
        w,
        8,
        targets,
        desc,
        **extra,
        fieldConfig={"defaults": defaults, "overrides": tunnel_overrides()},
        options={
            "legend": {
                "displayMode": "list",
                "placement": "bottom",
                "showLegend": True,
            },
            "tooltip": {"mode": "multi", "sort": "none"},
        },
    )


POOLS = 'proxy=~"socks5_pool|http_pool"'
panels = [
    stat(
        "Active tunnel",
        0,
        "vpn:tunnel_active == 1",
        "The tunnel HAProxy sends new connections to. 'none' = the proxy is down.",
        legend="{{server}}",
        text_mode="name",
        no_value="none",
    ),
    stat(
        "Usable tunnels",
        4,
        "sum(vpn:tunnel_usable)",
        "Active + standby. 2 = redundant, 1 = the next failure takes the proxy down.",
        thresholds=[
            {"color": CRIT, "value": None},
            {"color": WARN, "value": 1},
            {"color": GOOD, "value": 2},
        ],
    ),
    stat(
        "Role changes, 24 h",
        8,
        "sum(changes(vpn:tunnel_active[24h])) / 2",
        "Each change = new connections start leaving from another public IP. "
        "Planned handovers alone give ~1 per 50 min (~29 per day).",
        decimals=0,
    ),
    stat(
        "Active sessions",
        12,
        f"sum(haproxy_backend_current_sessions{{{POOLS}}})",
        "Open client connections through the balancer (SOCKS5 + HTTP).",
    ),
    stat(
        "Check time, active",
        16,
        'max(haproxy_server_check_duration_seconds{proxy="socks5_pool"} and on (server) (vpn:tunnel_active == 1))',
        "Time of the last end-to-end check (HTTP request through the tunnel). Timeout: 6 s.",
        unit="s",
        thresholds=[
            {"color": GOOD, "value": None},
            {"color": WARN, "value": 3},
            {"color": CRIT, "value": 5},
        ],
    ),
    stat(
        "Connections, 24 h",
        20,
        f"sum(increase(haproxy_backend_sessions_total{{{POOLS}}}[24h]))",
        "Client connections handled by the balancer over the last 24 hours.",
        decimals=0,
    ),
    panel(
        "state-timeline",
        "Tunnel state",
        0,
        4,
        24,
        6,
        [{"expr": "vpn:tunnel_state", "legendFormat": "{{server}}"}],
        "active = carries traffic; standby = healthy, weight 0; maint = the watchdog is draining/reconnecting it "
        "(planned rotation or failure) or the container is gone; down = the end-to-end health check fails.",
        # color mode must not be "thresholds": in Grafana 13 it overrides the mappings' colors and texts
        fieldConfig={
            "defaults": {
                "color": {"mode": "fixed", "fixedColor": "text"},
                "thresholds": {
                    "mode": "absolute",
                    "steps": [{"color": "text", "value": None}],
                },
                "mappings": [
                    {
                        "type": "range",
                        "options": {
                            "from": v - 0.5,
                            "to": v + 0.5,
                            "result": {"text": t, "color": c, "index": i},
                        },
                    }
                    for i, (v, t, c) in enumerate(
                        [
                            (3, "active", GOOD),
                            (2, "standby", NEUTRAL),
                            (1, "maint", WARN),
                            (0, "down", CRIT),
                        ]
                    )
                ],
                "custom": {"lineWidth": 0, "fillOpacity": 85},
            },
            "overrides": [],
        },
        options={
            "showValue": "never",
            "rowHeight": 0.8,
            "mergeValues": True,
            "alignValue": "left",
            "legend": {
                "displayMode": "list",
                "placement": "bottom",
                "showLegend": True,
            },
            "tooltip": {"mode": "single", "sort": "none"},
        },
    ),
    timeseries(
        "Open sessions per tunnel",
        0,
        10,
        12,
        [
            {
                "expr": f"sum by (server) (haproxy_server_current_sessions{{{POOLS}}})",
                "legendFormat": "{{server}}",
            }
        ],
        "Client connections currently going through each tunnel. Long-lived connections stay on the old "
        "tunnel after a handover until it reconnects.",
        "none",
        decimals=0,
    ),
    timeseries(
        "Download per tunnel",
        12,
        10,
        12,
        [
            {
                "expr": f"sum by (server) (rate(haproxy_server_bytes_out_total{{{POOLS}}}[1m]))",
                "legendFormat": "{{server}}",
            }
        ],
        "Response bytes from each tunnel to clients (1-minute rate).",
        "Bps",
    ),
    timeseries(
        "Health check duration",
        0,
        18,
        12,
        [
            {
                "expr": 'haproxy_server_check_duration_seconds{proxy="socks5_pool"}',
                "legendFormat": "{{server}}",
            }
        ],
        "End-to-end check: GET generate_204 through the tunnel. Alert above 3 s on average over 10 min.",
        "s",
    ),
    timeseries(
        "Failed health checks, per 5 min",
        12,
        18,
        12,
        [
            {
                "expr": 'increase(haproxy_server_check_failures_total{proxy="socks5_pool"}[$__interval])',
                "legendFormat": "{{server}}",
            }
        ],
        "Failed end-to-end checks. Two in a row mark the tunnel down.",
        "none",
        draw="bars",
        decimals=0,
        interval="5m",
    ),
]

dash = {
    "uid": "vpn-balancer",
    "title": "VPN balancer",
    "tags": ["vpn", "haproxy"],
    "timezone": "browser",
    "schemaVersion": 41,
    "version": 1,
    "editable": False,
    "refresh": "10s",
    "time": {"from": "now-6h", "to": "now"},
    "panels": panels,
    "templating": {"list": []},
    "annotations": {"list": []},
}
with open(sys.argv[1], "w") as f:
    json.dump(dash, f, indent=2)
print(len(panels), "panels")
