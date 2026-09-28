#!/bin/bash
# Fails unless FoundationModels (Apple's on-device model) is weak-linked in the app binary and the app
# still targets macOS 14. A strong link would make the app crash at launch on macOS 14 and 15.
set -euo pipefail
BIN="$1"
status=0
for arch in $(lipo -archs "$BIN"); do
  LOADS="$(otool -arch "$arch" -l "$BIN")"
  KIND="$(echo "$LOADS" | grep -B2 'FoundationModels.framework' | grep -o 'LC_LOAD[A-Z_]*DYLIB' | head -1 || true)"
  MINOS="$(echo "$LOADS" | grep -A4 LC_BUILD_VERSION | awk '/minos/ {print $2; exit}')"
  echo "$arch: FoundationModels ${KIND:-not linked}, minos $MINOS"
  if [ "$KIND" = "LC_LOAD_DYLIB" ]; then echo "::error::FoundationModels is strongly linked in the $arch slice"; status=1; fi
  if [ "$arch" = "arm64" ] && [ "$KIND" != "LC_LOAD_WEAK_DYLIB" ]; then echo "::error::FoundationModels is not weak-linked in the arm64 slice"; status=1; fi
  if [ "$MINOS" != "14.0" ]; then echo "::error::$arch slice targets macOS $MINOS, expected 14.0"; status=1; fi
done
exit $status
