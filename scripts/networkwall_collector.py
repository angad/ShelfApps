#!/usr/bin/env python3
"""Small JSON collector for NetworkWall.

Run on a Mac, Raspberry Pi, router, or NAS on the same LAN:

    python3 scripts/networkwall_collector.py --host 0.0.0.0 --port 8765

NetworkWall can ingest the `/devices.json` payload when it is reachable at a
known collector address. The schema is intentionally simple so router-specific
collectors can emit the same shape later.
"""

from __future__ import annotations

import argparse
import json
import re
import socket
import subprocess
import time
import shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


PORTS_BY_TYPE = {
    "Phones": [62078],
    "Computers": [22, 445, 548, 5900],
    "Smart Home": [1883, 8123],
    "Media": [554, 7000, 8008, 8009, 8060, 32400],
    "Network": [53, 80, 443, 5000, 5001],
}


def local_subnet() -> tuple[str, list[str]]:
    """Return a conservative /24 host list for the primary LAN address."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("1.1.1.1", 80))
        ip = sock.getsockname()[0]
    finally:
        sock.close()

    parts = ip.split(".")
    prefix = ".".join(parts[:3])
    return f"{prefix}.0/24", [f"{prefix}.{i}" for i in range(1, 255) if f"{prefix}.{i}" != ip]


def arp_table() -> dict[str, str]:
    try:
        output = subprocess.check_output(["arp", "-an"], stderr=subprocess.DEVNULL, text=True)
    except Exception:
        return {}

    table: dict[str, str] = {}
    for line in output.splitlines():
        match = re.search(r"\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-fA-F:]{8,})", line)
        if match:
            table[match.group(1)] = match.group(2).upper()
    return table


def reverse_name(ip: str) -> str:
    try:
        name = socket.gethostbyaddr(ip)[0]
        return "" if name == ip else name
    except Exception:
        return ""


def open_ports(ip: str, ports: list[int], timeout: float) -> list[int]:
    found: list[int] = []
    for port in ports:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        try:
            if sock.connect_ex((ip, port)) == 0:
                found.append(port)
        except Exception:
            pass
        finally:
            sock.close()
    return found


def classify(name: str, ports: list[int]) -> str:
    text = name.lower()
    if any(word in text for word in ["iphone", "ipad", "android", "phone"]):
        return "Phones"
    if any(word in text for word in ["macbook", "imac", "pc", "desktop", "laptop", "nas"]):
        return "Computers"
    if any(word in text for word in ["roku", "tv", "chromecast", "plex", "sonos"]):
        return "Media"
    if any(word in text for word in ["nest", "hue", "wemo", "home", "esp"]):
        return "Smart Home"
    if any(word in text for word in ["router", "gateway", "ap", "switch"]):
        return "Network"

    port_set = set(ports)
    for device_type, type_ports in PORTS_BY_TYPE.items():
        if port_set.intersection(type_ports):
            return device_type
    return "Unknown"


def scan() -> dict[str, Any]:
    subnet, hosts = local_subnet()
    arp = arp_table()
    scan_ports = sorted({port for ports in PORTS_BY_TYPE.values() for port in ports} | {80, 443, 8080})
    devices = []

    for ip in hosts:
        ports = open_ports(ip, scan_ports, 0.08)
        mac = arp.get(ip, "")
        if not ports and not mac:
            continue
        name = reverse_name(ip)
        device_type = classify(name, ports)
        devices.append(
            {
                "ip": ip,
                "name": name or f"Device {ip.rsplit('.', 1)[-1]}",
                "mac": mac,
                "vendor": "",
                "type": device_type,
                "ports": ports,
                "services": "",
            }
        )

    return {"subnet": subnet, "generatedAt": time.time(), "devices": devices}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path not in ("/", "/devices.json"):
            self.send_error(404)
            return
        payload = json.dumps(scan(), separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args: Any) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    advertiser = None
    if shutil.which("dns-sd"):
        try:
            advertiser = subprocess.Popen(
                ["dns-sd", "-R", "NetworkWall Collector", "_networkwall._tcp", "local", str(args.port), "path=/devices.json"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            advertiser = None
    print(f"NetworkWall collector serving http://{args.host}:{args.port}/devices.json")
    try:
        server.serve_forever()
    finally:
        if advertiser:
            advertiser.terminate()


if __name__ == "__main__":
    main()
