#!/bin/bash
# Ode installer: curl -fsSL https://raw.githubusercontent.com/jamiecurnow/ode/main/install.sh | bash
#
# Downloads the latest release into ~/Applications and launches it. Files fetched with curl aren't
# quarantined, so there's no "unidentified developer" dance with Gatekeeper.
set -euo pipefail

REPO="jamiecurnow/ode"
DEST="$HOME/Applications"
bold() { printf "\033[1m%s\033[0m\n" "$1"; }

[[ "$(uname)" == "Darwin" ]] || { echo "Ode is a macOS app."; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { echo "Ode needs an Apple Silicon Mac."; exit 1; }
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MAJOR >= 26 )) || { echo "Ode needs macOS 26 or later (you have $(sw_vers -productVersion))."; exit 1; }

bold "🎙  Installing Ode…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/$REPO/releases/latest/download/Ode.zip" -o "$TMP/Ode.zip"
ditto -x -k "$TMP/Ode.zip" "$TMP"

mkdir -p "$DEST"
pkill -x Ode 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Ode.app"
mv "$TMP/Ode.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Ode.app" 2>/dev/null || true

if ! command -v claude >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/claude" ]]; then
  echo
  echo "Heads up: Ode cleans up your dictation with Claude Code, which isn't installed yet."
  echo "Get it with:  curl -fsSL https://claude.ai/install.sh | bash   (then run: claude)"
fi

open "$DEST/Ode.app"
bold "✨ Done. Ode is in your menu bar, and the setup window will walk you through the rest."
