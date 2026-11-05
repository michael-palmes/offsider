# shellcheck shell=bash
# adb.sh: adb with a time limit (bash 3.2, sourced, no traps of its own), so a frozen emulator stops a script with its fix instead of holding it for hours.
#   adb_limited <seconds> <adb> <arguments>...   adb under an alarm; on timeout one line on stderr names the fix and it returns 124
#   ADB_FIX_OFFSIDER=<path>                      the offsider that line names (default: offsider)
#   ADB_QUIET=1                                  drops adb's own stderr, never that line

# The AVD an emulator serial belongs to, from the emulator's own pid file, so a frozen console is never asked; nothing when unknown.
_adb_avd_of() {
    local port="${1#emulator-}" file
    [[ "$1" == emulator-* && "$port" =~ ^[0-9]+$ ]] || return 0
    for file in "$HOME"/Library/Caches/TemporaryItems/avd/running/pid_*.ini; do
        [[ -f "$file" ]] || continue
        if grep -qx "port.serial=$port" "$file"; then
            sed -n 's/^avd\.name=//p' "$file" | head -1
            return 0
        fi
    done
}

adb_limited() {
    local seconds="$1" serial="" previous="" argument code avd offsider="${ADB_FIX_OFFSIDER:-offsider}"
    shift
    for argument in "$@"; do
        [[ "$previous" == -s ]] && serial="$argument"
        previous="$argument"
    done
    if [[ ! -x /usr/bin/perl ]]; then
        "$@"
        return
    fi
    # perl runs adb as its child and ends it at the limit, so the shell reports no signal of its own.
    /usr/bin/perl -e '
        my $seconds = shift @ARGV;
        defined(my $pid = fork) or exit 127;
        if (!$pid) { open(STDERR, ">", "/dev/null") if $ENV{ADB_QUIET}; exec { $ARGV[0] } @ARGV or exit 127 }
        $SIG{ALRM} = sub { kill "KILL", $pid; waitpid $pid, 0; exit 124 };
        alarm $seconds;
        waitpid $pid, 0;
        exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "$seconds" "$@"
    code=$?
    [[ "$code" -eq 124 ]] || return "$code"
    avd="$(_adb_avd_of "$serial")"
    if [[ -n "$avd" ]]; then
        printf '%s (%s) did not answer in %s s, so it may be frozen. Start it again: %s shutdown %s && %s boot %s\n' \
            "$avd" "$serial" "$seconds" "$offsider" "$serial" "$offsider" "$avd" >&2
    else
        printf '%s did not answer in %s s. Check it is running, unlocked and connected, then run this again.\n' "${serial:-The device}" "$seconds" >&2
    fi
    return 124
}
