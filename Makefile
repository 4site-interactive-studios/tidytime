# TidyTime — terminal-drivable build. Everything Claude Code needs runs from here.
.PHONY: bootstrap generate build run test coverage typecheck-app dmg doctor diagnose lint clean

PROJECT := TidyTime.xcodeproj
SCHEME  := TidyTime
CONFIG  ?= Debug
DERIVED := .build/dd

# Build provenance stamped into App/Info.plist (read back by TidyCore's BuildInfo) so the running
# app, its logs, and the diagnostic bundle can all say WHICH COMMIT they are. `-dirty` marks a
# build made from an unclean tree, because "8dda588" with uncommitted edits is a lie.
# Note the structure: `-dirty` is appended ONLY when a SHA was actually obtained. The naive
# `$(git rev-parse … || echo unknown)$(git diff --quiet || echo -dirty)` yields "unknown-dirty"
# outside a git repo — a string that reads as real provenance and suppresses the "no SHA" warning,
# which is precisely the lie this feature exists to prevent.
GIT_SHA   := $(shell sh -c 'sha=$$(git rev-parse --short HEAD 2>/dev/null) || { echo unknown; exit 0; }; git diff --quiet HEAD 2>/dev/null || sha="$$sha-dirty"; echo "$$sha"')
BUILT_AT  := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP     := TT_GIT_SHA=$(GIT_SHA) TT_BUILD_TIMESTAMP=$(BUILT_AT)

## bootstrap: install XcodeGen (if needed) and generate the Xcode project
bootstrap:
	@which xcodegen >/dev/null 2>&1 || brew install xcodegen
	@$(MAKE) generate
	@echo "Next: copy Local.xcconfig.example -> Local.xcconfig and set DEVELOPMENT_TEAM."

## generate: (re)generate TidyTime.xcodeproj from project.yml — run after adding source files
generate:
	xcodegen generate

## build: build the app bundle
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) $(STAMP) build

## run: build then launch the app
run: build
	open "$(DERIVED)/Build/Products/$(CONFIG)/TidyTime.app"

## test: run the TidyKit unit tests via SwiftPM (fast, no signing needed)
test:
	cd Packages/TidyKit && swift test

## coverage: run tests with coverage and print a per-file report for our Sources
coverage:
	@bash scripts/coverage.sh

## typecheck-app: compile-check App/ against the SDK without xcodebuild (see script header)
typecheck-app:
	@bash scripts/typecheck-app.sh

## dmg: build a Release app and package it as dist/TidyTime.dmg (see docs/RUNNING.md)
dmg:
	@bash scripts/make-dmg.sh

## diagnose: print the full redacted diagnostic bundle (no app, no clicking)
diagnose:
	@cd Packages/TidyKit && swift run -q tidytime-doctor $(ARGS)

## doctor: print the on-disk locations; run the app's built-in doctor view for live TCC status
doctor:
	@echo "Config: $$HOME/Library/Application Support/TidyTime/config.json"
	@echo "DB:     $$HOME/Library/Application Support/TidyTime/tidytime.sqlite"
	@echo "Run the app and open its 'doctor' view for live permission status."

## lint: verify internal documentation links resolve
lint:
	@bash scripts/check-doc-links.sh

## clean: remove generated project and build artifacts
clean:
	rm -rf $(DERIVED) $(PROJECT)
