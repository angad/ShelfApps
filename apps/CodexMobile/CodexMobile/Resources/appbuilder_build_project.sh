#!/bin/sh
set -eu

PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

CONF="$PROJECT_DIR/appbuilder.conf"
if [ -f "$CONF" ]; then
  # The Codex agent owns this project directory. The config is intentionally
  # shell-compatible so app projects can stay lightweight on iOS 12.
  # shellcheck disable=SC1090
  . "$CONF"
fi

base_name="$(basename "$PROJECT_DIR")"
APP_NAME="${APP_NAME:-$base_name}"
APP_NAME="$(printf '%s' "$APP_NAME" | tr -cd 'A-Za-z0-9_-')"
if [ -z "$APP_NAME" ]; then
  APP_NAME="CodexBuilt"
fi

slug="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
if [ -z "$slug" ]; then
  slug="codexbuilt"
fi
BUNDLE_ID="${BUNDLE_ID:-com.angad.generated.$slug}"

SRC_DIR="${SRC_DIR:-Source}"
RESOURCE_DIR="${RESOURCE_DIR:-Resources}"
FRAMEWORKS="${FRAMEWORKS:-UIKit Foundation QuartzCore CoreGraphics}"
SDK="${APPBUILDER_SDK:-/var/mobile/sdks/iPhoneOS12.4.sdk}"
if [ ! -d "$SDK" ]; then
  SDK="/var/mobile/sdks/iPhoneOS.sdk"
fi

WORK_ROOT="/var/mobile/AppBuilder/Projects/$APP_NAME"
OBJECTS="$WORK_ROOT/Objects"
BUILD="$WORK_ROOT/Build"
APP="$BUILD/$APP_NAME.app"
LOG="$WORK_ROOT/build.log"

rm -rf "$WORK_ROOT"
mkdir -p "$OBJECTS" "$BUILD"
exec > "$LOG" 2>&1

printf "[builder] project=%s\n" "$PROJECT_DIR"
printf "[builder] app=%s bundle=%s\n" "$APP_NAME" "$BUNDLE_ID"
printf "[builder] sdk=%s\n" "$SDK"

cd "$PROJECT_DIR"
if [ ! -d "$SRC_DIR" ]; then
  printf "error: source directory not found: %s\n" "$SRC_DIR" >&2
  exit 2
fi

set --
index=0
for source in $(find "$SRC_DIR" -type f -name '*.m' | sort); do
  index=$((index + 1))
  obj="$OBJECTS/$index.o"
  printf "[builder] compiling %s\n" "$source"
  # Keep source paths simple in generated projects; spaces are intentionally
  # unsupported by the lightweight POSIX shell build path.
  if [ -d "$PROJECT_DIR/Headers" ]; then
    clang -arch arm64 -miphoneos-version-min=12.0 -isysroot "$SDK" -fobjc-arc -I"$PROJECT_DIR/$SRC_DIR" -I"$PROJECT_DIR/Headers" -c "$source" -o "$obj"
  else
    clang -arch arm64 -miphoneos-version-min=12.0 -isysroot "$SDK" -fobjc-arc -I"$PROJECT_DIR/$SRC_DIR" -c "$source" -o "$obj"
  fi
  set -- "$@" "$obj"
done

if [ "$#" -eq 0 ]; then
  printf "error: no Objective-C .m files found under %s\n" "$SRC_DIR" >&2
  exit 2
fi

framework_args=""
for framework in $FRAMEWORKS; do
  framework_args="$framework_args -framework $framework"
done

printf "[builder] linking\n"
# shellcheck disable=SC2086
clang -arch arm64 -miphoneos-version-min=12.0 \
  -isysroot "$SDK" \
  -F"$SDK/System/Library/Frameworks" \
  "$@" \
  -o "$BUILD/$APP_NAME" \
  $framework_args

printf "[builder] packaging %s\n" "$APP"
mkdir -p "$APP"
cp "$BUILD/$APP_NAME" "$APP/$APP_NAME"

if [ -d "$PROJECT_DIR/$RESOURCE_DIR" ]; then
  printf "[builder] copying resources\n"
  (cd "$PROJECT_DIR/$RESOURCE_DIR" && tar cf - .) | (cd "$APP" && tar xf -)
fi

INFO_SOURCE=""
if [ -f "$PROJECT_DIR/Info.plist" ]; then
  INFO_SOURCE="$PROJECT_DIR/Info.plist"
elif [ -f "$PROJECT_DIR/$SRC_DIR/Info.plist" ]; then
  INFO_SOURCE="$PROJECT_DIR/$SRC_DIR/Info.plist"
fi

if [ -n "$INFO_SOURCE" ]; then
  sed \
    -e "s/__APP_NAME__/$APP_NAME/g" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__EXECUTABLE__/$APP_NAME/g" \
    "$INFO_SOURCE" > "$APP/Info.plist"
else
  cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFiles</key>
  <array>
    <string>Icon.png</string>
    <string>Icon-29@2x.png</string>
    <string>Icon-40@2x.png</string>
    <string>Icon-60@2x.png</string>
    <string>Icon-76@2x.png</string>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSRequiresIPhoneOS</key>
  <true/>
  <key>MinimumOSVersion</key>
  <string>12.0</string>
  <key>UIDeviceFamily</key>
  <array>
    <integer>1</integer>
  </array>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
  </array>
</dict>
</plist>
EOF
fi

printf 'APPL????' > "$APP/PkgInfo"
chmod 755 "$APP/$APP_NAME"
ldid -Hsha1 -Hsha256 -P -Cadhoc -I"$BUNDLE_ID" -S "$APP/$APP_NAME"

INSTALL_HELPER="/var/mobile/AppBuilder/bin/appbuilder_install_helper"
if [ -x "$INSTALL_HELPER" ]; then
  "$INSTALL_HELPER" "$APP" "$APP_NAME" "$BUNDLE_ID"
else
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  uicache -p "/Applications/$APP_NAME.app" || uicache
  uiopen "$BUNDLE_ID" || true
fi

printf "[builder] done app=%s bundle=%s log=%s\n" "/Applications/$APP_NAME.app" "$BUNDLE_ID" "$LOG"
