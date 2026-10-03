#!/bin/bash
# Builds, installs and launches the React Native playground (OffsiderPlaygroundRN) on iOS and Android.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${REPO_ROOT}/OffsiderPlaygroundRN"
BUILD_DIR="${APP_DIR}/build"
IOS_DERIVED_DATA="${BUILD_DIR}/ios/DerivedData"
IOS_APP="${IOS_DERIVED_DATA}/Build/Products/Release-iphonesimulator/OffsiderPlaygroundRN.app"
IOS_DEBUG_APP="${IOS_DERIVED_DATA}/Build/Products/Debug-iphonesimulator/OffsiderPlaygroundRN.app"
ANDROID_APK="${BUILD_DIR}/android/OffsiderPlaygroundRN-release.apk"
ANDROID_DEBUG_APK="${BUILD_DIR}/android/OffsiderPlaygroundRN-debug.apk"
APP_ID="com.mpalmes.offsider.playground.rn"
SCREEN_URL="offsiderplaygroundrn://screen"
METRO_PORT=8742
METRO_PIDFILE="${BUILD_DIR}/metro.pid"
METRO_LOG="${BUILD_DIR}/metro.log"
METRO_STATUS_URL="http://127.0.0.1:${METRO_PORT}/status"
METRO_START_TIMEOUT=60

export EXPO_NO_TELEMETRY=1
export EXPO_OFFLINE=1
export COCOAPODS_DISABLE_STATS=true
export LANG=en_US.UTF-8
export ANDROID_HOME="${ANDROID_HOME:-${HOME}/Library/Android/sdk}"

usage() {
  cat <<EOF
Usage: scripts/rn-playground.sh <command> [arguments]

Commands:
  build-ios [udid] [--debug] [--if-changed]
                                    Prebuild and build the simulator app (arm64), Release by default
  build-android [--debug] [--if-changed]
                                    Prebuild and build the arm64-v8a APK, release by default
  install-ios <udid> [--debug]      Install the app on a booted simulator
  install-android <serial> [--debug]
                                    Install the APK on a running emulator
  path-ios [--debug]                Print the app's path (it may not exist yet)
  path-android [--debug]            Print the APK's path (it may not exist yet)
  fingerprint <ios|android> [--debug]
                                    Print the source fingerprint --if-changed compares
  launch-ios <udid> <screen>        Launch straight to a fixture screen (-OffsiderScreen <screen>)
  launch-android <serial> <screen>  Launch straight to a fixture screen (${SCREEN_URL}/<screen>)
  metro start|stop|status           Run Metro for Debug builds in the background on 127.0.0.1:${METRO_PORT}
  dev-ios <udid> [--screen <screen>]
                                    Start Metro (as 'metro start'), build and install the Debug app
                                    if changed, and launch it from Metro (pnpm ios <udid>)
  dev-android <serial|avd> [--screen <screen>]
                                    The same on an emulator, booting an AVD that is not running
                                    (offsider boot) and setting 'adb reverse tcp:${METRO_PORT} tcp:${METRO_PORT}'
                                    so it reaches Metro over loopback (pnpm android <serial|avd>)

Options:
  --debug        The Debug configuration, which loads JavaScript from Metro on ${METRO_PORT}
  --if-changed   Skip the build when the fingerprint beside the artefact matches and the artefact exists

Artefacts:
  ${IOS_APP#"${REPO_ROOT}"/}
  ${IOS_DEBUG_APP#"${REPO_ROOT}"/}
  ${ANDROID_APK#"${REPO_ROOT}"/}
  ${ANDROID_DEBUG_APK#"${REPO_ROOT}"/}

Metro:
  'metro status' exits 0 when our Metro answers on ${METRO_PORT}, 1 otherwise.
  Log: ${METRO_LOG#"${REPO_ROOT}"/}
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

jdk17_home() {
  /usr/libexec/java_home -v 17 2>/dev/null || die "JDK 17 not found. Install one (for example Zulu 17)."
}

# Parsed by parse_build_flags: DEBUG, IF_CHANGED and the remaining positional POSITIONAL_ARG.
DEBUG=false
IF_CHANGED=false
POSITIONAL_ARG=""

parse_build_flags() {
  local allow_positional="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --debug) DEBUG=true ;;
      --if-changed) IF_CHANGED=true ;;
      -*) die "unknown option '$1'. Run 'scripts/rn-playground.sh help'." ;;
      *)
        [ "${allow_positional}" = true ] && [ -z "${POSITIONAL_ARG}" ] ||
          die "unexpected argument '$1'. Run 'scripts/rn-playground.sh help'."
        POSITIONAL_ARG="$1"
        ;;
    esac
    shift
  done
}

ios_configuration() {
  if [ "${DEBUG}" = true ]; then echo Debug; else echo Release; fi
}

android_variant() {
  if [ "${DEBUG}" = true ]; then echo debug; else echo release; fi
}

ios_app_path() {
  if [ "${DEBUG}" = true ]; then echo "${IOS_DEBUG_APP}"; else echo "${IOS_APP}"; fi
}

android_apk_path() {
  if [ "${DEBUG}" = true ]; then echo "${ANDROID_DEBUG_APK}"; else echo "${ANDROID_APK}"; fi
}

fingerprint_file() {
  case "$1" in
    ios) echo "${BUILD_DIR}/ios/$(ios_configuration).fingerprint" ;;
    android) echo "${BUILD_DIR}/android/$(android_variant).fingerprint" ;;
  esac
}

# SHA-256 over the playground's tracked and untracked (not ignored) files, the configuration and the toolchain.
compute_fingerprint() {
  local platform="$1"
  {
    printf 'platform=%s\n' "${platform}"
    case "${platform}" in
      ios)
        printf 'configuration=%s\n' "$(ios_configuration)"
        xcodebuild -version
        ;;
      android)
        printf 'variant=%s\n' "$(android_variant)"
        printf 'jdk=%s\n' "$(jdk17_home)"
        ;;
    esac
    (
      cd "${REPO_ROOT}"
      git ls-files -co --exclude-standard -z -- OffsiderPlaygroundRN scripts/rn-playground.sh |
        LC_ALL=C sort -z |
        while IFS= read -r -d '' file; do
          [ -f "${file}" ] || continue
          printf '%s  %s\n' "$(shasum -a 256 <"${file}" | cut -d ' ' -f 1)" "${file}"
        done
    )
  } | shasum -a 256 | cut -d ' ' -f 1
}

# Returns 0 when --if-changed is set, the artefact exists and its stored fingerprint matches.
build_is_current() {
  local platform="$1" artefact="$2" fingerprint="$3" stored
  [ "${IF_CHANGED}" = true ] || return 1
  [ -e "${artefact}" ] || return 1
  stored=$(cat "$(fingerprint_file "${platform}")" 2>/dev/null) || return 1
  [ "${stored}" = "${fingerprint}" ]
}

store_fingerprint() {
  local file
  file=$(fingerprint_file "$1")
  mkdir -p "$(dirname "${file}")"
  printf '%s\n' "$2" >"${file}"
}

build_ios() {
  parse_build_flags true "$@"
  local destination="generic/platform=iOS Simulator"
  if [ -n "${POSITIONAL_ARG}" ]; then
    destination="id=${POSITIONAL_ARG}"
  fi
  local configuration app fingerprint started
  configuration=$(ios_configuration)
  app=$(ios_app_path)
  fingerprint=$(compute_fingerprint ios)
  if build_is_current ios "${app}" "${fingerprint}"; then
    echo "Up to date: ${app} (fingerprint ${fingerprint})"
    return
  fi
  started=$(date +%s)
  rm -f "$(fingerprint_file ios)"
  install_node_modules
  (cd "${APP_DIR}" && pnpm exec expo prebuild --clean --platform ios)
  RCT_METRO_PORT="${METRO_PORT}" xcodebuild \
    -workspace "${APP_DIR}/ios/OffsiderPlaygroundRN.xcworkspace" \
    -scheme OffsiderPlaygroundRN \
    -configuration "${configuration}" \
    -sdk iphonesimulator \
    -destination "${destination}" \
    -derivedDataPath "${IOS_DERIVED_DATA}" \
    ARCHS=arm64 \
    build
  [ -d "${app}" ] || die "xcodebuild finished but ${app} is missing."
  store_fingerprint ios "${fingerprint}"
  echo "Built ${app} in $(elapsed_since "${started}")"
}

build_android() {
  parse_build_flags false "$@"
  local variant task apk fingerprint started java_home build_tools
  variant=$(android_variant)
  apk=$(android_apk_path)
  fingerprint=$(compute_fingerprint android)
  if build_is_current android "${apk}" "${fingerprint}"; then
    echo "Up to date: ${apk} (fingerprint ${fingerprint})"
    return
  fi
  started=$(date +%s)
  java_home=$(jdk17_home)
  rm -f "$(fingerprint_file android)"
  install_node_modules
  (cd "${APP_DIR}" && pnpm exec expo prebuild --clean --platform android)
  if [ "${DEBUG}" = true ]; then
    task=":app:assembleDebug"
  else
    task=":app:assembleRelease"
  fi
  (
    cd "${APP_DIR}/android"
    JAVA_HOME="${java_home}" ./gradlew "${task}" -PreactNativeArchitectures=arm64-v8a \
      -PreactNativeDevServerPort="${METRO_PORT}"
  )
  mkdir -p "$(dirname "${apk}")"
  cp "${APP_DIR}/android/app/build/outputs/apk/${variant}/app-${variant}.apk" "${apk}"
  build_tools=$(find "${ANDROID_HOME}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
  if [ -x "${build_tools}/zipalign" ]; then
    if "${build_tools}/zipalign" -c -P 16 -v 4 "${apk}" >/dev/null; then
      echo "zipalign: 16 KB page alignment verified"
    elif [ "${DEBUG}" = true ]; then
      echo "warning: ${apk} is not aligned for 16 KB pages (debug build, continuing)" >&2
    else
      die "${apk} is not aligned for 16 KB pages."
    fi
  else
    echo "warning: zipalign not found under ${ANDROID_HOME}/build-tools, skipped the 16 KB page check" >&2
  fi
  store_fingerprint android "${fingerprint}"
  echo "Built ${apk} in $(elapsed_since "${started}")"
}

install_ios() {
  parse_build_flags true "$@"
  require_arg "<udid>" "${POSITIONAL_ARG}"
  local app flag=""
  app=$(ios_app_path)
  [ "${DEBUG}" = true ] && flag=" --debug"
  [ -d "${app}" ] || die "${app} not found. Run 'scripts/rn-playground.sh build-ios${flag}' first."
  xcrun simctl install "${POSITIONAL_ARG}" "${app}"
}

install_android() {
  parse_build_flags true "$@"
  require_arg "<serial>" "${POSITIONAL_ARG}"
  local apk adb flag=""
  apk=$(android_apk_path)
  [ "${DEBUG}" = true ] && flag=" --debug"
  [ -f "${apk}" ] || die "${apk} not found. Run 'scripts/rn-playground.sh build-android${flag}' first."
  adb=$(adb_bin)
  "${adb}" -s "${POSITIONAL_ARG}" install -r "${apk}"
}

path_ios() {
  parse_build_flags false "$@"
  ios_app_path
}

path_android() {
  parse_build_flags false "$@"
  android_apk_path
}

print_fingerprint() {
  local platform="${1:-}"
  case "${platform}" in
    ios | android) ;;
    *) die "fingerprint needs a platform: ios or android." ;;
  esac
  shift
  parse_build_flags false "$@"
  compute_fingerprint "${platform}"
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

# Parsed by parse_dev_args: DEV_DEVICE and the optional DEV_SCREEN.
DEV_DEVICE=""
DEV_SCREEN=""

parse_dev_args() {
  local usage="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --screen)
        [ $# -ge 2 ] || die "--screen needs a fixture screen such as tap-test."
        require_screen "$2"
        DEV_SCREEN="$2"
        shift
        ;;
      -*) die "unknown option '$1'. Run 'scripts/rn-playground.sh help'." ;;
      *)
        [ -z "${DEV_DEVICE}" ] || die "unexpected argument '$1'. Run 'scripts/rn-playground.sh help'."
        DEV_DEVICE="$1"
        ;;
    esac
    shift
  done
  [ -n "${DEV_DEVICE}" ] || die "${usage} No default device is used."
}

reset_build_flags() {
  DEBUG=false
  IF_CHANGED=false
  POSITIONAL_ARG=""
}

offsider_bin() {
  if [ -x "${REPO_ROOT}/.build/debug/offsider" ]; then
    echo "${REPO_ROOT}/.build/debug/offsider"
  elif command -v offsider >/dev/null 2>&1; then
    command -v offsider
  else
    die "offsider not found at .build/debug/offsider or on PATH. Run 'swift build' first."
  fi
}

# The serial of the running emulator whose AVD is $1, else nothing.
running_serial_for_avd() {
  local adb="$1" avd="$2" devices serial state name
  devices=$("${adb}" devices)
  while read -r serial state; do
    case "${serial}" in emulator-*) ;; *) continue ;; esac
    [ "${state}" = device ] || continue
    name=$("${adb}" -s "${serial}" emu avd name </dev/null 2>/dev/null | tr -d '\r' | sed -n 1p) || name=""
    if [ "${name}" = "${avd}" ]; then
      echo "${serial}"
      return
    fi
  done <<<"${devices}"
}

print_metro_help() {
  echo "Metro runs in the background on 127.0.0.1:${METRO_PORT}. Log: ${METRO_LOG#"${REPO_ROOT}"/}. Stop it with 'scripts/rn-playground.sh metro stop'."
}

dev_ios() {
  parse_dev_args "a simulator is required: pnpm ios <udid> [--screen <screen>] (UDIDs from 'xcrun simctl list devices')." "$@"
  local udid="${DEV_DEVICE}"
  [[ "${udid}" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]] || die "'${udid}' is not a simulator UDID."
  xcrun simctl list devices booted | grep -qi "${udid}" || die "simulator ${udid} is not booted. Boot it first (xcrun simctl boot ${udid})."
  metro_start
  reset_build_flags
  build_ios "${udid}" --debug --if-changed
  reset_build_flags
  install_ios "${udid}" --debug
  if [ -n "${DEV_SCREEN}" ]; then
    xcrun simctl launch --terminate-running-process "${udid}" "${APP_ID}" --initialUrl "http://127.0.0.1:${METRO_PORT}" -OffsiderScreen "${DEV_SCREEN}"
  else
    xcrun simctl launch --terminate-running-process "${udid}" "${APP_ID}" --initialUrl "http://127.0.0.1:${METRO_PORT}"
  fi
  print_metro_help
}

dev_android() {
  parse_dev_args "an emulator is required: pnpm android <serial|avd> [--screen <screen>] (serials from 'adb devices')." "$@"
  local adb serial="" offsider
  adb=$(adb_bin)
  if [[ "${DEV_DEVICE}" =~ ^emulator-[0-9]+$ ]]; then
    "${adb}" -s "${DEV_DEVICE}" emu avd name >/dev/null 2>&1 || die "${DEV_DEVICE} is not a running emulator ('adb devices' lists them)."
    serial="${DEV_DEVICE}"
  else
    serial=$(running_serial_for_avd "${adb}" "${DEV_DEVICE}")
    if [ -z "${serial}" ]; then
      offsider=$(offsider_bin)
      echo "Booting ${DEV_DEVICE} with offsider boot"
      serial=$("${offsider}" boot "${DEV_DEVICE}" | tail -1 | tr -d '\r')
      [[ "${serial}" =~ ^emulator-[0-9]+$ ]] || die "offsider boot ${DEV_DEVICE} printed no emulator serial."
    fi
  fi
  metro_start
  reset_build_flags
  build_android --debug --if-changed
  reset_build_flags
  install_android "${serial}" --debug ||
    die "install failed on ${serial}. A release build signed with another key needs 'adb -s ${serial} uninstall ${APP_ID}' first."
  "${adb}" -s "${serial}" reverse "tcp:${METRO_PORT}" "tcp:${METRO_PORT}" >/dev/null
  echo "adb reverse: ${serial}'s 127.0.0.1:${METRO_PORT} reaches Metro on this Mac"
  "${adb}" -s "${serial}" shell am force-stop "${APP_ID}"
  "${adb}" -s "${serial}" shell am start -W -a android.intent.action.VIEW \
    -d "'exp+offsiderplaygroundrn://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A${METRO_PORT}'" "${APP_ID}"
  if [ -n "${DEV_SCREEN}" ]; then
    offsider=$(offsider_bin)
    "${offsider}" wait --id menu-title --timeout 180 --device "${serial}" ||
      die "the app did not show its menu within 180 s. Check ${METRO_LOG}."
    "${adb}" -s "${serial}" shell am start -W -a android.intent.action.VIEW -d "${SCREEN_URL}/${DEV_SCREEN}" "${APP_ID}"
  fi
  print_metro_help
}

# The process group in the pidfile when it is still alive, else nothing (a stale pidfile is removed).
metro_pgid() {
  local pgid
  [ -f "${METRO_PIDFILE}" ] || return 0
  pgid=$(tr -cd '0-9' <"${METRO_PIDFILE}")
  if [ -n "${pgid}" ] && kill -0 -- "-${pgid}" 2>/dev/null; then
    echo "${pgid}"
  else
    rm -f "${METRO_PIDFILE}"
  fi
}

metro_listeners() {
  lsof -nP -iTCP:"${METRO_PORT}" -sTCP:LISTEN -t 2>/dev/null | sort -u || true
}

metro_answers() {
  curl -fsS --max-time 2 "${METRO_STATUS_URL}" 2>/dev/null | grep -q 'packager-status:running'
}

# Fails when a process outside our Metro group listens on the port.
metro_check_port() {
  local ours="$1" pid pgid
  for pid in $(metro_listeners); do
    pgid=$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ') || pgid=""
    if [ -z "${ours}" ] || [ "${pgid}" != "${ours}" ]; then
      die "port ${METRO_PORT} is already in use by pid ${pid} ($(ps -o comm= -p "${pid}" 2>/dev/null || echo unknown)). Stop it first; this script only manages the Metro it started."
    fi
  done
}

# Replaces the calling (background) shell with the command as leader of a new session and process group.
exec_in_new_session() {
  if [ -x /usr/bin/perl ]; then
    exec /usr/bin/perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!\n"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' "$@"
  elif command -v python3 >/dev/null 2>&1; then
    exec python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
  else
    die "perl or python3 is required to start Metro in its own process group."
  fi
}

metro_start() {
  command -v pnpm >/dev/null 2>&1 || die "pnpm not found. Install pnpm 11 (brew install pnpm)."
  [ -d "${APP_DIR}/node_modules" ] || install_node_modules
  local pgid pid waited=0
  pgid=$(metro_pgid)
  metro_check_port "${pgid}"
  if [ -n "${pgid}" ]; then
    if metro_answers; then
      echo "Metro is already running (process group ${pgid}) on 127.0.0.1:${METRO_PORT}"
      return
    fi
    die "Metro (process group ${pgid}) is running but does not answer ${METRO_STATUS_URL}. Run 'scripts/rn-playground.sh metro stop' first."
  fi
  mkdir -p "${BUILD_DIR}"
  (
    cd "${APP_DIR}"
    export CI=1 EXPO_NO_TELEMETRY=1 EXPO_OFFLINE=1
    # --localhost binds the first address 'localhost' resolves to; ipv4first makes that 127.0.0.1, not ::1.
    export NODE_OPTIONS="${NODE_OPTIONS:+${NODE_OPTIONS} }--dns-result-order=ipv4first"
    exec_in_new_session pnpm exec expo start --dev-client --port "${METRO_PORT}" --localhost \
      </dev/null >"${METRO_LOG}" 2>&1 &
    echo $! >"${METRO_PIDFILE}"
  )
  pid=$(tr -cd '0-9' <"${METRO_PIDFILE}")
  sleep 1
  pgid=$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ') || pgid=""
  if [ "${pgid}" != "${pid}" ]; then
    kill -- "${pid}" 2>/dev/null || true
    rm -f "${METRO_PIDFILE}"
    tail -20 "${METRO_LOG}" >&2 || true
    die "Metro did not start in its own process group (pid ${pid}, group ${pgid:-none})."
  fi
  while ! metro_answers; do
    if ! kill -0 -- "-${pgid}" 2>/dev/null; then
      rm -f "${METRO_PIDFILE}"
      tail -40 "${METRO_LOG}" >&2 || true
      die "Metro exited before it answered ${METRO_STATUS_URL}. Log: ${METRO_LOG}"
    fi
    if [ "${waited}" -ge "${METRO_START_TIMEOUT}" ]; then
      metro_stop >/dev/null
      tail -40 "${METRO_LOG}" >&2 || true
      die "Metro did not answer ${METRO_STATUS_URL} within ${METRO_START_TIMEOUT}s. Log: ${METRO_LOG}"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "Metro is running (process group ${pgid}) on 127.0.0.1:${METRO_PORT}. Log: ${METRO_LOG}"
}

metro_stop() {
  local pgid waited=0
  pgid=$(metro_pgid)
  if [ -z "${pgid}" ]; then
    echo "Metro is not running"
    return
  fi
  kill -TERM -- "-${pgid}" 2>/dev/null || true
  while kill -0 -- "-${pgid}" 2>/dev/null; do
    if [ "${waited}" -ge 10 ]; then
      kill -KILL -- "-${pgid}" 2>/dev/null || true
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  rm -f "${METRO_PIDFILE}"
  echo "Metro stopped (process group ${pgid})"
}

metro_status() {
  local pgid
  pgid=$(metro_pgid)
  if [ -n "${pgid}" ] && metro_answers; then
    echo "Metro is running (process group ${pgid}) on 127.0.0.1:${METRO_PORT}"
    return 0
  fi
  if [ -n "${pgid}" ]; then
    echo "Metro (process group ${pgid}) is running but does not answer ${METRO_STATUS_URL}"
  else
    echo "Metro is not running"
    if [ -n "$(metro_listeners)" ]; then
      echo "Another process listens on ${METRO_PORT}: pid $(metro_listeners | tr '\n' ' ')"
    fi
  fi
  return 1
}

metro() {
  case "${1:-}" in
    start) metro_start ;;
    stop) metro_stop ;;
    status) metro_status ;;
    *) die "metro needs start, stop or status." ;;
  esac
}

command="${1:-help}"
shift || true

case "${command}" in
  build-ios) build_ios "$@" ;;
  build-android) build_android "$@" ;;
  install-ios) install_ios "$@" ;;
  install-android) install_android "$@" ;;
  path-ios) path_ios "$@" ;;
  path-android) path_android "$@" ;;
  fingerprint) print_fingerprint "$@" ;;
  launch-ios) launch_ios "$@" ;;
  launch-android) launch_android "$@" ;;
  metro) metro "$@" ;;
  dev-ios) dev_ios "$@" ;;
  dev-android) dev_android "$@" ;;
  help | -h | --help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
