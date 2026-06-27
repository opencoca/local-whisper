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
  # `open -g` (background) delivers the URL to Talking WITHOUT activating it,
  # so the app you were working in (VS Code, a chat, …) stays frontmost. That
  # matters: Talking reads the current selection / captures the paste target
  # from whatever is frontmost, so the trigger must NOT steal focus. (A plain
  # `open location` foregrounds the handler and breaks paste-back.)
  osacompile -o "$app" -e "do shell script \"open -g $url\""
  # Make the launcher itself a background agent so even launching it doesn't
  # flash to the foreground and momentarily steal focus.
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$app/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$app/Contents/Info.plist" >/dev/null 2>&1
  echo "  • $name.app  →  $url"
done

echo
echo "✅ Done. In Xencelabs Quick Keys, set a button's action to"
echo "   \"Open Application\" and pick one of the apps above."
open "$OUT_DIR" 2>/dev/null || true
