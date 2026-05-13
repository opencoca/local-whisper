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

release_finish: require_gitflow_next
	git flow release finish && git push origin develop && git push origin master && git push --tags && git checkout develop

hotfix_finish: require_gitflow_next
	git flow hotfix finish && git push origin develop && git push origin master && git push --tags && git checkout master

# 6. things_clean ----------------------------------------------------
things_clean:
	git clean --exclude='!.env*' -Xdf

# 7. .PHONY ----------------------------------------------------------
.PHONY: help show_vars require_gitflow_next \
	minor_release patch_release major_release hotfix \
	release_finish hotfix_finish things_clean \
	run build build_release app open_app logs clean
