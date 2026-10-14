#!/bin/bash
# Builds Ode.app into build/.
#
#   ./scripts/build.sh            build + sign
#   ./scripts/build.sh --install  ...then copy to /Applications (or ~/Applications) and launch
#   ./scripts/build.sh --dist     ...then package build/Ode.zip and build/Ode.dmg (what CI ships)
#
# Signing: uses your "Apple Development" certificate if you have one, so macOS keeps the Microphone
# and Accessibility permissions across rebuilds. Otherwise it ad-hoc signs, which works fine but
# macOS will ask for permissions again after each rebuild. Set CODESIGN_IDENTITY="" to force ad-hoc.
# Version: VERSION=1.2.3 ./scripts/build.sh (defaults to the one in Resources/Info.plist).
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Ode"
APP="build/$APP_NAME.app"
if [[ -w /Applications ]]; then INSTALL_DIR="/Applications"; else INSTALL_DIR="$HOME/Applications"; fi
IDENTITY="${CODESIGN_IDENTITY-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)}"

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp ".build/arm64-apple-macosx/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# whisper.cpp (on-device transcription). ditto keeps the framework's version symlinks intact.
ditto ".build/arm64-apple-macosx/release/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"
fi

# Sign the framework first: the app's signature covers it, and the hardened runtime only loads
# libraries signed by the same team.
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Frameworks/whisper.framework"
  codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/Ode.entitlements "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
  codesign --force --sign - --entitlements Resources/Ode.entitlements "$APP"
  echo "Ad-hoc signed (macOS will re-ask for permissions after each rebuild)"
fi

case "${1:-}" in
  --install)
    mkdir -p "$INSTALL_DIR"
    pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    [[ "$INSTALL_DIR" == "/Applications" ]] && rm -rf "$HOME/Applications/$APP_NAME.app"
    cp -R "$APP" "$INSTALL_DIR/"
    echo "Installed to $INSTALL_DIR/$APP_NAME.app"
    open "$INSTALL_DIR/$APP_NAME.app"
    ;;
  --dist)
    rm -f "build/$APP_NAME.zip" "build/$APP_NAME.dmg"
    ditto -c -k --keepParent "$APP" "build/$APP_NAME.zip"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "build/$APP_NAME.dmg" >/dev/null
    rm -rf "$STAGE"
    echo "Packaged build/$APP_NAME.zip and build/$APP_NAME.dmg"
    ;;
esac
