#!/usr/bin/env python3
"""
Extract portal-like URLs and MAC-like identifiers from a web page or local file.

This script is intentionally limited to passive parsing. It does not test
whether any MAC/portal combination grants access to a third-party service.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


MAC_RE = re.compile(
    r"(?<![0-9A-Fa-f])"
    r"(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"
    r"(?![0-9A-Fa-f])"
)
BARE_MAC_RE = re.compile(r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{12})(?![0-9A-Fa-f])")
URL_RE = re.compile(r"https?://[^\s\"'<>)]+", re.IGNORECASE)
TRAILING_URL_CHARS = ".,;:!?"

PORTAL_HINTS = (
    "/c/",
    "/c/index.html",
    "stalker_portal",
    "portal.php",
    "server/load.php",
    "mag",
    "stb",
)


class TextAndLinkExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: List[str] = []
        self.links: List[str] = []

    def handle_starttag(self, tag: str, attrs: Sequence[Tuple[str, Optional[str]]]) -> None:
        attrs_map = dict(attrs)
        if tag.lower() == "a" and attrs_map.get("href"):
            self.links.append(attrs_map["href"] or "")
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.parts.append(data)
            self.parts.append("\n")


def fetch_source(source: str, timeout: int) -> Tuple[str, str]:
    parsed = urllib.parse.urlparse(source)
    if parsed.scheme in {"http", "https"}:
        request = urllib.request.Request(
            source,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X) "
                    "AppleWebKit/605.1.15 Safari/605.1.15"
                )
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                charset = response.headers.get_content_charset() or "utf-8"
                return response.read().decode(charset, errors="replace"), response.geturl()
        except urllib.error.URLError as exc:
            raise SystemExit(f"Could not fetch {source}: {exc}") from exc

    path = Path(source)
    try:
        return path.read_text(encoding="utf-8", errors="replace"), path.resolve().as_uri()
    except OSError as exc:
        raise SystemExit(f"Could not read {source}: {exc}") from exc


def normalize_url(raw_url: str, base_url: str) -> str:
    url = html.unescape(raw_url).strip().rstrip(TRAILING_URL_CHARS)
    return urllib.parse.urljoin(base_url, url)


def normalize_mac(raw_mac: str) -> str:
    hex_digits = re.sub(r"[^0-9A-Fa-f]", "", raw_mac).upper()
    return ":".join(hex_digits[index : index + 2] for index in range(0, 12, 2))


def looks_like_portal(url: str) -> bool:
    lowered = url.lower()
    parsed = urllib.parse.urlparse(url)
    has_non_default_port = parsed.port is not None and parsed.port not in {80, 443}
    return has_non_default_port or any(hint in lowered for hint in PORTAL_HINTS)


def extract_text_and_urls(raw: str, base_url: str) -> Tuple[str, List[str]]:
    parser = TextAndLinkExtractor()
    parser.feed(raw)

    text = "\n".join(parser.parts)
    raw_urls = URL_RE.findall(raw) + URL_RE.findall(text) + parser.links
    urls = sorted({normalize_url(url, base_url) for url in raw_urls if url.strip()})
    return text, urls


def line_records(text: str, urls: Iterable[str]) -> List[Dict[str, str]]:
    records: List[Dict[str, str]] = []
    seen = set()
    current_portal = ""

    all_urls = sorted(set(urls))
    portal_urls = [url for url in all_urls if looks_like_portal(url)]
    first_portal = portal_urls[0] if portal_urls else ""

    for line_no, raw_line in enumerate(text.splitlines(), start=1):
        line = html.unescape(raw_line).strip()
        if not line:
            continue

        line_urls = [url.rstrip(TRAILING_URL_CHARS) for url in URL_RE.findall(line)]
        line_portals = [url for url in line_urls if looks_like_portal(url)]
        if line_portals:
            current_portal = line_portals[-1]

        macs = [normalize_mac(mac) for mac in MAC_RE.findall(line)]
        macs.extend(normalize_mac(mac) for mac in BARE_MAC_RE.findall(line))

        for mac in sorted(set(macs)):
            portal = current_portal or (line_portals[-1] if line_portals else first_portal)
            key = (portal, mac)
            if key in seen:
                continue
            seen.add(key)
            records.append(
                {
                    "portal": portal,
                    "mac": mac,
                    "line": str(line_no),
                    "context": line[:240],
                }
            )

    if records:
        return records

    for mac in sorted({normalize_mac(mac) for mac in MAC_RE.findall(text)}):
        records.append({"portal": first_portal, "mac": mac, "line": "", "context": ""})
    return records


def write_csv(path: Path, records: Sequence[Dict[str, str]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["portal", "mac", "line", "context"])
        writer.writeheader()
        writer.writerows(records)


def write_json(path: Path, records: Sequence[Dict[str, str]], urls: Sequence[str]) -> None:
    payload = {
        "records": list(records),
        "portal_urls": [url for url in urls if looks_like_portal(url)],
        "all_urls": list(urls),
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Passively extract portal-like URLs and MAC-like identifiers."
    )
    parser.add_argument("source", help="URL or local HTML/text file to parse")
    parser.add_argument(
        "-o",
        "--output",
        default="portal_indicators.csv",
        help="Output path. Defaults to portal_indicators.csv",
    )
    parser.add_argument(
        "--format",
        choices=("csv", "json"),
        default="csv",
        help="Output format. Defaults to csv.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=20,
        help="HTTP fetch timeout in seconds. Defaults to 20.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    raw, base_url = fetch_source(args.source, args.timeout)
    text, urls = extract_text_and_urls(raw, base_url)
    records = line_records(text, urls)

    output = Path(args.output)
    if args.format == "json":
        write_json(output, records, urls)
    else:
        write_csv(output, records)

    portal_count = len({record["portal"] for record in records if record["portal"]})
    mac_count = len({record["mac"] for record in records if record["mac"]})
    print(f"Wrote {len(records)} records to {output}")
    print(f"Unique portal-like URLs: {portal_count}")
    print(f"Unique MAC-like identifiers: {mac_count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
