#!/usr/bin/env bash
# Builds the iroh client library (EtLink) from the etd submodule.
# Output (not in git): Vendor/etd/apple/EtLink/EtLinkFFI.xcframework and
# Vendor/etd/apple/EtLink/Sources/EtLink/et_link.swift.
# Needs rustup (stable-aarch64-apple-darwin) and Xcode. Run once after
# cloning, and again after the submodule moves.
set -euo pipefail
cd "$(dirname "$0")/.."
git submodule update --init Vendor/etd
exec Vendor/etd/scripts/build-ios.sh
