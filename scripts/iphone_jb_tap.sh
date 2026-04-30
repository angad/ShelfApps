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
REMOTE_HELPER="${IPHONE_JB_TAP_HELPER:-/usr/local/bin/iphone_tap_hid}"
BUILD_DIR="$ROOT_DIR/device_control"
COORD_MODE="pixels"
SCREEN_SIZE="${IPHONE_SCREENSHOT_SIZE:-750x1334}"
HOLD_MS="${IPHONE_TAP_HOLD_MS:-80}"
INSTALL_HELPER=0

usage() {
  echo "Usage: $0 [--install-helper] [--pixels|--points] [--screen WIDTHxHEIGHT] x y [udid]"
  echo
  echo "Taps a jailbroken iPhone without WebDriverAgent by running an on-device HID helper over SSH."
  echo "The phone must have OpenSSH or another sshd reachable through usbmux/iproxy."
  echo
  echo "Defaults:"
  echo "  remote ssh port: $SSH_PORT"
  echo "  local ssh port:  $LOCAL_SSH_PORT"
  echo "  ssh key:         $SSH_KEY"
  echo "  remote helper:   $REMOTE_HELPER"
  echo "  coordinate mode: screenshot pixels, $SCREEN_SIZE"
  echo
  echo "Examples:"
  echo "  $0 --install-helper 375 667"
  echo "  $0 375 667"
  echo "  $0 --points 187.5 333.5"
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
  IPROXY_LOG="${TMPDIR:-/tmp}/iphone6-usb-control/ssh-iproxy-$UDID-$LOCAL_SSH_PORT.log"
  IPROXY_PID="${TMPDIR:-/tmp}/iphone6-usb-control/ssh-iproxy-$UDID-$LOCAL_SSH_PORT.pid"

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

check_ssh() {
  if ssh_base 'printf ok' >/dev/null 2>&1; then
    return 0
  fi

  cat >&2 <<EOF
Could not run commands over SSH on the iPhone.

This no-WDA path needs jailbreak command execution and non-interactive auth.
SSH is normally Dropbear on port 44 for this phone. If auth fails, install
this Mac's key on the phone or set IPHONE_JB_SSH_KEY to a working private key.

If your jailbreak uses different ports:

  IPHONE_JB_SSH_PORT=22      # or 44/2222/etc.
  IPHONE_JB_SSH_USER=root    # or mobile

The script will connect over USB with iproxy, not over Wi-Fi.
EOF
  return 1
}

build_helper() {
  need xcrun
  need ldid
  mkdir -p "$BUILD_DIR"
  sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
  helper="$BUILD_DIR/iphone_tap_hid"
  entitlements="$BUILD_DIR/iphone_tap_hid.entitlements.plist"

  xcrun --sdk iphoneos clang \
    -arch arm64 \
    -miphoneos-version-min=12.0 \
    -isysroot "$sdk_path" \
    "$ROOT_DIR/scripts/iphone_tap_hid.c" \
    -framework CoreFoundation \
    -o "$helper"

  cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>platform-application</key>
  <true/>
  <key>com.apple.private.security.no-container</key>
  <true/>
  <key>com.apple.private.skip-library-validation</key>
  <true/>
  <key>com.apple.springboard.debugapplications</key>
  <true/>
</dict>
</plist>
PLIST

  ldid -S"$entitlements" "$helper"
  printf '%s\n' "$helper"
}

install_helper() {
  helper="$(build_helper)"
  need scp
  scp \
    -O \
    -i "$SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -P "$LOCAL_SSH_PORT" \
    -o ConnectTimeout=3 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$helper" "$SSH_USER@127.0.0.1:/tmp/iphone_tap_hid"
  ssh_base "mkdir -p '$(dirname "$REMOTE_HELPER")' && cp /tmp/iphone_tap_hid '$REMOTE_HELPER' && chmod 755 '$REMOTE_HELPER'"
}

remote_has_helper() {
  ssh_base "test -x '$REMOTE_HELPER'" >/dev/null 2>&1
}

to_points() {
  python3 - "$COORD_MODE" "$SCREEN_SIZE" "$X" "$Y" <<'PY'
import sys

mode, screen, x_raw, y_raw = sys.argv[1:5]
x = float(x_raw)
y = float(y_raw)

if mode == "points":
    print("%.3f %.3f" % (x, y))
    raise SystemExit(0)
else:
    try:
        screen_width, screen_height = [float(part) for part in screen.lower().split("x", 1)]
    except ValueError:
        raise SystemExit("--screen must look like WIDTHxHEIGHT")
    point_width = 375.0
    point_height = 667.0

if screen_width <= 0 or screen_height <= 0:
    raise SystemExit("screen dimensions must be positive")

if not (0.0 <= x <= screen_width and 0.0 <= y <= screen_height):
    raise SystemExit("tap coordinate is outside the configured screen: %.3f %.3f" % (x, y))

print("%.3f %.3f" % (x * point_width / screen_width, y * point_height / screen_height))
PY
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --install-helper)
      INSTALL_HELPER=1
      shift
      ;;
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
check_ssh

if [ "$INSTALL_HELPER" -eq 1 ]; then
  install_helper
fi

if ! remote_has_helper; then
  echo "Remote helper is not installed at $REMOTE_HELPER." >&2
  echo "Run: $0 --install-helper $X $Y" >&2
  exit 1
fi

set -- $(to_points)
PX="$1"
PY="$2"

ssh_base "'$REMOTE_HELPER' '$PX' '$PY' '$HOLD_MS'"
