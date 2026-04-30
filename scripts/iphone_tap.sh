#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  . "$ROOT_DIR/.env"
  set +a
fi

UDID="${IPHONE_UDID:-${IOS_DEVICE_UDID:-${UDID:-}}}"
LOCAL_PORT="${IPHONE_WDA_LOCAL_PORT:-8100}"
REMOTE_PORT="${IPHONE_WDA_REMOTE_PORT:-8100}"
WDA_URL="${IPHONE_WDA_URL:-http://127.0.0.1:$LOCAL_PORT}"
COORD_MODE="pixels"
SCREEN_SIZE="${IPHONE_SCREENSHOT_SIZE:-}"
START_IPROXY=1

usage() {
  echo "Usage: $0 [--pixels|--points] [--screen WIDTHxHEIGHT] [--no-iproxy] x y [udid]"
  echo
  echo "Taps the connected iPhone through WebDriverAgent over USB."
  echo
  echo "Defaults:"
  echo "  Coordinates are screenshot pixels, suitable for PNGs from scripts/iphone_screenshot.sh."
  echo "  For iPhone 6 portrait screenshots this means 750x1334 pixels."
  echo
  echo "Environment:"
  echo "  IPHONE_UDID              Device id, usually loaded from .env"
  echo "  IPHONE_WDA_LOCAL_PORT    Local USB-forwarded WDA port, default 8100"
  echo "  IPHONE_WDA_REMOTE_PORT   Device WDA port, default 8100"
  echo "  IPHONE_WDA_URL           Existing WDA URL, default http://127.0.0.1:8100"
  echo "  IPHONE_SCREENSHOT_SIZE   Screenshot pixel size for conversion, e.g. 750x1334"
  echo
  echo "Examples:"
  echo "  $0 375 667"
  echo "  $0 --points 187.5 333.5"
  echo "  $0 --screen 1334x750 1200 80"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

status_reachable() {
  python3 - "$WDA_URL" <<'PY' >/dev/null 2>&1
import sys
import urllib.request

url = sys.argv[1].rstrip("/") + "/status"
with urllib.request.urlopen(url, timeout=1.0) as response:
    response.read()
PY
}

start_iproxy_if_needed() {
  if [ "$START_IPROXY" -ne 1 ]; then
    return 0
  fi

  if status_reachable; then
    return 0
  fi

  need iproxy
  mkdir -p "${TMPDIR:-/tmp}/iphone6-usb-control"
  log_path="${TMPDIR:-/tmp}/iphone6-usb-control/iproxy-$UDID-$LOCAL_PORT.log"
  pid_path="${TMPDIR:-/tmp}/iphone6-usb-control/iproxy-$UDID-$LOCAL_PORT.pid"

  if [ -f "$pid_path" ]; then
    old_pid="$(cat "$pid_path" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      sleep 0.5
      if status_reachable; then
        return 0
      fi
    fi
  fi

  iproxy "$LOCAL_PORT" "$REMOTE_PORT" -u "$UDID" >"$log_path" 2>&1 &
  echo "$!" > "$pid_path"

  i=0
  while [ "$i" -lt 20 ]; do
    if status_reachable; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.25
  done
}

run_tap() {
  python3 - "$WDA_URL" "$COORD_MODE" "$SCREEN_SIZE" "$PRODUCT_TYPE" "$X" "$Y" <<'PY'
import json
import sys
import urllib.error
import urllib.request

base_url, coord_mode, screen_size, product_type, raw_x, raw_y = sys.argv[1:7]
base_url = base_url.rstrip("/")
raw_x = float(raw_x)
raw_y = float(raw_y)


def request(method, path, payload=None, timeout=5):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base_url + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
            return response.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(body) if body else {}
        except json.JSONDecodeError:
            parsed = {"raw": body}
        return exc.code, parsed


def value_of(payload):
    return payload.get("value", payload)


status, body = request("GET", "/status")
if status >= 400:
    raise SystemExit("WebDriverAgent /status failed: HTTP %s %s" % (status, body))

session_payloads = [
    {"capabilities": {"alwaysMatch": {}, "firstMatch": [{}]}, "desiredCapabilities": {}},
    {"desiredCapabilities": {}},
]
session_id = None
last_session_error = None
for payload in session_payloads:
    status, body = request("POST", "/session", payload)
    value = value_of(body)
    session_id = body.get("sessionId")
    if not session_id and isinstance(value, dict):
        session_id = value.get("sessionId")
    if session_id:
        break
    last_session_error = (status, body)

if not session_id:
    raise SystemExit("Could not create WDA session: %s" % (last_session_error,))

status, body = request("GET", "/session/%s/window/size" % session_id)
window = value_of(body)
if not isinstance(window, dict) or "width" not in window or "height" not in window:
    status, body = request("GET", "/session/%s/window/rect" % session_id)
    window = value_of(body)
if not isinstance(window, dict) or "width" not in window or "height" not in window:
    raise SystemExit("Could not read WDA window size: HTTP %s %s" % (status, body))

window_width = float(window["width"])
window_height = float(window["height"])

if coord_mode == "points":
    tap_x = raw_x
    tap_y = raw_y
    source = "points"
else:
    if screen_size:
        try:
            screen_width, screen_height = [float(part) for part in screen_size.lower().split("x", 1)]
        except ValueError:
            raise SystemExit("--screen must look like WIDTHxHEIGHT")
    elif product_type == "iPhone7,2":
        if window_width > window_height:
            screen_width, screen_height = 1334.0, 750.0
        else:
            screen_width, screen_height = 750.0, 1334.0
    else:
        screen_width, screen_height = window_width, window_height

    tap_x = raw_x * window_width / screen_width
    tap_y = raw_y * window_height / screen_height
    source = "pixels %gx%g" % (screen_width, screen_height)

tap_payload = {"x": tap_x, "y": tap_y}
attempts = [
    ("wda_tap", "POST", "/session/%s/wda/tap/0" % session_id, tap_payload),
    (
        "touch_perform",
        "POST",
        "/session/%s/touch/perform" % session_id,
        {"actions": [{"action": "tap", "options": {"x": tap_x, "y": tap_y}}]},
    ),
    (
        "w3c_actions",
        "POST",
        "/session/%s/actions" % session_id,
        {
            "actions": [
                {
                    "type": "pointer",
                    "id": "finger1",
                    "parameters": {"pointerType": "touch"},
                    "actions": [
                        {"type": "pointerMove", "duration": 0, "x": int(round(tap_x)), "y": int(round(tap_y))},
                        {"type": "pointerDown", "button": 0},
                        {"type": "pause", "duration": 50},
                        {"type": "pointerUp", "button": 0},
                    ],
                }
            ]
        },
    ),
]

last_error = None
for name, method, path, payload in attempts:
    status, body = request(method, path, payload)
    value = value_of(body)
    has_error = isinstance(value, dict) and value.get("error") is not None
    if status < 400 and not has_error:
        print(
            "Tapped %.2f,%.2f WDA points from %s input %.2f,%.2f using %s"
            % (tap_x, tap_y, source, raw_x, raw_y, name)
        )
        raise SystemExit(0)
    last_error = (name, status, body)

raise SystemExit("Tap failed. Last WDA response: %s" % (last_error,))
PY
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --pixels)
      COORD_MODE="pixels"
      shift
      ;;
    --points)
      COORD_MODE="points"
      shift
      ;;
    --screen)
      SCREEN_SIZE="${2:-}"
      if [ -z "$SCREEN_SIZE" ]; then
        echo "--screen requires WIDTHxHEIGHT" >&2
        exit 1
      fi
      shift 2
      ;;
    --no-iproxy)
      START_IPROXY=0
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  usage >&2
  exit 1
fi

X="$1"
Y="$2"
UDID="${3:-$UDID}"

need python3
need idevice_id
need idevicepair
need ideviceinfo

if [ -z "$UDID" ]; then
  UDID="$(idevice_id -l | head -n 1)"
fi

if [ -z "$UDID" ]; then
  echo "No USB iOS device found." >&2
  exit 1
fi

if ! idevicepair -u "$UDID" validate >/dev/null 2>&1; then
  echo "Device pairing is not valid. Unlock the iPhone, tap Trust if prompted, then retry." >&2
  exit 1
fi

PRODUCT_TYPE="$(ideviceinfo -u "$UDID" -k ProductType 2>/dev/null || true)"

start_iproxy_if_needed

if ! status_reachable; then
  cat >&2 <<EOF
WebDriverAgent is not reachable at $WDA_URL.

USB transport is available, but iOS does not provide a raw public "tap"
service like it does for screenshots. Coordinate taps require a small
automation runner, normally WebDriverAgent, installed and running on the
iPhone. Once WDA is running on device port $REMOTE_PORT, this script will
control it over USB through iproxy.
EOF
  exit 1
fi

run_tap
