# Barback - build, run and package. `make help` lists the targets.
#
# Variables (override on the command line, e.g. `make app CONFIG=debug`):
#   VERSION      app/release version         (default: contents of the VERSION file)
#   CONFIG       release | debug for app/universal/run/install   (default: release)
#   INSTALL_DIR  where `make install` copies Barback.app         (default: /Applications)
#
# SwiftPM is run through Scripts/swiftw.sh, which adds what a Command Line Tools-only
# machine needs. The SWIFTW_* environment variables it reads are documented there.

SHELL := /bin/bash
.DEFAULT_GOAL := help

VERSION ?= $(strip $(shell cat VERSION 2>/dev/null))
CONFIG ?= release
INSTALL_DIR ?= /Applications

SWIFTW := Scripts/swiftw.sh
APP := dist/Barback.app
ZIP := dist/Barback-$(VERSION).zip
VERSION_ARG := $(if $(VERSION),--version $(VERSION),)

.PHONY: help build release test app universal run zip dmg install icon tap tap-dry-run publish-tap changelog-check prepare-release lint clean

help: ## Show this help
	@echo "Usage: make <target> [VERSION=x.y.z] [CONFIG=release|debug] [INSTALL_DIR=/Applications]"
	@echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Debug build of every target
	$(SWIFTW) build

release: ## Optimized build of every target
	$(SWIFTW) build -c release

test: ## Run the test suite
	$(SWIFTW) test

app: ## Assemble dist/Barback.app for this Mac and sign it ad-hoc
	Scripts/build_app.sh $(VERSION_ARG) --configuration $(CONFIG)

universal: ## Assemble a universal (arm64 + x86_64) dist/Barback.app
	Scripts/build_app.sh --universal $(VERSION_ARG) --configuration $(CONFIG)

run: app ## Build dist/Barback.app and open it
	open $(APP)

zip: ## Universal build packaged as dist/Barback-<version>.zip (+ .sha256 and barback.rb)
	Scripts/package_release.sh $(VERSION_ARG) --formats zip

dmg: ## Universal build packaged as dist/Barback-<version>.dmg (+ .sha256)
	Scripts/package_release.sh $(VERSION_ARG) --formats dmg

install: app ## Build, then copy Barback.app into INSTALL_DIR
	@if pgrep -x Barback >/dev/null; then echo "error: Barback is running; quit it before installing" >&2; exit 1; fi
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Barback.app"
	ditto $(APP) "$(INSTALL_DIR)/Barback.app"
	@echo "Installed $(INSTALL_DIR)/Barback.app"

icon: ## Regenerate Resources/AppIcon.icns and docs/assets/icon-1024.png
	$(SWIFTW) Scripts/make_icon.swift

$(ZIP):
	Scripts/package_release.sh $(VERSION_ARG) --formats zip

tap: $(ZIP) ## Render the Homebrew cask to dist/barback.rb from the local zip
	Scripts/render_cask.sh $(VERSION_ARG) --zip $(ZIP) --output dist/barback.rb

tap-dry-run: ## Render the cask for the published release and diff it against the tap
	Scripts/update_tap.sh $(VERSION_ARG) --from-release --dry-run

publish-tap: ## Pin the published release zip in MrAshRhodes/homebrew-tap (Casks/barback.rb)
	Scripts/update_tap.sh $(VERSION_ARG) --from-release

changelog-check: ## Validate CHANGELOG.md and print the notes for VERSION
	Scripts/changelog.sh check
	@Scripts/changelog.sh notes "$(VERSION)" --allow-unreleased >/dev/null

prepare-release: ## Set VERSION and move Unreleased changelog entries under it (VERSION=x.y.z)
	@if [[ "$(origin VERSION)" == file ]]; then echo "error: pass the new version, e.g. make prepare-release VERSION=1.2.3" >&2; exit 1; fi
	Scripts/changelog.sh release "$(VERSION)"
	printf '%s\n' "$(VERSION)" > VERSION

lint: ## Syntax-check the shell scripts (and run shellcheck when installed)
	@for f in Scripts/*.sh; do bash -n "$$f" || exit 1; done
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck Scripts/*.sh; else echo "shellcheck not installed; ran bash -n only"; fi
	plutil -lint Resources/Info.plist Resources/Barback.entitlements

clean: ## Remove .build and dist
	rm -rf .build dist
