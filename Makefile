# Makefile — Meeting Monitor (macOS Swift / Xcode)
.PHONY: default help tasks build run install uninstall clean test lint lint-fix format format-fix secrets \
	project icon check pkg distclean release _release-app _stage-dist _zip

default: help

# ----------------------------------------------------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------------------------------------------------

PROJECT        := MeetingMonitor.xcodeproj
SCHEME         := MeetingMonitor
APP_NAME       := Meeting Monitor
BUNDLE_ID      := com.meetingmonitor.app

CONFIGURATION_DEBUG   := Debug
CONFIGURATION_RELEASE := Release

BUILD_DIR      := build
DERIVED_DATA   := $(BUILD_DIR)/DerivedData
DIST_DIR       := dist
ARCHIVE_PATH   := $(BUILD_DIR)/MeetingMonitor.xcarchive
EXPORT_DIR     := $(BUILD_DIR)/export

# Read version from project.yml (fallback if xcodegen / plutil unavailable)
VERSION ?= $(shell sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml 2>/dev/null | head -1)
VERSION := $(if $(VERSION),$(VERSION),1.0.0)

# Destination for local install
INSTALL_DIR    ?= /Applications

# Auto-detect Developer ID identities (empty → ad-hoc / unsigned packaging).
# Works for any developer who has certs in their keychain — nothing hardcoded.
DEVELOPER_ID_APP ?= $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
DEVELOPER_ID_INSTALLER ?= $(shell security find-identity -v 2>/dev/null | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' | head -1)
# Team ID is the (XXXXXXXXXX) suffix on the identity string, when present.
DEVELOPMENT_TEAM ?= $(shell printf '%s' '$(DEVELOPER_ID_APP)' | sed -n 's/.*(\([A-Z0-9]\{10\}\))$$/\1/p')

# Colors
CYAN  := \033[36m
GREEN := \033[32m
YELL  := \033[33m
RED   := \033[31m
BOLD  := \033[1m
RESET := \033[0m

define say
	@printf "$(CYAN)→$(RESET) %s\n" "$(1)"
endef

define ok
	@printf "$(GREEN)✅$(RESET) %s\n" "$(1)"
endef

define warn
	@printf "$(YELL)⚠️$(RESET)  %s\n" "$(1)"
endef

# Common xcodebuild flags
XCODEBUILD := xcodebuild \
	-project "$(PROJECT)" \
	-scheme "$(SCHEME)" \
	-destination 'platform=macOS' \
	-derivedDataPath "$(DERIVED_DATA)"

# ----------------------------------------------------------------------------------------------------------------------
# Paths to built products
# ----------------------------------------------------------------------------------------------------------------------

DEBUG_APP   := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION_DEBUG)/$(APP_NAME).app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION_RELEASE)/$(APP_NAME).app
DIST_APP    := $(DIST_DIR)/$(APP_NAME).app
DIST_PKG    := $(DIST_DIR)/MeetingMonitor-$(VERSION).pkg
DIST_ZIP    := $(DIST_DIR)/MeetingMonitor-$(VERSION).zip

# ----------------------------------------------------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------------------------------------------------

help tasks: ## Show this help message
	@printf "\n$(BOLD)Meeting Monitor$(RESET) — macOS menu bar meeting monitor\n"
	@printf "Version: $(VERSION)\n\n"
	@printf "Available commands:\n"
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@printf "\nSigning:\n"
	@if [ -n "$(DEVELOPER_ID_APP)" ]; then \
		printf "  App:       $(GREEN)%s$(RESET)\n" "$(DEVELOPER_ID_APP)"; \
	else \
		printf "  App:       $(YELL)ad-hoc (no Developer ID Application found)$(RESET)\n"; \
	fi
	@if [ -n "$(DEVELOPER_ID_INSTALLER)" ]; then \
		printf "  Installer: $(GREEN)%s$(RESET)\n" "$(DEVELOPER_ID_INSTALLER)"; \
	else \
		printf "  Installer: $(YELL)unsigned pkg (no Developer ID Installer found)$(RESET)\n"; \
	fi
	@printf "\nExamples:\n"
	@printf "  make project       # Regenerate MeetingMonitor.xcodeproj (xcodegen)\n"
	@printf "  make test          # Run unit tests\n"
	@printf "  make lint          # SwiftLint strict gate (must be clean)\n"
	@printf "  make format        # SwiftFormat gate (must be clean)\n"
	@printf "  make build         # Debug .app\n"
	@printf "  make run           # Build Debug and launch\n"
	@printf "  make install       # Release → /Applications\n"
	@printf "  make release       # dist/: .app + .pkg + .zip\n"
	@printf "\n"

# ----------------------------------------------------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------------------------------------------------

build: ## Build Debug configuration (ad-hoc signed)
	$(call say,Building $(APP_NAME) [$(CONFIGURATION_DEBUG)]…)
	@$(XCODEBUILD) \
		-configuration $(CONFIGURATION_DEBUG) \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		build
	$(call ok,Debug build ready)
	@printf "   $(DEBUG_APP)\n"

# ----------------------------------------------------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------------------------------------------------

run: build ## Build Debug and launch the app
	$(call say,Launching $(APP_NAME)…)
	@# Menu bar agent — kill any previous instance first
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@open "$(DEBUG_APP)"
	$(call ok,Launched (menu bar — no Dock icon))

# ----------------------------------------------------------------------------------------------------------------------
# Install / Uninstall
# ----------------------------------------------------------------------------------------------------------------------

install: ## Build Release and install to /Applications
	$(call say,Building Release for install…)
	@$(MAKE) --no-print-directory _release-app
	$(call say,Installing to $(INSTALL_DIR)/$(APP_NAME).app…)
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@ditto "$(RELEASE_APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	$(call ok,Installed → $(INSTALL_DIR)/$(APP_NAME).app)
	@printf "   Open with: open \"$(INSTALL_DIR)/$(APP_NAME).app\"\n"

uninstall: ## Remove app from /Applications
	$(call say,Removing $(INSTALL_DIR)/$(APP_NAME).app…)
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	$(call ok,Uninstalled)

# ----------------------------------------------------------------------------------------------------------------------
# Release (.app + .pkg + .zip)
# ----------------------------------------------------------------------------------------------------------------------

release: ## Full release: Release .app, .pkg, and .zip into dist/
	@printf "\n$(BOLD)🚀 Release $(APP_NAME) v$(VERSION)$(RESET)\n\n"
	@$(MAKE) --no-print-directory _release-app
	@$(MAKE) --no-print-directory _stage-dist
	@$(MAKE) --no-print-directory pkg
	@$(MAKE) --no-print-directory _zip
	@printf "\n$(GREEN)✅ Release complete$(RESET)\n"
	@printf "   App:  $(DIST_APP)\n"
	@printf "   Pkg:  $(DIST_PKG)\n"
	@printf "   Zip:  $(DIST_ZIP)\n"
	@shasum -a 256 "$(DIST_APP)/Contents/MacOS/$(APP_NAME)" "$(DIST_PKG)" "$(DIST_ZIP)" | sed 's|^|   SHA: |'
	@printf "\n"

# Internal: Release xcodebuild (Developer ID when available)
_release-app:
	$(call say,Building $(APP_NAME) [$(CONFIGURATION_RELEASE)]…)
	@if [ -n "$(DEVELOPER_ID_APP)" ]; then \
		printf "   Signing with: $(DEVELOPER_ID_APP)\n"; \
		$(XCODEBUILD) \
			-configuration $(CONFIGURATION_RELEASE) \
			CODE_SIGN_IDENTITY="$(DEVELOPER_ID_APP)" \
			CODE_SIGN_STYLE=Manual \
			$(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM),) \
			OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
			build; \
	else \
		printf "   $(YELL)No Developer ID — ad-hoc signing$(RESET)\n"; \
		$(XCODEBUILD) \
			-configuration $(CONFIGURATION_RELEASE) \
			CODE_SIGN_IDENTITY="-" \
			build; \
	fi
	@test -d "$(RELEASE_APP)" || { printf "$(RED)🚨 Build product missing: $(RELEASE_APP)$(RESET)\n"; exit 1; }
	$(call ok,Release .app built)

_stage-dist:
	$(call say,Staging dist/…)
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)"
	@ditto "$(RELEASE_APP)" "$(DIST_APP)"
	$(call ok,Staged $(DIST_APP))

pkg: ## Build installer .pkg from dist/ (or Release product)
	@if [ ! -d "$(DIST_APP)" ]; then \
		$(MAKE) --no-print-directory _release-app; \
		$(MAKE) --no-print-directory _stage-dist; \
	fi
	$(call say,Creating installer package…)
	@# component-plist free path: stage under a fake root
	@rm -rf "$(BUILD_DIR)/pkgroot"
	@mkdir -p "$(BUILD_DIR)/pkgroot/Applications"
	@ditto "$(DIST_APP)" "$(BUILD_DIR)/pkgroot/Applications/$(APP_NAME).app"
	@if [ -n "$(DEVELOPER_ID_INSTALLER)" ]; then \
		pkgbuild \
			--root "$(BUILD_DIR)/pkgroot" \
			--identifier "$(BUNDLE_ID)" \
			--version "$(VERSION)" \
			--install-location "/" \
			--sign "$(DEVELOPER_ID_INSTALLER)" \
			"$(DIST_PKG)"; \
	else \
		pkgbuild \
			--root "$(BUILD_DIR)/pkgroot" \
			--identifier "$(BUNDLE_ID)" \
			--version "$(VERSION)" \
			--install-location "/" \
			"$(DIST_PKG)"; \
		printf "$(YELL)⚠️  Package is unsigned (no Developer ID Installer)$(RESET)\n"; \
	fi
	@rm -rf "$(BUILD_DIR)/pkgroot"
	$(call ok,Package → $(DIST_PKG))

_zip:
	$(call say,Zipping app…)
	@rm -f "$(DIST_ZIP)"
	@ditto -c -k --keepParent "$(DIST_APP)" "$(DIST_ZIP)"
	$(call ok,Zip → $(DIST_ZIP))

# ----------------------------------------------------------------------------------------------------------------------
# Test
# ----------------------------------------------------------------------------------------------------------------------

test: ## Run full Xcode unit test suite
	$(call say,Running Xcode tests…)
	@$(XCODEBUILD) \
		-configuration $(CONFIGURATION_DEBUG) \
		CODE_SIGN_IDENTITY="-" \
		-enableCodeCoverage YES \
		test
	$(call ok,Tests passed)

# ----------------------------------------------------------------------------------------------------------------------
# Lint gate
# ----------------------------------------------------------------------------------------------------------------------

lint: ## SwiftLint strict gate — every warning is an error
	$(call say,Running SwiftLint (strict)…)
	@command -v swiftlint >/dev/null || { printf "$(RED)🚨 swiftlint not installed. brew install swiftlint$(RESET)\n"; exit 1; }
	@swiftlint lint --strict --reporter github-actions-logging
	$(call ok,Lint clean)

lint-fix: ## Auto-correct autocorrectable SwiftLint violations
	@swiftlint lint --fix
	@swiftlint lint --strict --reporter github-actions-logging
	$(call ok,Lint clean after fix)

format: ## SwiftFormat lint gate — detect formatting drift
	@command -v swiftformat >/dev/null || { printf "$(RED)🚨 swiftformat not installed. brew install swiftformat$(RESET)\n"; exit 1; }
	@swiftformat . --lint
	$(call ok,Format clean)

format-fix: ## Auto-format all Swift sources
	@command -v swiftformat >/dev/null || { printf "$(RED)🚨 swiftformat not installed. brew install swiftformat$(RESET)\n"; exit 1; }
	@swiftformat .
	$(call ok,Formatted)

secrets: ## Secret scan gate — gitleaks detects committed credentials/tokens
	@command -v gitleaks >/dev/null || { printf "$(RED)🚨 gitleaks not installed. brew install gitleaks$(RESET)\n"; exit 1; }
	@gitleaks dir . --no-banner
	$(call ok,No secrets found)

# ----------------------------------------------------------------------------------------------------------------------
# Project maintenance
# ----------------------------------------------------------------------------------------------------------------------

project: ## Regenerate Xcode project from project.yml (xcodegen)
	$(call say,Running xcodegen…)
	@command -v xcodegen >/dev/null || { printf "$(RED)🚨 xcodegen not installed. brew install xcodegen$(RESET)\n"; exit 1; }
	@# project.yml declares the entitlement properties, so xcodegen writes the full file.
	@xcodegen generate
	@grep -q "app-sandbox" MeetingMonitor/Resources/MeetingMonitor.entitlements || \
		{ printf "$(RED)🚨 Sandbox entitlement missing after xcodegen — check project.yml$(RESET)\n"; exit 1; }
	$(call ok,MeetingMonitor.xcodeproj regenerated)

icon: ## Regenerate AppIcon asset catalog
	$(call say,Generating app icon…)
	@swift Scripts/generate_icon.swift MeetingMonitor/Resources/Assets.xcassets/AppIcon.appiconset
	$(call ok,Icon set updated)

check: ## Verify Xcode CLI is pointed at Xcode.app
	$(call say,Checking toolchain…)
	@xcode-select -p
	@xcodebuild -version
	@swift --version | head -1
	@if [ -n "$(DEVELOPER_ID_APP)" ]; then printf "   App identity: $(DEVELOPER_ID_APP)\n"; fi
	@if [ -n "$(DEVELOPER_ID_INSTALLER)" ]; then printf "   Installer identity: $(DEVELOPER_ID_INSTALLER)\n"; fi
	$(call ok,Toolchain OK)

# ----------------------------------------------------------------------------------------------------------------------
# Clean
# ----------------------------------------------------------------------------------------------------------------------

clean: ## Remove build/ and local DerivedData
	@rm -rf "$(BUILD_DIR)"
	$(call ok,Clean)

distclean: clean ## Remove build/ and dist/
	@rm -rf "$(DIST_DIR)"
	$(call ok,Dist clean)