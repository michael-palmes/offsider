#!/usr/bin/env bash
# Renders the release SBOM (CycloneDX 1.6 JSON) from the committed pins. Bash 3.2 and jq only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITHUB_REPO="${GITHUB_REPO:-michael-palmes/offsider}"
VERSION=""
OUTPUT=""
COMMIT=""
IDB_CHECKOUT=""
IDB_REQUIRED=0

# Loaded at run time from the person's Xcode or macOS, never shipped: name, provider, where it lives.
RUNTIME_FRAMEWORKS="
CoreSimulator Xcode /Library/Developer/PrivateFrameworks/CoreSimulator.framework
CoreDevice Xcode /Library/Developer/PrivateFrameworks/CoreDevice.framework
SimulatorKit Xcode Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework
DTXConnectionServices Xcode Xcode.app/Contents/SharedFrameworks/DTXConnectionServices.framework
XCTDaemonControl Xcode Xcode.app/Contents/SharedFrameworks/XCTDaemonControl.framework
XCUIAutomation Xcode Xcode.app/Contents/SharedFrameworks/XCUIAutomation.framework
XCTest Xcode Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework
MobileDevice macOS /System/Library/PrivateFrameworks/MobileDevice.framework
AccessibilityPlatformTranslation macOS /System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework
AVConference macOS /System/Library/PrivateFrameworks/AVConference.framework
"

die() { echo "sbom.sh: error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/sbom.sh --version X.Y.Z [options]

Prints Offsider's CycloneDX 1.6 SBOM: every package in Package.resolved, the idb
fork's frameworks with their upstream, the Android helper, and the Xcode and macOS
frameworks loaded at run time (never shipped).

Options:
  --version V         The release version (required, no leading "v")
  --output FILE       Write to FILE instead of stdout
  --commit SHA        Record the source commit (default: git rev-parse HEAD, when there is one)
  --idb-checkout DIR  Check the run-time list against idb's frameworks there; given, it must exist
                      (default: idb_checkout/, checked only when present)
  --root DIR          Read the repository at DIR (default: this checkout)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --output) OUTPUT="${2:?--output needs a file}"; shift 2 ;;
    --commit) COMMIT="${2:?--commit needs a value}"; shift 2 ;;
    --idb-checkout) IDB_CHECKOUT="${2:?--idb-checkout needs a directory}"; IDB_REQUIRED=1; shift 2 ;;
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; echo "sbom.sh: error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$VERSION" ] || { usage >&2; echo "sbom.sh: error: --version is required" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "invalid version '${VERSION}'"
command -v jq > /dev/null || die "jq is required (brew install jq)"

RESOLVED="${ROOT}/Package.resolved"
BUILD_SCRIPT="${ROOT}/scripts/build.sh"
RELEASE_SCRIPT="${ROOT}/scripts/release.sh"
HELPER_MANIFEST="${ROOT}/Sources/Offsider/Resources/helper/manifest.json"
for f in "$RESOLVED" "$BUILD_SCRIPT" "$RELEASE_SCRIPT" "$HELPER_MANIFEST"; do
  [ -f "$f" ] || die "missing ${f}"
done

# The defaults build.sh clones and release.sh ships, read from the scripts so they cannot drift.
IDB_URL="$(sed -n 's/^IDB_GIT_URL="\${IDB_GIT_URL:-\(https:[^}]*\)}"$/\1/p' "$BUILD_SCRIPT")"
IDB_REF="$(sed -n 's/^DEFAULT_IDB_GIT_REF="\([0-9a-f]\{40\}\)"$/\1/p' "$BUILD_SCRIPT")"
IDB_BASE="$(sed -n 's/^IDB_UPSTREAM_BASE_REF="\${IDB_UPSTREAM_BASE_REF:-\([0-9a-f]\{40\}\)}"$/\1/p' "$BUILD_SCRIPT")"
FRAMEWORKS="$(sed -n 's/^FRAMEWORKS="\([A-Za-z ]*\)"$/\1/p' "$RELEASE_SCRIPT")"
[[ "$IDB_URL" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "no idb fork URL in ${BUILD_SCRIPT}"
[ -n "$IDB_REF" ] || die "no idb fork pin (DEFAULT_IDB_GIT_REF) in ${BUILD_SCRIPT}"
[ -n "$IDB_BASE" ] || die "no upstream idb base (IDB_UPSTREAM_BASE_REF) in ${BUILD_SCRIPT}"
[ -n "$FRAMEWORKS" ] || die "no FRAMEWORKS list in ${RELEASE_SCRIPT}"

listed() { printf '%s\n' "$RUNTIME_FRAMEWORKS" | awk -v n="$1" '$1 == n { found = 1 } END { exit !found }'; }
missing=""
while IFS= read -r name; do
  listed "$name" || missing="${missing} ${name}"
done < <(grep -rhoE --include='*.swift' '(Private|Shared)Frameworks/[A-Za-z0-9]+\.framework' "${ROOT}/Sources" 2>/dev/null \
           | sed -E 's/.*Frameworks\/([A-Za-z0-9]+)\.framework/\1/' | sort -u)
if [ -z "$IDB_CHECKOUT" ] && [ -d "${ROOT}/idb_checkout" ]; then IDB_CHECKOUT="${ROOT}/idb_checkout"; fi
if [ -n "$IDB_CHECKOUT" ]; then
  weak="${IDB_CHECKOUT}/FBControlCore/Utility/FBWeakFramework+ApplePrivateFrameworks.swift"
  if [ -f "$weak" ]; then
    while IFS= read -r name; do
      listed "$name" || missing="${missing} ${name}"
    done < <(sed -n 's/^ *@objc(\([A-Za-z0-9]*\)) public class var .*/\1/p' "$weak")
  elif [ "$IDB_REQUIRED" = 1 ]; then
    die "missing ${weak}: run scripts/build.sh setup first, or leave out --idb-checkout"
  fi
fi
[ -z "$missing" ] || die "add the run-time frameworks${missing} to RUNTIME_FRAMEWORKS in scripts/sbom.sh"

if [ -z "$COMMIT" ]; then COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"; fi
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  TIMESTAMP="$(date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
else
  TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
if command -v uuidgen > /dev/null; then SERIAL="$(uuidgen)"; else SERIAL="$(cat /proc/sys/kernel/random/uuid)"; fi
SERIAL="urn:uuid:$(printf '%s' "$SERIAL" | tr 'A-F' 'a-f')"

render() {
  jq -n \
    --arg version "$VERSION" --arg commit "$COMMIT" --arg timestamp "$TIMESTAMP" --arg serial "$SERIAL" \
    --arg repo "$GITHUB_REPO" --arg idb_url "$IDB_URL" --arg idb_ref "$IDB_REF" --arg idb_base "$IDB_BASE" \
    --arg frameworks "$FRAMEWORKS" --arg runtime "$RUNTIME_FRAMEWORKS" \
    --slurpfile resolved "$RESOLVED" --slurpfile helper "$HELPER_MANIFEST" '
    def prop($name; $value): {name: ("offsider:" + $name), value: ($value | tostring)};
    def words: split(" ") | map(select(length > 0));
    def swift_purl($location; $version):
      ($location | sub("^https?://"; "") | sub("\\.git$"; "") | sub("/$"; "") | split("/")) as $parts
      | "pkg:swift/" + ($parts[:-1] | join("/")) + "/" + $parts[-1] + "@" + $version;

    $resolved[0] as $r | $helper[0] as $h
    | ($idb_url | sub("^https://github.com/"; "") | sub("\\.git$"; "")) as $idb_repo
    | if ($r.pins | length) == 0 then error("Package.resolved has no pins")
      elif any($r.pins[]; .kind != "remoteSourceControl") then error("Package.resolved has a pin that is not remoteSourceControl")
      elif ($h.dex.sha256 | test("^[0-9a-f]{64}$") | not) then error("the helper manifest has no dex SHA-256")
      else . end
    | {
        bomFormat: "CycloneDX",
        specVersion: "1.6",
        serialNumber: $serial,
        version: 1,
        metadata: {
          timestamp: $timestamp,
          tools: {components: [{type: "application", name: "sbom.sh", description: "scripts/sbom.sh in the Offsider repository"}]},
          component: ({
            type: "application",
            "bom-ref": "offsider",
            name: "offsider",
            version: $version,
            licenses: [{license: {id: "MIT"}}],
            purl: ("pkg:github/" + $repo + "@v" + $version),
            externalReferences: [{type: "vcs", url: ("https://github.com/" + $repo)}]
          } + (if $commit == "" then {} else {properties: [prop("commit"; $commit)]} end))
        },
        components: (
          [$r.pins[] | (.state.version // .state.revision) as $v | {
            type: "library",
            "bom-ref": ("swift:" + .identity),
            name: .identity,
            version: $v,
            purl: swift_purl(.location; $v),
            externalReferences: [{type: "vcs", url: .location}],
            properties: [prop("revision"; .state.revision)]
          }]
          + [$frameworks | words[] | {
            type: "framework",
            "bom-ref": ("idb:" + .),
            name: .,
            version: $idb_ref,
            licenses: [{license: {id: "MIT"}}],
            purl: ("pkg:github/" + $idb_repo + "@" + $idb_ref + "#" + .),
            externalReferences: [{type: "vcs", url: $idb_url}],
            pedigree: {
              ancestors: [{
                type: "framework",
                name: .,
                version: $idb_base,
                purl: ("pkg:github/facebook/idb@" + $idb_base + "#" + .),
                externalReferences: [{type: "vcs", url: "https://github.com/facebook/idb"}]
              }],
              commits: [{uid: $idb_ref, url: ("https://github.com/" + $idb_repo + "/commit/" + $idb_ref)}]
            },
            properties: [prop("shipped"; true), prop("path"; "Frameworks/" + . + ".framework")]
          }]
          + [{
            type: "application",
            "bom-ref": ("helper:" + $h.helper),
            name: $h.helper,
            version: $h.helperVersion,
            description: "Offsider'\''s Android helper, run on the device with app_process",
            licenses: [{license: {id: "MIT"}}],
            hashes: [{alg: "SHA-256", content: $h.dex.sha256}],
            properties: [
              prop("shipped"; true),
              prop("path"; "Offsider_Offsider.bundle/Contents/Resources/helper/" + $h.dex.file),
              prop("protocol"; $h.protocol),
              prop("jdk-major"; $h.jdkMajor),
              prop("d8-build-tools"; $h.d8.buildTools),
              prop("android-platform"; $h.androidJar.platform),
              prop("min-api"; $h.minApi)
            ]
          }]
          + [$runtime | split("\n")[] | words | select(length == 3) | {
            type: "framework",
            "bom-ref": ("runtime:" + .[0]),
            name: .[0],
            supplier: {name: "Apple Inc."},
            description: ("Loaded at run time from the person'\''s " + .[1] + "; never shipped"),
            properties: [prop("shipped"; false), prop("provided-by"; .[1]), prop("path"; .[2])]
          }]
        )
      }'
}

sbom="$(render)" || die "could not render the SBOM from ${RESOLVED} and ${HELPER_MANIFEST}"
if [ -n "$OUTPUT" ]; then
  tmp="${OUTPUT}.tmp.$$"
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$sbom" > "$tmp"
  mv "$tmp" "$OUTPUT"
else
  printf '%s\n' "$sbom"
fi
