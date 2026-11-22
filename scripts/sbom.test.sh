#!/usr/bin/env bash
# Tests for scripts/sbom.sh against this checkout and small fixture trees: run with `bash scripts/sbom.test.sh`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBOM="${ROOT}/scripts/sbom.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/offsider-sbom-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$name" "$expected" "$actual"
  fi
}

# status <args...> prints the exit status, then the last line sbom.sh wrote to stderr.
status() {
  local rc=0
  bash "$SBOM" "$@" > "${WORK}/out.json" 2> "${WORK}/err.txt" || rc=$?
  printf '%s %s' "$rc" "$(tail -n 1 "${WORK}/err.txt")"
}

# fixture <dir> copies the files sbom.sh reads into a tree it can change.
fixture() {
  mkdir -p "$1/scripts" "$1/Sources/Offsider/Resources/helper" "$1/Sources/Offsider/Platform"
  cp "${ROOT}/Package.resolved" "$1/Package.resolved"
  cp "${ROOT}/scripts/build.sh" "${ROOT}/scripts/release.sh" "$1/scripts/"
  cp "${ROOT}/Sources/Offsider/Resources/helper/manifest.json" "$1/Sources/Offsider/Resources/helper/"
  printf 'let path = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"\n' > "$1/Sources/Offsider/Platform/Loader.swift"
}

real="${WORK}/real.json"
bash "$SBOM" --version 1.2.3 --output "$real" 2> "${WORK}/real-err.txt"
check "renders this checkout" 0 "$?"
check "is CycloneDX 1.6" "CycloneDX 1.6" "$(jq -r '.bomFormat + " " + .specVersion' "$real")"
check "names the release version and purl" "1.2.3 pkg:github/michael-palmes/offsider@v1.2.3" \
  "$(jq -r '.metadata.component | .version + " " + .purl' "$real")"
check "records the commit" "$(git -C "$ROOT" rev-parse HEAD)" \
  "$(jq -r '.metadata.component.properties[] | select(.name == "offsider:commit") | .value' "$real")"
check "every bom-ref is unique" 0 "$(jq '[.components[]."bom-ref"] | length - (unique | length)' "$real")"

# Every pin in Package.resolved, by URL, revision and version: a pin the SBOM drops fails here.
pins="$(jq -r '.pins[] | [.identity, .location, .state.revision, (.state.version // .state.revision)] | @tsv' "${ROOT}/Package.resolved")"
check "Package.resolved has pins to check" true "$([ -n "$pins" ] && echo true || echo false)"
while IFS="$(printf '\t')" read -r identity location revision version; do
  [ -n "$identity" ] || continue
  got="$(jq -r --arg id "$identity" '.components[] | select(."bom-ref" == "swift:" + $id)
    | [.version, .externalReferences[0].url, (.properties[] | select(.name == "offsider:revision") | .value), .purl] | @tsv' "$real")"
  slug="$(printf '%s' "$location" | sed -E 's#^https?://##; s#\.git$##')"
  check "pin ${identity}" "$(printf '%s\t%s\t%s\tpkg:swift/%s@%s' "$version" "$location" "$revision" "$slug" "$version")" "$got"
done <<EOF
$pins
EOF
check "lists exactly the Package.resolved pins as Swift packages" \
  "$(jq '.pins | length' "${ROOT}/Package.resolved")" "$(jq '[.components[] | select(."bom-ref" | startswith("swift:"))] | length' "$real")"

idb_ref="$(sed -n 's/^DEFAULT_IDB_GIT_REF="\([0-9a-f]*\)"$/\1/p' "${ROOT}/scripts/build.sh")"
idb_base="$(sed -n 's/^IDB_UPSTREAM_BASE_REF="\${IDB_UPSTREAM_BASE_REF:-\([0-9a-f]*\)}"$/\1/p' "${ROOT}/scripts/build.sh")"
frameworks="$(sed -n 's/^FRAMEWORKS="\(.*\)"$/\1/p' "${ROOT}/scripts/release.sh")"
check "the idb pin is in build.sh" true "$([ ${#idb_ref} = 40 ] && [ ${#idb_base} = 40 ] && echo true || echo false)"
check "lists the frameworks release.sh ships" "$frameworks" \
  "$(jq -r '[.components[] | select(."bom-ref" | startswith("idb:")) | .name] | join(" ")' "$real")"
for name in $frameworks; do
  check "${name} comes from the fork at the pinned commit" "pkg:github/michael-palmes/idb@${idb_ref}#${name} true" \
    "$(jq -r --arg n "$name" '.components[] | select(."bom-ref" == "idb:" + $n)
      | .purl + " " + ((.properties[] | select(.name == "offsider:shipped") | .value))' "$real")"
  check "${name} names facebook/idb at the base as its ancestor" \
    "pkg:github/facebook/idb@${idb_base}#${name} ${idb_ref}" \
    "$(jq -r --arg n "$name" '.components[] | select(."bom-ref" == "idb:" + $n)
      | .pedigree.ancestors[0].purl + " " + .pedigree.commits[0].uid' "$real")"
done

dex="${ROOT}/Sources/Offsider/Resources/helper/offsider-helper.dex"
check "the helper's digest is the committed dex's" "$(shasum -a 256 "$dex" | cut -d' ' -f1)" \
  "$(jq -r '.components[] | select(."bom-ref" == "helper:offsider-helper") | .hashes[0].content' "$real")"
check "the helper's version is the manifest's" "$(jq -r .helperVersion "${ROOT}/Sources/Offsider/Resources/helper/manifest.json")" \
  "$(jq -r '.components[] | select(."bom-ref" == "helper:offsider-helper") | .version' "$real")"

check "CoreSimulator comes from Xcode, never shipped" "Xcode false" \
  "$(jq -r '.components[] | select(."bom-ref" == "runtime:CoreSimulator")
    | [(.properties[] | select(.name == "offsider:provided-by") | .value), (.properties[] | select(.name == "offsider:shipped") | .value)] | join(" ")' "$real")"
check "every run-time framework is marked not shipped" 0 \
  "$(jq '[.components[] | select(."bom-ref" | startswith("runtime:")) | select(any(.properties[]; .name == "offsider:shipped" and .value != "false"))] | length' "$real")"
for name in $(grep -rhoE --include='*.swift' '(Private|Shared)Frameworks/[A-Za-z0-9]+\.framework' "${ROOT}/Sources" \
                | sed -E 's/.*Frameworks\/([A-Za-z0-9]+)\.framework/\1/' | sort -u); do
  check "lists ${name}, which Sources loads" "runtime:${name}" \
    "$(jq -r --arg n "$name" '.components[] | select(."bom-ref" == "runtime:" + $n) | ."bom-ref"' "$real")"
done

fx="${WORK}/extra-pin"
fixture "$fx"
jq '.pins += [{identity: "swift-example", kind: "remoteSourceControl", location: "https://github.com/example/swift-example.git",
  state: {revision: "0000000000000000000000000000000000000001", version: "9.8.7"}}]' "${ROOT}/Package.resolved" > "$fx/Package.resolved"
bash "$SBOM" --version 1.2.3 --root "$fx" --output "${WORK}/extra.json" 2> /dev/null
check "a new pin appears with no change to sbom.sh" "9.8.7 pkg:swift/github.com/example/swift-example@9.8.7" \
  "$(jq -r '.components[] | select(."bom-ref" == "swift:swift-example") | .version + " " + .purl' "${WORK}/extra.json")"
check "a tree with no git records no commit" null "$(jq -c '.metadata.component.properties' "${WORK}/extra.json")"

fx="${WORK}/branch-pin"
fixture "$fx"
jq '.pins[0].state = {branch: "main", revision: "0000000000000000000000000000000000000002"}' "${ROOT}/Package.resolved" > "$fx/Package.resolved"
bash "$SBOM" --version 1.2.3 --root "$fx" --output "${WORK}/branch.json" 2> /dev/null
check "a branch pin uses its revision as the version" "0000000000000000000000000000000000000002" \
  "$(jq -r --arg id "$(jq -r '.pins[0].identity' "$fx/Package.resolved")" '.components[] | select(."bom-ref" == "swift:" + $id) | .version' "${WORK}/branch.json")"

fx="${WORK}/local-pin"
fixture "$fx"
jq '.pins[0].kind = "localSourceControl"' "${ROOT}/Package.resolved" > "$fx/Package.resolved"
check "a pin it cannot describe fails instead of being dropped" 1 "$(status --version 1.2.3 --root "$fx" | cut -d' ' -f1)"

fx="${WORK}/no-pins"
fixture "$fx"
printf '{"pins": [], "version": 3}\n' > "$fx/Package.resolved"
check "an empty Package.resolved fails" 1 "$(status --version 1.2.3 --root "$fx" | cut -d' ' -f1)"

fx="${WORK}/new-framework"
fixture "$fx"
printf 'let path = "/System/Library/PrivateFrameworks/NewThing.framework/NewThing"\n' > "$fx/Sources/Offsider/Platform/New.swift"
check "a framework Sources loads but the list lacks fails, naming it" \
  "1 sbom.sh: error: add the run-time frameworks NewThing to RUNTIME_FRAMEWORKS in scripts/sbom.sh" \
  "$(status --version 1.2.3 --root "$fx")"

fx="${WORK}/idb"
fixture "$fx"
mkdir -p "$fx/idb/FBControlCore/Utility"
printf '  @objc(CoreSimulator) public class var coreSimulator: FBWeakFramework {\n  @objc(OtherKit) public class var otherKit: FBWeakFramework {\n' \
  > "$fx/idb/FBControlCore/Utility/FBWeakFramework+ApplePrivateFrameworks.swift"
check "a framework idb loads but the list lacks fails, naming it" \
  "1 sbom.sh: error: add the run-time frameworks OtherKit to RUNTIME_FRAMEWORKS in scripts/sbom.sh" \
  "$(status --version 1.2.3 --root "$fx" --idb-checkout "$fx/idb")"
mkdir -p "$fx/idb_checkout"
cp -R "$fx/idb/FBControlCore" "$fx/idb_checkout/"
check "an idb_checkout in the tree is checked without asking" 1 "$(status --version 1.2.3 --root "$fx" | cut -d' ' -f1)"
check "a named idb checkout must exist" 1 "$(status --version 1.2.3 --root "${WORK}/extra-pin" --idb-checkout "${WORK}/nowhere" | cut -d' ' -f1)"

fx="${WORK}/no-pin"
fixture "$fx"
sed 's/^DEFAULT_IDB_GIT_REF=.*/DEFAULT_IDB_GIT_REF="main"/' "${ROOT}/scripts/build.sh" > "$fx/scripts/build.sh"
check "an idb pin that is not a commit fails" \
  "1 sbom.sh: error: no idb fork pin (DEFAULT_IDB_GIT_REF) in $(cd "$fx" && pwd)/scripts/build.sh" "$(status --version 1.2.3 --root "$fx")"

check "the version is required" 2 "$(status | cut -d' ' -f1)"
check "a version with a v fails" 1 "$(status --version v1.2.3 | cut -d' ' -f1)"
check "an unknown argument fails" 2 "$(status --version 1.2.3 --bogus | cut -d' ' -f1)"
check "SOURCE_DATE_EPOCH sets the timestamp" "2023-11-14T22:13:20Z" \
  "$(SOURCE_DATE_EPOCH=1700000000 bash "$SBOM" --version 1.2.3 --root "${WORK}/extra-pin" | jq -r .metadata.timestamp)"
check "--output leaves stdout empty" "" "$(bash "$SBOM" --version 1.2.3 --root "${WORK}/extra-pin" --output "${WORK}/quiet.json")"
check "serial numbers are fresh UUID URNs" true \
  "$(jq -r '.serialNumber | test("^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")' "${WORK}/quiet.json")"

printf 'sbom.test.sh: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
