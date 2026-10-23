#!/usr/bin/env bash
# Xcode build phase of ET-mac: etd + etd-ssh into Contents/MacOS, the
# login item's plist into Contents/Library/LaunchAgents, both binaries signed
# with the app's identity (hardened runtime when it is a real identity).
set -euo pipefail
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
"$SRCROOT/../scripts/build-etd-mac.sh" "$APP" > /dev/null
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp -f "$SRCROOT/Mac/LaunchAgents/xyz.ericsharma.et.etd.plist" "$APP/Contents/Library/LaunchAgents/"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
for bin in etd etd-ssh; do
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP/Contents/MacOS/$bin"
  else
    # A Developer ID build (scripts/mac-release) is notarized: secure timestamp.
    TS="--timestamp=none"
    case "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" in *"Developer ID"*) TS="--timestamp" ;; esac
    codesign --force --sign "$IDENTITY" --options runtime $TS "$APP/Contents/MacOS/$bin"
  fi
done
