.PHONY: help frameworks build test e2e clean

help:
	@echo "Common Offsider commands"
	@echo "  make frameworks  Build the pinned IDB frameworks and XCFrameworks"
	@echo "  make build       Build Offsider"
	@echo "  make test        Run default tests (non-E2E)"
	@echo "  make e2e         Run full E2E flow (build + simulator tests)"
	@echo "  make clean       Clean Swift build artifacts"

frameworks:
	for step in setup clean frameworks install strip xcframeworks; do ./scripts/build.sh $$step || exit 1; done

build:
	swift build

test:
	swift test

e2e:
	./test-runner.sh

clean:
	swift package clean
