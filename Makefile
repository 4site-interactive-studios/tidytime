# TidyTime — terminal-drivable build. Everything Claude Code needs runs from here.
.PHONY: bootstrap generate build run test package-test doctor lint clean

PROJECT := TidyTime.xcodeproj
SCHEME  := TidyTime
CONFIG  ?= Debug
DERIVED := .build/dd

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
		-derivedDataPath $(DERIVED) build

## run: build then launch the app
run: build
	open "$(DERIVED)/Build/Products/$(CONFIG)/TidyTime.app"

## test: run the TidyKit unit tests via SwiftPM (fast, no signing needed)
test:
	cd Packages/TidyKit && swift test

## coverage: run tests with coverage and print a per-file report for our Sources
coverage:
	@bash scripts/coverage.sh

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
