.PHONY: help frameworks build test e2e e2e-android grpc-generate helper helper-check clean

help:
	@echo "Common Offsider commands"
	@echo "  make frameworks     Build the pinned IDB frameworks and XCFrameworks"
	@echo "  make build          Build Offsider"
	@echo "  make test           Run default tests (non-E2E)"
	@echo "  make e2e            Run full E2E flow (build + simulator tests)"
	@echo "  make e2e-android    Run the Android emulator E2E suites (needs OFFSIDER_ANDROID_DEVICE)"
	@echo "  make grpc-generate  Regenerate the emulator gRPC client from the vendored proto"
	@echo "  make helper         Rebuild the Android helper dex after changing AndroidHelper/ (JDK 17)"
	@echo "  make helper-check   Rebuild the Android helper and compare it with the committed dex"
	@echo "  make clean          Clean Swift build artifacts"

frameworks:
	for step in setup clean frameworks install strip xcframeworks; do ./scripts/build.sh $$step || exit 1; done

build:
	swift build

test:
	swift test

e2e:
	./test-runner.sh

e2e-android:
	./test-runner.sh --android

grpc-generate:
	./scripts/generate-emulator-grpc.sh

helper:
	./scripts/build.sh helper

helper-check:
	./scripts/build.sh helper --check

clean:
	swift package clean
