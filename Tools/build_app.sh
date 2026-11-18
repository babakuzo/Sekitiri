#!/bin/bash
# Build/package Sekitiri locally. This never installs or replaces an installed app.
#
# Signing: without SEKITIRI_SIGN_IDENTITY the app gets an ad-hoc signature that
# only runs on this Mac. Set it to a "Developer ID Application: …" identity to
# sign for distribution, with the hardened runtime, a secure timestamp and the
# entitlements in BuildSupport/Sekitiri.entitlements (needed for notarization).
set -euo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd -P)"
APP_VERSION="${SEKITIRI_VERSION:-1.2.0}"
APP_BUILD="${SEKITIRI_BUILD:-2026.10.21}"
SKIP_BUILD=0

usage() {
    echo "Usage: $0 [--skip-build] [output.app]"
    echo "Default output: $PROJECT_ROOT/.local-validation/Sekitiri.app"
    echo "--skip-build packages the existing release product without compiling."
}
fail() { echo "ERROR: $*" >&2; exit 1; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
if [[ "${1:-}" == "--skip-build" ]]; then SKIP_BUILD=1; shift; fi
[[ $# -le 1 ]] || { usage >&2; exit 1; }
APP_DEST="${1:-$PROJECT_ROOT/.local-validation/Sekitiri.app}"
[[ "$APP_DEST" != -* ]] || fail "Output must be a path to an .app bundle."
[[ ! -L "$APP_DEST" ]] || fail "Refusing to replace a symbolic-link output."
APP_BASENAME="$(basename -- "$APP_DEST")"
[[ "$APP_BASENAME" == *.app && "$APP_BASENAME" != ".app" ]] || fail "Output must end in .app."
mkdir -p -- "$(dirname -- "$APP_DEST")"
APP_PARENT="$(cd -- "$(dirname -- "$APP_DEST")" && pwd -P)"
APP_DEST="$APP_PARENT/$APP_BASENAME"
case "$APP_DEST" in
    /Applications/*|"$HOME/Applications/"*) fail "Choose a staging output; installation is a separate step." ;;
esac

SIGN_IDENTITY="${SEKITIRI_SIGN_IDENTITY:--}"
ENTITLEMENTS="$PROJECT_ROOT/BuildSupport/Sekitiri.entitlements"
METAL_LIBRARY="$PROJECT_ROOT/BuildSupport/default.metallib"
[[ -f "$METAL_LIBRARY" ]] || fail "Missing BuildSupport/default.metallib. Build MLX's Cmlx Metal library first."
[[ -f "$PROJECT_ROOT/Sources/Info.plist" ]] || fail "Missing Sources/Info.plist."
[[ -f "$PROJECT_ROOT/Sources/Assets/AppIcon.png" ]] || fail "Missing app icon."

if [[ "$SKIP_BUILD" == 0 ]]; then
    echo "Building release Sekitiri…"
    (cd -- "$PROJECT_ROOT" && swift build -c release)
fi
# Ask SwiftPM for its architecture-specific product path rather than assuming
# Apple Silicon or hard-coding a user's checkout location. This does not build.
BIN_DIRECTORY="$(cd -- "$PROJECT_ROOT" && swift build -c release --show-bin-path)"
APP_EXECUTABLE="$BIN_DIRECTORY/SekitiriApp"
[[ -f "$APP_EXECUTABLE" ]] || fail "No release product found. Run this script without --skip-build first."

STAGING_DIRECTORY="$(mktemp -d "$APP_PARENT/.Sekitiri-build.XXXXXX")"
STAGED_APP="$STAGING_DIRECTORY/$APP_BASENAME"
PREVIOUS_APP="$STAGING_DIRECTORY/previous.app"
PUBLISHED=0
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$result" != 0 && -d "$PREVIOUS_APP" ]]; then
        if [[ "$PUBLISHED" == 1 && -d "$APP_DEST" ]]; then rm -rf -- "$APP_DEST"; fi
        mv -- "$PREVIOUS_APP" "$APP_DEST" || echo "Previous bundle remains at $PREVIOUS_APP" >&2
    fi
    if [[ ! -e "$PREVIOUS_APP" ]]; then rm -rf -- "$STAGING_DIRECTORY"; fi
    exit "$result"
}
trap cleanup EXIT
mkdir -p "$STAGED_APP/Contents/MacOS/Resources" "$STAGED_APP/Contents/Resources"
cp "$PROJECT_ROOT/Sources/Info.plist" "$STAGED_APP/Contents/Info.plist"
PLIST="$STAGED_APP/Contents/Info.plist"
set_string() {
    /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || :
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}
set_bool() {
    /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || :
    /usr/libexec/PlistBuddy -c "Add :$1 bool $2" "$PLIST"
}
set_string CFBundleName Sekitiri
set_string CFBundleDisplayName Sekitiri
set_string CFBundleIdentifier local.sekitiri
set_string CFBundleVersion "$APP_BUILD"
set_string CFBundleShortVersionString "$APP_VERSION"
set_string CFBundlePackageType APPL
set_string CFBundleExecutable Sekitiri
set_string CFBundleIconFile AppIcon.png
set_string LSMinimumSystemVersion 15.0
set_string NSPrincipalClass NSApplication
set_bool NSHighResolutionCapable true
# Retain every source privacy key; preserve this additional usage description
# from the previous packaging helper for system audio permission attribution.
set_string NSScreenCaptureUsageDescription "Sekitiri records system audio during meetings. Nothing is captured from your screen."
/usr/bin/plutil -lint "$PLIST"

cp "$APP_EXECUTABLE" "$STAGED_APP/Contents/MacOS/Sekitiri"
chmod +x "$STAGED_APP/Contents/MacOS/Sekitiri"
cp -R "$PROJECT_ROOT/Sources/Assets/." "$STAGED_APP/Contents/Resources/"
cp "$METAL_LIBRARY" "$STAGED_APP/Contents/Resources/default.metallib"
cp "$METAL_LIBRARY" "$STAGED_APP/Contents/MacOS/Resources/default.metallib"

# Standard macOS signing requires resources below Contents/Resources. Never
# put package bundles or symlinks beside Contents: strict signing rejects that
# layout as unsealed root content. Supported model snapshots include their own
# tokenizer configuration; see BUILD.md for the SwiftPM fallback limitation.
shopt -s nullglob
for resource in "$BIN_DIRECTORY"/*.bundle; do
    case "$(basename -- "$resource")" in *Tests.bundle) continue ;; esac
    cp -R "$resource" "$STAGED_APP/Contents/Resources/"
done

# Signing failures are fatal. Validate the staged bundle before moving either
# it or a previous staging output; a failed package leaves the old copy intact.
# Metal libraries are executable code too. Sign their staged copies before
# signing the enclosing executable/app; never modify the source shader file.
# Nested code is signed inside out; the app's own signature then seals it.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN=(/usr/bin/codesign --force --sign -)
    APP_SIGN=("${SIGN[@]}")
else
    [[ -f "$ENTITLEMENTS" ]] || fail "Missing BuildSupport/Sekitiri.entitlements."
    SIGN=(/usr/bin/codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY")
    APP_SIGN=("${SIGN[@]}" --entitlements "$ENTITLEMENTS")
fi
"${SIGN[@]}" "$STAGED_APP/Contents/Resources/default.metallib"
"${SIGN[@]}" "$STAGED_APP/Contents/MacOS/Resources/default.metallib"
"${APP_SIGN[@]}" "$STAGED_APP/Contents/MacOS/Sekitiri"
"${APP_SIGN[@]}" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
if [[ -e "$APP_DEST" ]]; then
    [[ -d "$APP_DEST" && ! -L "$APP_DEST" ]] || fail "Existing output is not an app directory."
    EXISTING_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DEST/Contents/Info.plist" 2>/dev/null || :)"
    [[ "$EXISTING_IDENTIFIER" == "local.sekitiri" ]] || fail "Refusing to replace an unrelated app bundle."
    mv -- "$APP_DEST" "$PREVIOUS_APP"
fi
mv -- "$STAGED_APP" "$APP_DEST"
PUBLISHED=1
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DEST"
if [[ -d "$PREVIOUS_APP" ]]; then rm -rf -- "$PREVIOUS_APP"; fi
printf 'Built and verified %s (version %s, build %s).\n' "$APP_DEST" "$APP_VERSION" "$APP_BUILD"
