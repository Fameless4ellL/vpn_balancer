from json import load
from sys import exit


def main():
    src = "/opt/piavpn/etc/data.json"
    with open(src) as f:
        regions = load(f)["cachedModernRegionsList"]["regions"]
    lines = [
        f'{r["id"]} {s["ip"]} {s["cn"]}'
        for r in regions
        if not r.get("offline")
        for s in r["servers"].get("ovpnudp", [])
    ]
    if not lines:
        exit(f"no servers found in {src}")
    with open("servers.txt", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"servers.txt: {len(lines)} servers")


if __name__ == "__main__":
    main()
