#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail=0

tracked_and_stageable_files() {
  git ls-files --cached --others --exclude-standard
}

report() {
  fail=1
  printf '%s\n' "$1" >&2
}

check_forbidden_paths() {
  tracked_and_stageable_files | while IFS= read -r path; do
    case "$path" in
      .DS_Store|*/.DS_Store)
        printf 'forbidden macOS metadata file: %s\n' "$path"
        ;;
      *.log|*.ips|*.ips.ca|*_syslog*.txt|*.xcresult|*.xcresult/*)
        printf 'forbidden log/diagnostic file: %s\n' "$path"
        ;;
      *.ipa|*.app|*.dSYM/*|*.xcarchive/*|*.xcodeproj/*|*.xcworkspace/*)
        printf 'forbidden generated path: %s\n' "$path"
        ;;
      build/*|*/build/*|Payload/*|*/Payload/*)
        printf 'forbidden build/package path: %s\n' "$path"
        ;;
      diagnostics/*|*/diagnostics/*|device_screenshots/*|device_control/*|device_crashes/*|device_media/*)
        printf 'forbidden local device artifact: %s\n' "$path"
        ;;
      apps/CodexMobile/CodexMobile/Resources/codex|apps/CodexMobile/CodexMobile/Resources/codex_probe)
        printf 'forbidden CodexMobile local binary: %s\n' "$path"
        ;;
      apps/CodexMobile/entitlements.plist)
        printf 'forbidden local jailbreak entitlement file: %s\n' "$path"
        ;;
      *Cookies.json|*cookies.json|*Cookie*.json|*cookie*.json)
        printf 'forbidden cookie/private data file: %s\n' "$path"
        ;;
      .env|.env.*)
        if [ "$path" != ".env.example" ]; then
          printf 'forbidden local env file: %s\n' "$path"
        fi
        ;;
    esac
  done
}

forbidden_paths="$(check_forbidden_paths)"
if [ -n "$forbidden_paths" ]; then
  report "$forbidden_paths"
fi

secret_hits="$(
  tracked_and_stageable_files |
    grep -Ev '(^|/)(build|Payload|diagnostics|device_screenshots|device_control|device_crashes|device_media)/' |
    xargs grep -nI -E \
      'sk-[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|refresh_token[[:space:]]*[=:][[:space:]]*[^[:space:]]+|device_code[[:space:]]*[=:][[:space:]]*[^[:space:]]+|IPHONE_UDID[[:space:]]*=[[:space:]]*[A-Za-z0-9-]{10,}|OPENAI_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]+' \
      2>/dev/null || true
)"
if [ -n "$secret_hits" ]; then
  report "possible secret or device identifier in stageable files:
$secret_hits"
fi

if [ "$fail" -ne 0 ]; then
  printf '\nOpen-source hygiene check failed.\n' >&2
  exit 1
fi

printf 'Open-source hygiene check passed.\n'
