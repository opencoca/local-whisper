#!/bin/bash
set -euo pipefail
# Sage.is Talking — trigger-app generator
#
# Builds tiny AppleScript launcher apps that each open one `talking://` URL.
# Point a Xencelabs Quick Keys button (or Stream Deck / any "open app/file"
# action) at the generated .app and it fires the matching lane. A compiled
# AppleScript app launches in tens of milliseconds with no window — the
# fastest-acting bridge for a hardware button (faster than a Shortcuts
# shortcut, and unlike a .command it opens no Terminal window).
#
# Usage:
#   scripts/make-trigger-apps.sh [output-dir]
#
# Default output-dir: ~/Applications/Talking Triggers

OUT_DIR="${1:-$HOME/Applications/Talking Triggers}"

mkdir -p "$OUT_DIR"

# name|url
TRIGGERS=(
  "Talking Live|talking://live"
  "Talking Live Stop|talking://live-stop"
  "Talking Stop & Return|talking://live-stop-return"
  "Talking Speak|talking://speak"
)

echo "🎛  Generating Talking trigger apps in: $OUT_DIR"
for entry in "${TRIGGERS[@]}"; do
  name="${entry%%|*}"
  url="${entry##*|}"
  app="$OUT_DIR/$name.app"
  rm -rf "$app"
  osacompile -o "$app" -e "open location \"$url\""
  echo "  • $name.app  →  $url"
done

echo
echo "✅ Done. In Xencelabs Quick Keys, set a button's action to"
echo "   \"Open Application\" and pick one of the apps above."
open "$OUT_DIR" 2>/dev/null || true
