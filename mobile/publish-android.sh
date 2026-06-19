#!/usr/bin/env bash
set -euo pipefail

# Build a signed release APK and optionally create a GitHub release
#
# Usage:
#   ./publish-android.sh                    # build signed APK only
#   ./publish-android.sh --release v1.0.0   # build + create GitHub release
#
# Required env vars for signing:
#   export ANDROID_KEY_PASSWORD=<keystore-pass>
#   export ANDROID_STORE_PASSWORD=<keystore-pass>

MOBILE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${MOBILE_DIR}/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ALIAS="${ALIAS:-immich}"

TAG="${1:-}"
VERSION="${2:-}"

# Ensure flutter is on PATH
if ! command -v flutter &>/dev/null; then
  if [[ -d "$HOME/develop/flutter/bin" ]]; then
    export PATH="$HOME/develop/flutter/bin:$PATH"
  else
    echo "ERROR: flutter not found. Install Flutter or add it to PATH."
    exit 1
  fi
fi

echo "=== Publishing Immich Android ==="

echo ">>> Building signed release APK..."
cd "${MOBILE_DIR}"
flutter pub get 2>&1 | tail -1
dart run build_runner build --delete-conflicting-outputs 2>&1 | tail -1
flutter build apk --release

APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
APK_SIZE="$(du -h "${APK_PATH}" | cut -f1)"

echo ""
echo "=== Signed release APK built ==="
echo "  APK:  ${MOBILE_DIR}/${APK_PATH}"
echo "  Size: ${APK_SIZE}"

if [[ "${TAG}" == "--release" && -n "${VERSION}" ]]; then
  echo ""
  echo ">>> Creating GitHub release ${VERSION}..."
  cd "${REPO_ROOT}"
  gh release create "${VERSION}" \
    --title "Immich Mobile ${VERSION}" \
    --notes "Release ${VERSION}" \
    "${MOBILE_DIR}/${APK_PATH}#immich-${VERSION}-universal.apk"
  echo "=== GitHub release created ==="
  echo "  https://github.com/RyamosThomas/immich/releases/tag/${VERSION}"
fi

echo ""
echo "Done."
