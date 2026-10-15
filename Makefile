.PHONY: help setup frameworks build e2e-devices test e2e e2e-android e2e-rn-ios e2e-rn-debug-ios e2e-rn-debug-android e2e-foldable e2e-android-fold e2e-android-phone e2e-ios-device rn-typecheck grpc-generate helper helper-check clean

help:
	@echo "Common Offsider commands"
	@echo "  make setup          First run: build the pinned idb frameworks, then Offsider"
	@echo "  make frameworks     Build the pinned idb frameworks and XCFrameworks (reuses a matching build)"
	@echo "  make build          Build Offsider"
	@echo "  make test           Run default tests (non-E2E)"
	@echo "  make e2e            Run full E2E flow (build + simulator tests)"
	@echo "  make e2e-devices    Show the E2E simulator and emulators, and create the missing ones"
	@echo "  make e2e-android    Run the Android emulator E2E suites on Offsider_E2E (booted if needed)"
	@echo "  make e2e-rn-ios     Run the React Native playground suites on an iOS simulator (needs pnpm)"
	@echo "  make e2e-rn-debug-ios      Run the React Native Debug smoke suite on iOS with Metro on 8742"
	@echo "  make e2e-rn-debug-android  Run the React Native Debug smoke suite on Android with Metro on 8742"
	@echo "  make e2e-foldable   Run the foldable suite on the Offsider Duo simulator, folding it with offsider posture"
	@echo "  make e2e-android-fold  Run the foldable suite on the Offsider_E2E_Fold AVD"
	@echo "  make e2e-android-phone Run the phone suites on the USB phone OFFSIDER_ANDROID_PHONE names"
	@echo "  make e2e-ios-device  Run the device suites on the wired iPhone or iPad OFFSIDER_IOS_DEVICE names (needs OFFSIDER_IOS_TEAM_ID)"
	@echo "  make rn-typecheck   Typecheck the React Native playground"
	@echo "  make grpc-generate  Regenerate the emulator gRPC client from the vendored proto"
	@echo "  make helper         Rebuild the Android helper dex after changing AndroidHelper/ (JDK 17)"
	@echo "  make helper-check   Rebuild the Android helper and compare it with the committed dex"
	@echo "  make clean          Clean Swift build artifacts"

setup:
	./scripts/build.sh dev
	swift build

frameworks:
	./scripts/build.sh dev

build:
	@test -d build_products/XCFrameworks/FBSimulatorControl.xcframework || { echo "The idb frameworks are not built yet. Run: ./scripts/build.sh dev" >&2; exit 1; }
	swift build

test:
	swift test

e2e:
	./test-runner.sh --simulator

e2e-devices:
	./scripts/e2e-devices.sh

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

e2e-android-phone:
	./test-runner.sh --android-phone

e2e-ios-device:
	./test-runner.sh --ios-device

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
