#!/bin/bash
# Builds, installs and launches the React Native playground (OffsiderPlaygroundRN) on iOS and Android.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${REPO_ROOT}/OffsiderPlaygroundRN"
BUILD_DIR="${APP_DIR}/build"
IOS_DERIVED_DATA="${BUILD_DIR}/ios/DerivedData"
IOS_APP="${IOS_DERIVED_DATA}/Build/Products/Release-iphonesimulator/OffsiderPlaygroundRN.app"
ANDROID_APK="${BUILD_DIR}/android/OffsiderPlaygroundRN-release.apk"
APP_ID="com.mpalmes.offsider.playground.rn"
SCREEN_URL="offsiderplaygroundrn://screen"
METRO_PORT=8742

export EXPO_NO_TELEMETRY=1
export EXPO_OFFLINE=1
export COCOAPODS_DISABLE_STATS=true
export LANG=en_US.UTF-8
export ANDROID_HOME="${ANDROID_HOME:-${HOME}/Library/Android/sdk}"

usage() {
  cat <<EOF
Usage: scripts/rn-playground.sh <command> [arguments]

Commands:
  build-ios [udid]                  Prebuild and build the Release simulator app (arm64)
  build-android                     Prebuild and build the arm64-v8a release APK
  install-ios <udid>                Install the app on a booted simulator
  install-android <serial>          Install the APK on a running emulator
  launch-ios <udid> <screen>        Launch straight to a fixture screen (-OffsiderScreen <screen>)
  launch-android <serial> <screen>  Launch straight to a fixture screen (${SCREEN_URL}/<screen>)
  dev-ios <udid>                    Debug build and run with Metro on ${METRO_PORT} (pnpm ios <udid>)
  dev-android <serial|avd>          Debug build and run with Metro on ${METRO_PORT} (pnpm android <serial|avd>)

Artefacts:
  ${IOS_APP#"${REPO_ROOT}"/}
  ${ANDROID_APK#"${REPO_ROOT}"/}
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_arg() {
  [ -n "${2:-}" ] || die "$1 is required. Run 'scripts/rn-playground.sh help'."
}

require_screen() {
  require_arg "<screen>" "${1:-}"
  [[ "$1" =~ ^[a-z][a-z-]*$ ]] || die "screen '$1' is not a fixture id such as tap-test."
}

adb_bin() {
  if [ -x "${ANDROID_HOME}/platform-tools/adb" ]; then
    echo "${ANDROID_HOME}/platform-tools/adb"
  elif command -v adb >/dev/null 2>&1; then
    command -v adb
  else
    die "adb not found. Install Android SDK platform-tools or set ANDROID_HOME."
  fi
}

install_node_modules() {
  command -v pnpm >/dev/null 2>&1 || die "pnpm not found. Install pnpm 11 (brew install pnpm)."
  (cd "${APP_DIR}" && pnpm install --frozen-lockfile)
}

elapsed_since() {
  echo "$(($(date +%s) - $1))s"
}

build_ios() {
  local destination="generic/platform=iOS Simulator"
  if [ -n "${1:-}" ]; then
    destination="id=$1"
  fi
  local started
  started=$(date +%s)
  install_node_modules
  (cd "${APP_DIR}" && pnpm exec expo prebuild --clean --platform ios)
  xcodebuild \
    -workspace "${APP_DIR}/ios/OffsiderPlaygroundRN.xcworkspace" \
    -scheme OffsiderPlaygroundRN \
    -configuration Release \
    -sdk iphonesimulator \
    -destination "${destination}" \
    -derivedDataPath "${IOS_DERIVED_DATA}" \
    ARCHS=arm64 \
    build
  [ -d "${IOS_APP}" ] || die "xcodebuild finished but ${IOS_APP} is missing."
  echo "Built ${IOS_APP} in $(elapsed_since "${started}")"
}

build_android() {
  local started java_home build_tools
  started=$(date +%s)
  java_home=$(/usr/libexec/java_home -v 17) || die "JDK 17 not found. Install one (for example Zulu 17)."
  install_node_modules
  (cd "${APP_DIR}" && pnpm exec expo prebuild --clean --platform android)
  (
    cd "${APP_DIR}/android"
    JAVA_HOME="${java_home}" ./gradlew :app:assembleRelease -PreactNativeArchitectures=arm64-v8a
  )
  mkdir -p "$(dirname "${ANDROID_APK}")"
  cp "${APP_DIR}/android/app/build/outputs/apk/release/app-release.apk" "${ANDROID_APK}"
  build_tools=$(find "${ANDROID_HOME}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
  if [ -x "${build_tools}/zipalign" ]; then
    "${build_tools}/zipalign" -c -P 16 -v 4 "${ANDROID_APK}" >/dev/null ||
      die "${ANDROID_APK} is not aligned for 16 KB pages."
    echo "zipalign: 16 KB page alignment verified"
  else
    echo "warning: zipalign not found under ${ANDROID_HOME}/build-tools, skipped the 16 KB page check" >&2
  fi
  echo "Built ${ANDROID_APK} in $(elapsed_since "${started}")"
}

install_ios() {
  require_arg "<udid>" "${1:-}"
  [ -d "${IOS_APP}" ] || die "${IOS_APP} not found. Run 'scripts/rn-playground.sh build-ios' first."
  xcrun simctl install "$1" "${IOS_APP}"
}

install_android() {
  require_arg "<serial>" "${1:-}"
  [ -f "${ANDROID_APK}" ] || die "${ANDROID_APK} not found. Run 'scripts/rn-playground.sh build-android' first."
  local adb
  adb=$(adb_bin)
  "${adb}" -s "$1" install -r "${ANDROID_APK}"
}

launch_ios() {
  require_arg "<udid>" "${1:-}"
  require_screen "${2:-}"
  xcrun simctl launch --terminate-running-process "$1" "${APP_ID}" -OffsiderScreen "$2"
}

launch_android() {
  require_arg "<serial>" "${1:-}"
  require_screen "${2:-}"
  local adb
  adb=$(adb_bin)
  "${adb}" -s "$1" shell am start -S -W -a android.intent.action.VIEW -d "${SCREEN_URL}/$2" "${APP_ID}"
}

dev_ios() {
  [ -n "${1:-}" ] || die "a simulator is required: pnpm ios <udid> (UDIDs from 'xcrun simctl list devices'). No default device is used."
  [[ "$1" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] || die "'$1' is not a simulator UDID."
  (cd "${APP_DIR}" && pnpm exec expo run:ios --device "$1" --port "${METRO_PORT}")
}

dev_android() {
  [ -n "${1:-}" ] || die "an emulator is required: pnpm android <serial|avd> (serials from 'adb devices'). No default device is used."
  local device="$1" adb
  if [[ "${device}" =~ ^emulator-[0-9]+$ ]]; then
    adb=$(adb_bin)
    device=$("${adb}" -s "$1" emu avd name 2>/dev/null | head -1 | tr -d '\r') || device=""
    [ -n "${device}" ] || die "$1 is not a running emulator ('adb devices' lists them)."
  fi
  (cd "${APP_DIR}" && pnpm exec expo run:android --device "${device}" --port "${METRO_PORT}")
}

command="${1:-help}"
shift || true

case "${command}" in
  build-ios) build_ios "$@" ;;
  build-android) build_android ;;
  install-ios) install_ios "$@" ;;
  install-android) install_android "$@" ;;
  launch-ios) launch_ios "$@" ;;
  launch-android) launch_android "$@" ;;
  dev-ios) dev_ios "$@" ;;
  dev-android) dev_android "$@" ;;
  help | -h | --help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
