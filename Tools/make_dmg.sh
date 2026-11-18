#!/bin/bash
# Build a distributable Sekitiri disk image: the app signed with a Developer ID,
# beside an Applications shortcut, in a signed and (optionally) notarized DMG.
#
#   SEKITIRI_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   SEKITIRI_NOTARY_PROFILE=sekitiri \
#   Tools/make_dmg.sh
#
# SEKITIRI_NOTARY_PROFILE names credentials saved once with
#   xcrun notarytool store-credentials <name> --apple-id <id> --team-id <TEAMID>
# Without it the DMG is signed but not notarized, so Gatekeeper still warns.
# Output: dist/Sekitiri-<version>.dmg
set -euo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIRECTORY/.." && pwd -P)"
fail() { echo "ERROR: $*" >&2; exit 1; }

IDENTITY="${SEKITIRI_SIGN_IDENTITY:-}"
[[ "$IDENTITY" == "Developer ID Application:"* ]] \
    || fail "Set SEKITIRI_SIGN_IDENTITY to a \"Developer ID Application: …\" identity (see: security find-identity -v -p codesigning)."
VERSION="${SEKITIRI_VERSION:-1.2.0}"
export SEKITIRI_VERSION="$VERSION"
export SEKITIRI_BUILD="${SEKITIRI_BUILD:-$(date +%Y.%m.%d)}"

DIST="$PROJECT_ROOT/dist"
APP="$DIST/Sekitiri.app"
DMG="$DIST/Sekitiri-$VERSION.dmg"
mkdir -p "$DIST"

"$SCRIPT_DIRECTORY/build_app.sh" "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"

STAGE="$(mktemp -d "$DIST/.dmg.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/Sekitiri.app"
ln -s /Applications "$STAGE/Applications"
rm -f -- "$DMG"
/usr/bin/hdiutil create -volname "Sekitiri" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
/usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ -n "${SEKITIRI_NOTARY_PROFILE:-}" ]]; then
    echo "Submitting to Apple for notarization (usually a few minutes)…"
    /usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$SEKITIRI_NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$DMG"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    echo "Notarized: $DMG"
else
    echo "Signed but not notarized: $DMG"
    echo "Set SEKITIRI_NOTARY_PROFILE to notarize, so it opens without a warning."
fi
