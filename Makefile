# 1. help (default target — must come first) -------------------------
help:
	@echo "================================================"
	@echo "       $(OWNER)/$(PROJECT_NAME) by Startr.Cloud"
	@echo "================================================"
	@echo "This is the default make command."
	@echo "This command lists available make commands."
	@echo ""
	@echo "Usage example:"
	@echo "    make run"
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
FULL_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
BRANCH      := $(shell echo $(FULL_BRANCH) | sed 's/.*\///' | tr '[:upper:]' '[:lower:]')
TAG         := $(shell git describe --always --tag)

# Owner and project name extracted from git remote URL
REMOTE_URL   := $(shell git config --get remote.origin.url 2>/dev/null || echo "unknown/unknown")
OWNER        := $(shell echo $(REMOTE_URL) | sed -E 's|.*[:/]([^/]+)/[^/]+(.git)?$$|\1|')
PROJECT_NAME := $(shell echo $(REMOTE_URL) | sed -E 's|.*[:/][^/]+/([^/]+)(.git)?$$|\1|' | sed 's/\.git$$//')

# Container name (used by Docker block if present)
CONTAINER := $(PROJECT)-$(BRANCH)

# Load environment overrides from .env if present
-include .env

# 3. show_vars (debug helper) ----------------------------------------
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
release_finish: require_gitflow_next release_preflight
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
.PHONY: help show_vars require_gitflow_next \
	minor_release patch_release major_release hotfix \
	release_finish hotfix_finish things_clean \
	run build build_release app open_app logs clean \
	setup release_preflight release_all internal_tag
