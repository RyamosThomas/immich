#!/usr/bin/env bash
set -euo pipefail

# Android build script for Immich mobile app
#
# Usage:
#   ./build-android.sh          # debug build (default)
#   ./build-android.sh release  # signed release build
#   ./build-android.sh debug    # explicit debug build
#
# For release builds, set signing env vars:
#   export ANDROID_KEY_PASSWORD=<keystore-pass>
#   export ANDROID_STORE_PASSWORD=<keystore-pass>

MODE="${1:-debug}"
MOBILE_DIR="$(cd "$(dirname "$0")" && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ALIAS="${ALIAS:-immich}"

# Ensure flutter is on PATH
if ! command -v flutter &>/dev/null; then
  if [[ -d "$HOME/develop/flutter/bin" ]]; then
    export PATH="$HOME/develop/flutter/bin:$PATH"
  else
    echo "ERROR: flutter not found. Install Flutter or add it to PATH."
    exit 1
  fi
fi

echo "=== Building Immich Android (${MODE}) ==="
echo "  Flutter:  $(flutter --version 2>/dev/null | head -1)"
echo "  Android:  ${ANDROID_HOME}"
echo ""

cd "${MOBILE_DIR}"

echo ">>> Getting dependencies..."
flutter pub get 2>&1 | tail -1

echo ">>> Running code generation..."
dart run build_runner build --delete-conflicting-outputs 2>&1 | tail -1

if [[ "${MODE}" == "release" ]]; then
  echo ">>> Building release APK..."
  flutter build apk --release
  APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
else
  echo ">>> Building debug APK..."
  flutter build apk --debug
  APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
fi

echo ""
echo "=== ${MODE^} build complete ==="
echo "  APK:  ${MOBILE_DIR}/${APK_PATH}"
echo "  Size: $(du -h "${APK_PATH}" | cut -f1)"
echo ""
echo "Install on device:"
echo "  adb install ${APK_PATH}"
