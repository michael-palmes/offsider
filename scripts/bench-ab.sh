#!/usr/bin/env bash
# Compares a base build with the branch on one Offsider device in paired, seeded runs.
set -euo pipefail

DEVICE=""
SCENARIOS=""
BASE_REF=""
BASE_BIN=""
HEAD_BIN=""
PAIRS=20
WARMUP=1
SEED=1
OUT=""
ALLOW_OUTPUT_CHANGE=0

ALLOWED_AVDS="Offsider_E2E_Pixel_9 Offsider_E2E_Pixel_9_Pro_Fold"
KNOWN_SCENARIOS="android-describe android-describe-uiautomator android-tap-id android-tap-id-verify android-batch-describe-5 ios-describe ios-tap-id ios-tap-id-verify"

usage() {
  cat <<EOF
Usage: $0 --device <id> --scenario <name>[,<name>...] [--base <ref>|--base-bin <path>] [--head-bin <path>]
          [--pairs 20] [--warmup 1] [--seed 1] [--out <dir>] [--allow-output-change]

Runs each scenario as pairs of base and head samples in a seeded order, drops pairs whose
exit code or stdout hash differ, and reports medians, a bootstrap 95% interval and a verdict
(faster, slower, same or unresolved; a 5% dead zone and a 10 ms floor).

Devices: an emulator-<port> whose AVD is one of: ${ALLOWED_AVDS}
         or a simulator whose name starts with Offsider.
Scenarios: ${KNOWN_SCENARIOS}
Base: --base defaults to the merge base of origin/main and HEAD, built once (release) in a
      detached worktree under \$TMPDIR/offsider-bench/worktrees. Head is this checkout (release).
Records: \${OFFSIDER_BENCH_DIR:-\$TMPDIR/offsider-bench}/<UTC timestamp>/ (0700): runs.tsv,
         summary.txt and result.json. Only hashes of stdout are kept, never the output.
EOF
}

die() {
  echo "bench-ab: $1" >&2
  exit "${2:-1}"
}

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "missing value for $1" 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) need_value "$@"; DEVICE="$2"; shift 2 ;;
    --scenario) need_value "$@"; SCENARIOS="$2"; shift 2 ;;
    --base) need_value "$@"; BASE_REF="$2"; shift 2 ;;
    --base-bin) need_value "$@"; BASE_BIN="$2"; shift 2 ;;
    --head-bin) need_value "$@"; HEAD_BIN="$2"; shift 2 ;;
    --pairs) need_value "$@"; PAIRS="$2"; shift 2 ;;
    --warmup) need_value "$@"; WARMUP="$2"; shift 2 ;;
    --seed) need_value "$@"; SEED="$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    --allow-output-change) ALLOW_OUTPUT_CHANGE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" 64 ;;
  esac
done

[[ -n "$DEVICE" ]] || { usage >&2; die "--device is required" 64; }
[[ -n "$SCENARIOS" ]] || { usage >&2; die "--scenario is required" 64; }
[[ -z "$BASE_REF" || -z "$BASE_BIN" ]] || die "pass --base or --base-bin, not both" 64
for number in "$PAIRS" "$WARMUP" "$SEED"; do
  [[ "$number" =~ ^[0-9]+$ ]] || die "--pairs, --warmup and --seed take whole numbers" 64
done
command -v python3 >/dev/null || die "python3 is required" 1

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
PLATFORM=""
for scenario in ${SCENARIOS//,/ }; do
  case " $KNOWN_SCENARIOS " in
    *" $scenario "*) ;;
    *) die "unknown scenario: $scenario (known: $KNOWN_SCENARIOS)" 64 ;;
  esac
  side="${scenario%%-*}"
  [[ -z "$PLATFORM" || "$PLATFORM" == "$side" ]] || die "one run drives one device, so its scenarios must all be android-* or all ios-*" 64
  PLATFORM="$side"
done

find_adb() {
  local candidate
  for candidate in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
    if [[ -n "$candidate" && -x "$candidate/platform-tools/adb" ]]; then
      echo "$candidate/platform-tools/adb"
      return 0
    fi
  done
  command -v adb || return 1
}

# The guard runs before anything is built or sent: only Offsider-tagged devices, one per run.
DEVICE_NAME=""
if [[ "$PLATFORM" == "android" ]]; then
  [[ "$DEVICE" =~ ^emulator-[0-9]+$ ]] || die "$DEVICE is not an emulator serial (emulator-<port>); bench-ab drives only Offsider AVDs" 2
  ADB="$(find_adb)" || die "adb not found; set ANDROID_HOME" 2
  DEVICE_NAME="$(ADB_MDNS=0 "$ADB" -s "$DEVICE" emu avd name 2>/dev/null | head -n 1 | tr -d '\r')" || true
  case " $ALLOWED_AVDS " in
    *" $DEVICE_NAME "*) ;;
    *) die "$DEVICE runs AVD '${DEVICE_NAME:-unknown}', not one of: $ALLOWED_AVDS" 2 ;;
  esac
else
  [[ "$DEVICE" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ ]] || die "$DEVICE is not a simulator UDID" 2
  DEVICE_NAME="$(xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1].upper()
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device["udid"].upper() == udid:
            print(device["name"])
' "$DEVICE")"
  [[ "$DEVICE_NAME" == Offsider* ]] || die "$DEVICE is '${DEVICE_NAME:-unknown}', not a simulator whose name starts with Offsider" 2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BENCH_ROOT="${OFFSIDER_BENCH_DIR:-${TMPDIR:-/tmp}/offsider-bench}"
OUT="${OUT:-$BENCH_ROOT/$STAMP}"
OUT_PARENT="$(dirname "$OUT")"
[[ -d "$OUT_PARENT" ]] || (umask 077 && mkdir -p "$OUT_PARENT")
OUT="$(cd "$OUT_PARENT" && pwd -P)/$(basename "$OUT")"
case "$OUT/" in
  "$(cd "$REPO" && pwd -P)/"*)
    git -C "$REPO" check-ignore -q "$OUT" || die "$OUT is inside the repository and not ignored by git; records are never committed" 2
    ;;
esac
[[ ! -e "$OUT" ]] || die "$OUT already exists" 2
(umask 077 && mkdir "$OUT")
chmod 700 "$OUT"

release_build() {
  local directory="$1"
  (cd "$directory" && swift build -c release --product offsider >&2 && echo "$(swift build -c release --show-bin-path)/offsider")
}

IDB_DIR="${IDB_CHECKOUT_DIR:-$REPO/idb_checkout}"
HEAD_SHA="$(git -C "$REPO" rev-parse --short HEAD)"
DIRTY=false
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || DIRTY=true

if [[ -z "$HEAD_BIN" ]]; then
  echo "bench-ab: building head ($HEAD_SHA) in release" >&2
  HEAD_BIN="$(IDB_CHECKOUT_DIR="$IDB_DIR" release_build "$REPO")"
fi

if [[ -n "$BASE_BIN" ]]; then
  BASE_SHA="binary"
else
  if [[ -z "$BASE_REF" ]]; then
    BASE_REF="$(git -C "$REPO" merge-base origin/main HEAD 2>/dev/null || git -C "$REPO" merge-base main HEAD)"
  fi
  BASE_SHA="$(git -C "$REPO" rev-parse --short "$BASE_REF^{commit}")"
  WORKTREE="$BENCH_ROOT/worktrees/$BASE_SHA"
  if [[ ! -f "$WORKTREE/.bench-built" ]]; then
    echo "bench-ab: building base ($BASE_SHA) in release in $WORKTREE" >&2
    if [[ ! -d "$WORKTREE" ]]; then
      (umask 077 && mkdir -p "$BENCH_ROOT/worktrees")
      # A purged TMPDIR leaves a stale registration that would block the add.
      git -C "$REPO" worktree prune
      git -C "$REPO" worktree add --detach "$WORKTREE" "$BASE_SHA" >&2
    fi
    if [[ ! -d "$WORKTREE/build_products" ]]; then
      cp -Rc "$REPO/build_products" "$WORKTREE/build_products" 2>/dev/null || cp -R "$REPO/build_products" "$WORKTREE/build_products"
    fi
    IDB_CHECKOUT_DIR="$IDB_DIR" release_build "$WORKTREE" >/dev/null
    touch "$WORKTREE/.bench-built"
  fi
  BASE_BIN="$(cd "$WORKTREE" && swift build -c release --show-bin-path)/offsider"
fi
[[ -x "$BASE_BIN" ]] || die "base binary not found: $BASE_BIN" 1
[[ -x "$HEAD_BIN" ]] || die "head binary not found: $HEAD_BIN" 1

CORES="$(sysctl -n hw.ncpu)"
LOAD="$(sysctl -n vm.loadavg | awk '{print $2}')"
if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) / 2 else 1)" "$LOAD" "$CORES"; then
  echo "bench-ab: warning: the 1-minute load average is $LOAD on $CORES cores; results on a busy Mac are noisy" >&2
fi

open_screen() {
  local screen="$1"
  if [[ "$PLATFORM" == "android" ]]; then
    "$REPO/scripts/rn-playground.sh" launch-android "$DEVICE" "$screen" >&2 || echo "bench-ab: warning: could not open $screen; running on the screen that is showing" >&2
  else
    xcrun simctl launch --terminate-running-process "$DEVICE" com.mpalmes.offsider.playground -OffsiderScreen "$screen" >/dev/null 2>&1 \
      || echo "bench-ab: warning: could not open $screen; running on the screen that is showing" >&2
  fi
  sleep 2
}

export BENCH_OUT="$OUT" BENCH_DEVICE="$DEVICE" BENCH_DEVICE_NAME="$DEVICE_NAME"
export BENCH_BASE_BIN="$BASE_BIN" BENCH_HEAD_BIN="$HEAD_BIN" BENCH_BASE_SHA="$BASE_SHA" BENCH_HEAD_SHA="$HEAD_SHA"
export BENCH_DIRTY="$DIRTY" BENCH_PAIRS="$PAIRS" BENCH_WARMUP="$WARMUP" BENCH_SEED="$SEED"
export BENCH_ALLOW_OUTPUT_CHANGE="$ALLOW_OUTPUT_CHANGE" BENCH_LOAD_START="$LOAD"
BENCH_XCODE="$(xcodebuild -version 2>/dev/null | head -n 1 || true)"
BENCH_MACOS="$(sw_vers -productVersion)"
export BENCH_XCODE BENCH_MACOS

STOP_REASON="completed"
trap 'STOP_REASON="interrupted"' INT TERM
for scenario in ${SCENARIOS//,/ }; do
  # tap-test is static; screens with live content (rows-test's progress label) change the output hash between samples.
  open_screen tap-test
  BENCH_SCENARIO="$scenario" python3 - <<'PY' || STOP_REASON="interrupted"
import hashlib, os, random, re, subprocess, sys, time

out = os.environ["BENCH_OUT"]
device = os.environ["BENCH_DEVICE"]
scenario = os.environ["BENCH_SCENARIO"]
pairs = int(os.environ["BENCH_PAIRS"])
warmup = int(os.environ["BENCH_WARMUP"])
seed = int(os.environ["BENCH_SEED"])
bins = {"base": os.environ["BENCH_BASE_BIN"], "head": os.environ["BENCH_HEAD_BIN"]}

commands = {
    "android-describe": (["describe-ui", "--device", device], {}),
    "android-describe-uiautomator": (["describe-ui", "--device", device], {"OFFSIDER_ANDROID_TREE": "uiautomator"}),
    "android-tap-id": (["tap", "--id", "tap-test-area", "--device", device], {}),
    "android-tap-id-verify": (["tap", "--id", "tap-test-area", "--verify", "--device", device], {}),
    "android-batch-describe-5": (["batch", "--device", device] + ["--step", "describe-ui"] * 5, {}),
    "ios-describe": (["describe-ui", "--device", device], {}),
    "ios-tap-id": (["tap", "--id", "tap-test-area", "--device", device], {}),
    "ios-tap-id-verify": (["tap", "--id", "tap-test-area", "--verify", "--device", device], {}),
}
arguments, extra = commands[scenario]
environment = dict(os.environ, OFFSIDER_TIMINGS="1", ADB_MDNS="0", **extra)
timing_line = re.compile(r"^offsider timing: (\S+) (\d+) ms$")
timestamp = re.compile(r'"timestamp"\s*:\s*("[^"]*"|[0-9.]+)')

def sample(side):
    start = time.perf_counter_ns()
    result = subprocess.run([bins[side]] + arguments, env=environment, stdin=subprocess.DEVNULL, capture_output=True)
    wall = (time.perf_counter_ns() - start) / 1e6
    text = result.stdout.decode("utf-8", "replace").replace(device, "<device>")
    digest = hashlib.sha256(timestamp.sub('"timestamp":0', text).encode()).hexdigest()[:16]
    phases = {}
    for line in result.stderr.decode("utf-8", "replace").splitlines():
        match = timing_line.match(line.strip())
        if match:
            phases[match.group(1)] = phases.get(match.group(1), 0) + int(match.group(2))
    return {"exit": result.returncode, "hash": digest, "wall": wall, "phases": phases}

order = random.Random(f"{seed}:{scenario}")
rows = []
for pair in range(-warmup, pairs):
    first = "base" if order.random() < 0.5 else "head"
    second = "head" if first == "base" else "base"
    for position, side in enumerate((first, second)):
        record = sample(side)
        record.update(pair=pair, side=side, order=position)
        if pair >= 0:
            rows.append(record)
    print(f"bench-ab: {scenario} pair {pair + 1}/{pairs}" if pair >= 0 else f"bench-ab: {scenario} warm-up", file=sys.stderr)

path = os.path.join(out, "runs.tsv")
new = not os.path.exists(path)
with open(path, "a") as handle:
    if new:
        handle.write("pair\tside\torder\tscenario\texit\tstdout_sha256\twall_ms\tphases\n")
    for row in rows:
        phases = ",".join(f"{name}={row['phases'][name]}" for name in sorted(row["phases"]))
        handle.write(f"{row['pair']}\t{row['side']}\t{row['order']}\t{scenario}\t{row['exit']}\t{row['hash']}\t{row['wall']:.1f}\t{phases}\n")
PY
  [[ "$STOP_REASON" == "completed" ]] || break
done

BENCH_LOAD_END="$(sysctl -n vm.loadavg | awk '{print $2}')"
export BENCH_LOAD_END BENCH_STOP_REASON="$STOP_REASON"
python3 - <<'PY'
import csv, json, math, os, random, statistics

out = os.environ["BENCH_OUT"]
allow_output_change = os.environ["BENCH_ALLOW_OUTPUT_CHANGE"] == "1"
seed = int(os.environ["BENCH_SEED"])
DEAD_ZONE = 0.05
FLOOR_MS = 10.0
MIN_PAIRS = 6
RESAMPLES = 4000

rows = []
path = os.path.join(out, "runs.tsv")
if os.path.exists(path):
    with open(path) as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            row["phases"] = dict((part.split("=")[0], int(part.split("=")[1])) for part in row["phases"].split(",") if part)
            rows.append(row)

def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))]

def compare(base, head, label):
    ratios = [math.log(h / b) for b, h in zip(base, head) if b > 0 and h > 0]
    differences = [h - b for b, h in zip(base, head)]
    if len(ratios) < MIN_PAIRS:
        return {"metric": label, "pairs": len(ratios), "verdict": "unresolved",
                "baseMedianMs": statistics.median(base) if base else None, "headMedianMs": statistics.median(head) if head else None}
    generator = random.Random(seed)
    medians = [statistics.median(generator.choices(ratios, k=len(ratios))) for _ in range(RESAMPLES)]
    low, high = math.exp(percentile(medians, 0.025)) - 1, math.exp(percentile(medians, 0.975)) - 1
    if abs(statistics.median(differences)) < FLOOR_MS:
        verdict = "same"
    elif high < -DEAD_ZONE:
        verdict = "faster"
    elif low > DEAD_ZONE:
        verdict = "slower"
    elif low >= -DEAD_ZONE and high <= DEAD_ZONE:
        verdict = "same"
    else:
        verdict = "unresolved"
    return {
        "metric": label, "pairs": len(ratios), "baseMedianMs": statistics.median(base), "headMedianMs": statistics.median(head),
        "change": math.exp(statistics.median(ratios)) - 1, "interval": [low, high],
        "medianDifferenceMs": statistics.median(differences), "verdict": verdict,
    }

results = []
for scenario in dict.fromkeys(row["scenario"] for row in rows):
    samples = [row for row in rows if row["scenario"] == scenario]
    by_pair = {}
    for row in samples:
        by_pair.setdefault(int(row["pair"]), {})[row["side"]] = row
    signature = (lambda row: row["exit"]) if allow_output_change else (lambda row: (row["exit"], row["stdout_sha256"]))
    unstable = [side for side in ("base", "head") if len({signature(row) for row in samples if row["side"] == side}) > 1]
    kept, dropped = [], []
    for pair, sides in sorted(by_pair.items()):
        if len(sides) < 2:
            continue
        if signature(sides["base"]) == signature(sides["head"]):
            kept.append(sides)
        else:
            dropped.append({"pair": pair, "reason": "exit code differs" if sides["base"]["exit"] != sides["head"]["exit"] else "stdout differs"})
    entry = {"scenario": scenario, "kept": len(kept), "dropped": dropped, "unstable": unstable}
    if unstable:
        entry["verdict"] = "unstable"
    else:
        entry["wall"] = compare([float(p["base"]["wall_ms"]) for p in kept], [float(p["head"]["wall_ms"]) for p in kept], "wall")
        totals = [(p["base"]["phases"].get("total"), p["head"]["phases"].get("total")) for p in kept]
        totals = [(b, h) for b, h in totals if b and h]
        entry["total"] = compare([b for b, _ in totals], [h for _, h in totals], "total")
        entry["verdict"] = entry["total"]["verdict"] if totals else entry["wall"]["verdict"]
        names = sorted({name for p in kept for side in p.values() for name in side["phases"]} - {"total"})
        def phase_median(name, side):
            values = [p[side]["phases"][name] for p in kept if name in p[side]["phases"]]
            return statistics.median(values) if values else None
        entry["phases"] = {name: {side: phase_median(name, side) for side in ("base", "head")} for name in names}
    results.append(entry)

def ms(value):
    return f"{value:.0f} ms" if value is not None else "n/a"

dirty = " (dirty)" if os.environ["BENCH_DIRTY"] == "true" else ""
lines = [
    f"bench-ab/1  base {os.environ['BENCH_BASE_SHA']}  head {os.environ['BENCH_HEAD_SHA']}{dirty}  device {os.environ['BENCH_DEVICE_NAME']}"
    f"  pairs {os.environ['BENCH_PAIRS']}  load {os.environ['BENCH_LOAD_START']} to {os.environ['BENCH_LOAD_END']}",
    f"{'scenario':<30}{'base p50':>10}{'head p50':>10}{'change':>9}   {'95% interval':<18}verdict",
]
for entry in results:
    note = f"kept {entry['kept']}, dropped {len(entry['dropped'])}"
    if entry["verdict"] == "unstable":
        lines.append(f"{entry['scenario']:<30}{'':<40}unstable ({', '.join(entry['unstable'])} output varies; {note})")
        continue
    metric = entry["total"] if entry["total"].get("baseMedianMs") is not None else entry["wall"]
    if "interval" not in metric:
        lines.append(f"{entry['scenario']:<30}{ms(metric.get('baseMedianMs')):>10}{ms(metric.get('headMedianMs')):>10}{'':<21}unresolved ({note})")
    else:
        interval = f"[{metric['interval'][0] * 100:+.1f}%, {metric['interval'][1] * 100:+.1f}%]"
        lines.append(
            f"{entry['scenario']:<30}{ms(metric['baseMedianMs']):>10}{ms(metric['headMedianMs']):>10}{metric['change'] * 100:>+8.1f}%   "
            f"{interval:<18}{entry['verdict']} ({metric['metric']}; {note})"
        )
    for name, sides in entry["phases"].items():
        lines.append(f"  {name:<28}{ms(sides['base']):>10}{ms(sides['head']):>10}")
summary = "\n".join(lines) + "\n"
with open(os.path.join(out, "summary.txt"), "w") as handle:
    handle.write(summary)
with open(os.path.join(out, "result.json"), "w") as handle:
    json.dump({
        "version": "bench-ab/1",
        "base": os.environ["BENCH_BASE_SHA"],
        "head": os.environ["BENCH_HEAD_SHA"],
        "dirty": os.environ["BENCH_DIRTY"] == "true",
        "device": os.environ["BENCH_DEVICE_NAME"],
        "macOS": os.environ["BENCH_MACOS"],
        "xcode": os.environ["BENCH_XCODE"],
        "loadAverage": {"start": float(os.environ["BENCH_LOAD_START"]), "end": float(os.environ["BENCH_LOAD_END"])},
        "pairs": int(os.environ["BENCH_PAIRS"]),
        "warmup": int(os.environ["BENCH_WARMUP"]),
        "seed": seed,
        "allowOutputChange": allow_output_change,
        "stopReason": os.environ["BENCH_STOP_REASON"],
        "scenarios": results,
    }, handle, indent=2, sort_keys=True)
print(summary, end="")
PY
echo "bench-ab: records in $OUT" >&2
[[ "$STOP_REASON" == "completed" ]]
