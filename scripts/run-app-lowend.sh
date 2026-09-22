#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TimbreDock"
APP_DIR="${LOWEND_APP_DIR:-$ROOT/build/LowEndCircuit_artefacts/Release/NativeSystemAudio/$APP_NAME.app}"
APP="$APP_DIR/Contents/MacOS/$APP_NAME"
BUNDLE_ID="${1:-}"

if [ ! -x "$APP" ]; then
    echo "Native system-audio app was not found. Build it first:"
    echo "  ./scripts/build-native-system-audio-app.sh"
    exit 1
fi

if [ -z "$BUNDLE_ID" ]; then
    echo "Usage: scripts/run-app-lowend.sh com.example.AppBundleID"
    echo
    echo "Running apps:"
    "$APP" --list-apps
    exit 1
fi

shift
exec "$APP" --bundle-id "$BUNDLE_ID" "$@"
