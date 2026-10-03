.PHONY: help frameworks build test e2e e2e-android e2e-rn-ios e2e-rn-debug-ios e2e-rn-debug-android e2e-foldable e2e-android-fold rn-typecheck grpc-generate helper helper-check clean

help:
	@echo "Common Offsider commands"
	@echo "  make frameworks     Build the pinned IDB frameworks and XCFrameworks"
	@echo "  make build          Build Offsider"
	@echo "  make test           Run default tests (non-E2E)"
	@echo "  make e2e            Run full E2E flow (build + simulator tests)"
	@echo "  make e2e-android    Run the Android emulator E2E suites (needs OFFSIDER_ANDROID_DEVICE)"
	@echo "  make e2e-rn-ios     Run the React Native playground suites on an iOS simulator (needs pnpm)"
	@echo "  make e2e-rn-debug-ios      Run the React Native Debug smoke suite on iOS with Metro on 8742"
	@echo "  make e2e-rn-debug-android  Run the React Native Debug smoke suite on Android with Metro on 8742"
	@echo "  make e2e-foldable   Run the foldable suite on the Offsider Duo iPhone simulator, folding it with offsider posture"
	@echo "  make e2e-android-fold  Run the foldable suite on the Offsider_E2E_Pixel_9_Pro_Fold AVD"
	@echo "  make rn-typecheck   Typecheck the React Native playground"
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

e2e-rn-ios:
	./test-runner.sh --rn-ios

e2e-rn-debug-ios:
	./test-runner.sh --rn-ios --rn-debug

e2e-rn-debug-android:
	./test-runner.sh --android --rn-debug

e2e-foldable:
	./test-runner.sh --foldable

e2e-android-fold:
	./test-runner.sh --android-fold

rn-typecheck:
	pnpm --dir OffsiderPlaygroundRN typecheck

grpc-generate:
	./scripts/generate-emulator-grpc.sh

helper:
	./scripts/build.sh helper

helper-check:
	./scripts/build.sh helper --check

clean:
	swift package clean
