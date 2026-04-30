#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  . "$ROOT_DIR/.env"
  set +a
fi

IOS12_DDI_URL="https://raw.githubusercontent.com/strengthen/DeviceSupport/87a0097b933ee9219b779837ab0c5c8e52027230/iOS/12.4.zip"
IOS12_DDI_SHA256="947db4635c625dc68f72b64443fc16005e8595f2c21632b9d586217cd47093b8"
CACHE_DIR="${IPHONE_SCREENSHOT_CACHE_DIR:-$HOME/Library/Caches/iphone6-device-support}"
TIMEOUT="${IPHONE_SCREENSHOT_TIMEOUT:-20}"
UDID="${IPHONE_UDID:-${IOS_DEVICE_UDID:-${UDID:-}}}"

usage() {
  echo "Usage: $0 [output.png] [udid]"
  echo
  echo "Captures a screenshot from a connected iPhone over USB."
  echo "Set IPHONE_UDID in .env to avoid passing a device id."
  echo "Default output: device_screenshots/iphone-YYYYmmdd-HHMMSS.png"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

find_developer_image_dir() {
  if [ -n "${IPHONE_DEVELOPER_IMAGE_DIR:-}" ]; then
    if [ -f "$IPHONE_DEVELOPER_IMAGE_DIR/DeveloperDiskImage.dmg" ] &&
       [ -f "$IPHONE_DEVELOPER_IMAGE_DIR/DeveloperDiskImage.dmg.signature" ]; then
      printf '%s\n' "$IPHONE_DEVELOPER_IMAGE_DIR"
      return 0
    fi
  fi

  if [ -d "$CACHE_DIR/12.4" ] &&
     [ -f "$CACHE_DIR/12.4/DeveloperDiskImage.dmg" ] &&
     [ -f "$CACHE_DIR/12.4/DeveloperDiskImage.dmg.signature" ]; then
    printf '%s\n' "$CACHE_DIR/12.4"
    return 0
  fi

  xcode_dev="$(xcode-select -p 2>/dev/null || true)"
  if [ -n "$xcode_dev" ]; then
    xcode_dir="$xcode_dev/Platforms/iPhoneOS.platform/DeviceSupport/12.4"
    if [ -f "$xcode_dir/DeveloperDiskImage.dmg" ] &&
       [ -f "$xcode_dir/DeveloperDiskImage.dmg.signature" ]; then
      printf '%s\n' "$xcode_dir"
      return 0
    fi
  fi

  return 1
}

ensure_developer_image_dir() {
  if image_dir="$(find_developer_image_dir)"; then
    printf '%s\n' "$image_dir"
    return 0
  fi

  need curl
  need unzip
  need shasum

  mkdir -p "$CACHE_DIR"
  zip_path="$CACHE_DIR/12.4.zip"
  tmp_zip="$CACHE_DIR/12.4.zip.tmp"

  echo "Downloading iOS 12.4 Developer Disk Image..." >&2
  curl -L --fail --silent --show-error -o "$tmp_zip" "$IOS12_DDI_URL"

  actual_sha="$(sha256_file "$tmp_zip")"
  if [ "$actual_sha" != "$IOS12_DDI_SHA256" ]; then
    rm -f "$tmp_zip"
    echo "Downloaded Developer Disk Image checksum did not match." >&2
    echo "Expected: $IOS12_DDI_SHA256" >&2
    echo "Actual:   $actual_sha" >&2
    exit 1
  fi

  rm -rf "$CACHE_DIR/12.4"
  mv "$tmp_zip" "$zip_path"
  unzip -q "$zip_path" -d "$CACHE_DIR"

  if [ ! -f "$CACHE_DIR/12.4/DeveloperDiskImage.dmg" ] ||
     [ ! -f "$CACHE_DIR/12.4/DeveloperDiskImage.dmg.signature" ]; then
    echo "Downloaded archive did not contain DeveloperDiskImage.dmg and signature." >&2
    exit 1
  fi

  printf '%s\n' "$CACHE_DIR/12.4"
}

mount_developer_image() {
  image_dir="$1"
  mount_log="$(mktemp "${TMPDIR:-/tmp}/iphone-image-mount.XXXXXX")"
  if ideviceimagemounter -u "$UDID" \
      "$image_dir/DeveloperDiskImage.dmg" \
      "$image_dir/DeveloperDiskImage.dmg.signature" >"$mount_log" 2>&1; then
    rm -f "$mount_log"
    return 0
  fi

  if grep -q 'already mounted at /Developer' "$mount_log"; then
    rm -f "$mount_log"
    return 0
  fi

  cat "$mount_log" >&2
  rm -f "$mount_log"
  return 1
}

capture_once() {
  output="$1"
  capture_log="$2"
  rm -f "$output"
  if perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
      idevicescreenshot -u "$UDID" "$output" >"$capture_log" 2>&1 &&
     [ -s "$output" ] &&
     file "$output" | grep -q 'PNG image data'; then
    return 0
  fi
  return 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

need idevice_id
need idevicepair
need ideviceinfo
need ideviceimagemounter
need idevicescreenshot
need file
need perl

OUTPUT="${1:-$ROOT_DIR/device_screenshots/iphone-$(date +%Y%m%d-%H%M%S).png}"
UDID="${2:-$UDID}"

if [ -z "$UDID" ]; then
  UDID="$(idevice_id -l | head -n 1)"
fi

if [ -z "$UDID" ]; then
  echo "No USB iOS device found." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

if ! idevicepair -u "$UDID" validate >/dev/null 2>&1; then
  echo "Device pairing is not valid. Unlock the iPhone, tap Trust if prompted, then retry." >&2
  exit 1
fi

product_version="$(ideviceinfo -u "$UDID" -k ProductVersion 2>/dev/null || true)"
product_type="$(ideviceinfo -u "$UDID" -k ProductType 2>/dev/null || true)"
echo "Capturing $product_type iOS $product_version ($UDID)"

log_path="$(mktemp "${TMPDIR:-/tmp}/iphone-screenshot.XXXXXX")"
if capture_once "$OUTPUT" "$log_path"; then
  rm -f "$log_path"
  echo "Screenshot saved to $OUTPUT"
  exit 0
fi

if grep -qi 'Developer disk image\|screenshotr service\|Invalid service' "$log_path"; then
  image_dir="$(ensure_developer_image_dir)"
  echo "Mounting Developer Disk Image from $image_dir"
  mount_developer_image "$image_dir"
else
  echo "Initial screenshot attempt failed; mounting Developer Disk Image and retrying." >&2
  image_dir="$(ensure_developer_image_dir)"
  mount_developer_image "$image_dir"
fi

if capture_once "$OUTPUT" "$log_path"; then
  rm -f "$log_path"
  echo "Screenshot saved to $OUTPUT"
  exit 0
fi

cat "$log_path" >&2
rm -f "$log_path"
echo "Screenshot capture failed." >&2
exit 1
