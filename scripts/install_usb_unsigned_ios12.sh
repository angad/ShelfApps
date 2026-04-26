#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  . "$ROOT_DIR/.env"
  set +a
fi

DEFAULT_APP_DIR="$ROOT_DIR/apps/OverheadFlight"
APP_DIR="${APP_DIR:-}"
UDID="${IPHONE_UDID:-${IOS_DEVICE_UDID:-${UDID:-}}}"
BUILD_SDK_MARKER="${BUILD_SDK_MARKER:-17.2}"
BUILD_LD_MARKER="${BUILD_LD_MARKER:-1022.1}"

usage() {
  echo "Usage: $0 [app-dir] [udid]"
  echo "       $0 [udid]"
  echo
  echo "Default app-dir: apps/OverheadFlight"
  echo
  echo "Set IPHONE_UDID in .env to avoid passing a device id on the command line."
}

resolve_app_dir() {
  candidate="$1"
  if [ -d "$candidate" ]; then
    (CDPATH= cd -- "$candidate" && pwd)
    return
  fi

  if [ -d "$ROOT_DIR/$candidate" ]; then
    (CDPATH= cd -- "$ROOT_DIR/$candidate" && pwd)
    return
  fi

  return 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -n "${1:-}" ]; then
  if resolved="$(resolve_app_dir "$1")"; then
    APP_DIR="$resolved"
    UDID="${2:-$UDID}"
  else
    APP_DIR="${APP_DIR:-$DEFAULT_APP_DIR}"
    UDID="${1:-$UDID}"
  fi
else
  APP_DIR="${APP_DIR:-$DEFAULT_APP_DIR}"
fi

if [ ! -f "$APP_DIR/project.yml" ]; then
  echo "No project.yml found in app directory: $APP_DIR"
  exit 1
fi

read_project_value() {
  key="$1"
  awk -F': *' -v key="$key" '{
    field = $1
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", field)
    if (field == key) {
      value = $2
      gsub(/"/, "", value)
      print value
      exit
    }
  }' "$APP_DIR/project.yml"
}

PROJECT_NAME="${PROJECT_NAME:-$(read_project_value name)}"
APP_NAME="${APP_NAME:-$(read_project_value PRODUCT_NAME)}"
BUNDLE_ID="${BUNDLE_ID:-$(read_project_value PRODUCT_BUNDLE_IDENTIFIER)}"

if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME="$(basename "$APP_DIR")"
fi

if [ -z "$APP_NAME" ]; then
  APP_NAME="$PROJECT_NAME"
fi

if [ -z "$BUNDLE_ID" ]; then
  echo "Could not determine PRODUCT_BUNDLE_IDENTIFIER from $APP_DIR/project.yml."
  echo "Set BUNDLE_ID explicitly or add PRODUCT_BUNDLE_IDENTIFIER to the app target settings."
  exit 1
fi

if [ -z "$UDID" ]; then
  UDID="$(idevice_id -l | head -n 1)"
fi

if [ -z "$UDID" ]; then
  echo "No USB iOS device found."
  exit 1
fi

if ! command -v ldid >/dev/null 2>&1; then
  echo "ldid is required for this unsigned iOS 12 USB install path."
  echo "Install it with: brew install ldid-procursus"
  exit 1
fi

cd "$APP_DIR"

xcodegen generate
xcodebuild \
  -project "${PROJECT_NAME}.xcodeproj" \
  -target "$APP_NAME" \
  -sdk iphoneos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  clean \
  build

APP_PATH="build/Debug-iphoneos/${APP_NAME}.app"
BIN_PATH="${APP_PATH}/${APP_NAME}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-}"
if [ -z "$ENTITLEMENTS_PATH" ] && [ -f "$APP_DIR/entitlements.plist" ]; then
  ENTITLEMENTS_PATH="$APP_DIR/entitlements.plist"
fi
SIGN_ARG="-S"
if [ -n "$ENTITLEMENTS_PATH" ]; then
  SIGN_ARG="-S$ENTITLEMENTS_PATH"
fi

rm -rf "${APP_PATH}/_CodeSignature" "${BIN_PATH}.vtool"
xcrun vtool \
  -set-build-version ios 12.0 "$BUILD_SDK_MARKER" \
  -tool ld "$BUILD_LD_MARKER" \
  -replace \
  -output "${BIN_PATH}.vtool" \
  "$BIN_PATH"
mv "${BIN_PATH}.vtool" "$BIN_PATH"
chmod +x "$BIN_PATH"
ldid -Hsha1 -Hsha256 -P -Cadhoc -I"$BUNDLE_ID" "$SIGN_ARG" "$BIN_PATH"

find "$APP_PATH" -type f | while IFS= read -r candidate; do
  if [ "$candidate" = "$BIN_PATH" ]; then
    continue
  fi
  if file "$candidate" | grep -q 'Mach-O .*executable'; then
    chmod +x "$candidate"
    helper_id="${BUNDLE_ID}.$(basename "$candidate" | tr -c '[:alnum:].-' '_')"
    ldid -Hsha1 -Hsha256 -P -Cadhoc -I"$helper_id" "$SIGN_ARG" "$candidate"
  fi
done

rm -rf Payload "${APP_NAME}.ipa"
mkdir Payload
cp -R "$APP_PATH" Payload/
/usr/bin/zip -qry "${APP_NAME}.ipa" Payload

ideviceinstaller -u "$UDID" install "${APP_NAME}.ipa"
ideviceinstaller -u "$UDID" list --user | grep "$BUNDLE_ID"
