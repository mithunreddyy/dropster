#!/bin/zsh
# Builds Dropster and installs it to /Applications, then opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/Dropster.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ "${1:-}" == "--no-build" ]] || ./scripts/build-app.sh

# Quit any running copy so the bundle can be replaced.
osascript -e 'tell application id "app.dropster.Dropster" to quit' >/dev/null 2>&1 || true
pkill -x Dropster 2>/dev/null || true
sleep 1

rm -rf "${DEST:?}"
ditto build/Dropster.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Make the installed copy the one Launch Services (Spotlight, Launchpad, login items) uses.
"$LSREGISTER" -u build/Dropster.app >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST"

# Let the installed copy register itself as the login item on its first run.
defaults delete app.dropster.Dropster loginItemConfigured >/dev/null 2>&1 || true

open "$DEST"
echo "Installed $DEST"
