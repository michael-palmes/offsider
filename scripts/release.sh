#!/usr/bin/env bash
# Offsider release pipeline: stage -> sign -> notarize -> package -> verify -> brew-gate.
# Consumes build_products/ from `scripts/build.sh xcframeworks` + `scripts/build.sh executable`.
# Used unchanged by release.yml (Developer ID), ci.yml (--adhoc) and local rehearsals. Bash 3.2 compatible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${REPO_ROOT}/build_products}"
ENTITLEMENTS="${ENTITLEMENTS:-${REPO_ROOT}/entitlements.plist}"
GITHUB_REPO="${GITHUB_REPO:-michael-palmes/offsider}"
TEAM_ID="${TEAM_ID:-Q4B8N8ZKA2}"
EXPECTED_AUTHORITY="${EXPECTED_AUTHORITY:-Developer ID Application: Michael Palmes (${TEAM_ID})}"

EXE=offsider
BUNDLE=Offsider_Offsider.bundle
BUNDLE_ID=com.mpalmes.offsider
FRAMEWORKS="FBControlCore XCTestBootstrap FBSimulatorControl FBDeviceControl"
LICENCE_FILES="LICENSE THIRD_PARTY_LICENSES"
# Exactly these, in this order. In a main executable @loader_path/Frameworks resolves to the same
# directory and Homebrew's fix_dynamic_linkage deletes the duplicate, then ad-hoc re-signs the binary.
EXE_RPATHS="/usr/lib/swift @executable_path/Frameworks"
# CoreSimulator ships with Xcode outside the SDK; FBSimulatorControl links it by absolute path.
LINKAGE_ALLOWED='^(@rpath/|/usr/lib/|/System/Library/|/Library/Developer/PrivateFrameworks/CoreSimulator\.framework/)'

VERSION=""
DIST="${REPO_ROOT}/dist"
STAGE=""
ARCHIVE=""
URL=""
ADHOC=0
CHECK_NOTARIZATION=0
SIGN_ID=""
SIGN_TS=""

CLEANUP=""
add_cleanup() { CLEANUP="$1; ${CLEANUP}"; }
run_cleanup() { set +e; eval "${CLEANUP}"; true; }
trap run_cleanup EXIT

die() { echo "release.sh: error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

usage() {
  cat <<'EOF'
Usage: scripts/release.sh <command> --version X.Y.Z[-pre] [options]

Commands:
  stage           Copy build_products into dist/offsider-<v>-arm64, normalise rpaths, sanitise
  sign            Sign inside-out with $OFFSIDER_SIGNING_IDENTITY (hardened runtime, timestamp)
  notarize        notarytool submit --wait ($OFFSIDER_NOTARY_KEY_PATH, $OFFSIDER_NOTARY_KEY_ID, $OFFSIDER_NOTARY_ISSUER_ID)
  package         Create dist/offsider-<v>-arm64.tar.gz and dist/SHA256SUMS
  verify          Extract the tarball and check layout, linkage, signatures, behaviour
  brew-gate       Install the tarball via a throwaway local tap and prove Homebrew changed nothing
  render-formula  Print Formula/offsider.rb for the GitHub release URL
  rehearse        stage, sign, [notarize], package, verify, brew-gate

Options:
  --version V            Required. No leading "v".
  --dist DIR             Output directory (default: ./dist)
  --stage DIR            Staged payload (default: DIST/offsider-V-arm64)
  --archive PATH         Tarball (default: DIST/offsider-V-arm64.tar.gz)
  --url URL              Formula URL override (render-formula)
  --adhoc                Sign ad-hoc; skip notarisation and Developer ID checks (CI)
  --check-notarization   verify: require Apple's online ticket for every code object
EOF
}

is_macho() { case "$(file -b "$1")" in Mach-O*) return 0 ;; *) return 1 ;; esac; }
is_executable_macho() { case "$(file -b "$1")" in *executable*) return 0 ;; *) return 1 ;; esac; }

macho_files() {
  find "$1" -type f | LC_ALL=C sort | while IFS= read -r f; do
    if is_macho "$f"; then printf '%s\n' "$f"; fi
  done
}

list_rpaths() {
  otool -l "$1" | awk '$1 == "cmd" { r = ($2 == "LC_RPATH") } r && $1 == "path" { print $2; r = 0 }'
}

list_linkage() { otool -L "$1" | tail -n +2 | awk '{ print $1 }'; }

# Mirrors Homebrew's MachOShim#resolve_variable_name: @loader_path always, @executable_path only for executables.
resolve_rpath() {
  local file="$1" rp="$2" dir
  dir="$(cd "$(dirname "$file")" && pwd -P)"
  case "$rp" in
    @loader_path*) rp="${dir}${rp#@loader_path}" ;;
    @executable_path*) if is_executable_macho "$file"; then rp="${dir}${rp#@executable_path}"; fi ;;
  esac
  if [ -d "$rp" ]; then (cd "$rp" && pwd -P); else printf '%s\n' "$rp"; fi
}

duplicate_rpaths() {
  local f="$1" rp
  for rp in $(list_rpaths "$f"); do resolve_rpath "$f" "$rp"; done | LC_ALL=C sort | uniq -d
}

normalise_executable_rpaths() {
  local exe="$1" rp
  for rp in $(list_rpaths "$exe"); do install_name_tool -delete_rpath "$rp" "$exe"; done
  for rp in $EXE_RPATHS; do install_name_tool -add_rpath "$rp" "$exe"; done
}

# Drop absolute rpaths (Xcode toolchain, build dirs) and rpaths that resolve to a duplicate.
sanitise_library_rpaths() {
  local f="$1" rp key seen="|"
  for rp in $(list_rpaths "$f"); do
    case "$rp" in
      @*|/usr/lib/swift) ;;
      *) log "  drop rpath ${rp} from ${f#"${STAGE}"/}"; install_name_tool -delete_rpath "$rp" "$f" ;;
    esac
  done
  for rp in $(list_rpaths "$f"); do
    key="$(resolve_rpath "$f" "$rp")"
    case "$seen" in
      *"|${key}|"*) log "  drop duplicate rpath ${rp} from ${f#"${STAGE}"/}"; install_name_tool -delete_rpath "$rp" "$f" ;;
      *) seen="${seen}${key}|" ;;
    esac
  done
}

sanitise() {
  find "$1" \( -name '._*' -o -name '.DS_Store' \) -exec rm -f {} +
  xattr -cr "$1"
}

cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

cdhashes() {
  local root="$1" name
  printf '%s %s\n' "$EXE" "$(cdhash "${root}/${EXE}")"
  for name in $FRAMEWORKS; do
    printf 'Frameworks/%s.framework %s\n' "$name" "$(cdhash "${root}/Frameworks/${name}.framework")"
  done
}

# Content manifest of the code payload (licence files are installed elsewhere by the formula).
manifest() {
  (cd "$1" && find "$EXE" "$BUNDLE" Frameworks \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
    else printf 'F %s %s\n' "$p" "$(shasum -a 256 "$p" | cut -d' ' -f1)"; fi
  done)
}

codesign_retry() {
  local attempt=1
  until codesign "$@"; do
    [ "$attempt" -lt 4 ] || die "codesign failed after ${attempt} attempts: $*"
    log "codesign failed (attempt ${attempt}); retrying in $((attempt * 15))s"
    sleep $((attempt * 15))
    attempt=$((attempt + 1))
  done
}

cs() { codesign_retry --force --sign "$SIGN_ID" --options runtime "$SIGN_TS" "$@"; }

need_version() {
  local re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
  [ -n "$VERSION" ] || die "--version is required"
  [[ "$VERSION" =~ $re ]] || die "invalid version '${VERSION}' (no leading v)"
  mkdir -p "$DIST"
  DIST="$(cd "$DIST" && pwd)"
  STAGE="${STAGE:-${DIST}/offsider-${VERSION}-arm64}"
  ARCHIVE="${ARCHIVE:-${DIST}/offsider-${VERSION}-arm64.tar.gz}"
}

# SwiftPM's Bundle.module falls back to an absolute .build path baked into the binary. Hide it
# so smoke tests prove the shipped layout works, not the build tree.
with_build_dir_hidden() {
  local b="${REPO_ROOT}/.build" h="${REPO_ROOT}/.build.hidden-by-release-sh"
  if [ -e "$b" ]; then
    mv "$b" "$h"
    add_cleanup "if [ -e $(printf %q "$h") ]; then mv $(printf %q "$h") $(printf %q "$b"); fi"
  fi
  "$@"
  if [ -e "$h" ]; then mv "$h" "$b"; fi
}

smoke() {
  local exe="$1" out
  out="$("$exe" --version)"
  [ "$out" = "$VERSION" ] || die "${exe} --version printed '${out}', expected '${VERSION}'"
  out="$("$exe" init --print)"
  case "$out" in *"name: offsider"*) ;; *) die "${exe} init --print did not find the resource bundle" ;; esac
}

require_line() { printf '%s\n' "$2" | grep -Fxq -- "$3" || die "$1: codesign output lacks '$3'"; }

verify_code() {
  local p="$1" kind="${2:-}" info line
  codesign --verify --strict --verbose=2 "$p"
  info="$(codesign -dv --verbose=4 "$p" 2>&1)"
  if [ "$ADHOC" = 1 ]; then
    require_line "$p" "$info" "Signature=adhoc"
    case "$info" in *"flags=0x10002(adhoc,runtime)"*) ;; *) die "$p: hardened runtime flag missing" ;; esac
  else
    for line in "Authority=${EXPECTED_AUTHORITY}" "Authority=Developer ID Certification Authority" \
                "Authority=Apple Root CA" "TeamIdentifier=${TEAM_ID}"; do
      require_line "$p" "$info" "$line"
    done
    case "$info" in *"flags=0x10000(runtime)"*) ;; *) die "$p: expected flags=0x10000(runtime)" ;; esac
    case "$info" in *"
Timestamp="*) ;; *) die "$p: no secure timestamp" ;; esac
  fi
  if [ "$kind" = exe ]; then
    require_line "$p" "$info" "Identifier=${BUNDLE_ID}"
    diff <(codesign -d --entitlements - --xml "$p" 2>/dev/null | plutil -convert xml1 -o - -) \
         <(plutil -convert xml1 -o - "$ENTITLEMENTS") >/dev/null \
      || die "$p: signed entitlements differ from ${ENTITLEMENTS}"
  fi
}

verify_signatures() {
  local root="$1" name
  for name in $FRAMEWORKS; do verify_code "${root}/Frameworks/${name}.framework"; done
  verify_code "${root}/${EXE}" exe
}

verify_tree() {
  local root="$1" top f rp bad
  top="$(cd "$root" && find . -mindepth 1 -maxdepth 1 | sed "s|^\./||" | LC_ALL=C sort | tr '\n' ' ')"
  [ "$top" = "Frameworks LICENSE Offsider_Offsider.bundle THIRD_PARTY_LICENSES offsider " ] \
    || die "unexpected top-level entries: ${top}"
  top="$(cd "${root}/Frameworks" && find . -mindepth 1 -maxdepth 1 | sed "s|^\./||" | LC_ALL=C sort | tr '\n' ' ')"
  [ "$top" = "FBControlCore.framework FBDeviceControl.framework FBSimulatorControl.framework XCTestBootstrap.framework " ] \
    || die "unexpected frameworks: ${top}"
  [ -z "$(find "$root" \( -name '._*' -o -name '.DS_Store' \) -print)" ] || die "AppleDouble or .DS_Store files present"
  [ "$(list_rpaths "${root}/${EXE}" | tr '\n' ' ')" = "${EXE_RPATHS} " ] \
    || die "executable rpaths are not exactly: ${EXE_RPATHS}"
  macho_files "$root" | while IFS= read -r f; do
    [ "$(lipo -archs "$f")" = arm64 ] || die "${f#"$root"/}: not arm64-only"
    for rp in $(list_rpaths "$f"); do
      case "$rp" in @*|/usr/lib/swift) ;; *) die "${f#"$root"/}: absolute rpath ${rp}" ;; esac
    done
    [ -z "$(duplicate_rpaths "$f")" ] || die "${f#"$root"/}: rpaths resolve to duplicates (Homebrew would rewrite and re-sign)"
    bad="$(list_linkage "$f" | grep -Ev "$LINKAGE_ALLOWED" || true)"
    [ -z "$bad" ] || die "${f#"$root"/}: load commands outside the allowed prefixes: ${bad}"
  done
}

render_formula() {  # version url sha256 [explicit]
  local version_line=""
  if [ "${4:-}" = explicit ]; then version_line="  version \"$1\""$'\n'; fi
  cat <<EOF
class Offsider < Formula
  desc "Drive iOS Simulators from the terminal and AI agents"
  homepage "https://github.com/${GITHUB_REPO}"
  url "$2"
${version_line}  sha256 "$3"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on xcode: "26.0"

  # Pre-built, Developer ID signed and notarised payload. Keep @rpath install names so
  # Homebrew's relocation does not rewrite the frameworks and replace their signatures.
  preserve_rpath

  def install
    libexec.install "offsider", "Offsider_Offsider.bundle", "Frameworks"
    prefix.install "LICENSE", "THIRD_PARTY_LICENSES"
    bin.install_symlink libexec/"offsider"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/offsider --version")
    assert_match "name: offsider", shell_output("#{bin}/offsider init --print")
  end
end
EOF
}

cmd_stage() {
  need_version
  local name fw lf copy="ditto --norsrc --noextattr --noqtn --noacl"
  [ -x "${BUILD_OUTPUT_DIR}/${EXE}" ] || die "missing ${BUILD_OUTPUT_DIR}/${EXE} (run scripts/build.sh executable)"
  [ -d "${BUILD_OUTPUT_DIR}/${BUNDLE}" ] || die "missing ${BUILD_OUTPUT_DIR}/${BUNDLE}"
  rm -rf "$STAGE"
  mkdir -p "${STAGE}/Frameworks"
  $copy "${BUILD_OUTPUT_DIR}/${EXE}" "${STAGE}/${EXE}"
  $copy "${BUILD_OUTPUT_DIR}/${BUNDLE}" "${STAGE}/${BUNDLE}"
  for name in $FRAMEWORKS; do
    fw="${STAGE}/Frameworks/${name}.framework"
    [ -d "${BUILD_OUTPUT_DIR}/Frameworks/${name}.framework" ] || die "missing ${name}.framework"
    $copy "${BUILD_OUTPUT_DIR}/Frameworks/${name}.framework" "$fw"
    [ "$(readlink "${fw}/Versions/Current")" = A ] || die "${name}.framework: Versions/Current is not A"
    # Build-time only; not needed at runtime and not worth shipping or sealing.
    rm -rf "${fw}/Headers" "${fw}/PrivateHeaders" "${fw}/Modules" \
           "${fw}/Versions/A/Headers" "${fw}/Versions/A/PrivateHeaders" "${fw}/Versions/A/Modules"
  done
  for lf in $LICENCE_FILES; do cp "${REPO_ROOT}/${lf}" "${STAGE}/${lf}"; done
  sanitise "$STAGE"
  normalise_executable_rpaths "${STAGE}/${EXE}"
  macho_files "${STAGE}/Frameworks" | while IFS= read -r f; do sanitise_library_rpaths "$f"; done
  log "staged ${STAGE}"
}

cmd_sign() {
  need_version
  local name fw main
  if [ "$ADHOC" = 1 ]; then
    SIGN_ID="-"; SIGN_TS="--timestamp=none"
  else
    SIGN_ID="${OFFSIDER_SIGNING_IDENTITY:?set OFFSIDER_SIGNING_IDENTITY to the Developer ID Application name or SHA-1}"
    SIGN_TS="--timestamp"
  fi
  for name in $FRAMEWORKS; do
    fw="${STAGE}/Frameworks/${name}.framework"
    main="${fw}/Versions/A/${name}"
    [ -f "$main" ] || die "missing ${main}"
    if [ -n "$(find "$fw" -mindepth 1 -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' \) -print)" ]; then
      die "${name}.framework contains nested bundles; add explicit inside-out signing for them"
    fi
    # Loose code inside the framework (dylibs, helpers) first, then the framework itself.
    macho_files "$fw" | while IFS= read -r f; do
      if [ "$f" != "$main" ]; then cs "$f"; fi
    done
    cs "$fw"
  done
  cs --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "${STAGE}/${EXE}"
  verify_signatures "$STAGE"
  log "signed ${STAGE} as ${SIGN_ID}"
}

cmd_notarize() {
  need_version
  : "${OFFSIDER_NOTARY_KEY_PATH:?}" "${OFFSIDER_NOTARY_KEY_ID:?}" "${OFFSIDER_NOTARY_ISSUER_ID:?}"
  command -v jq >/dev/null || die "jq is required (brew install jq)"
  local zip id status
  local auth=(--key "$OFFSIDER_NOTARY_KEY_PATH" --key-id "$OFFSIDER_NOTARY_KEY_ID" --issuer "$OFFSIDER_NOTARY_ISSUER_ID")
  zip="${DIST}/$(basename "$STAGE").zip"
  rm -f "$zip"
  ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$STAGE" "$zip"
  cdhashes "$STAGE" > "${DIST}/notarised-cdhashes.txt"
  log "submitting $(basename "$zip") to Apple notary service"
  xcrun notarytool submit "$zip" "${auth[@]}" --wait --timeout 1h --output-format json \
    > "${DIST}/notary-submit.json" || true
  id="$(jq -r '.id // empty' "${DIST}/notary-submit.json" 2>/dev/null || true)"
  status="$(jq -r '.status // empty' "${DIST}/notary-submit.json" 2>/dev/null || true)"
  [ -n "$id" ] || { cat "${DIST}/notary-submit.json" >&2; die "notarytool submit failed"; }
  xcrun notarytool log "$id" "${auth[@]}" "${DIST}/notary-log.json" || true
  if [ "$status" != Accepted ]; then
    cat "${DIST}/notary-log.json" >&2 || true
    die "notarisation ${id} finished with status '${status}'"
  fi
  if [ "$(jq -r '.issues | length' "${DIST}/notary-log.json" 2>/dev/null || echo 0)" != 0 ]; then
    log "notary accepted with issues:"; jq '.issues' "${DIST}/notary-log.json" >&2
  fi
  rm -f "$zip"
  log "notarised: submission ${id}"
}

cmd_package() {
  need_version
  sanitise "$STAGE"
  rm -f "$ARCHIVE" "$(dirname "$ARCHIVE")/SHA256SUMS"
  # shellcheck disable=SC2086
  COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata --no-xattrs --no-acls --no-fflags \
    --uid 0 --gid 0 --numeric-owner \
    -czf "$ARCHIVE" -C "$STAGE" "$EXE" "$BUNDLE" Frameworks $LICENCE_FILES
  (cd "$(dirname "$ARCHIVE")" && shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS)
  log "packaged $(cat "$(dirname "$ARCHIVE")/SHA256SUMS")"
}

cmd_verify() {
  need_version
  local x listing f n
  [ -f "$ARCHIVE" ] || die "archive not found: ${ARCHIVE}"
  x="$(mktemp -d)"; listing="$(mktemp)"
  add_cleanup "rm -rf $(printf %q "$x") $(printf %q "$listing")"
  (cd "$(dirname "$ARCHIVE")" && shasum -a 256 -c SHA256SUMS)
  /usr/bin/tar -tzf "$ARCHIVE" > "$listing"
  if grep -Eq '(^|/)\._' "$listing"; then die "archive contains AppleDouble entries"; fi
  /usr/bin/tar -xzf "$ARCHIVE" -C "$x"
  verify_tree "$x"
  verify_signatures "$x"
  if [ -f "${DIST}/notarised-cdhashes.txt" ]; then
    diff <(cdhashes "$x") "${DIST}/notarised-cdhashes.txt" || die "shipped code differs from the notarised submission"
  fi
  with_build_dir_hidden smoke "${x}/${EXE}"
  if [ "$CHECK_NOTARIZATION" = 1 ]; then
    for f in "${x}/${EXE}" "${x}"/Frameworks/*.framework; do
      n=1
      until codesign --verify --check-notarization -R='notarized' --verbose=2 "$f"; do
        [ "$n" -lt 10 ] || die "${f#"$x"/}: no notarisation ticket visible from Apple"
        log "ticket not visible yet for ${f#"$x"/} (attempt ${n}); retrying in 30s"
        sleep 30; n=$((n + 1))
      done
    done
  fi
  log "spctl (informational; for a bare CLI '-t exec' reports 'rejected ... not an app')"
  spctl -a -t exec -vv "${x}/${EXE}" 2>&1 || true
  spctl -a -t open --context context:primary-signature -vv "${x}/${EXE}" 2>&1 || true
  log "verified ${ARCHIVE}"
}

# Homebrew with a throwaway user config (trust store, brew.env) so the gate never edits the
# user's own. The user brew.env is loaded after the prefix one, so its allow list wins.
GATE_CONFIG_HOME=""
gate_brew() { XDG_CONFIG_HOME="$GATE_CONFIG_HOME" brew "$@"; }

cmd_brew_gate() {
  need_version
  command -v brew >/dev/null || die "Homebrew not found"
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
  if brew list --formula offsider >/dev/null 2>&1; then
    die "offsider is already installed; run 'brew uninstall offsider' before the gate"
  fi
  local root tapdir tap="offsider-gate/local" sha keg archive_abs user_cfg allowed
  root="$(mktemp -d)"; root="$(cd "$root" && pwd -P)"; add_cleanup "rm -rf $(printf %q "$root")"
  tapdir="${root}/homebrew-local"; mkdir -p "${tapdir}/Formula"
  GATE_CONFIG_HOME="${root}/config"; mkdir -p "${GATE_CONFIG_HOME}/homebrew"
  user_cfg="${HOME}/.homebrew"
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then user_cfg="${XDG_CONFIG_HOME}/homebrew"; fi
  if [ -f "${user_cfg}/brew.env" ]; then
    grep -v '^HOMEBREW_ALLOWED_TAPS=' "${user_cfg}/brew.env" > "${GATE_CONFIG_HOME}/homebrew/brew.env" || true
  fi
  if [ -f "${user_cfg}/trust.json" ]; then cp "${user_cfg}/trust.json" "${GATE_CONFIG_HOME}/homebrew/trust.json"; fi
  allowed="$(brew config 2>/dev/null | sed -n 's/^HOMEBREW_ALLOWED_TAPS: //p')"
  if [ -n "$allowed" ]; then
    # A tap with a custom remote only matches an allow list entry naming that remote (the path).
    printf 'HOMEBREW_ALLOWED_TAPS=%s %s %s\n' "$allowed" "$tap" "$tapdir" >> "${GATE_CONFIG_HOME}/homebrew/brew.env"
  fi
  archive_abs="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
  sha="$(shasum -a 256 "$archive_abs" | cut -d' ' -f1)"
  # file:// URLs do not yield a version (brew parses "64"), so the gate formula states it.
  render_formula "$VERSION" "file://${archive_abs}" "$sha" explicit > "${tapdir}/Formula/offsider.rb"
  git -C "$tapdir" init -q
  git -C "$tapdir" add Formula/offsider.rb
  git -C "$tapdir" -c user.name=release-gate -c user.email=release-gate@localhost -c commit.gpgsign=false \
    commit -q -m "offsider ${VERSION} (gate)"
  gate_brew untap --force "$tap" >/dev/null 2>&1 || true
  gate_brew tap "$tap" "$tapdir"
  add_cleanup "gate_brew uninstall --force offsider >/dev/null 2>&1; gate_brew untap --force ${tap} >/dev/null 2>&1"
  # Homebrew 7 refuses to load formulae from taps that are not trusted.
  gate_brew trust --tap "$tap"
  gate_brew install --formula --verbose "${tap}/offsider"
  keg="$(brew --cellar)/offsider/${VERSION}"
  [ -d "${keg}/libexec" ] || die "keg not found at ${keg}"
  diff <(manifest "$STAGE") <(manifest "${keg}/libexec") || die "Homebrew modified the installed payload"
  verify_signatures "${keg}/libexec"
  with_build_dir_hidden smoke "$(brew --prefix)/bin/offsider"
  gate_brew test --verbose "${tap}/offsider"
  log "Homebrew gate passed: payload byte-identical, signatures intact"
}

cmd_render_formula() {
  need_version
  local sha url
  sha="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
  url="${URL:-https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/offsider-${VERSION}-arm64.tar.gz}"
  render_formula "$VERSION" "$url" "$sha"
}

cmd_rehearse() {
  need_version
  cmd_stage
  cmd_sign
  if [ "$ADHOC" = 0 ]; then cmd_notarize; CHECK_NOTARIZATION=1; fi
  cmd_package
  cmd_verify
  cmd_brew_gate
  log "rehearsal complete: ${ARCHIVE}"
}

command_name="${1:-help}"
if [ $# -gt 0 ]; then shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?}"; shift 2 ;;
    --dist) DIST="${2:?}"; shift 2 ;;
    --stage) STAGE="${2:?}"; shift 2 ;;
    --archive) ARCHIVE="${2:?}"; shift 2 ;;
    --url) URL="${2:?}"; shift 2 ;;
    --adhoc) ADHOC=1; shift ;;
    --check-notarization) CHECK_NOTARIZATION=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$command_name" in
  stage) cmd_stage ;;
  sign) cmd_sign ;;
  notarize) cmd_notarize ;;
  package) cmd_package ;;
  verify) cmd_verify ;;
  brew-gate) cmd_brew_gate ;;
  render-formula) cmd_render_formula ;;
  rehearse) cmd_rehearse ;;
  help) usage ;;
  *) usage >&2; die "unknown command: ${command_name}" ;;
esac
