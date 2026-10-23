#!/usr/bin/env bash
# Builds etd and etd-ssh for Apple silicon from Vendor/etd (the same commit
# as EtLink), for E.T. for macOS (docs/PLAN-macos.md §4.1).
#   scripts/build-etd-mac.sh            → prints the directory with both
#   scripts/build-etd-mac.sh <app>      → also copies them into <app>/Contents/MacOS
# Xcode runs it as a build phase of ET-mac.
set -euo pipefail
cd "$(dirname "$0")/../Vendor/etd"
export PATH="$HOME/.cargo/bin:$PATH"
TC="${RUST_TOOLCHAIN:-stable-aarch64-apple-darwin}"
# The C parts (ring) need the macOS SDK, also from inside an Xcode build.
unset IPHONEOS_DEPLOYMENT_TARGET 2>/dev/null || true
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export SDKROOT MACOSX_DEPLOYMENT_TARGET=15.0
cargo "+$TC" build --release -p etd --bin etd --bin etd-ssh --target aarch64-apple-darwin >&2
OUT="$PWD/target/aarch64-apple-darwin/release"
if [ $# -ge 1 ]; then
  DEST="$1/Contents/MacOS"
  mkdir -p "$DEST"
  cp -f "$OUT/etd" "$OUT/etd-ssh" "$DEST/"
fi
echo "$OUT"
