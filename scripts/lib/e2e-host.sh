#!/usr/bin/env bash
# The Mac's load and the crash reports simulators write, for test-runner.sh: a boot waits for a quiet Mac, and a run says what crashed.
# shellcheck disable=SC2034 # the E2E_* values are read by test-runner.sh
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

# SpringBoard missed its launch watchdog and looped booting at load 106 on 18 cores; boots at twice the cores came up cleanly.
E2E_LOAD_PER_CORE=2
# How long a boot waits for that, and how often it looks.
E2E_LOAD_WAIT_LIMIT=600
E2E_LOAD_POLL=15
# Set when a wait gives up, for the caller's error.
E2E_BUSY_MESSAGE=""

# The 1-minute load average, such as 12.34.
e2e_load_now() {
    sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{ print $1 }'
}

e2e_cores() {
    local cores
    cores="$(sysctl -n hw.logicalcpu 2>/dev/null)" || cores=""
    [[ "$cores" =~ ^[1-9][0-9]*$ ]] || cores=8
    printf '%s\n' "$cores"
}

# Succeeds when <load> is at or under <ceiling>.
e2e_load_ok() {
    awk -v load="$1" -v ceiling="$2" 'BEGIN { exit !(load + 0 <= ceiling + 0) }'
}

# Succeeds when the 1-minute load is at most twice the cores, or cannot be read.
e2e_mac_is_quiet() {
    local load
    load="$(e2e_load_now)"
    [[ -z "$load" ]] || e2e_load_ok "$load" $(( $(e2e_cores) * E2E_LOAD_PER_CORE ))
}

# Waits up to <limit> seconds, with one line saying so, for a quiet Mac to boot <what>; fails with E2E_BUSY_MESSAGE set.
e2e_wait_for_quiet_mac() {
    local what="$1" limit="${2:-$E2E_LOAD_WAIT_LIMIT}" cores ceiling load waited=0
    cores="$(e2e_cores)"
    ceiling=$(( cores * E2E_LOAD_PER_CORE ))
    load="$(e2e_load_now)"
    [[ -n "$load" ]] || return 0
    e2e_load_ok "$load" "$ceiling" && return 0
    spinner_start "Waiting for a quiet Mac to boot $what: load $load, boots below $ceiling"
    while (( waited < limit )); do
        sleep "$E2E_LOAD_POLL"
        waited=$(( waited + E2E_LOAD_POLL ))
        load="$(e2e_load_now)"
        if [[ -z "$load" ]] || e2e_load_ok "$load" "$ceiling"; then
            spinner_stop
            ui_row ok "Mac is quiet" "load ${load:-unknown} $UI_DOT waited $(ui_elapsed "$waited")"
            return 0
        fi
    done
    spinner_stop
    E2E_BUSY_MESSAGE="The Mac stayed busy for $(ui_elapsed "$waited") (load $load; boots wait for $ceiling, twice its $cores cores), so $what was not booted. Let other builds and simulators finish, then run again."
    return 1
}

# "<process><TAB><bundle id>" per report of <udid> in <folder> the find tests after them select, from its first 16 KB as doctor reads.
e2e_simulator_crashes() {
    local folder="$1" udid="$2"
    shift 2
    [[ -d "$folder" ]] || return 0
    find "$folder" -maxdepth 1 -type f -name '*.ips' "$@" -print0 2>/dev/null |
        while IFS= read -r -d '' report; do
            prefix="$(head -c 16384 "$report")"
            [[ "$prefix" == *"com.apple.CoreSimulator.SimDevice.$udid\""* ]] || continue
            process="$(printf '%s\n' "$prefix" | grep -o -m 1 '"procName" : "[^"]*"' | sed 's/.*: "\(.*\)"/\1/')"
            bundle="$(printf '%s\n' "$prefix" | head -1 | grep -o '"bundleID":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/')"
            printf '%s\t%s\n' "${process:-unknown}" "$bundle"
        done
}

# A line per process of simulator <udid> that crashed 5 or more times in the last 10 minutes, the rule doctor's simulator.crash-loop fails on.
e2e_crash_loop() {
    e2e_simulator_crashes "$1" "$2" -mmin -10 | cut -f1 | sort | uniq -c |
        awk '{ n = $1; sub(/^ *[0-9]+ /, ""); if (n >= 5) printf "%s crashed %d times in the last 10 minutes\n", $0, n }'
}

# Refuses a simulator in a crash loop with a quiet boot as the fix, since erasing under load brought the loop back; only a person erases.
e2e_refuse_crash_loop() {
    local folder="$1" udid="$2" name="${3:-$2}" status="$4" looping line
    looping="$(e2e_crash_loop "$folder" "$udid")" || true
    [[ -n "$looping" ]] || return 0
    if [[ "$status" == "Booted" ]]; then
        print_error "$name is in a crash loop: shut it down, wait for the Mac to be quiet, then run again to boot it once."
    else
        print_error "$name was in a crash loop: wait for the Mac to be quiet and 10 minutes without a crash, then run again to boot it once."
    fi
    while IFS= read -r line; do log "    $line"; done <<<"$looping"
    if [[ "$status" == "Booted" ]]; then
        ui_try "xcrun simctl shutdown $udid"
    fi
    if [[ "$UI_AGENT" == 1 ]]; then
        log "Never erase it yourself. If it loops again on a quiet Mac, ask the user to run this in their own terminal (it removes its apps and settings):"
    else
        log "Only if it loops again on a quiet Mac, erase it (this removes its apps and settings):"
    fi
    print_person_command "xcrun simctl erase $udid"
    return 1
}

# Counts <udid>'s reports since <marker>; E2E_CRASHES_FATAL names SpringBoard, PosterBoard and apps whose bundle id starts with <app>.
e2e_run_crashes() {
    local folder="$1" udid="$2" marker="$3" app="$4" rows
    E2E_CRASHES_TOTAL=0 E2E_CRASHES_DETAIL="" E2E_CRASHES_FATAL=""
    [[ -f "$marker" ]] || return 0
    rows="$(e2e_simulator_crashes "$folder" "$udid" -newer "$marker")"
    [[ -n "$rows" ]] || return 0
    E2E_CRASHES_TOTAL="$(printf '%s\n' "$rows" | grep -c .)"
    E2E_CRASHES_DETAIL="$(printf '%s\n' "$rows" | cut -f1 | sort | uniq -c | sort -k1,1nr -k2 |
        awk '{ n = $1; sub(/^ *[0-9]+ /, ""); printf "%s%s %d", sep, $0, n; sep = ", " }')"
    E2E_CRASHES_FATAL="$(printf '%s\n' "$rows" |
        awk -F '\t' -v app="$app" '$1 == "SpringBoard" || $1 == "PosterBoard" || (app != "" && index($2, app) == 1) { print $1 }' |
        sort -u | awk '{ printf "%s%s", sep, $0; sep = ", " }')"
}
