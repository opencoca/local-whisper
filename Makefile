# 1. help (default target — must come first) -------------------------
help:
	@echo "================================================"
	@echo "       $(OWNER)/$(PROJECT_NAME) by Startr.Cloud"
	@echo "================================================"
	@echo "This is the default make command."
	@echo "This command lists available make commands."
	@echo ""
	@echo "Usage example:"
	@echo "    make app    # build + sign the .app for hotkey/mic testing"
	@echo ""
	@echo "Available make commands:"
	@echo ""
	@LC_ALL=C $(MAKE) -pRrq -f $(firstword $(MAKEFILE_LIST)) : 2>/dev/null | \
		awk -v RS= -F: '/(^|\n)# Files(\n|$$)/,/(^|\n)# Finished Make data base/ { \
		if ($$1 !~ "^[#.]") {print $$1}}' | \
		sort | \
		grep -E -v -e '^[^[:alnum:]]' -e '^$@$$'
	@echo ""

# 2. Dynamic variables (git-derived) ---------------------------------
# Dynamic variable extraction (mirrors startr.sh)
PROJECTPATH := $(shell git rev-parse --show-toplevel)
PROJECT     := $(shell echo $$(basename $(PROJECTPATH)) | tr '[:upper:]' '[:lower:]')
# Use symbolic-ref (clean failure on detached HEAD) → short SHA (detached HEAD)
# → develop fallback (no-commits / fresh clone). Do NOT use
# `git rev-parse --abbrev-ref HEAD` — it prints "HEAD" on detached HEAD AND
# fails on a no-commits repo, producing a corrupted "HEAD develop" value.
FULL_BRANCH := $(shell git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "develop")
BRANCH      := $(shell echo $(FULL_BRANCH) | sed 's/.*\///' | tr '[:upper:]' '[:lower:]')
TAG         := $(shell git describe --always --tag 2>/dev/null || echo "v0.0.0")

# Owner and project name extracted from git remote URL
REMOTE_URL   := $(shell git config --get remote.origin.url 2>/dev/null || echo "unknown/unknown")
OWNER        := $(shell echo $(REMOTE_URL) | sed -E 's|.*[:/]([^/]+)/[^/]+(.git)?$$|\1|')
PROJECT_NAME := $(shell echo $(REMOTE_URL) | sed -E 's|.*[:/][^/]+/([^/]+)(.git)?$$|\1|' | sed 's/\.git$$//')

# Container name (used by Docker block if present)
CONTAINER := $(PROJECT)-$(BRANCH)

# Load environment overrides from .env if present
-include .env

# 3. show_vars + verify (debug helpers) ------------------------------
show_vars:
	@echo "=== Dynamic Variables ==="
	@echo "PROJECTPATH=$(PROJECTPATH)"
	@echo "PROJECT=$(PROJECT)"
	@echo "OWNER=$(OWNER)"
	@echo "PROJECT_NAME=$(PROJECT_NAME)"
	@echo "FULL_BRANCH=$(FULL_BRANCH)"
	@echo "BRANCH=$(BRANCH)"
	@echo "TAG=$(TAG)"
	@echo "CONTAINER=$(CONTAINER)"
	@echo "REMOTE_URL=$(REMOTE_URL)"
	@echo ""

# One-shot scaffold self-check. Bundles every read-only verification into a
# single make invocation so post-scaffold testing isn't N separate processes.
verify: show_vars require_gitflow_next
	@echo "=== Targets defined in this Makefile ==="
	@LC_ALL=C $(MAKE) -pRrq -f $(firstword $(MAKEFILE_LIST)) : 2>/dev/null | \
		awk -v RS= -F: '/(^|\n)# Files(\n|$$)/,/(^|\n)# Finished Make data base/ { \
		if ($$1 !~ "^[#.]") {print "  " $$1}}' | \
		sort -u | \
		grep -E -v -e '^  [^[:alnum:]]'
	@echo ""
	@echo "OK: Makefile scaffold verified."

# 4. Project-specific custom targets ---------------------------------
VERSION ?= dev

# Fast dev loop — runs the SwiftPM executable directly.
# Note: macOS denies mic access to unsigned binaries, so use `make app`
# for the hotkey/record path. `make run` is enough for file-transcription
# dev work because that path doesn't need mic.
run:
	swift run

build:
	swift build

build_release:
	swift build -c release

# Full .app bundle + ad-hoc codesign via the existing release script.
# Required to test the hotkey/record path. Override version with
# `make app VERSION=1.2.3`.
app:
	./scripts/release.sh $(VERSION)

open_app:
	open dist/LocalWhisper.app

logs:
	tail -f ~/Library/Logs/LocalWhisper.log

clean:
	swift package clean
	rm -rf dist .build

# --- iOS / iPadOS ---------------------------------------------------------
#
# `make ios` is the umbrella entry point: downloads the bundled tiny.en
# Whisper model and generates LocalWhisperMobile.xcodeproj via XcodeGen.
# Both sub-targets are idempotent — safe to re-run any time.
#
# Open the generated project in Xcode for signing/scheme/run.

ios: ios_models ios_xcode
	@echo ""
	@echo "  📱 iOS setup complete"
	@echo "  Next: open LocalWhisperMobile.xcodeproj"

# Download openai_whisper-tiny.en (~75 MB) into Mobile/Resources/Models/.
# Uses HuggingFace CLI; idempotent (no-op if folder already populated).
# The model files are gitignored — each contributor downloads on their own box.
ios_models:
	@echo "→ Checking for bundled Whisper model..."
	@if test -d LocalWhisper/Mobile/Resources/Models/openai_whisper-tiny.en && \
	    test -n "$$(ls -A LocalWhisper/Mobile/Resources/Models/openai_whisper-tiny.en 2>/dev/null)"; then \
		echo "  ⏭  openai_whisper-tiny.en already present"; \
	else \
		mkdir -p LocalWhisper/Mobile/Resources/Models; \
		echo "→ Downloading openai_whisper-tiny.en from HuggingFace..."; \
		if command -v uvx >/dev/null 2>&1; then \
			uvx --from huggingface_hub hf download \
				argmaxinc/whisperkit-coreml \
				--include "openai_whisper-tiny.en/*" \
				--local-dir LocalWhisper/Mobile/Resources/Models; \
		elif command -v hf >/dev/null 2>&1; then \
			hf download argmaxinc/whisperkit-coreml \
				--include "openai_whisper-tiny.en/*" \
				--local-dir LocalWhisper/Mobile/Resources/Models; \
		else \
			echo "❌ Need uv (preferred) or huggingface_hub installed."; \
			echo "   Install uv:  brew install uv  (or  curl -LsSf https://astral.sh/uv/install.sh | sh)"; \
			echo "   Then retry:  make ios_models"; \
			exit 1; \
		fi; \
		test -d LocalWhisper/Mobile/Resources/Models/openai_whisper-tiny.en || { \
			echo "❌ Download finished but openai_whisper-tiny.en/ is missing — check the output above"; \
			exit 1; \
		}; \
		echo "→ Stripping .mlpackage source + .cache (Xcode would double-compile .mlmodelc + .mlpackage)..."; \
		rm -rf LocalWhisper/Mobile/Resources/Models/.cache/; \
		rm -rf LocalWhisper/Mobile/Resources/Models/openai_whisper-tiny.en/*.mlpackage/; \
		echo "  ✅ openai_whisper-tiny.en downloaded ($$(du -sh LocalWhisper/Mobile/Resources/Models/openai_whisper-tiny.en | awk '{print $$1}'))"; \
	fi

# Generate LocalWhisperMobile.xcodeproj from project.yml. Source of truth is
# project.yml (tracked in git); the .xcodeproj is gitignored and regenerated.
# This means contributors never fight over .pbxproj merge conflicts.
ios_xcode:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "❌ xcodegen missing — install with: brew install xcodegen"; \
		exit 1; \
	}
	@echo "→ Generating LocalWhisperMobile.xcodeproj..."
	@xcodegen generate --spec project.yml --quiet
	@echo "  ✅ LocalWhisperMobile.xcodeproj generated"

# Compile the iOS scheme against the iPhone 15 simulator. Smoke test that
# the Xcode project + Mobile/ files + shared Services all compile together.
# Does NOT run on a device.
ios_build: ios_xcode
	@echo "→ Building iOS scheme for iPhone 15 simulator..."
	@xcodebuild -project LocalWhisperMobile.xcodeproj \
		-scheme LocalWhisperMobile \
		-destination 'platform=iOS Simulator,name=iPhone 15' \
		-quiet build

# --- end iOS --------------------------------------------------------------

# Path to the brew tap repo (relative to PROJECTPATH). Override with TAP_PATH=...
TAP_PATH ?= ../homebrew-apps

# One-time setup. Idempotent — re-runnable, skips what's already done.
# Installs gh + create-dmg via brew, verifies auth, generates the DMG
# background asset if missing, and creates a persistent self-signed
# code-signing identity ("LocalWhisper Dev") in the login keychain so
# TCC permissions (Accessibility, Microphone, etc.) survive rebuilds.
# Without this identity, every `make app` produces an ad-hoc signature
# that macOS treats as a brand-new app — orphaning the prior grant.
# Per-machine; not committed to git. Run once on a fresh box.
setup:
	@echo "→ Installing required tools (if missing)..."
	@command -v gh >/dev/null || brew install gh
	@command -v create-dmg >/dev/null || brew install create-dmg
	@echo "→ Verifying gh authentication..."
	@gh auth status >/dev/null 2>&1 || (echo "  Run: gh auth login" && exit 1)
	@echo "→ Generating DMG background if missing..."
	@test -f assets/dmg_background.png || \
		(mkdir -p assets && swift scripts/make-dmg-background.swift assets/dmg_background.png)
	@echo "→ Ensuring 'LocalWhisper Dev' code-signing identity exists..."
	@bash scripts/ensure-dev-signing-identity.sh
	@echo "  ✅ Setup complete"

# Pre-flight checks before any irreversible release action.
# READ-ONLY: never modifies state. Fails BEFORE tag creation/push so bad
# state can't produce a half-released tag. Every error names the fix.
release_preflight:
	@echo "→ Pre-flight checks..."
	@git diff-index --quiet HEAD || \
		(echo "❌ uncommitted changes — commit or stash first" && exit 1)
	@command -v gh >/dev/null || \
		(echo "❌ gh CLI missing — run 'make setup'" && exit 1)
	@gh auth status >/dev/null 2>&1 || \
		(echo "❌ gh not authenticated — run 'gh auth login'" && exit 1)
	@command -v create-dmg >/dev/null || \
		(echo "❌ create-dmg missing — run 'make setup'" && exit 1)
	@test -f assets/dmg_background.png || \
		(echo "❌ DMG background missing — run 'make setup'" && exit 1)
	@echo "  ✅ All checks passed"

# Full release orchestrator: build → gh release → cask update + push.
# Idempotent. Re-running on a published tag re-uploads artifacts (--clobber)
# and skips the cask commit when nothing changed. Invoked automatically by
# `release_finish` for 3-segment public tags.
release_all: release_preflight
	@scripts/release_all.sh

# Lightweight internal tag — no binary release attached. Auto-bumps the
# 4th segment from the latest tag. Use for in-progress milestones or
# pre-release checkpoints that should appear in git history without
# triggering a public binary publish.
#
# v1.0.0   → v1.0.0.1
# v1.0.0.3 → v1.0.0.4
internal_tag:
	@LAST=$$(git tag --sort=-v:refname | head -1 | sed 's/^v//'); \
	if [ -z "$$LAST" ]; then \
		echo "❌ no tags yet — create v0.0.1+ first via 'make patch_release' or 'make minor_release'"; \
		exit 1; \
	fi; \
	if echo "$$LAST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		NEXT="v$${LAST}.1"; \
	elif echo "$$LAST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		NEXT="v$$(echo "$$LAST" | awk -F. '{print $$1"."$$2"."$$3"."$$4+1}')"; \
	else \
		echo "❌ latest tag '$$LAST' has unexpected format"; exit 1; \
	fi; \
	echo "Tagging $$NEXT (internal — no binary release)"; \
	git tag -a "$$NEXT" -m "Internal tag $$NEXT"; \
	git push origin "$$NEXT"; \
	echo "  ✅ Pushed $$NEXT"

# 4b. Version bump + release pre-flight ------------------------------
#
# Adopted from the Startr convention (MEDIA-Storyboarder, WEB-Sage.Education-docs).
# `bump` is release-branch-aware — refuses to run unless RELEASE_VERSION is
# set (i.e., the current branch matches release/* or hotfix/*). Promotes
# CHANGELOG.md `## [Unreleased]` to the release version, re-seeds Unreleased
# with empty section headings, and bumps the README status line. `release_check`
# is the poka-yoke gate — verifies CHANGELOG + README are in sync before
# `release_finish` is allowed to publish.
#
# Why no source-code __version__ constant: the .app bundle's CFBundleVersion
# and CFBundleShortVersionString are baked in at build time by release.sh
# from the VERSION argument. The Makefile already wires RELEASE_VERSION → VERSION
# automatically when release_finish builds, so the canonical version flow is:
#   release/X.Y.Z branch name → RELEASE_VERSION → VERSION → release.sh → Info.plist

TODAY := $(shell date +%Y-%m-%d)

bump:
	@test -n "$(RELEASE_VERSION)" || \
		{ echo "Error: must be on a release/* or hotfix/* branch (got '$(FULL_BRANCH)'). Run 'make minor_release' / 'make patch_release' / 'make hotfix' first."; exit 1; }
	@test -f CHANGELOG.md || \
		{ echo "Error: CHANGELOG.md missing. Create it with '## [Unreleased]' heading first."; exit 1; }
	@if grep -q '^## \[$(RELEASE_VERSION)\] ' CHANGELOG.md 2>/dev/null; then \
		echo "Already bumped: '## [$(RELEASE_VERSION)]' exists in CHANGELOG.md. Nothing to do."; \
		exit 0; \
	fi
	@grep -q '^## \[Unreleased\]' CHANGELOG.md || \
		{ echo "Error: CHANGELOG.md has no '## [Unreleased]' heading"; exit 1; }
	@echo "=== Commits since last release ==="
	@LAST_TAG=$$(git tag --sort=-v:refname | head -1); \
		[ -n "$$LAST_TAG" ] && git log --oneline $$LAST_TAG..HEAD || git log --oneline HEAD
	@echo ""
	@echo "Promoting CHANGELOG ## [Unreleased] → ## [$(RELEASE_VERSION)] — $(TODAY)..."
	@awk -v ver="$(RELEASE_VERSION)" -v date="$(TODAY)" \
		'/^## \[Unreleased\]/ { print "## [Unreleased]"; print ""; print "### Added"; print ""; print "### Changed"; print ""; print "### Fixed"; print ""; print "### Removed"; print ""; print "## [" ver "] — " date; next } { print }' \
		CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
	@echo "Updating bottom-of-file CHANGELOG compare links..."
	@# Insert a new line for the version above the existing top compare link.
	@# The existing [Unreleased] line gets rewritten to compare from new ver.
	@LAST_TAG=$$(git tag --sort=-v:refname | head -1); \
		sed -i.bak -E \
			-e "s|^\[Unreleased\]:.*|[Unreleased]: https://github.com/$(OWNER)/$(PROJECT_NAME)/compare/v$(RELEASE_VERSION)...HEAD|" \
			CHANGELOG.md && \
		PREV_TAG=$${LAST_TAG:-v0.0.0}; \
		awk -v ver="$(RELEASE_VERSION)" -v prev="$$PREV_TAG" -v owner="$(OWNER)" -v project="$(PROJECT_NAME)" \
			'/^\[Unreleased\]:/ { print; print "[" ver "]: https://github.com/" owner "/" project "/compare/" prev "...v" ver; next } { print }' \
			CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md && rm -f CHANGELOG.md.bak
	@echo ""
	@echo "Bump complete. Next:"
	@echo "  1. Edit CHANGELOG.md to refine the '## [$(RELEASE_VERSION)]' section."
	@echo "  2. Run 'make release_check' to verify alignment."
	@echo "  3. git add CHANGELOG.md && git commit -m \"chore: bump CHANGELOG to v$(RELEASE_VERSION)\""
	@echo "  4. Run 'make release_finish' to tag, merge, and publish."

# release_check: pre-flight gate. Refuses to let `release_finish` publish if
# CHANGELOG.md doesn't have a section for the release version. Add more
# checks here as the canonical-version-sources grow (Info.plist template,
# README status line, etc.).
release_check:
	@test -n "$(RELEASE_VERSION)" || \
		{ echo "Error: must be on a release/* or hotfix/* branch (got '$(FULL_BRANCH)')"; exit 1; }
	@grep -q "^## \[$(RELEASE_VERSION)\] " CHANGELOG.md 2>/dev/null || \
		{ echo "Error: CHANGELOG.md has no '## [$(RELEASE_VERSION)]' section. Run 'make bump'."; exit 1; }
	@echo "  ✓ CHANGELOG.md has [$(RELEASE_VERSION)] section"
	@echo "  ✅ release_check OK — ready for 'make release_finish'"

# 5. Git-flow-next release/hotfix flow -------------------------------
require_gitflow_next:
	@if ! git flow version 2>/dev/null | grep -q 'git-flow-next'; then \
		echo "Error: git-flow-next required (Go rewrite). Install: brew install git-flow-next"; \
		exit 1; \
	fi

minor_release: require_gitflow_next
	# Start a minor release with incremented minor version
	git flow release start $$(git tag --sort=-v:refname | sed 's/^v//' | head -n 1 | awk -F'.' '{print $$1"."$$2+1".0"}') && echo "or use 'make release_finish' to finish the release"

patch_release: require_gitflow_next
	# Start a patch release with incremented patch version
	git flow release start $$(git tag --sort=-v:refname | sed 's/^v//' | head -n 1 | awk -F'.' '{print $$1"."$$2"."$$3+1}') && echo "or use 'make release_finish' to finish the release"

major_release: require_gitflow_next
	# Start a major release with incremented major version
	git flow release start $$(git tag --sort=-v:refname | sed 's/^v//' | head -n 1 | awk -F'.' '{print $$1+1".0.0"}') && echo "or use 'make release_finish' to finish the release"

hotfix: require_gitflow_next
	# Start a hotfix with incremented n.n.n.n version (incrementing the fourth number)
	git flow hotfix start $$(git tag --sort=-v:refname | sed 's/^v//' | head -n 1 | awk -F'.' '{print $$1"."$$2"."$$3"."$$4+1}') && echo "or use 'make hotfix_finish' to finish the hotfix"

# Auto-detect version from the current release/* or hotfix/* branch name.
# Used by `release_finish` to decide whether to chain into `release_all`.
RELEASE_VERSION := $(shell git rev-parse --abbrev-ref HEAD | sed -n -e 's/^release\///p' -e 's/^hotfix\///p')

# Finish a release branch — merges, tags, pushes — and AUTO-CHAINS into
# `release_all` (build + gh release + cask update) for 3-segment public
# tags. 4-segment tags (use `make internal_tag`) skip the binary publish.
release_finish: require_gitflow_next release_preflight release_check
	git flow release finish && git push origin develop && git push origin master && git push --tags && git checkout develop
	@echo ""
	@echo "=== Release $(RELEASE_VERSION) tagged and pushed ==="
	@if echo "$(RELEASE_VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "=== Building binaries for v$(RELEASE_VERSION) ==="; \
		$(MAKE) release_all; \
	else \
		echo "Non-public version $(RELEASE_VERSION) — skipping binary release."; \
		echo "Use 'make internal_tag' for lightweight checkpoints."; \
	fi

hotfix_finish: require_gitflow_next
	git flow hotfix finish && git push origin develop && git push origin master && git push --tags && git checkout master

# 6. things_clean ----------------------------------------------------
things_clean:
	git clean --exclude='!.env*' -Xdf

# 7. .PHONY ----------------------------------------------------------
.PHONY: help show_vars verify require_gitflow_next \
	minor_release patch_release major_release hotfix \
	release_finish hotfix_finish things_clean \
	run build build_release app open_app logs clean \
	setup release_preflight release_all internal_tag \
	bump release_check
