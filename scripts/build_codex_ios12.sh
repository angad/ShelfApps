#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

CODEX_REPO="${CODEX_REPO:-$HOME/workspace/codex}"
CODEX_RS_DIR="${CODEX_RS_DIR:-}"
TARGET="${CODEX_IOS_TARGET:-aarch64-apple-ios}"
MIN_IOS="${CODEX_IOS_MIN_VERSION:-12.0}"
PROFILE="release"
COPY_OUTPUT=1
SKIP_BUILD=0
OUTPUT_PATH="$ROOT_DIR/apps/CodexMobile/CodexMobile/Resources/codex"

usage() {
  cat <<EOF
Usage: $0 [options]

Cross-compile the official Codex Rust CLI for an owned iOS 12 arm64 device and
copy the resulting binary into CodexMobile's ignored local resource slot.

Options:
  --codex-repo PATH     Path to the official Codex checkout. Default: $CODEX_REPO
  --codex-rs PATH       Path to codex-rs. Overrides --codex-repo/codex-rs.
  --target TRIPLE       Rust target triple. Default: $TARGET
  --min-ios VERSION     iOS deployment target. Default: $MIN_IOS
  --debug               Build debug profile instead of release.
  --output PATH         Copy binary to PATH. Default: $OUTPUT_PATH
  --no-copy             Build and verify only; do not copy into CodexMobile.
  --skip-build          Verify/copy an already built target artifact.
  -h, --help            Show this help.

Environment:
  CODEX_REPO
  CODEX_RS_DIR
  CODEX_IOS_TARGET
  CODEX_IOS_MIN_VERSION
  RUSTFLAGS             Appended after this script's required iOS link flags.

The output binary is intentionally ignored by Git:
  apps/CodexMobile/CodexMobile/Resources/codex
EOF
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --codex-repo)
      CODEX_REPO="$2"
      shift 2
      ;;
    --codex-rs)
      CODEX_RS_DIR="$2"
      shift 2
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    --min-ios)
      MIN_IOS="$2"
      shift 2
      ;;
    --debug)
      PROFILE="debug"
      shift
      ;;
    --output)
      OUTPUT_PATH="$2"
      COPY_OUTPUT=1
      shift 2
      ;;
    --no-copy)
      COPY_OUTPUT=0
      shift
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$CODEX_RS_DIR" ]; then
  CODEX_RS_DIR="$CODEX_REPO/codex-rs"
fi

if [ ! -f "$CODEX_RS_DIR/Cargo.toml" ]; then
  echo "Codex Rust workspace not found: $CODEX_RS_DIR" >&2
  echo "Clone the official Codex repo, or pass --codex-repo /path/to/codex." >&2
  exit 2
fi

if [ ! -f "$CODEX_RS_DIR/code-mode/src/runtime_stub.rs" ] ||
   ! grep -q 'target_os = "ios"' "$CODEX_RS_DIR/code-mode/src/lib.rs" 2>/dev/null; then
  cat >&2 <<EOF
[codex-ios] warning: this Codex checkout does not appear to contain the iOS
compatibility stubs used by the known-good build.

The known-good checkout is the official OpenAI Codex repository plus small local
iOS portability edits:
  - disable v8/deno_core_icudata code-mode runtime on iOS
  - provide code-mode runtime/service stubs for iOS
  - disable arboard clipboard support on iOS
  - include iOS in process-hardening cfg gates where needed

Continuing anyway; if cargo fails, apply equivalent iOS portability patches in
the Codex checkout and rerun this script. See:
  $ROOT_DIR/docs/codex-ios-portability.md
EOF
fi

need cargo
need rustc
need rustup
need xcrun
need file
need otool

case "$TARGET" in
  aarch64-apple-ios)
    ;;
  *)
    echo "This script is written for physical arm64 iOS devices; got target: $TARGET" >&2
    exit 2
    ;;
esac

if ! rustup target list --installed | grep -qx "$TARGET"; then
  echo "[codex-ios] installing Rust target $TARGET"
  rustup target add "$TARGET"
fi

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
CLANGXX="$(xcrun --sdk iphoneos --find clang++)"
AR="$(xcrun --sdk iphoneos --find ar)"

export SDKROOT
export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS"
export CC_aarch64_apple_ios="$CLANG"
export CXX_aarch64_apple_ios="$CLANGXX"
export AR_aarch64_apple_ios="$AR"
export CFLAGS_aarch64_apple_ios="-arch arm64 -isysroot $SDKROOT -miphoneos-version-min=$MIN_IOS"
export CXXFLAGS_aarch64_apple_ios="$CFLAGS_aarch64_apple_ios"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$CLANG"

required_rustflags="-C link-arg=-target -C link-arg=arm64-apple-ios$MIN_IOS -C link-arg=-isysroot -C link-arg=$SDKROOT -C link-arg=-miphoneos-version-min=$MIN_IOS"
if [ -n "${RUSTFLAGS:-}" ]; then
  export RUSTFLAGS="$required_rustflags $RUSTFLAGS"
else
  export RUSTFLAGS="$required_rustflags"
fi

echo "[codex-ios] codex-rs: $CODEX_RS_DIR"
echo "[codex-ios] target:   $TARGET"
echo "[codex-ios] min iOS:  $MIN_IOS"
echo "[codex-ios] sdk:      $SDKROOT"
echo "[codex-ios] profile:  $PROFILE"

if [ "$SKIP_BUILD" -ne 1 ]; then
  cargo_args="build -p codex-cli --bin codex --target $TARGET"
  if [ "$PROFILE" = "release" ]; then
    cargo_args="$cargo_args --release"
  fi
  # shellcheck disable=SC2086
  (cd "$CODEX_RS_DIR" && cargo $cargo_args)
fi

BUILT_BINARY="$CODEX_RS_DIR/target/$TARGET/$PROFILE/codex"
if [ ! -x "$BUILT_BINARY" ]; then
  echo "Built Codex binary not found or not executable: $BUILT_BINARY" >&2
  exit 1
fi

if ! file "$BUILT_BINARY" | grep -q 'Mach-O 64-bit executable arm64'; then
  echo "Output is not an arm64 iOS-style Mach-O executable:" >&2
  file "$BUILT_BINARY" >&2
  exit 1
fi

MINOS="$(otool -l "$BUILT_BINARY" | awk '/LC_BUILD_VERSION/{seen=1} seen && /minos/{print $2; exit}')"
if [ -n "$MINOS" ] && [ "$MINOS" != "$MIN_IOS" ]; then
  echo "Unexpected LC_BUILD_VERSION minos: $MINOS, expected $MIN_IOS" >&2
  echo "Check RUSTFLAGS and IPHONEOS_DEPLOYMENT_TARGET before installing on iOS 12." >&2
  exit 1
fi

echo "[codex-ios] verified: $(file "$BUILT_BINARY")"
otool -l "$BUILT_BINARY" | awk '/LC_BUILD_VERSION/{seen=1; print; next} seen && /platform|minos|sdk/{print} seen && /ntools/{exit}'

if [ "$COPY_OUTPUT" -eq 1 ]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  cp "$BUILT_BINARY" "$OUTPUT_PATH"
  chmod 755 "$OUTPUT_PATH"
  echo "[codex-ios] copied to: $OUTPUT_PATH"
  echo "[codex-ios] sha256: $(shasum -a 256 "$OUTPUT_PATH" | awk '{print $1}')"
else
  echo "[codex-ios] built at: $BUILT_BINARY"
  echo "[codex-ios] sha256: $(shasum -a 256 "$BUILT_BINARY" | awk '{print $1}')"
fi
