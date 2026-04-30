#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  . "$ROOT_DIR/.env"
  set +a
fi

UDID="${IPHONE_UDID:-${IOS_DEVICE_UDID:-${UDID:-}}}"
SSH_USER="${IPHONE_JB_SSH_USER:-root}"
SSH_PORT="${IPHONE_JB_SSH_PORT:-44}"
LOCAL_SSH_PORT="${IPHONE_JB_LOCAL_SSH_PORT:-30044}"
SSH_KEY="${IPHONE_JB_SSH_KEY:-$HOME/.ssh/iphone6_jb_control}"

usage() {
  echo "Usage:"
  echo "  $0 ensure"
  echo "  $0 size"
  echo "  $0 open BUNDLE_ID"
  echo "  $0 tap X Y [hold-ms]"
  echo "  $0 swipe X1 Y1 X2 Y2 [duration-ms]"
  echo "  $0 type TEXT [delay-sec]"
  echo
  echo "Controls a jailbroken iPhone over USB using ZXTouch, no WDA required."
  echo "Coordinates are screenshot pixels, e.g. iPhone 6 portrait is 750x1334."
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

start_iproxy() {
  need iproxy
  mkdir -p "${TMPDIR:-/tmp}/iphone6-usb-control"
  IPROXY_LOG="${TMPDIR:-/tmp}/iphone6-usb-control/zxtouch-ssh-iproxy-$UDID-$LOCAL_SSH_PORT.log"
  IPROXY_PID="${TMPDIR:-/tmp}/iphone6-usb-control/zxtouch-ssh-iproxy-$UDID-$LOCAL_SSH_PORT.pid"

  if [ -f "$IPROXY_PID" ]; then
    old_pid="$(cat "$IPROXY_PID" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      return 0
    fi
  fi

  iproxy "$LOCAL_SSH_PORT" "$SSH_PORT" -u "$UDID" >"$IPROXY_LOG" 2>&1 &
  echo "$!" > "$IPROXY_PID"
  sleep 0.5
}

ssh_base() {
  if [ -f "$SSH_KEY" ]; then
    ssh \
      -i "$SSH_KEY" \
      -o IdentitiesOnly=yes \
      -o BatchMode=yes \
      -p "$LOCAL_SSH_PORT" \
      -o ConnectTimeout=3 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "$SSH_USER@127.0.0.1" "$@"
  else
    ssh \
      -o BatchMode=yes \
      -p "$LOCAL_SSH_PORT" \
      -o ConnectTimeout=3 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "$SSH_USER@127.0.0.1" "$@"
  fi
}

remote_python() {
  ssh_base python3 - "$@"
}

ensure_zxtouch() {
  if remote_python <<'PY' >/dev/null 2>&1
import socket
from zxtouch.client import zxtouch
s = socket.socket()
s.settimeout(1.0)
s.connect(("127.0.0.1", 6000))
s.close()
PY
  then
    return 0
  fi

  ssh_base 'uiopen com.zjx.zxtouch >/dev/null 2>&1 || true'
  sleep 1

  remote_python <<'PY'
import socket
import sys
import time

deadline = time.time() + 8
last_error = None
while time.time() < deadline:
    try:
        from zxtouch.client import zxtouch  # noqa: F401
        s = socket.socket()
        s.settimeout(1.0)
        s.connect(("127.0.0.1", 6000))
        s.close()
        print("ZXTouch service is listening on 127.0.0.1:6000")
        sys.exit(0)
    except Exception as exc:
        last_error = exc
        time.sleep(0.5)

print("ZXTouch service is not reachable: %r" % (last_error,), file=sys.stderr)
sys.exit(1)
PY
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -lt 1 ]; then
  usage
  exit 0
fi

COMMAND="$1"
shift

need idevice_id
need idevicepair
need ssh

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

start_iproxy

case "$COMMAND" in
  ensure)
    ensure_zxtouch
    ;;
  size)
    ensure_zxtouch >/dev/null
    remote_python <<'PY'
from zxtouch.client import zxtouch
z = zxtouch("127.0.0.1")
print(z.get_screen_size())
print(z.get_screen_scale())
print(z.get_screen_orientation())
PY
    ;;
  open)
    if [ $# -ne 1 ]; then
      usage >&2
      exit 1
    fi
    ensure_zxtouch >/dev/null
    remote_python "$1" <<'PY'
import sys
from zxtouch.client import zxtouch
z = zxtouch("127.0.0.1")
print(z.switch_to_app(sys.argv[1]))
PY
    ;;
  tap)
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
      usage >&2
      exit 1
    fi
    ensure_zxtouch >/dev/null
    remote_python "$1" "$2" "${3:-80}" <<'PY'
import sys
import time
from zxtouch.client import zxtouch
from zxtouch.touchtypes import TOUCH_DOWN, TOUCH_UP

x = float(sys.argv[1])
y = float(sys.argv[2])
hold_ms = max(10, int(float(sys.argv[3])))
z = zxtouch("127.0.0.1")
z.touch(TOUCH_DOWN, 1, x, y)
time.sleep(hold_ms / 1000.0)
z.touch(TOUCH_UP, 1, x, y)
print("tap %.1f %.1f %dms" % (x, y, hold_ms))
PY
    ;;
  swipe)
    if [ $# -lt 4 ] || [ $# -gt 5 ]; then
      usage >&2
      exit 1
    fi
    ensure_zxtouch >/dev/null
    remote_python "$1" "$2" "$3" "$4" "${5:-450}" <<'PY'
import sys
import time
from zxtouch.client import zxtouch
from zxtouch.touchtypes import TOUCH_DOWN, TOUCH_MOVE, TOUCH_UP

x1 = float(sys.argv[1])
y1 = float(sys.argv[2])
x2 = float(sys.argv[3])
y2 = float(sys.argv[4])
duration_ms = max(80, int(float(sys.argv[5])))
steps = 12
z = zxtouch("127.0.0.1")
z.touch(TOUCH_DOWN, 1, x1, y1)
for step in range(1, steps):
    t = step / float(steps)
    z.touch(TOUCH_MOVE, 1, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
    time.sleep(duration_ms / 1000.0 / steps)
z.touch(TOUCH_UP, 1, x2, y2)
print("swipe %.1f %.1f %.1f %.1f %dms" % (x1, y1, x2, y2, duration_ms))
PY
    ;;
  type)
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
      usage >&2
      exit 1
    fi
    ensure_zxtouch >/dev/null
    encoded_text="$(printf '%s' "$1" | base64 | tr -d '\n')"
    remote_python "$encoded_text" "${2:-0.16}" <<'PY'
import base64
import sys
import time
from zxtouch.client import zxtouch

text = base64.b64decode(sys.argv[1]).decode("utf-8")
delay = max(0.03, float(sys.argv[2]))
for ch in text:
    z = zxtouch("127.0.0.1")
    z.insert_text(ch)
    time.sleep(delay)
print("typed %d characters" % len(text))
PY
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac
