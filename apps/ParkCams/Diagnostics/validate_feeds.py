#!/usr/bin/env python3
import concurrent.futures
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

SOURCE = "ParkCams/ParkCamsViewController.m"
TIMEOUT = 12


def decode_html(value):
    if not value:
        return ""
    return (
        value.replace("&amp;", "&")
        .replace("&quot;", '"')
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#x2F;", "/")
        .replace("&#x2f;", "/")
        .replace("&#x3A;", ":")
        .replace("&#x3a;", ":")
    )


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


def get_url(url, limit=None):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "RangerLens feed validation",
            "Accept": "*/*",
        },
    )
    context = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=context) as response:
        data = response.read(limit) if limit else response.read()
        return response.getcode(), response.headers, data


def load_catalog():
    source = open(SOURCE, "r", encoding="utf-8").read()
    pattern = re.compile(
        r'parkWithName:@"([^"]+)" code:@"([^"]+)".*?webcamURL:@"([^"]+)" feedCount:(\d+)\]',
        re.S,
    )
    parks = []
    for name, code, url, feed_count in pattern.findall(source):
        parks.append(
            {
                "name": name,
                "code": code,
                "url": url,
                "feed_count": int(feed_count),
            }
        )
    return parks


def parse_feeds(html, base_url):
    feeds = []
    seen = set()

    direct_image = first_group(html, r'id=["\']webcamRefreshImage["\'][^>]+src=["\']([^"\']+)["\']')
    if direct_image:
        title = decode_html(first_group(html, r"<h1[^>]*>(.*?)</h1>") or "Still Webcam")
        image_url = absolute_url(direct_image, base_url)
        feeds.append({"title": title, "kind": "still", "url": image_url})
        seen.add(image_url)

    pixel_camera = first_group(html, r'data-camera=["\']([^"\']+)["\']')
    if pixel_camera and "pixelcaster.com" in html:
        stream = f"https://cs7.pixelcaster.com/nps/{pixel_camera}.stream/playlist_dvr.m3u8"
        feeds.append({"title": "Old Faithful Live", "kind": "hls", "url": stream})
        seen.add(stream)

    for match in re.finditer(r'(?:https?:)?//[^"\'\s<>]+\.m3u8[^"\'\s<>]*', html, flags=re.I):
        stream = absolute_url(match.group(0), base_url)
        if stream not in seen:
            feeds.append({"title": "Live Stream", "kind": "hls", "url": stream})
            seen.add(stream)

    for match in re.finditer(
        r'<img[^>]+class=["\'][^"\']*WebcamPreview__CoverImage[^"\']*["\'][^>]*>',
        html,
        flags=re.I | re.S,
    ):
        tag = match.group(0)
        src = first_group(tag, r'src=["\']([^"\']+)["\']')
        image_url = absolute_url(src, base_url)
        if not image_url or image_url in seen:
            continue
        lower = image_url.lower()
        if "inactive" in lower or "placeholder" in lower or lower.endswith(".svg"):
            continue
        title = first_group(tag, r'title=["\']([^"\']+)["\']') or first_group(tag, r'alt=["\']([^"\']+)["\']') or "Park Webcam"
        feeds.append({"title": decode_html(title), "kind": "still", "url": image_url})
        seen.add(image_url)

    return feeds


def validate_feed(feed):
    try:
        status, headers, data = get_url(feed["url"], limit=256 * 1024)
        content_type = headers.get("Content-Type", "").lower()
        if status >= 400:
            return False, f"HTTP {status}"
        if feed["kind"] == "hls":
            text = data[:4096].decode("utf-8", errors="ignore")
            if "#EXTM3U" in text:
                return True, "HLS playlist"
            return False, "not an HLS playlist"
        if content_type.startswith("image/") or data.startswith((b"\xff\xd8", b"\x89PNG", b"GIF8")):
            return True, content_type or "image bytes"
        return False, content_type or "not image bytes"
    except Exception as exc:
        return False, str(exc)


def validate_park(park):
    result = {**park, "page_ok": False, "feeds": []}
    try:
        status, headers, data = get_url(park["url"])
        result["page_status"] = status
        result["page_ok"] = status < 400
        html = data.decode("utf-8", errors="ignore")
    except Exception as exc:
        result["page_error"] = str(exc)
        return result

    for feed in parse_feeds(html, park["url"]):
        ok, note = validate_feed(feed)
        result["feeds"].append({**feed, "ok": ok, "note": note})
    return result


def main():
    parks = load_catalog()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        for result in executor.map(validate_park, parks):
            results.append(result)

    ok_count = 0
    fail_count = 0
    for park in results:
        feeds = park["feeds"]
        ok = [feed for feed in feeds if feed["ok"]]
        bad = [feed for feed in feeds if not feed["ok"]]
        ok_count += len(ok)
        fail_count += len(bad)
        print(f"{park['name']}: page={'ok' if park.get('page_ok') else 'FAIL'} feeds={len(feeds)} ok={len(ok)} bad={len(bad)}")
        for feed in bad:
            print(f"  BAD {feed['kind']} {feed['title']}: {feed['note']} :: {feed['url']}")
    print(f"\nTOTAL parks={len(results)} feeds={ok_count + fail_count} ok={ok_count} bad={fail_count}")

    with open("Diagnostics/feed_validation.json", "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2)

    return 1 if fail_count else 0


if __name__ == "__main__":
    sys.exit(main())
