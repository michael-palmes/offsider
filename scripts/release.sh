#!/usr/bin/env bash
# Offsider release pipeline: stage -> sign -> notarize -> record -> package -> verify -> brew-gate.
# Consumes build_products/ from `scripts/build.sh xcframeworks` + `scripts/build.sh executable`.
# Used unchanged by release.yml (Developer ID), ci.yml (--adhoc) and local rehearsals. Bash 3.2 compatible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${REPO_ROOT}/build_products}"
# Release builds keep library validation on (entitlements.plist is empty); only ad-hoc builds, which carry no
# Team ID, need entitlements-adhoc.plist to load the frameworks. Resolved after the arguments are parsed.
ENTITLEMENTS="${ENTITLEMENTS:-}"
GITHUB_REPO="${GITHUB_REPO:-michael-palmes/offsider}"
# The signing team comes from the environment (.env locally, a secret in CI); Developer ID checks need it.
TEAM_ID="${TEAM_ID:-}"
EXPECTED_AUTHORITY="${EXPECTED_AUTHORITY:-Developer ID Application: Michael Palmes (${TEAM_ID})}"

EXE=offsider
BUNDLE=Offsider_Offsider.bundle
HELPER_DIR="${BUNDLE}/Contents/Resources/helper"
HELPER_MANIFEST_SOURCE="${REPO_ROOT}/Sources/Offsider/Resources/helper/manifest.json"
BUNDLE_ID=com.mpalmes.offsider
FRAMEWORKS="FBControlCore XCTestBootstrap FBSimulatorControl FBDeviceControl"
LICENCE_FILES="LICENSE THIRD_PARTY_LICENSES"
# Exactly these, in this order. In a main executable @loader_path/Frameworks resolves to the same
# directory and Homebrew's fix_dynamic_linkage deletes the duplicate, then ad-hoc re-signs the binary.
EXE_RPATHS="/usr/lib/swift @executable_path/Frameworks"
# CoreSimulator ships with Xcode outside the SDK; FBSimulatorControl links it by absolute path.
LINKAGE_ALLOWED='^(@rpath/|/usr/lib/|/System/Library/|/Library/Developer/PrivateFrameworks/CoreSimulator\.framework/)'
# What a tarball may unpack to: far above a release (about 100 MB in a few hundred entries), far below what fills a runner's disk.
UNPACK_MAX_BYTES=$((1024 * 1024 * 1024))
UNPACK_MAX_ENTRIES=20000

VERSION=""
DIST="${REPO_ROOT}/dist"
STAGE=""
ARCHIVE=""
RECORD_DIR=""
SBOM=""
SHA256_EXPECTED=""
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
  record          Write build-info.txt and offsider-<v>.cdx.json (scripts/sbom.sh) and copy SECURITY.md, beside the tarball
  package         Create dist/offsider-<v>-arm64.tar.gz and dist/SHA256SUMS (the tarball, then record's three files)
  pack-payload    Create dist/offsider-<v>-arm64-unsigned.tar.gz and dist/PAYLOAD.sha256 from the stage
  unpack-payload  Recreate the stage from the unsigned payload (the signing job); --sha256 checks it first
  unpack-archive  Recreate the stage from the signed tarball (the verify job)
  verify          Extract the tarball and check layout, linkage, signatures, behaviour
  brew-gate       Install the tarball via a throwaway local tap and prove Homebrew changed nothing
  render-formula  Print Formula/offsider.rb for the GitHub release URL
  rehearse        stage, sign, [notarize], record, package, verify, brew-gate
  check-security  Fail unless line 1 of SECURITY.md reads "**As of version <v>.**"
  tag             Make the signed tag v<v>: needs check-security to pass, a clean main equal to
                  origin/main (fetched first) and an unused tag. Never pushes; prints the push command.

Options:
  --version V            Required, except by rehearse (default: git describe, without the leading "v"). No leading "v".
  --dist DIR             Output directory (default: ./dist)
  --stage DIR            Staged payload (default: DIST/offsider-V-arm64)
  --archive PATH         Tarball (default: DIST/offsider-V-arm64.tar.gz)
  --url URL              Formula URL override (render-formula)
  --adhoc                Sign ad-hoc; skip notarisation and Developer ID checks (CI)
  --check-notarization   verify: require Apple's online ticket for every code object
  --sha256 HEX           unpack-payload: the payload digest the build job recorded (default: dist/PAYLOAD.sha256)
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

check_version() {
  local re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
  [ -n "$VERSION" ] || die "--version is required"
  [[ "$VERSION" =~ $re ]] || die "invalid version '${VERSION}' (no leading v)"
}

need_version() {
  check_version
  mkdir -p "$DIST"
  DIST="$(cd "$DIST" && pwd)"
  STAGE="${STAGE:-${DIST}/offsider-${VERSION}-arm64}"
  ARCHIVE="${ARCHIVE:-${DIST}/offsider-${VERSION}-arm64.tar.gz}"
  RECORD_DIR="$(dirname "$ARCHIVE")"
  SBOM="${RECORD_DIR}/offsider-${VERSION}.cdx.json"
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
    [ -n "$TEAM_ID" ] || die "set TEAM_ID (the Apple team that signs releases) in .env; --adhoc needs no team"
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

# The bundled Android helper must be the committed dex, byte for byte as its manifest describes.
verify_helper() {
  local root="$1" manifest dex want have
  manifest="${root}/${HELPER_DIR}/manifest.json"
  dex="${root}/${HELPER_DIR}/offsider-helper.dex"
  if [ ! -f "$dex" ] || [ ! -f "$manifest" ]; then die "${HELPER_DIR}: helper dex or manifest missing"; fi
  cmp -s "$manifest" "$HELPER_MANIFEST_SOURCE" || die "${HELPER_DIR}/manifest.json differs from the committed manifest"
  want="$(plutil -extract dex.sha256 raw -o - "$manifest")"
  have="$(shasum -a 256 "$dex" | cut -d' ' -f1)"
  [ "$want" = "$have" ] || die "${HELPER_DIR}/offsider-helper.dex has sha256 ${have}, its manifest says ${want}"
}

render_formula() {  # version url sha256 [explicit]
  local version_line=""
  if [ "${4:-}" = explicit ]; then version_line="  version \"$1\""$'\n'; fi
  cat <<EOF
class Offsider < Formula
  desc "Inspect and drive iOS and Android simulators, emulators and USB devices"
  homepage "https://offsidercli.com/"
  url "$2"
${version_line}  sha256 "$3"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe
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
  verify_helper "$STAGE"
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

# The signing job never builds: it signs a payload the build job packed, after checking its digest.
cmd_pack_payload() {
  need_version
  local payload="${DIST}/offsider-${VERSION}-arm64-unsigned.tar.gz"
  [ -d "$STAGE" ] || die "stage not found: ${STAGE} (run stage first)"
  sanitise "$STAGE"
  rm -f "$payload" "${DIST}/PAYLOAD.sha256"
  # shellcheck disable=SC2086
  COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata --no-xattrs --no-acls --no-fflags \
    --uid 0 --gid 0 --numeric-owner \
    -czf "$payload" -C "$STAGE" "$EXE" "$BUNDLE" Frameworks $LICENCE_FILES
  (cd "$DIST" && shasum -a 256 "$(basename "$payload")" > PAYLOAD.sha256)
  log "packed $(cat "${DIST}/PAYLOAD.sha256")"
}

# Before anything is unpacked: only plain files, folders and links inside the tree, within the entry and byte caps.
vet_tarball() {
  local tarball="$1" names listing line path mode size target total=0 count=0
  names="$(mktemp)"; listing="$(mktemp)"
  add_cleanup "rm -f $(printf %q "$names") $(printf %q "$listing")"
  /usr/bin/tar -tzf "$tarball" > "$names" 2>/dev/null || die "${tarball}: cannot be listed"
  /usr/bin/tar -tvzf "$tarball" --numeric-owner > "$listing" 2>/dev/null || die "${tarball}: cannot be listed"
  [ "$(wc -l < "$names")" = "$(wc -l < "$listing")" ] || die "${tarball}: its two listings disagree"
  while IFS= read -r path; do
    case "$path" in /*) die "${tarball}: absolute path ${path}" ;; esac
    case "/${path}/" in */../*) die "${tarball}: path with .. ${path}" ;; esac
  done < "$names"
  while IFS= read -r line; do
    mode="${line%% *}"
    read -r _ _ _ _ size _ <<< "$line"
    case "$mode" in
      -*|d*) ;;
      l*)
        target="${line##* -> }"
        case "$target" in /*) die "${tarball}: link to an absolute path: ${line}" ;; esac
        case "/${target}/" in */../*) die "${tarball}: link with ..: ${line}" ;; esac
        ;;
      *) die "${tarball}: not a plain file, folder or link: ${line}" ;;
    esac
    [[ "$size" =~ ^[0-9]+$ ]] || die "${tarball}: unreadable size: ${line}"
    total=$((total + size)); count=$((count + 1))
    [ "$total" -le "$UNPACK_MAX_BYTES" ] || die "${tarball}: unpacks to more than ${UNPACK_MAX_BYTES} bytes"
    [ "$count" -le "$UNPACK_MAX_ENTRIES" ] || die "${tarball}: more than ${UNPACK_MAX_ENTRIES} entries"
  done < "$listing"
}

unpack_into_stage() {
  local tarball="$1"
  [ -f "$tarball" ] || die "tarball not found: ${tarball}"
  vet_tarball "$tarball"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  /usr/bin/tar -xzf "$tarball" -C "$STAGE"
  verify_tree "$STAGE"
  verify_helper "$STAGE"
  log "unpacked ${tarball} into ${STAGE}"
}

cmd_unpack_payload() {
  need_version
  local payload="${DIST}/offsider-${VERSION}-arm64-unsigned.tar.gz" actual
  [ -f "$payload" ] || die "payload not found: ${payload}"
  if [ -n "$SHA256_EXPECTED" ]; then
    [[ "$SHA256_EXPECTED" =~ ^[0-9a-f]{64}$ ]] || die "--sha256 must be 64 lowercase hex characters"
    actual="$(shasum -a 256 "$payload" | cut -d' ' -f1)"
    [ "$actual" = "$SHA256_EXPECTED" ] || die "payload digest mismatch: expected ${SHA256_EXPECTED}, got ${actual}"
    log "payload digest matches ${SHA256_EXPECTED}"
  else
    (cd "$DIST" && shasum -a 256 -c PAYLOAD.sha256)
  fi
  unpack_into_stage "$payload"
}

cmd_unpack_archive() {
  need_version
  (cd "$DIST" && shasum -a 256 -c SHA256SUMS)
  unpack_into_stage "$ARCHIVE"
}

# Line 1 of SECURITY.md names the version it describes; trailing spaces and one CR are let through, nothing else.
check_security_version() {
  local file="${REPO_ROOT}/SECURITY.md" line="" want="**As of version ${VERSION}.**"
  [ -f "$file" ] || die "SECURITY.md not found in ${REPO_ROOT}"
  IFS= read -r line < "$file" || true
  line="${line%$'\r'}"
  while [ "${line% }" != "$line" ]; do line="${line% }"; done
  [ "$line" = "$want" ] || die "line 1 of SECURITY.md must read '${want}' (it reads '${line}'); change it in the release pull request"
}

cmd_check_security() {
  check_version
  check_security_version
  log "SECURITY.md names version ${VERSION}"
}

# What a rebuild would need to know; outside GitHub Actions the runner fields read "local".
write_build_info() {
  local pin_url pin_ref commit xcode swift_version macos dex line
  # shellcheck disable=SC2016
  pin_url="$(sed -n 's/^IDB_GIT_URL="\${IDB_GIT_URL:-\(https:[^}]*\)}"$/\1/p' "${SCRIPT_DIR}/build.sh")"
  pin_ref="$(sed -n 's/^DEFAULT_IDB_GIT_REF="\([0-9a-f]\{40\}\)"$/\1/p' "${SCRIPT_DIR}/build.sh")"
  if [ -z "$pin_url" ] || [ -z "$pin_ref" ]; then die "no idb fork URL or pin in ${SCRIPT_DIR}/build.sh"; fi
  commit="$(git -C "$REPO_ROOT" rev-parse HEAD)" || die "build-info.txt needs the commit: ${REPO_ROOT} is not a git checkout"
  git -C "$REPO_ROOT" diff --quiet HEAD || commit="${commit}-dirty"
  macos="$(sw_vers -productVersion) $(sw_vers -buildVersion)"
  xcode="$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')"
  swift_version="$(swift --version 2>&1 | sed -n 1p)"
  dex="$(plutil -extract dex.sha256 raw -o - "$HELPER_MANIFEST_SOURCE")"
  {
    echo "version=${VERSION}"
    echo "commit=${commit}"
    echo "workflow_ref=${GITHUB_WORKFLOW_REF:-local}"
    echo "run_id=${GITHUB_RUN_ID:-local}"
    echo "run_attempt=${GITHUB_RUN_ATTEMPT:-local}"
    echo "runner_environment=${RUNNER_ENVIRONMENT:-local}"
    echo "runner_labels=${RELEASE_RUNNER_LABELS:-local}"
    echo "runner_image=${ImageOS:-local}${ImageVersion:+ ${ImageVersion}}"
    echo "macos=${macos}"
    echo "xcode=${xcode}"
    echo "swift=${swift_version}"
    echo "idb=${pin_url}@${pin_ref}"
    echo "helper_dex_sha256=${dex}"
  } > "${RECORD_DIR}/build-info.txt"
  while IFS= read -r line; do
    case "$line" in ?*=?*) ;; *) die "build-info.txt has an empty value: '${line}'" ;; esac
  done < "${RECORD_DIR}/build-info.txt"
}

cmd_record() {
  need_version
  mkdir -p "$RECORD_DIR"
  rm -f "${RECORD_DIR}/build-info.txt" "$SBOM" "${RECORD_DIR}/SECURITY.md"
  write_build_info
  "${SCRIPT_DIR}/sbom.sh" --version "$VERSION" --output "$SBOM"
  cp "${REPO_ROOT}/SECURITY.md" "${RECORD_DIR}/SECURITY.md"
  log "recorded build-info.txt, $(basename "$SBOM") and SECURITY.md in ${RECORD_DIR}"
}

cmd_package() {
  need_version
  local f
  for f in build-info.txt "$(basename "$SBOM")" SECURITY.md; do
    [ -f "${RECORD_DIR}/${f}" ] || die "missing ${RECORD_DIR}/${f} (run record first)"
  done
  sanitise "$STAGE"
  rm -f "$ARCHIVE" "${RECORD_DIR}/SHA256SUMS"
  # shellcheck disable=SC2086
  COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata --no-xattrs --no-acls --no-fflags \
    --uid 0 --gid 0 --numeric-owner \
    -czf "$ARCHIVE" -C "$STAGE" "$EXE" "$BUNDLE" Frameworks $LICENCE_FILES
  (cd "$RECORD_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" build-info.txt "$(basename "$SBOM")" SECURITY.md > SHA256SUMS)
  log "packaged:"
  cat "${RECORD_DIR}/SHA256SUMS" >&2
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
  vet_tarball "$ARCHIVE"
  /usr/bin/tar -xzf "$ARCHIVE" -C "$x"
  verify_tree "$x"
  verify_helper "$x"
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

# rehearse alone may leave out --version: it takes git describe's, without the leading v and keeping -dirty.
default_rehearse_version() {
  [ -z "$VERSION" ] || return 0
  VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || true)"
  VERSION="${VERSION#v}"
  [ -n "$VERSION" ] || die "--version is required: git describe found no version"
  log "rehearse: using version ${VERSION} from git describe"
}

# Every variable a signed rehearsal reads, checked before any work, so one run names all that are missing.
require_rehearse_variables() {
  local name missing=""
  [ "$ADHOC" = 0 ] || return 0
  for name in OFFSIDER_SIGNING_IDENTITY OFFSIDER_NOTARY_KEY_PATH OFFSIDER_NOTARY_KEY_ID OFFSIDER_NOTARY_ISSUER_ID TEAM_ID; do
    [ -n "${!name:-}" ] || missing="${missing} ${name}"
  done
  [ -n "$missing" ] || return 0
  echo "release.sh: error: rehearse needs these set:${missing}" >&2
  echo "Try: fill them in .env (see .env.example), run 'set -a; . ./.env; set +a', then rehearse again; --adhoc needs none of them" >&2
  exit 1
}

cmd_rehearse() {
  default_rehearse_version
  require_rehearse_variables
  need_version
  cmd_stage
  cmd_sign
  if [ "$ADHOC" = 0 ]; then cmd_notarize; CHECK_NOTARIZATION=1; fi
  cmd_record
  cmd_package
  cmd_verify
  cmd_brew_gate
  log "rehearsal complete: ${ARCHIVE}"
}

# The release starts when the tag is pushed, and a person pushes it: this stops at the signed tag.
cmd_tag() {
  check_version
  local tag="v${VERSION}" head remote
  git_repo() { git -C "$REPO_ROOT" "$@"; }
  [ "$(git_repo symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = main ] \
    || die "check out main first: a release is tagged on main"
  [ -z "$(git_repo status --porcelain)" ] || die "the working tree has changes; commit or remove them, then tag"
  git_repo fetch --quiet --no-tags origin "+refs/heads/main:refs/remotes/origin/main" \
    || die "could not fetch origin's main, so main cannot be compared with it"
  head="$(git_repo rev-parse HEAD)"
  [ "$head" = "$(git_repo rev-parse refs/remotes/origin/main)" ] \
    || die "main is not origin/main; pull or push until they match, then tag"
  check_security_version
  ! git_repo rev-parse --quiet --verify "refs/tags/${tag}" >/dev/null || die "tag ${tag} already exists here"
  remote="$(git_repo ls-remote --tags origin "refs/tags/${tag}")" || die "could not ask origin whether ${tag} exists"
  [ -z "$remote" ] || die "tag ${tag} already exists on origin"
  git_repo tag -s "$tag" -m "Offsider ${VERSION}" || die "could not make the signed tag ${tag}; check git's signing key"
  log "tagged ${tag} at ${head}; nothing was pushed. Push it to start the release:"
  echo "git push origin ${tag}"
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
    --sha256) SHA256_EXPECTED="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ -z "$ENTITLEMENTS" ]; then
  if [ "$ADHOC" = 1 ]; then ENTITLEMENTS="${REPO_ROOT}/entitlements-adhoc.plist"; else ENTITLEMENTS="${REPO_ROOT}/entitlements.plist"; fi
fi
if [ "$ADHOC" = 0 ] && [ "$command_name" != help ] \
   && /usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$ENTITLEMENTS" >/dev/null 2>&1; then
  die "release builds keep library validation on; ${ENTITLEMENTS} disables it (ad-hoc builds use entitlements-adhoc.plist)"
fi

case "$command_name" in
  stage) cmd_stage ;;
  sign) cmd_sign ;;
  notarize) cmd_notarize ;;
  package) cmd_package ;;
  pack-payload) cmd_pack_payload ;;
  unpack-payload) cmd_unpack_payload ;;
  unpack-archive) cmd_unpack_archive ;;
  verify) cmd_verify ;;
  brew-gate) cmd_brew_gate ;;
  render-formula) cmd_render_formula ;;
  rehearse) cmd_rehearse ;;
  record) cmd_record ;;
  check-security) cmd_check_security ;;
  tag) cmd_tag ;;
  help) usage ;;
  *) usage >&2; die "unknown command: ${command_name}" ;;
esac
