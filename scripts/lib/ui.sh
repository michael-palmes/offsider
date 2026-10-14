# shellcheck shell=bash
# shellcheck disable=SC2034 # the palette is for the scripts that source this file
# ui.sh: the shared look for Offsider's scripts (bash 3.2, sourced, no traps of its own).
#
#   ui_banner <emoji> <title>        cyan double-rule banner
#   ui_section <emoji> <title>       cyan rule, bold title, cyan rule
#   ui_heading <emoji> <title>       a bold sub-heading inside a section
#   ui_step <n> <total> <title>      a "Step n/total" header with a trailing rule
#   ui_question <text> [controls]    bold question, dim controls in parentheses to its right
#   select_menu <question> <row>...  arrow-key picker; a row is "emoji|label|note"; sets SELECTED_INDEX, returns 1 on quit
#                                    UI_RECOMMENDED_INDEX=<n> badges and starts on row n; UI_COLLAPSE=0 keeps the rows
#   confirm <question> [yes|no]      Yes or No picker (the default starts selected); returns 0 for Yes
#   spinner_start <text>             animate on stderr while a quiet step runs; spinner_stop clears it
#   ui_run_logged <label> <log> <cmd>...  spinner, command output into <log>, then a receipt, or its last 30 lines and the log path
#   print_success|print_info <text>  receipt (stdout); print_warning|print_error <text> (stderr)
#   ui_next <command>                the bold "Next:" line a script ends with
#   log <text>                       dim progress line on stderr
#   warn <text> [try]                yellow warning on stderr, with an optional Try: line
#   ui_try <command>                 a bold Try: line on stderr
#   die <text> [try] [code]          one red line on stderr, one Try: line, then exit (default 1)
#   ui_cleanup                       stop the spinner and show the cursor; call it from the script's EXIT trap
#
# NO_COLOR or a pipe drops colour; NO_COLOR, UI_ASCII=1 or a non-UTF-8 locale swaps glyphs for [OK] [x] [!] > = -.

[[ -n "${_OFFSIDER_UI_SH:-}" ]] && return 0
_OFFSIDER_UI_SH=1

ui_init() {
    if [[ -n "${FORCE_COLOR:-}" && "${FORCE_COLOR}" != 0 ]] || { [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 && -t 2 ]]; }; then
        GREEN=$'\033[0;32m' RED=$'\033[0;31m' YELLOW=$'\033[0;33m' BLUE=$'\033[0;34m'
        CYAN=$'\033[0;36m' MAGENTA=$'\033[0;35m' DIM=$'\033[2m' BOLD=$'\033[1m' NC=$'\033[0m'
    else
        GREEN='' RED='' YELLOW='' BLUE='' CYAN='' MAGENTA='' DIM='' BOLD='' NC=''
    fi
    local locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    if [[ -n "${NO_COLOR:-}" || -n "${UI_ASCII:-}" || "$locale" != *[Uu][Tt][Ff]* ]]; then
        UI_ASCII_MODE=1
        _UI_OK='[OK]' _UI_ERR='[x]' _UI_WARN='[!]' _UI_INFO='->' _UI_CURSOR='>'
        _UI_HEAVY='=' _UI_LIGHT='-' _UI_DOT='-' _UI_KEYS='up/down, Enter, Q to quit'
        _UI_FRAMES="|/-\\"
    else
        UI_ASCII_MODE=0
        _UI_OK='✅' _UI_ERR='❌' _UI_WARN='⚠️ ' _UI_INFO='→' _UI_CURSOR='▸'
        _UI_HEAVY='═' _UI_LIGHT='─' _UI_DOT='·' _UI_KEYS='↑↓, Enter, Q to quit'
        _UI_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    fi
}
ui_init

_UI_SPINNER_PID=""

ui_cols() {
    local c="${COLUMNS:-}"
    [[ "$c" =~ ^[0-9]+$ ]] || c="$(tput cols 2>/dev/null || echo 80)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    printf '%s' "$c"
}

_ui_rule() {
    local char="$1" width="$2" out="" i
    for (( i = 0; i < width; i++ )); do out="${out}${char}"; done
    printf '%s' "$out"
}

_ui_width() {
    local w
    w="$(ui_cols)"
    (( w > 60 )) && w=60
    (( w < 30 )) && w=30
    printf '%s' "$w"
}

# Emoji are dropped in ASCII mode, so a title never prints as mojibake.
_ui_glyph() {
    if [[ "$UI_ASCII_MODE" == 1 || -z "$1" ]]; then printf ''; else printf '%s  ' "$1"; fi
}

ui_banner() {
    local rule
    rule="$(_ui_rule "$_UI_HEAVY" "$(_ui_width)")"
    printf '\n%s%s%s\n%s  %s%s%s\n%s%s%s\n' "$CYAN" "$rule" "$NC" "$BOLD" "$(_ui_glyph "$1")" "$2" "$NC" "$CYAN" "$rule" "$NC"
}

ui_section() {
    local rule
    rule="$(_ui_rule "$_UI_LIGHT" "$(_ui_width)")"
    printf '\n%s%s%s\n%s%s%s%s\n%s%s%s\n' "$CYAN" "$rule" "$NC" "$BOLD" "$(_ui_glyph "$1")" "$2" "$NC" "$CYAN" "$rule" "$NC"
}

ui_heading() { printf '\n%s%s%s%s\n' "$BOLD" "$(_ui_glyph "$1")" "$2" "$NC"; }

ui_step() {
    local label="Step $1/$2 ${_UI_DOT} $3" fill
    fill=$(( $(_ui_width) - ${#label} - 4 ))
    (( fill < 2 )) && fill=2
    printf '\n%s%s%s %s%s%s %s%s%s\n\n' "$DIM" "$_UI_LIGHT$_UI_LIGHT" "$NC" "$CYAN" "$label" "$NC" "$DIM" "$(_ui_rule "$_UI_LIGHT" "$fill")" "$NC"
}

ui_question() {
    printf '%s%s%s  %s(%s)%s\n' "$BOLD" "$1" "$NC" "$DIM" "${2:-$_UI_KEYS}" "$NC" >&2
}

print_success() { printf '%s%s  %s%s\n' "$GREEN" "$_UI_OK" "$1" "$NC"; }
print_info() { printf '%s%s %s%s\n' "$CYAN" "$_UI_INFO" "$1" "$NC"; }
print_warning() { printf '%s%s %s%s\n' "$YELLOW" "$_UI_WARN" "$1" "$NC" >&2; }
print_error() { printf '%s%s  %s%s\n' "$RED" "$_UI_ERR" "$1" "$NC" >&2; }
ui_next() { printf '\n%sNext:%s %s\n' "$BOLD" "$NC" "$1"; }
log() { printf '%s%s%s\n' "$DIM" "$*" "$NC" >&2; }

ui_try() {
    [[ -n "${1:-}" ]] || return 0
    printf '   %sTry:%s %s\n' "$BOLD" "$NC" "$1" >&2
}

warn() {
    print_warning "$1"
    ui_try "${2:-}"
}

die() {
    spinner_stop
    print_error "$1"
    ui_try "${2:-}"
    exit "${3:-1}"
}

spinner_start() {
    spinner_stop
    if [[ ! -t 2 ]]; then
        printf '%s\n' "$1" >&2
        return 0
    fi
    local msg="$1" parent=$$ max
    max=$(( $(ui_cols) - 4 ))
    (( ${#msg} > max )) && msg="${msg:0:max}"
    (
        trap 'exit 0' INT TERM HUP
        n=${#_UI_FRAMES} i=0
        while kill -0 "$parent" 2>/dev/null; do
            printf '\r%s%s %s%s' "$DIM" "${_UI_FRAMES:i:1}" "$msg" "$NC" >&2
            i=$(( (i + 1) % n ))
            sleep 0.1
        done
    ) &
    _UI_SPINNER_PID=$!
}

spinner_stop() {
    [[ -n "$_UI_SPINNER_PID" ]] || return 0
    kill "$_UI_SPINNER_PID" 2>/dev/null || true
    wait "$_UI_SPINNER_PID" 2>/dev/null || true
    _UI_SPINNER_PID=""
    printf '\r\033[K' >&2
}

ui_cleanup() {
    spinner_stop
    [[ -t 2 ]] && printf '\033[?25h' >&2
    return 0
}

_ui_elapsed() {
    local s="$1"
    if (( s >= 60 )); then printf '%dm %02ds' $(( s / 60 )) $(( s % 60 )); else printf '%ds' "$s"; fi
}

ui_run_logged() {
    local label="$1" logfile="$2" started rc errexit=0
    shift 2
    [[ $- == *e* ]] && errexit=1
    mkdir -p "$(dirname "$logfile")"
    started=$SECONDS
    spinner_start "$label"
    # Errexit is off around the subshell on purpose: `( ) || rc=$?` would silently disable it inside.
    set +e
    ( set -e; "$@" ) >>"$logfile" 2>&1
    rc=$?
    [[ "$errexit" == 1 ]] && set -e
    spinner_stop
    if [[ "$rc" -eq 0 ]]; then
        printf '%s%s  %s%s %s%s%s\n' "$GREEN" "$_UI_OK" "$label" "$NC" "$DIM" "$(_ui_elapsed $(( SECONDS - started )))" "$NC"
        return 0
    fi
    print_error "$label failed"
    printf '%s' "$DIM" >&2
    tail -30 "$logfile" >&2
    printf '%s' "$NC" >&2
    printf '   %sLog:%s %s\n' "$BOLD" "$NC" "$logfile" >&2
    return "$rc"
}

# Rows are "emoji|label|note"; fills _UI_ROW_EMOJI, _UI_ROW_LABEL and _UI_ROW_NOTE.
_ui_split_row() {
    local row="$1"
    _UI_ROW_EMOJI="${row%%|*}"
    row="${row#*|}"
    _UI_ROW_LABEL="${row%%|*}"
    if [[ "$row" == *"|"* ]]; then _UI_ROW_NOTE="${row#*|}"; else _UI_ROW_NOTE=""; fi
}

_ui_label_width() {
    local row width=0
    for row in "$@"; do
        _ui_split_row "$row"
        (( ${#_UI_ROW_LABEL} > width )) && width=${#_UI_ROW_LABEL}
    done
    _UI_LABEL_WIDTH=$width
}

# One row, cut to the terminal width so a redraw can always count one line per row.
_ui_draw_row() {
    local index="$1" selected="$2" row="$3" cols="$4" emoji badge="" pad note room text
    _ui_split_row "$row"
    emoji="$(_ui_glyph "$_UI_ROW_EMOJI")"
    if [[ "${UI_RECOMMENDED_INDEX:-}" == "$index" ]]; then badge="  ${MAGENTA}(Recommended)${NC}"; fi
    pad=$(( _UI_LABEL_WIDTH - ${#_UI_ROW_LABEL} + 2 ))
    note="$_UI_ROW_NOTE"
    room=$(( cols - 4 - ${#emoji} - _UI_LABEL_WIDTH - 2 - 16 ))
    [[ -n "$emoji" ]] && room=$(( room - 1 ))
    if (( room < 8 )); then note=""; elif (( ${#note} > room )); then note="${note:0:room-1}…"; fi
    [[ "$UI_ASCII_MODE" == 1 ]] && note="${note//…/...}"
    text="${emoji}${_UI_ROW_LABEL}"
    if [[ -n "$note" ]]; then text="${text}$(printf '%*s' "$pad" '')"; fi
    if [[ "$selected" == 1 ]]; then
        printf '\r\033[K  %s%s %s%s%s%s%s%s\n' "$GREEN" "$_UI_CURSOR" "$text" "$NC" "${note:+$DIM}" "$note" "${note:+$NC}" "$badge" >&2
    else
        printf '\r\033[K    %s%s%s%s%s\n' "$text" "${note:+$DIM}" "$note" "${note:+$NC}" "$badge" >&2
    fi
}

# Numbered fallback for a stdin that is not a terminal: reads one line, an empty line takes the recommended row.
_ui_select_numbered() {
    local question="$1" count i answer default
    shift
    count=$#
    default="${UI_RECOMMENDED_INDEX:-}"
    printf '%s%s%s\n' "$BOLD" "$question" "$NC" >&2
    i=1
    for row in "$@"; do
        _ui_split_row "$row"
        printf '  %d) %s%s%s\n' "$i" "$_UI_ROW_LABEL" "${_UI_ROW_NOTE:+  }" "$_UI_ROW_NOTE" >&2
        i=$(( i + 1 ))
    done
    printf 'Choose 1-%d%s: ' "$count" "${default:+ (Enter for $(( default + 1 )))}" >&2
    IFS= read -r answer || return 1
    if [[ -z "$answer" && -n "$default" ]]; then answer=$(( default + 1 )); fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= count )); then
        SELECTED_INDEX=$(( answer - 1 ))
        return 0
    fi
    return 1
}

select_menu() {
    local question="$1" count cols current i key rest total_lines
    shift
    count=$#
    SELECTED_INDEX=""
    (( count > 0 )) || return 1
    if [[ ! -t 0 || ! -t 2 ]]; then
        _ui_select_numbered "$question" "$@"
        return $?
    fi
    current=0
    if [[ "${UI_RECOMMENDED_INDEX:-}" =~ ^[0-9]+$ ]] && (( UI_RECOMMENDED_INDEX < count )); then
        current=$UI_RECOMMENDED_INDEX
    fi
    cols="$(ui_cols)"
    _ui_label_width "$@"
    local rows=("$@")
    ui_question "$question"
    printf '\n' >&2
    printf '\033[?25l' >&2
    while :; do
        for (( i = 0; i < count; i++ )); do
            if (( i == current )); then _ui_draw_row "$i" 1 "${rows[i]}" "$cols"; else _ui_draw_row "$i" 0 "${rows[i]}" "$cols"; fi
        done
        key=""
        IFS= read -rsn1 key || { key=q; }
        case "$key" in
            $'\x1b')
                rest=""
                IFS= read -rsn2 -t 1 rest || true
                case "$rest" in
                    '[A') current=$(( (current - 1 + count) % count )) ;;
                    '[B') current=$(( (current + 1) % count )) ;;
                esac
                ;;
            k) current=$(( (current - 1 + count) % count )) ;;
            j) current=$(( (current + 1) % count )) ;;
            '') break ;;
            q|Q) current=-1; break ;;
            [1-9]) if (( key <= count )); then current=$(( key - 1 )); fi ;;
        esac
        printf '\033[%dA' "$count" >&2
    done
    printf '\033[?25h' >&2
    if (( current < 0 )); then return 1; fi
    SELECTED_INDEX=$current
    if [[ "${UI_COLLAPSE:-1}" != 0 ]]; then
        total_lines=$(( count + 2 ))
        printf '\033[%dA\033[J' "$total_lines" >&2
        _ui_split_row "${rows[current]}"
        printf '%s%s  %s%s%s\n' "$GREEN" "$_UI_OK" "$(_ui_glyph "$_UI_ROW_EMOJI")" "$_UI_ROW_LABEL" "$NC" >&2
    fi
    return 0
}

confirm() {
    local question="$1" default="${2:-yes}"
    local UI_RECOMMENDED_INDEX=""
    if [[ "$default" == no ]]; then
        select_menu "$question" "❌|No" "✅|Yes" || return 1
        [[ "$SELECTED_INDEX" == 1 ]]
    else
        select_menu "$question" "✅|Yes" "❌|No" || return 1
        [[ "$SELECTED_INDEX" == 0 ]]
    fi
}
