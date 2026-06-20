#!/usr/bin/env bash
# scripts/build-release.sh
#
# One-shot Play-Store release build for ChowSA (POSIX / WSL / macOS).
#
# Mirrors scripts/build-release.ps1 — see that file for the why behind each
# flag. Usage:
#
#   ./scripts/build-release.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f android/key.properties ]; then
  echo "ERROR: android/key.properties is missing — release builds will fall back to the debug signature and Play will reject the AAB. Create it before running this script." >&2
  exit 1
fi

echo "==> flutter clean"
flutter clean

echo "==> flutter pub get"
flutter pub get

echo "==> flutter analyze"
flutter analyze

echo "==> flutter build appbundle (production)"
flutter build appbundle \
  --release \
  --dart-define=IS_PRODUCTION=true \
  -PIS_PRODUCTION=true

AAB="build/app/outputs/bundle/release/app-release.aab"
if [ -f "$AAB" ]; then
  size=$(du -h "$AAB" | cut -f1)
  echo
  echo "Release bundle ready: $AAB ($size)"
  echo "Upload to Play Console → Internal testing track first."
else
  echo "ERROR: build reported success but $AAB was not found." >&2
  exit 1
fi
