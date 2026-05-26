#!/bin/bash
set -euo pipefail
# release_all.sh — Build LocalWhisper release artifacts and publish.
#
# Mirrors the Startr canonical pattern (see /Users/somma/bin/TodoScope/scripts/release_all.sh).
#
#   - macOS .app bundle + polished DMG + ZIP via `make app`
#   - Uploaded to GitHub Releases via `gh` (idempotent — re-runs replace artifacts)
#   - Brew cask in $TAP_PATH updated + committed + pushed (no-op if unchanged)
#
# Safe to re-run. Each external mutation is guarded:
#   - `gh release upload --clobber` replaces in place if the tag already exists
#   - cask commit is skipped when the file diff is empty
#
# Usage:  make release_all          # invoked by `make release_finish` for 3-segment tags
#         scripts/release_all.sh    # direct invocation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

VERSION=$(git describe --tags --abbrev=0 | sed 's/^v//')
TAG="v${VERSION}"
TAP_PATH="${TAP_PATH:-../homebrew-apps}"

# Single source of truth for the repo URL — tracks the git remote so no
# manual updates needed when the repo moves to a new org.
REPO_URL=$(git remote get-url origin \
    | sed 's|git@github.com:|https://github.com/|' \
    | sed 's|\.git$||')
# Owner/repo slug for passing to `gh` explicitly. Required when this fork
# has multiple remotes (e.g. `upstream` from t2o2), because gh's
# default-repo selection can otherwise pick the wrong one and refuse the
# release with "tag exists locally but has not been pushed to <upstream>".
REPO_SLUG=$(echo "$REPO_URL" | sed -E 's|^https://github.com/||')

echo ""
echo "  🎙️  LocalWhisper Release — ${TAG}"
echo "  =================================="
echo ""

# --- 1. Preflight (defensive — Makefile already ran this, but the script
#         can be invoked directly so double-check) ---
echo "→ Pre-flight checks..."
command -v gh >/dev/null         || { echo "❌ gh missing — run 'make setup'"; exit 1; }
command -v create-dmg >/dev/null || { echo "❌ create-dmg missing — run 'make setup'"; exit 1; }
gh auth status >/dev/null 2>&1   || { echo "❌ gh not authenticated — run 'gh auth login'"; exit 1; }
test -d "$TAP_PATH/Casks"        || { echo "❌ $TAP_PATH/Casks not found (set TAP_PATH=...)"; exit 1; }
test -f "$TAP_PATH/Casks/local-whisper.rb" || { echo "❌ cask file missing in tap"; exit 1; }
test -f "$PROJECT_DIR/assets/dmg_background.png" || { echo "❌ DMG background missing — run 'make setup'"; exit 1; }
echo "  ✅ Tools, auth, and tap all present"

# --- 2. Build the artifacts (idempotent: overwrites dist/) ---
echo ""
echo "→ Building LocalWhisper ${TAG}..."
make app VERSION="${VERSION}"

DMG="dist/LocalWhisper-${VERSION}.dmg"
ZIP="dist/LocalWhisper-${VERSION}.zip"
test -f "$DMG" || { echo "❌ DMG missing after build: $DMG"; exit 1; }
test -f "$ZIP" || { echo "❌ ZIP missing after build: $ZIP"; exit 1; }
echo "  ✅ Built $(basename "$DMG") + $(basename "$ZIP")"

# --- 3. Upload to GitHub Releases FIRST (most likely to fail; do it
#         before touching the cask so a half-state doesn't lie about
#         the SHA of an unpublished artifact) ---
echo ""
if gh release view --repo "$REPO_SLUG" "$TAG" >/dev/null 2>&1; then
    echo "→ Release $TAG exists — replacing artifacts (--clobber)..."
    gh release upload --repo "$REPO_SLUG" "$TAG" --clobber "$DMG" "$ZIP"
else
    echo "→ Creating GitHub Release: $TAG"
    gh release create --repo "$REPO_SLUG" "$TAG" \
        --title "LocalWhisper $TAG" \
        --generate-notes \
        "$DMG" "$ZIP"
fi
RELEASE_URL=$(gh release view --repo "$REPO_SLUG" "$TAG" --json url --jq .url 2>/dev/null || echo "${REPO_URL}/releases/tag/${TAG}")
echo "  ✅ ${RELEASE_URL}"

# --- 4. Update brew cask (idempotent — only commits when the file
#         actually changed; only pushes if there's a new commit) ---
echo ""
echo "→ Updating brew cask in $TAP_PATH..."
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
# macOS sed: BSD syntax requires '' after -i.
sed -i '' "s/^  version \".*\"/  version \"${VERSION}\"/" "$TAP_PATH/Casks/local-whisper.rb"
sed -i '' "s/^  sha256 .*/  sha256 \"${SHA}\"/"          "$TAP_PATH/Casks/local-whisper.rb"

if (cd "$TAP_PATH" && git diff --quiet Casks/local-whisper.rb); then
    echo "  ⏭  Cask already at ${TAG} with matching SHA — nothing to commit"
else
    (cd "$TAP_PATH" \
        && git add Casks/local-whisper.rb \
        && git commit -m "local-whisper: bump to ${TAG}" \
        && git push)
    echo "  ✅ Cask bumped + pushed"
fi

# --- 5. Final summary — copy-paste ready ---
echo ""
echo "  =================================="
echo "  🎙️  LocalWhisper ${TAG} — Shipped!"
echo "  =================================="
echo ""
echo "  Release:    ${RELEASE_URL:-${REPO_URL}/releases/tag/${TAG}}"
echo "  Install:    brew install --cask sage-is/apps/local-whisper"
echo "  Direct DMG: ${REPO_URL}/releases/download/${TAG}/LocalWhisper-${VERSION}.dmg"
echo ""
