#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT/SystemAudioProcessor"
BUILD_DIR="${LOWEND_BUILD_DIR:-$ROOT/build/SystemAudioProcessor}"
# The visible bundle carries the v0.4.0 product name. The parent directory shape
# (build/LowEndCircuit_artefacts/Release/NativeSystemAudio) and the internal
# package/library/CLI names stay unchanged for script and release compatibility.
APP_NAME="TimbreDock"
FINAL_APP_DIR="${LOWEND_APP_DIR:-$ROOT/build/LowEndCircuit_artefacts/Release/NativeSystemAudio/$APP_NAME.app}"
SCRATCH_DIR="${LOWEND_SWIFT_SCRATCH_DIR:-$BUILD_DIR/.build}"
SHADER_SOURCE="$PACKAGE_DIR/Shaders/SpectrumShaders.metal"
ICON_SOURCE="$PACKAGE_DIR/Assets/LowEndNativeAudioIcon.icns"
LOCALIZATION_DIR="$PACKAGE_DIR/Assets/Localization"
APP_VERSION="0.4.0"

# Absolute overrides make isolated QA independent of the caller's directory.
for output_path in "$BUILD_DIR" "$FINAL_APP_DIR" "$SCRATCH_DIR"; do
    case "$output_path" in
        /*) ;;
        *) echo "Build/app/scratch paths must be absolute: $output_path" >&2; exit 1 ;;
    esac
done
case "$FINAL_APP_DIR" in
    */*.app) ;;
    *) echo "LOWEND_APP_DIR must name an .app bundle" >&2; exit 1 ;;
esac
APP_PARENT=$(dirname "$FINAL_APP_DIR")
mkdir -p "$BUILD_DIR" "$APP_PARENT"
STAGING_ROOT=$(mktemp -d "$APP_PARENT/.lowend-stage.XXXXXX")
APP_DIR="$STAGING_ROOT/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
BACKUP_DIR=""
cleanup() {
    if [ -n "$BACKUP_DIR" ] && [ -e "$BACKUP_DIR" ] && [ ! -e "$FINAL_APP_DIR" ]; then
        mv "$BACKUP_DIR" "$FINAL_APP_DIR"
    fi
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A shallow clone's commit count is not globally monotonic. CI can supply its
# run number; the hash+dirty state is the authoritative source identity.
BUILD_NUMBER="${LOWEND_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)}"
case "$BUILD_NUMBER" in ''|*[!0-9]*) echo "LOWEND_BUILD_NUMBER must contain digits only" >&2; exit 1 ;; esac
GIT_COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
GIT_DIRTY=""
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
    GIT_DIRTY="-dirty"
fi
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_ID="${GIT_COMMIT}${GIT_DIRTY} · ${BUILD_DATE}"

# Explicit overrides allow an installed compatible SDK without changing the
# system developer directory or silently downgrading the default SDK.
swift_build() {
    if [ -n "${LOWEND_SWIFT_SDK:-}" ]; then
        set -- --sdk "$LOWEND_SWIFT_SDK" "$@"
    fi
    if [ -n "${LOWEND_SWIFT_BUILD_SYSTEM:-}" ]; then
        set -- --build-system "$LOWEND_SWIFT_BUILD_SYSTEM" "$@"
    fi
    swift build --package-path "$PACKAGE_DIR" -c release --scratch-path "$SCRATCH_DIR" "$@"
}
swift_build --product SystemAudioProcessor
swift_build --product LowEndSupportChecks
BIN_DIR=$(swift_build --show-bin-path)
"$BIN_DIR/LowEndSupportChecks"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/SystemAudioProcessor" "$MACOS_DIR/$APP_NAME"
cp "$SHADER_SOURCE" "$RESOURCES_DIR/SpectrumShaders.metal"
cp "$ICON_SOURCE" "$RESOURCES_DIR/LowEndNativeAudioIcon.icns"
# AppKit resolves these lproj resources from the sealed bundle to localize the
# permission strings; they are not part of the SwiftPM resource bundle.
test -d "$LOCALIZATION_DIR/en.lproj"
test -d "$LOCALIZATION_DIR/ko.lproj"
for locale in en ko; do
    localization_file="$LOCALIZATION_DIR/$locale.lproj/InfoPlist.strings"
    test -f "$localization_file"
    plutil -lint "$localization_file" >/dev/null
    mkdir -p "$RESOURCES_DIR/$locale.lproj"
    cp "$localization_file" "$RESOURCES_DIR/$locale.lproj/InfoPlist.strings"
done
test -f "$RESOURCES_DIR/en.lproj/InfoPlist.strings"
test -f "$RESOURCES_DIR/ko.lproj/InfoPlist.strings"
RESOURCE_BUNDLE="SystemAudioProcessor_SystemAudioProcessor.bundle"
test -d "$BIN_DIR/$RESOURCE_BUNDLE"
# Signed .app bundles cannot have unsealed files beside Contents. The shader
# loader resolves this resource bundle explicitly before any SwiftPM fallback.
cp -R "$BIN_DIR/$RESOURCE_BUNDLE" "$RESOURCES_DIR/$RESOURCE_BUNDLE"
RESOURCE_BUNDLE_DIR="$RESOURCES_DIR/$RESOURCE_BUNDLE"
# Native SwiftPM emits a flat bundle; swiftbuild emits a macOS Contents bundle.
# Preserve either bundle layout and verify the resource that Bundle resolves.
RESOURCE_SHADER=""
for candidate in "$RESOURCE_BUNDLE_DIR/Contents/Resources/SpectrumShaders.metal" \
                 "$RESOURCE_BUNDLE_DIR/SpectrumShaders.metal"; do
    if [ -f "$candidate" ]; then RESOURCE_SHADER="$candidate"; break; fi
done
if [ ! -f "$RESOURCE_SHADER" ]; then
    echo "Swift resource bundle is missing SpectrumShaders.metal" >&2
    exit 1
fi
for locale in en ko; do
    for table in Localizable Main Spatial Runtime; do
        localized_table=""
        for candidate in "$RESOURCE_BUNDLE_DIR/Contents/Resources/$locale.lproj/$table.strings" \
                         "$RESOURCE_BUNDLE_DIR/$locale.lproj/$table.strings"; do
            if [ -f "$candidate" ]; then localized_table="$candidate"; break; fi
        done
        if [ ! -f "$localized_table" ]; then
            echo "Swift resource bundle is missing $locale.lproj/$table.strings" >&2
            exit 1
        fi
        plutil -lint "$localized_table" >/dev/null
        cp "$localized_table" "$RESOURCES_DIR/$locale.lproj/$table.strings"
    done
done
cmp "$SHADER_SOURCE" "$RESOURCES_DIR/SpectrumShaders.metal"
cmp "$SHADER_SOURCE" "$RESOURCE_SHADER"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.codexaudiolab.lowendcircuit.systemaudio</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>LowEndNativeAudioIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ko</string>
    </array>
    <key>LCBuildCommit</key>
    <string>${GIT_COMMIT}${GIT_DIRTY}</string>
    <key>LCBuildDate</key>
    <string>${BUILD_DATE}</string>
    <key>LCBuildID</key>
    <string>${BUILD_ID}</string>
    <key>LCCaptureLeaseVersion</key>
    <integer>1</integer>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>TimbreDock captures system or selected app audio so it can apply audio effects and play the processed signal to your speakers or headphones.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>TimbreDock sends Apple events to Music to detect playback state and source format.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# Test the exact signed Release executable that will be delivered. This runs
# deterministic offline checks only; benchmarks and RateMatchBench are opt-in.
"$MACOS_DIR/$APP_NAME" --self-test
python3 "$ROOT/scripts/check-native-cli.py" "$MACOS_DIR/$APP_NAME"

# Preserve the existing app until the replacement has passed every check.
# A failed move restores it through cleanup; no unvalidated build deletes it.
if [ -e "$FINAL_APP_DIR" ]; then
    BACKUP_DIR="$STAGING_ROOT/previous.app"
    mv "$FINAL_APP_DIR" "$BACKUP_DIR"
fi
mv "$APP_DIR" "$FINAL_APP_DIR"
if ! codesign --verify --deep --strict "$FINAL_APP_DIR"; then
    mv "$FINAL_APP_DIR" "$STAGING_ROOT/failed.app"
    exit 1
fi
if [ -n "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
    BACKUP_DIR=""
fi

printf 'Built and verified Release app:\n  %s\n' "$FINAL_APP_DIR"
printf 'Offline checks:\n  "%s/Contents/MacOS/%s" --self-test\n' "$FINAL_APP_DIR" "$APP_NAME"
printf 'Optional CPU benchmark (does not change audio devices):\n  "%s/Contents/MacOS/%s" --benchmark-output-conditioning\n' "$FINAL_APP_DIR" "$APP_NAME"
