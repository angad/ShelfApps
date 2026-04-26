#!/usr/bin/env python3
"""Build a compact RangerLens manifest from the official NPS API.

The NPS API key is read from the workspace .env file and is never written to
the generated manifest. The iPhone app consumes the generated JSON directly.
"""

import concurrent.futures
import email.utils
import html
import json
import os
from pathlib import Path
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

APP_ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_ROOT = APP_ROOT.parents[1]
SOURCE = APP_ROOT / "ParkCams" / "ParkCamsViewController.m"
OUTPUT = APP_ROOT / "ParkCams" / "ParkCamsManifest.json"
REPORT = APP_ROOT / "Diagnostics" / "nps_manifest_report.json"
API_BASE = "https://developer.nps.gov/api/v1"
TIMEOUT = 16
STILL_MAX_AGE_SECONDS = 4 * 60 * 60


def load_env_key():
    for env_path in (WORKSPACE_ROOT / ".env", APP_ROOT / ".env"):
        if not env_path.exists():
            continue
        for raw_line in env_path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.strip() == "NPS_API_KEY":
                value = value.strip().strip('"').strip("'")
                if value:
                    return value
    return os.environ.get("NPS_API_KEY")


def decode_html(value):
    return html.unescape(value or "")


def absolute_url(raw, base):
    decoded = decode_html(raw)
    if not decoded:
        return None
    if decoded.startswith("//"):
        return "https:" + decoded
    if decoded.startswith("/"):
        return "https://www.nps.gov" + decoded
    return urllib.parse.urljoin(base, decoded)


def first_group(text, pattern):
    if not text:
        return None
    match = re.search(pattern, text, flags=re.I | re.S)
    return match.group(1) if match else None


def cache_busted(url):
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}rangerlens={int(time.time())}"


def get_url(url, *, api_key=None, limit=None, accept="*/*"):
    headers = {
        "User-Agent": "RangerLens manifest builder",
        "Accept": accept,
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    }
    if api_key:
        headers["X-Api-Key"] = api_key
    req = urllib.request.Request(url, headers=headers)
    context = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=context) as response:
        data = response.read(limit) if limit else response.read()
        return response.getcode(), response.headers, data


def api_get(path, api_key, params):
    query = urllib.parse.urlencode(params)
    status, headers, data = get_url(f"{API_BASE}/{path}?{query}", api_key=api_key, accept="application/json")
    if status >= 400:
        raise RuntimeError(f"NPS API HTTP {status}")
    return json.loads(data.decode("utf-8"))


def load_seed_catalog():
    source = SOURCE.read_text(encoding="utf-8")
    pattern = re.compile(
        r'parkWithName:@"([^"]+)" code:@"([^"]+)" region:@"([^"]+)" category:@"([^"]+)" detail:@"([^"]+)" webcamURL:@"([^"]+)" feedCount:(\d+)\]',
        re.S,
    )
    parks = []
    for name, code, region, category, detail, webcam_url, feed_count in pattern.findall(source):
        parks.append(
            {
                "name": name,
                "code": code,
                "region": region,
                "category": category,
                "detail": detail,
                "webcamURL": webcam_url,
                "seedFeedCount": int(feed_count),
            }
        )
    return parks


def parse_feeds(html_text, base_url, title_hint=None):
    feeds = []
    seen = set()

    def add_feed(title, kind, image_url=None, stream_url=None, source_url=None):
        key = stream_url or image_url
        if not key or key in seen:
            return
        seen.add(key)
        feeds.append(
            {
                "title": decode_html(title or title_hint or "Webcam").strip() or "Webcam",
                "kind": kind,
                "imageURL": image_url or "",
                "streamURL": stream_url or "",
                "sourceURL": source_url or base_url,
            }
        )

    direct_image = first_group(html_text, r'id=["\']webcamRefreshImage["\'][^>]+src=["\']([^"\']+)["\']')
    if direct_image:
        page_title = title_hint or decode_html(first_group(html_text, r"<h1[^>]*>(.*?)</h1>") or "Still Webcam")
        add_feed(page_title, "Still Webcam", image_url=absolute_url(direct_image, base_url))

    pixel_camera = first_group(html_text, r'data-camera=["\']([^"\']+)["\']')
    if pixel_camera and "pixelcaster.com" in html_text:
        poster = first_group(html_text, r'poster:\s*["\']([^"\']+)["\']')
        stream = f"https://cs7.pixelcaster.com/nps/{pixel_camera}.stream/playlist_dvr.m3u8"
        add_feed(title_hint or "Live Stream", "Live HLS", image_url=absolute_url(poster, base_url), stream_url=stream)

    for match in re.finditer(r'(?:https?:)?//[^"\'\s<>]+\.m3u8[^"\'\s<>]*', html_text, flags=re.I):
        stream = absolute_url(match.group(0), base_url)
        add_feed(title_hint or "Live Stream", "Live HLS", stream_url=stream)

    for match in re.finditer(
        r'<img[^>]+class=["\'][^"\']*WebcamPreview__CoverImage[^"\']*["\'][^>]*>',
        html_text,
        flags=re.I | re.S,
    ):
        tag = match.group(0)
        src = first_group(tag, r'src=["\']([^"\']+)["\']')
        image_url = absolute_url(src, base_url)
        if not image_url:
            continue
        lower = image_url.lower()
        if "inactive" in lower or "placeholder" in lower or lower.endswith(".svg"):
            continue
        title = first_group(tag, r'title=["\']([^"\']+)["\']') or first_group(tag, r'alt=["\']([^"\']+)["\']')
        add_feed(title or title_hint or "Park Webcam", "Still Webcam", image_url=image_url)

    return feeds


def last_modified_age(headers):
    value = headers.get("Last-Modified")
    if not value:
        return None
    parsed = email.utils.parsedate_to_datetime(value)
    if not parsed:
        return None
    return time.time() - parsed.timestamp()


def validate_feed(feed):
    url = feed.get("streamURL") or feed.get("imageURL")
    if not url:
        return {**feed, "available": False, "availabilityNote": "Missing direct feed URL"}
    try:
        fetch_url = url if feed.get("streamURL") else cache_busted(url)
        status, headers, data = get_url(fetch_url, limit=256 * 1024)
        content_type = headers.get("Content-Type", "").lower()
        if status >= 400:
            return {**feed, "available": False, "availabilityNote": f"HTTP {status}"}
        if feed.get("streamURL"):
            text = data[:4096].decode("utf-8", errors="ignore")
            if "#EXTM3U" in text:
                return {**feed, "available": True, "availabilityNote": "Available"}
            return {**feed, "available": False, "availabilityNote": "Not an HLS playlist"}
        if not (content_type.startswith("image/") or data.startswith((b"\xff\xd8", b"\x89PNG", b"GIF8"))):
            return {**feed, "available": False, "availabilityNote": content_type or "Not image data"}
        age = last_modified_age(headers)
        if age is not None and age > STILL_MAX_AGE_SECONDS:
            hours = max(1, round(age / 3600))
            return {**feed, "available": False, "availabilityNote": f"Stale image: updated {hours}h ago"}
        return {**feed, "available": True, "availabilityNote": "Available"}
    except Exception as exc:
        return {**feed, "available": False, "availabilityNote": str(exc)}


def choose_park_image(park_record):
    images = park_record.get("images") or []
    for image in images:
        url = image.get("url")
        if url:
            return url
    return ""


def collect_park_images(park_record, limit=8):
    photos = []
    seen = set()
    for image in park_record.get("images") or []:
        url = image.get("url")
        if not url or url in seen:
            continue
        seen.add(url)
        title = strip_tags(image.get("title"))
        caption = strip_tags(image.get("caption"))
        alt_text = strip_tags(image.get("altText"))
        credit = strip_tags(image.get("credit"))
        photos.append(
            {
                "url": url,
                "title": title,
                "caption": caption or alt_text or title,
                "credit": credit,
            }
        )
        if len(photos) >= limit:
            break
    return photos


def strip_tags(value):
    return re.sub(r"<[^>]+>", "", decode_html(value or "")).strip()


def build_park(seed, api_key):
    code = seed["code"]
    park_record = {}
    webcam_records = []
    errors = []

    try:
        parks_response = api_get("parks", api_key, {"parkCode": code, "fields": "images", "limit": 1})
        park_record = (parks_response.get("data") or [{}])[0]
    except Exception as exc:
        errors.append(f"parks API: {exc}")

    try:
        webcams_response = api_get("webcams", api_key, {"parkCode": code, "limit": 100})
        webcam_records = webcams_response.get("data") or []
    except Exception as exc:
        errors.append(f"webcams API: {exc}")

    raw_feeds = []
    seen_pages = set()
    webcam_pages = webcam_records or [{"url": seed["webcamURL"], "title": seed["name"], "status": "", "isStreaming": False}]
    for webcam in webcam_pages:
        page_url = webcam.get("url") or seed["webcamURL"]
        if not page_url or page_url in seen_pages:
            continue
        seen_pages.add(page_url)
        try:
            _status, _headers, data = get_url(page_url)
            page_html = data.decode("utf-8", errors="ignore")
            parsed = parse_feeds(page_html, page_url, title_hint=webcam.get("title"))
            for feed in parsed:
                feed["sourceStatus"] = webcam.get("status") or ""
                feed["apiStreaming"] = bool(webcam.get("isStreaming"))
                if webcam.get("status") and webcam.get("status") != "Active":
                    feed.setdefault("availabilityNote", f"NPS status: {webcam.get('status')}")
                raw_feeds.append(feed)
        except Exception as exc:
            raw_feeds.append(
                {
                    "title": webcam.get("title") or "Webcam",
                    "kind": "Live HLS" if webcam.get("isStreaming") else "Still Webcam",
                    "imageURL": "",
                    "streamURL": "",
                    "sourceURL": page_url,
                    "available": False,
                    "availabilityNote": str(exc),
                    "sourceStatus": webcam.get("status") or "",
                    "apiStreaming": bool(webcam.get("isStreaming")),
                }
            )

    deduped = []
    seen_feeds = set()
    for feed in raw_feeds:
        key = feed.get("streamURL") or feed.get("imageURL") or feed.get("sourceURL")
        if key in seen_feeds:
            continue
        seen_feeds.add(key)
        if "available" in feed:
            deduped.append(feed)
        else:
            deduped.append(validate_feed(feed))

    available_count = sum(1 for feed in deduped if feed.get("available"))
    live_count = sum(1 for feed in deduped if feed.get("available") and feed.get("streamURL"))
    official_name = (park_record.get("name") or seed["name"]).replace(" National Park", "")
    states = park_record.get("states") or seed["region"]
    description = strip_tags(park_record.get("description")) or seed["detail"]
    if len(description) > 132:
        description = description[:129].rstrip() + "..."

    return {
        "name": official_name,
        "code": code,
        "region": states.replace(",", ", "),
        "category": seed["category"],
        "detail": description,
        "webcamURL": seed["webcamURL"],
        "heroImageURL": choose_park_image(park_record),
        "postImages": collect_park_images(park_record),
        "feedCount": available_count,
        "possibleFeedCount": len(deduped),
        "hasLiveVideo": live_count > 0,
        "feeds": deduped,
        "errors": errors,
    }


def main():
    api_key = load_env_key()
    if not api_key:
        print("NPS_API_KEY was not found in .env or the environment.", file=sys.stderr)
        return 2

    seeds = load_seed_catalog()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        future_to_seed = {executor.submit(build_park, seed, api_key): seed for seed in seeds}
        for future in concurrent.futures.as_completed(future_to_seed):
            results.append(future.result())

    order = {seed["code"]: index for index, seed in enumerate(seeds)}
    results.sort(key=lambda park: order.get(park["code"], 9999))

    manifest = {
        "generatedAt": int(time.time()),
        "source": "NPS API /parks?fields=images and /webcams plus direct feed validation",
        "parks": [
            {key: value for key, value in park.items() if key != "errors"}
            for park in results
        ],
    }
    OUTPUT.write_text(json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    REPORT.write_text(json.dumps(results, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    parks_with_feeds = sum(1 for park in results if park["feedCount"] > 0)
    available = sum(park["feedCount"] for park in results)
    possible = sum(park["possibleFeedCount"] for park in results)
    live = sum(1 for park in results if park["hasLiveVideo"])
    print(f"Wrote {OUTPUT}")
    print(f"parks={len(results)} parks_with_feeds={parks_with_feeds} available_feeds={available} possible_feeds={possible} parks_with_live={live}")
    for park in results:
        unavailable = park["possibleFeedCount"] - park["feedCount"]
        print(f"{park['code']:4} {park['feedCount']:2}/{park['possibleFeedCount']:2} feeds live={park['hasLiveVideo']} hidden={unavailable:2} {park['name']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
