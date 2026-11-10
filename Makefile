.PHONY: build build-release dist test lint format runner runner-project export-check clean help

SWIFT := xcrun swift

build: ## Debug build of the CLI
	@$(SWIFT) build

build-release: ## Release build of the CLI
	@$(SWIFT) build -c release --product deviceloop

dist: ## Signed and notarized arm64 tarball in dist/ (TAG=v<version>, see scripts/release.sh)
	@scripts/release.sh $(TAG)

test: ## Unit tests
	@DEVICELOOP_HOME=$(CURDIR)/.build/deviceloop-home $(SWIFT) test

lint: ## Check formatting
	@$(SWIFT) format lint --strict --recursive Sources Tests Runner

format: ## Format sources in place
	@$(SWIFT) format --in-place --recursive Sources Tests Runner

runner: ## Build the on-device runner for the simulator without signing
	@xcodebuild build-for-testing \
		-project Runner/DeviceLoopRunner.xcodeproj \
		-scheme DeviceLoopRunner \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath .build/runner-sim \
		CODE_SIGNING_ALLOWED=NO -quiet

runner-project: ## Regenerate Runner/DeviceLoopRunner.xcodeproj from Runner/project.yml (needs xcodegen)
	@cd Runner && xcodegen generate

export-check: ## Run the exported fixture flows on a booted simulator: make export-check DEVICE=<udid> ARTIFACTS=<new dir>
	@$(SWIFT) build --product deviceloop
	@python3 scripts/export-check.py --binary .build/debug/deviceloop --device "$(DEVICE)" --artifacts "$(ARTIFACTS)"

clean: ## Remove build products
	@$(SWIFT) package clean

help: ## Show targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-16s %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
