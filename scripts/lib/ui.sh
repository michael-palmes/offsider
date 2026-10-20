# shellcheck shell=bash
# shellcheck disable=SC2034 # the palette and the UI_* values are for the scripts that source this file
# ui.sh: the shared look for Offsider's scripts (bash 3.2, sourced, no traps of its own).
# A person gets the look of the Swift kit in Sources/OffsiderCore/Terminal/; an agent gets plain, prefixed lines.
#
#   ui_header <emoji> <title> [summary]   bold title, dim summary on the right (or under it), cyan rule; join parts with $UI_DOT
#   ui_banner, ui_section                 the same header, for the scripts' openings and steps
#   ui_heading <emoji> <title>            a bold sub-heading inside a section (the emoji is not drawn)
#   ui_row <status> <label> [detail]      a status row that never wraps; status is ok, warn, fail, skip, run, on or off
#                                         UI_ROW_LABEL_WIDTH=<n> pads labels so rows line up
#   ui_kv <label> <value> [detail]        a dim label and its value; UI_KV_LABEL_WIDTH=<n> pads labels
#   ui_receipt <headline> [detail]...     the ✅ line a change ends with (stdout); print_success is the same
#   ui_wrap <text> [indent]               prose wrapped at 72 columns, never inside a `code` span (drawn cyan)
#   ui_notice <kind> <text> [command]     warning (Try), note (See) and progress on stderr; next on stdout; try <command>
#   warn <text> [try], ui_try <command>, ui_next <command>, log <text>   short forms of ui_notice
#   print_error <text>                    the ❌ line: the first sentence bold red, the rest under it (stderr)
#   die <text> [try] [code]               print_error, a Try line, then exit (default 1)
#   print_warning|print_info <text>       a warning (stderr), or a dim arrow and the text (stdout)
#   ui_question <text> [controls]         bold question, dim controls in parentheses beside it
#   select_menu <question> <row>...       arrow-key picker; a row is "emoji|label|note"; sets SELECTED_INDEX, returns 1 on quit
#                                         UI_RECOMMENDED_INDEX=<n> badges and starts on row n; UI_COLLAPSE=0 keeps the rows
#   confirm <question> [yes|no]           Yes or No picker (the default starts selected); returns 0 for Yes
#   spinner_start <text>, spinner_stop    animate on stderr while a quiet step runs, with the time taken after 3 s
#   ui_run_logged <label> <log> <cmd>...  spinner, output into <log>, then a row; on failure its last UI_TAIL_LINES (30) and the log
#   ui_cols, ui_width, ui_breakpoint      terminal columns, the prose width (at most 72), narrow, regular or wide
#   ui_widest <text>...                   the columns the widest text fills, for UI_ROW_LABEL_WIDTH
#   ui_elapsed <seconds>                  12s, or 2m 05s
#   ui_path <path>                        the path with the home folder as ~ (a person's only)
#   ui_cleanup                            stop the spinner and show the cursor; call it from the script's EXIT trap
#
# An agent (OFFSIDER_OUTPUT=agent, CLAUDE_CODE_CHILD_SESSION or AI_AGENT set; OFFSIDER_OUTPUT=person wins) sets UI_AGENT=1:
# no escapes, no animation, Error:, Warning:, Note:, Try: and Next: prefixes, and a picker never waits for keys.
# NO_COLOR, TERM=dumb or a pipe drops colour; NO_COLOR, UI_ASCII=1 or a locale that is not UTF-8 swaps glyphs for ASCII.

[[ -n "${_OFFSIDER_UI_SH:-}" ]] && return 0
_OFFSIDER_UI_SH=1

# True when a marker variable holds anything but blanks or 0, as AgentMarkers.present decides.
_ui_marked() {
    local value="${1:-}"
    value="${value//[[:space:]]/}"
    [[ -n "$value" && "$value" != 0 ]]
}

ui_init() {
    local named="${OFFSIDER_OUTPUT:-}"
    named="${named//[[:space:]]/}"
    case "$named" in
        [Pp][Ee][Rr][Ss][Oo][Nn]) UI_AGENT=0 ;;
        [Aa][Gg][Ee][Nn][Tt]) UI_AGENT=1 ;;
        *)
            UI_AGENT=0
            if _ui_marked "${CLAUDE_CODE_CHILD_SESSION:-}" || _ui_marked "${AI_AGENT:-}"; then UI_AGENT=1; fi
            ;;
    esac
    local colour=0
    if [[ "$UI_AGENT" == 1 ]]; then
        colour=0
    elif [[ -n "${FORCE_COLOR:-}" && "${FORCE_COLOR}" != 0 ]]; then
        colour=1
    elif [[ -z "${NO_COLOR:-}" && "${TERM:-}" != dumb && -t 1 && -t 2 ]]; then
        colour=1
    fi
    if [[ "$colour" == 1 ]]; then
        GREEN=$'\033[0;32m' RED=$'\033[0;31m' YELLOW=$'\033[0;33m' BLUE=$'\033[0;34m'
        CYAN=$'\033[0;36m' MAGENTA=$'\033[0;35m' DIM=$'\033[2m' BOLD=$'\033[1m' NC=$'\033[0m'
    else
        GREEN='' RED='' YELLOW='' BLUE='' CYAN='' MAGENTA='' DIM='' BOLD='' NC=''
    fi
    local locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" asked="${UI_ASCII:-}"
    UI_ASCII_MODE=0
    if [[ -n "${NO_COLOR:-}" || ( -n "$asked" && "$asked" != 0 ) ]]; then UI_ASCII_MODE=1; fi
    if [[ -n "$locale" && "$locale" != *[Uu][Tt][Ff]-8* && "$locale" != *[Uu][Tt][Ff]8* ]]; then UI_ASCII_MODE=1; fi
    # An agent reads the same bytes whatever its locale, so its glyphs never switch.
    if [[ "$UI_AGENT" == 1 ]]; then UI_ASCII_MODE=0; fi
    if [[ "$UI_ASCII_MODE" == 1 ]]; then
        _UI_OK='[OK]' _UI_ERR='[x]' _UI_WARN='[!]' _UI_TIP='[tip]' _UI_INFO='->' _UI_CURSOR='>'
        _UI_LIGHT='-' _UI_DOT='-' _UI_ELLIPSIS='...' _UI_KEYS='up/down, Enter, Q quit'
        _UI_FRAMES=('|' '/' '-' "\\")
    else
        _UI_OK='✅' _UI_ERR='❌' _UI_WARN='⚠️' _UI_TIP='💡' _UI_INFO='→' _UI_CURSOR='▸'
        _UI_LIGHT='─' _UI_DOT='·' _UI_ELLIPSIS='…' _UI_KEYS='↑↓, Enter, Q quit'
        _UI_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    fi
    UI_DOT="$_UI_DOT"
    return 0
}
ui_init

_UI_SPINNER_PID=""

# Terminal columns: COLUMNS from 1 to 1000, then the terminal's own size, then tput, then 80, as TerminalSize.resolve does.
ui_cols() {
    local c="${COLUMNS:-}" size=""
    c="${c//[[:space:]]/}"
    if [[ "$c" =~ ^[0-9]+$ ]] && (( 10#$c >= 1 && 10#$c <= 1000 )); then
        printf '%d' "$(( 10#$c ))"
        return 0
    fi
    size="$( { stty size </dev/tty; } 2>/dev/null )" || size=""
    c="${size##* }"
    if [[ "$c" =~ ^[0-9]+$ ]] && (( 10#$c > 0 )); then
        printf '%d' "$(( 10#$c ))"
        return 0
    fi
    c="$(tput cols 2>/dev/null)" || c=""
    if [[ "$c" =~ ^[0-9]+$ ]] && (( 10#$c > 0 )); then
        printf '%d' "$(( 10#$c ))"
        return 0
    fi
    printf '80'
}

# The prose and rule width: one short of the edge, at most 72 and never under 20, as Canvas.prose is.
ui_width() {
    local w
    w=$(( $(ui_cols) - 1 ))
    (( w > 72 )) && w=72
    (( w < 20 )) && w=20
    printf '%d' "$w"
}

# Breakpoint in Sources/OffsiderCore/Terminal/Canvas.swift: narrow under 60, regular to 99, wide from 100; an agent has no width.
ui_breakpoint() {
    local c
    if [[ "$UI_AGENT" == 1 ]]; then printf 'regular'; return 0; fi
    c="$(ui_cols)"
    if (( c < 60 )); then printf 'narrow'; elif (( c < 100 )); then printf 'regular'; else printf 'wide'; fi
}

ui_widest() {
    local text widest=0
    for text in "$@"; do
        _ui_measure "$text"
        if (( _UI_W > widest )); then widest=$_UI_W; fi
    done
    printf '%d' "$widest"
}

ui_elapsed() {
    local s="$1"
    if (( s >= 60 )); then printf '%dm %02ds' $(( s / 60 )) $(( s % 60 )); else printf '%ds' "$s"; fi
}

ui_path() {
    local path="$1"
    if [[ "$UI_AGENT" != 1 && -n "${HOME:-}" && "$HOME" != / && "$path" == "$HOME"/* ]]; then path="~${path#"$HOME"}"; fi
    printf '%s' "$path"
}

# Columns a code point fills: TerminalText.cells, with the same wide ranges.
_ui_cells() {
    local cp="$1"
    if (( cp < 0x20 || (cp >= 0x7F && cp < 0xA0) )); then _UI_CELLS=0; return 0; fi
    if (( cp < 0x300 )); then _UI_CELLS=1; return 0; fi
    if (( (cp >= 0x300 && cp <= 0x36F) || (cp >= 0x483 && cp <= 0x489) || (cp >= 0x1AB0 && cp <= 0x1AFF)
        || (cp >= 0x1DC0 && cp <= 0x1DFF) || (cp >= 0x200B && cp <= 0x200F) || (cp >= 0x2028 && cp <= 0x202E)
        || (cp >= 0x2060 && cp <= 0x2064) || (cp >= 0x20D0 && cp <= 0x20FF) || (cp >= 0xFE00 && cp <= 0xFE0F)
        || (cp >= 0xFE20 && cp <= 0xFE2F) || cp == 0xFEFF || (cp >= 0x1160 && cp <= 0x11FF)
        || (cp >= 0xE0000 && cp <= 0xE007F) || (cp >= 0xE0100 && cp <= 0xE01EF) )); then
        _UI_CELLS=0
        return 0
    fi
    if (( (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x231A && cp <= 0x231B) || (cp >= 0x23E9 && cp <= 0x23EC)
        || cp == 0x23F0 || cp == 0x23F3 || (cp >= 0x25FD && cp <= 0x25FE) || (cp >= 0x2614 && cp <= 0x2615)
        || (cp >= 0x2648 && cp <= 0x2653) || cp == 0x267F || cp == 0x2693 || cp == 0x26A1 || (cp >= 0x26AA && cp <= 0x26AB)
        || (cp >= 0x26BD && cp <= 0x26BE) || (cp >= 0x26C4 && cp <= 0x26C5) || cp == 0x26CE || cp == 0x26D4 || cp == 0x26EA
        || (cp >= 0x26F2 && cp <= 0x26F3) || cp == 0x26F5 || cp == 0x26FA || cp == 0x26FD || cp == 0x2705
        || (cp >= 0x270A && cp <= 0x270B) || cp == 0x2728 || cp == 0x274C || cp == 0x274E || (cp >= 0x2753 && cp <= 0x2755)
        || cp == 0x2757 || (cp >= 0x2795 && cp <= 0x2797) || cp == 0x27B0 || cp == 0x27BF || (cp >= 0x2B1B && cp <= 0x2B1C)
        || cp == 0x2B50 || cp == 0x2B55 || (cp >= 0x2E80 && cp <= 0xA4CF) || (cp >= 0xAC00 && cp <= 0xD7A3)
        || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFE30 && cp <= 0xFE4F) || (cp >= 0xFF00 && cp <= 0xFF60)
        || (cp >= 0xFFE0 && cp <= 0xFFE6) || cp == 0x1F004 || cp == 0x1F0CF || cp == 0x1F18E || (cp >= 0x1F191 && cp <= 0x1F19A)
        || (cp >= 0x1F1E6 && cp <= 0x1F2FF) || (cp >= 0x1F300 && cp <= 0x1F64F) || (cp >= 0x1F680 && cp <= 0x1F6FF)
        || (cp >= 0x1F7E0 && cp <= 0x1F7EB) || (cp >= 0x1F900 && cp <= 0x1F9FF) || (cp >= 0x1FA70 && cp <= 0x1FAFF)
        || (cp >= 0x20000 && cp <= 0x3FFFD) )); then
        _UI_CELLS=2
        return 0
    fi
    _UI_CELLS=1
}

# Splits text into what a terminal draws as one glyph each, in _UI_CL, with their columns in _UI_CW and the total in _UI_W.
# Bytes are decoded by hand under the C locale, so the result never depends on the caller's locale; escapes take no columns.
_ui_clusters() {
    local LC_ALL=C
    local s="$1" n i=0 b c k len cp joined=0 ri=0 last=-1 piece
    _UI_CL=() _UI_CW=() _UI_W=0
    n=${#s}
    while (( i < n )); do
        printf -v b '%d' "'${s:i:1}"
        if (( b < 0 )); then b=$(( b + 256 )); fi
        if (( b == 27 )); then
            piece=$'\033'
            i=$(( i + 1 ))
            if [[ "${s:i:1}" == '[' ]]; then
                piece="${piece}["
                i=$(( i + 1 ))
                while (( i < n )); do
                    printf -v c '%d' "'${s:i:1}"
                    piece="${piece}${s:i:1}"
                    i=$(( i + 1 ))
                    if (( c >= 0x40 && c <= 0x7E )); then break; fi
                done
            fi
            _UI_CL[${#_UI_CL[@]}]="$piece"
            _UI_CW[${#_UI_CW[@]}]=0
            last=-1
            continue
        fi
        if (( b < 0x80 )); then len=1 cp=$b
        elif (( b >= 0xF0 && b < 0xF8 )); then len=4 cp=$(( b & 0x07 ))
        elif (( b >= 0xE0 )); then len=3 cp=$(( b & 0x0F ))
        elif (( b >= 0xC0 )); then len=2 cp=$(( b & 0x1F ))
        else len=1 cp=0xFFFD
        fi
        k=1
        while (( k < len )); do
            printf -v c '%d' "'${s:i+k:1}"
            if (( c < 0 )); then c=$(( c + 256 )); fi
            if (( (c & 0xC0) != 0x80 )); then len=$k cp=0xFFFD; break; fi
            cp=$(( (cp << 6) | (c & 0x3F) ))
            k=$(( k + 1 ))
        done
        piece="${s:i:len}"
        i=$(( i + len ))
        if (( last >= 0 )) && { (( joined == 1 )) || (( cp == 0x200D )) \
            || (( (cp >= 0x300 && cp <= 0x36F) || (cp >= 0x1AB0 && cp <= 0x1AFF) || (cp >= 0x1DC0 && cp <= 0x1DFF) )) \
            || (( (cp >= 0x20D0 && cp <= 0x20FF) || (cp >= 0xFE00 && cp <= 0xFE0F) || (cp >= 0xFE20 && cp <= 0xFE2F) )) \
            || (( cp >= 0xE0020 && cp <= 0xE007F )) || (( cp >= 0x1F3FB && cp <= 0x1F3FF && _UI_CW[last] == 2 )) \
            || (( ri == 1 && cp >= 0x1F1E6 && cp <= 0x1F1FF )); }; then
            _UI_CL[last]="${_UI_CL[last]}${piece}"
            if (( cp == 0xFE0F && _UI_CW[last] == 1 )); then _UI_CW[last]=2; _UI_W=$(( _UI_W + 1 )); fi
            if (( cp == 0xFE0E && _UI_CW[last] == 2 )); then _UI_CW[last]=1; _UI_W=$(( _UI_W - 1 )); fi
            joined=0
            if (( cp == 0x200D )); then joined=1; fi
            ri=0
            continue
        fi
        _ui_cells "$cp"
        _UI_CL[${#_UI_CL[@]}]="$piece"
        _UI_CW[${#_UI_CW[@]}]=$_UI_CELLS
        last=$(( ${#_UI_CL[@]} - 1 ))
        _UI_W=$(( _UI_W + _UI_CELLS ))
        joined=0
        ri=0
        if (( cp >= 0x1F1E6 && cp <= 0x1F1FF )); then ri=1; fi
    done
    return 0
}

# _UI_W: the columns text fills. Plain printable ASCII takes the fast path.
_ui_measure() {
    local LC_ALL=C
    if [[ "$1" != *[![:print:]]* ]]; then
        _UI_W=${#1}
        return 0
    fi
    _ui_clusters "$1"
}

# _UI_T: plain text cut by whole glyphs to at most <width> columns, the ellipsis marking the cut; unchanged when it fits.
_ui_truncate() {
    local text="$1" width="$2" mark="${3-$_UI_ELLIPSIS}" mark_width budget used=0 k=0 out=""
    _UI_T=""
    (( width > 0 )) || return 0
    _ui_measure "$text"
    if (( _UI_W <= width )); then _UI_T="$text"; return 0; fi
    _ui_measure "$mark"
    mark_width=$_UI_W
    if (( width <= mark_width )); then
        if (( mark_width <= width )); then _UI_T="$mark"; fi
        return 0
    fi
    budget=$(( width - mark_width ))
    local LC_ALL=C
    if [[ "$text" != *[![:print:]]* ]]; then
        _UI_T="${text:0:budget}${mark}"
        return 0
    fi
    _ui_clusters "$text"
    while (( k < ${#_UI_CL[@]} )); do
        if (( used + _UI_CW[k] > budget )); then break; fi
        out="${out}${_UI_CL[k]}"
        used=$(( used + _UI_CW[k] ))
        k=$(( k + 1 ))
    done
    _UI_T="${out}${mark}"
}

# _UI_LINES: text broken between words to fit <width>; a `code` span stays whole, and so does a word wider than a line.
_ui_wrap_lines() {
    local text="$1" width="$2" word line="" ticks total open=0 merged=() k=0 current=""
    _UI_LINES=()
    local -a words=()
    IFS=' ' read -r -a words <<<"$text" || true
    total="${text//[!\`]/}"
    total=${#total}
    for word in ${words[@]+"${words[@]}"}; do
        if (( open == 1 )); then current="${current} ${word}"; else current="$word"; fi
        ticks="${word//[!\`]/}"
        k=${#ticks}
        while (( k > 0 )); do
            if (( open == 1 || total >= 2 )); then open=$(( 1 - open )); fi
            total=$(( total - 1 ))
            k=$(( k - 1 ))
        done
        if (( open == 0 )); then merged[${#merged[@]}]="$current"; current=""; fi
    done
    if [[ -n "$current" ]]; then merged[${#merged[@]}]="$current"; fi
    local line_width word_width
    for word in ${merged[@]+"${merged[@]}"}; do
        _ui_measure "$word"
        word_width=$_UI_W
        if [[ -z "$line" ]]; then
            line="$word" line_width=$word_width
        elif (( line_width + 1 + word_width <= width )); then
            line="${line} ${word}" line_width=$(( line_width + 1 + word_width ))
        else
            _UI_LINES[${#_UI_LINES[@]}]="$line"
            line="$word" line_width=$word_width
        fi
    done
    _UI_LINES[${#_UI_LINES[@]}]="$line"
    return 0
}

# _UI_C: a line with each balanced `code` span cyan and without its backticks, the rest in <base>; TerminalText.codeSpans.
_ui_code_spans() {
    local text="$1" base="${2:-}" rest parts=() count paired i=0 out="" part
    rest="$text"
    while [[ "$rest" == *'`'* ]]; do
        parts[${#parts[@]}]="${rest%%\`*}"
        rest="${rest#*\`}"
    done
    parts[${#parts[@]}]="$rest"
    count=${#parts[@]}
    if (( count < 3 )); then
        if [[ -n "$text" && -n "$base" ]]; then _UI_C="${base}${text}${NC}"; else _UI_C="$text"; fi
        return 0
    fi
    paired=$count
    (( count % 2 == 0 )) && paired=$(( count - 1 ))
    while (( i < count )); do
        part="${parts[i]}"
        if (( i >= paired )); then
            out="${out}${base}\`${part}${base:+$NC}"
        elif (( i % 2 == 1 )); then
            out="${out}${CYAN}${part}${NC}"
        elif [[ -n "$part" ]]; then
            out="${out}${base}${part}${base:+$NC}"
        fi
        i=$(( i + 1 ))
    done
    _UI_C="$out"
}

# Prints <lead> and the text wrapped to the prose width under it, the continuation lines indented by the lead's width.
_ui_lead_block() {
    local lead="$1" text="$2" tone="${3:-}" lead_tone="${4:-}" indent width k=0
    _ui_measure "$lead"
    indent="$(printf '%*s' "$_UI_W" '')"
    width=$(( $(ui_width) - _UI_W ))
    (( width < 10 )) && width=10
    _ui_wrap_lines "$text" "$width"
    while (( k < ${#_UI_LINES[@]} )); do
        _ui_code_spans "${_UI_LINES[k]}" "$tone"
        if (( k == 0 )); then
            printf '%s%s\n' "${lead:+${lead_tone}${lead}${lead_tone:+$NC}}" "$_UI_C"
        else
            printf '%s%s\n' "$indent" "$_UI_C"
        fi
        k=$(( k + 1 ))
    done
}

# A dim label and a cyan command that never wraps, as TerminalUI.commands draws them.
_ui_command_line() {
    printf '%s%s%s%s  %s%s%s\n' "$1" "$DIM" "$2" "$NC" "$CYAN" "$3" "$NC"
}

_ui_rule() {
    local char="$1" width="$2" out="" i
    for (( i = 0; i < width; i++ )); do out="${out}${char}"; done
    printf '%s' "$out"
}

ui_header() {
    local mark="$1" title="$2" summary="${3:-}"
    if [[ "$UI_AGENT" == 1 ]]; then
        printf '%s%s\n' "$title" "${summary:+: $summary}"
        return 0
    fi
    local usable frame lead="" title_width summary_width natural k=0
    usable=$(( $(ui_cols) - 1 ))
    (( usable < 1 )) && usable=1
    frame=$usable
    (( frame > 72 )) && frame=72
    if [[ "$UI_ASCII_MODE" != 1 && -n "$mark" ]]; then lead="${mark}  "; fi
    _ui_measure "${lead}${title}"
    title_width=$_UI_W
    _ui_measure "$summary"
    summary_width=$_UI_W
    natural=$title_width
    [[ -n "$summary" ]] && natural=$(( title_width + 2 + summary_width ))
    (( natural > frame && natural <= usable )) && frame=$natural
    if (( title_width > frame )); then
        _ui_measure "$lead"
        _ui_truncate "$title" $(( frame - _UI_W ))
        title="$_UI_T"
        title_width=$frame
    fi
    printf '\n'
    if [[ -z "$summary" ]]; then
        printf '%s%s%s%s\n' "$lead" "$BOLD" "$title" "$NC"
    elif (( title_width + 2 + summary_width <= frame )); then
        printf '%s%s%s%s%*s%s%s%s\n' "$lead" "$BOLD" "$title" "$NC" $(( frame - title_width - summary_width )) '' "$DIM" "$summary" "$NC"
    else
        printf '%s%s%s%s\n' "$lead" "$BOLD" "$title" "$NC"
        _ui_wrap_lines "$summary" $(( frame - 4 ))
        while (( k < ${#_UI_LINES[@]} )); do
            printf '    %s%s%s\n' "$DIM" "${_UI_LINES[k]}" "$NC"
            k=$(( k + 1 ))
        done
    fi
    printf '%s%s%s\n\n' "$CYAN" "$(_ui_rule "$_UI_LIGHT" "$frame")" "$NC"
    return 0
}

ui_banner() { ui_header "$1" "$2" "${3:-}"; }
ui_section() { ui_header "$1" "$2" "${3:-}"; }

ui_heading() {
    if [[ "$UI_AGENT" == 1 ]]; then
        printf '%s\n' "$2"
        return 0
    fi
    printf '\n  %s%s%s\n' "$BOLD" "$2" "$NC"
}

ui_step() {
    local label="Step $1/$2 ${_UI_DOT} $3" fill
    if [[ "$UI_AGENT" == 1 ]]; then
        printf 'Step %s/%s: %s\n' "$1" "$2" "$3"
        return 0
    fi
    _ui_measure "$label"
    fill=$(( $(ui_width) - _UI_W - 4 ))
    (( fill < 2 )) && fill=2
    printf '\n%s%s%s %s%s%s %s%s%s\n\n' "$DIM" "$_UI_LIGHT$_UI_LIGHT" "$NC" "$CYAN" "$label" "$NC" "$DIM" "$(_ui_rule "$_UI_LIGHT" "$fill")" "$NC"
}

# The glyph a row leads with, its colour, and its columns: Unicode for a person and an agent, tags under ASCII.
_ui_status() {
    local status="$1"
    _UI_GLYPH_TONE=""
    if [[ "$UI_ASCII_MODE" == 1 ]]; then
        case "$status" in
            ok) _UI_GLYPH='[OK]' _UI_GLYPH_TONE="$GREEN" ;;
            warn) _UI_GLYPH='[!]' _UI_GLYPH_TONE="$YELLOW" ;;
            fail) _UI_GLYPH='[x]' _UI_GLYPH_TONE="$RED" ;;
            run) _UI_GLYPH='[..]' ;;
            on) _UI_GLYPH='[*]' _UI_GLYPH_TONE="$GREEN" ;;
            off) _UI_GLYPH='[o]' _UI_GLYPH_TONE="$DIM" ;;
            *) _UI_GLYPH='[-]' _UI_GLYPH_TONE="$DIM" ;;
        esac
        _UI_GLYPH_WIDTH=4
        return 0
    fi
    case "$status" in
        ok) _UI_GLYPH='✓' _UI_GLYPH_TONE="$GREEN" ;;
        warn) _UI_GLYPH='!' _UI_GLYPH_TONE="$YELLOW" ;;
        fail) _UI_GLYPH='✗' _UI_GLYPH_TONE="$RED" ;;
        run) _UI_GLYPH='◐' ;;
        on) _UI_GLYPH='●' _UI_GLYPH_TONE="$GREEN" ;;
        off) _UI_GLYPH='○' _UI_GLYPH_TONE="$DIM" ;;
        *) _UI_GLYPH='-' _UI_GLYPH_TONE="$DIM" ;;
    esac
    _UI_GLYPH_WIDTH=1
}

ui_row() {
    local status="$1" label="$2" detail="${3:-}" pad=0 want="${UI_ROW_LABEL_WIDTH:-}" room label_width
    _ui_status "$status"
    _ui_measure "$label"
    label_width=$_UI_W
    if [[ "$want" =~ ^[0-9]+$ ]] && (( want > label_width )); then pad=$(( want - label_width )); fi
    if [[ "$UI_AGENT" == 1 ]]; then
        if [[ -n "$detail" ]]; then
            printf '%s %s%*s  %s\n' "$_UI_GLYPH" "$label" "$pad" '' "$detail"
        else
            printf '%s %s\n' "$_UI_GLYPH" "$label"
        fi
        return 0
    fi
    local glyph="$_UI_GLYPH"
    while (( ${#glyph} < _UI_GLYPH_WIDTH )); do glyph="${glyph} "; done
    room=$(( $(ui_cols) - 1 - 3 - _UI_GLYPH_WIDTH ))
    if (( label_width > room )); then
        _ui_truncate "$label" "$room"
        label="$_UI_T" pad=0 detail=""
    elif [[ -n "$detail" ]]; then
        if (( label_width + pad > room )); then pad=$(( room - label_width )); fi
        local left=$(( room - label_width - pad - 2 ))
        _ui_measure "$detail"
        if (( _UI_W > left && left < 4 )); then
            detail=""
        else
            _ui_truncate "$detail" "$left"
            detail="$_UI_T"
        fi
    fi
    if [[ -n "$detail" ]]; then
        printf '  %s%s%s %s%*s  %s%s%s\n' "$_UI_GLYPH_TONE" "$glyph" "${_UI_GLYPH_TONE:+$NC}" "$label" "$pad" '' "$DIM" "$detail" "$NC"
    else
        printf '  %s%s%s %s\n' "$_UI_GLYPH_TONE" "$glyph" "${_UI_GLYPH_TONE:+$NC}" "$label"
    fi
    return 0
}

ui_kv() {
    local label="$1" value="$2" detail="${3:-}" pad=0 want="${UI_KV_LABEL_WIDTH:-}"
    if [[ "$UI_AGENT" == 1 ]]; then
        printf '%s: %s%s\n' "$label" "$value" "${detail:+ ($detail)}"
        return 0
    fi
    _ui_measure "$label"
    if [[ "$want" =~ ^[0-9]+$ ]] && (( want > _UI_W )); then pad=$(( want - _UI_W )); fi
    printf '  %s%s%*s%s  %s%s\n' "$DIM" "$label" "$pad" '' "$NC" "$value" "${detail:+  ${DIM}${detail}${NC}}"
}

ui_receipt() {
    local headline="$1" detail lead indent width k
    shift
    if [[ "$UI_AGENT" == 1 ]]; then
        printf '%s\n' "$headline"
        for detail in "$@"; do printf '%s\n' "$detail"; done
        return 0
    fi
    if [[ "$UI_ASCII_MODE" == 1 ]]; then lead="${_UI_OK} "; else lead="${_UI_OK}  "; fi
    _ui_lead_block "$lead" "$headline" "${GREEN}${BOLD}"
    _ui_measure "$lead"
    indent="$(printf '%*s' "$_UI_W" '')"
    width=$(( $(ui_width) - _UI_W ))
    (( width < 10 )) && width=10
    for detail in "$@"; do
        _ui_wrap_lines "$detail" "$width"
        k=0
        while (( k < ${#_UI_LINES[@]} )); do
            printf '%s%s%s%s\n' "$indent" "$DIM" "${_UI_LINES[k]}" "$NC"
            k=$(( k + 1 ))
        done
    done
    return 0
}

ui_wrap() {
    local text="$1" indent="${2:-}" k=0 width
    if [[ "$UI_AGENT" == 1 ]]; then
        printf '%s%s\n' "$indent" "$text"
        return 0
    fi
    _ui_measure "$indent"
    width=$(( $(ui_width) - _UI_W ))
    (( width < 10 )) && width=10
    _ui_wrap_lines "$text" "$width"
    while (( k < ${#_UI_LINES[@]} )); do
        _ui_code_spans "${_UI_LINES[k]}"
        printf '%s%s\n' "$indent" "$_UI_C"
        k=$(( k + 1 ))
    done
}

ui_notice() {
    local kind="$1" text="${2:-}" command="${3:-}" lead
    case "$kind" in
        warning|note)
            if [[ "$UI_AGENT" == 1 ]]; then
                if [[ "$kind" == warning ]]; then printf 'Warning: %s\n' "$text" >&2; else printf 'Note: %s\n' "$text" >&2; fi
                if [[ -n "$command" && "$text" != *"$command"* ]]; then printf 'Try: %s\n' "$command" >&2; fi
                return 0
            fi
            if [[ "$kind" == warning ]]; then lead="$_UI_WARN"; else lead="$_UI_TIP"; fi
            if [[ "$UI_ASCII_MODE" == 1 ]]; then lead="${lead} "; else lead="${lead}  "; fi
            if [[ "$kind" == warning ]]; then
                _ui_lead_block "$lead" "$text" "$YELLOW" "$YELLOW" >&2
            else
                _ui_lead_block "$lead" "$text" >&2
            fi
            if [[ -n "$command" ]]; then
                _ui_measure "$lead"
                if [[ "$kind" == warning ]]; then
                    _ui_command_line "$(printf '%*s' "$_UI_W" '')" "Try" "$command" >&2
                else
                    _ui_command_line "$(printf '%*s' "$_UI_W" '')" "See" "$command" >&2
                fi
            fi
            ;;
        try)
            [[ -n "$text" ]] || return 0
            if [[ "$UI_AGENT" == 1 ]]; then printf 'Try: %s\n' "$text" >&2; else _ui_command_line "    " "Try" "$text" >&2; fi
            ;;
        next)
            [[ -n "$text" ]] || return 0
            if [[ "$UI_AGENT" == 1 ]]; then printf 'Next: %s\n' "$text"; else printf '\n'; _ui_command_line "" "Next" "$text"; fi
            ;;
        progress)
            if [[ "$UI_AGENT" == 1 ]]; then printf '%s\n' "$text" >&2; else printf '%s%s%s\n' "$DIM" "$text" "$NC" >&2; fi
            ;;
        *)
            printf 'ui_notice: unknown kind %s\n' "$kind" >&2
            return 2
            ;;
    esac
    return 0
}

warn() { ui_notice warning "$1" "${2:-}"; }
ui_try() { ui_notice try "${1:-}"; }
ui_next() { ui_notice next "${1:-}"; }
log() { ui_notice progress "$*"; }
print_success() { ui_receipt "$@"; }
print_warning() { ui_notice warning "$1"; }

print_info() {
    if [[ "$UI_AGENT" == 1 ]]; then printf '%s\n' "$1"; else printf '%s%s%s %s\n' "$DIM" "$_UI_INFO" "$NC" "$1"; fi
}

# _UI_HEAD and _UI_REST: the first sentence and what follows, a full stop and a space before a capital or ` ending it.
_ui_first_sentence() {
    local text="$1" scan="$1" done_part="" before after trimmed
    while [[ "$scan" == *". "* ]]; do
        before="${scan%%. *}"
        after="${scan#*. }"
        trimmed="${after#"${after%%[! ]*}"}"
        case "${trimmed:0:1}" in
            [[:upper:]]|'`')
                _UI_HEAD="${done_part}${before}."
                _UI_REST="$trimmed"
                return 0
                ;;
        esac
        done_part="${done_part}${before}. "
        scan="$after"
    done
    _UI_HEAD="$text" _UI_REST=""
}

print_error() {
    local lead
    if [[ "$UI_AGENT" == 1 ]]; then
        printf 'Error: %s\n' "$1" >&2
        return 0
    fi
    if [[ "$UI_ASCII_MODE" == 1 ]]; then lead="${_UI_ERR} "; else lead="${_UI_ERR}  "; fi
    _ui_first_sentence "$1"
    _ui_lead_block "$lead" "$_UI_HEAD" "${RED}${BOLD}" >&2
    if [[ -n "$_UI_REST" ]]; then
        _ui_measure "$lead"
        _ui_lead_block "$(printf '%*s' "$_UI_W" '')" "$_UI_REST" >&2
    fi
    return 0
}

die() {
    spinner_stop
    print_error "$1"
    if [[ -n "${2:-}" && "$1" != *"$2"* ]]; then ui_try "$2"; fi
    exit "${3:-1}"
}

ui_question() {
    local question="$1" controls="(${2:-$_UI_KEYS})" cols
    cols="$(ui_cols)"
    _ui_measure "$question $controls"
    if (( _UI_W <= cols - 1 )); then
        printf '%s%s%s %s%s%s\n' "$BOLD" "$question" "$NC" "$DIM" "$controls" "$NC" >&2
        _UI_QUESTION_WIDTH=$_UI_W
        return 0
    fi
    _ui_truncate "$question" $(( cols - 1 ))
    printf '%s%s%s\n' "$BOLD" "$_UI_T" "$NC" >&2
    _ui_measure "$_UI_T"
    _UI_QUESTION_WIDTH=$_UI_W
}

# The terminal rows lines of the given widths fill once the terminal is <cols> wide: a line wider than it folds.
_ui_rows_used() {
    local cols="$1" total=0 w
    shift
    (( cols < 1 )) && cols=1
    for w in "$@"; do
        if (( w <= cols )); then total=$(( total + 1 )); else total=$(( total + (w + cols - 1) / cols )); fi
    done
    _UI_ROWS=$total
}

spinner_start() {
    spinner_stop
    if [[ "$UI_AGENT" == 1 || ! -t 2 ]]; then
        printf '%s\n' "$1" >&2
        return 0
    fi
    local label="$1" parent=$$
    (
        trap 'exit 0' INT TERM HUP
        count=${#_UI_FRAMES[@]} i=0 started=$SECONDS cols=0 took="" room=0
        while kill -0 "$parent" 2>/dev/null; do
            if (( i % 10 == 0 )); then cols="$(ui_cols)"; fi
            took=""
            if (( SECONDS - started >= 3 )); then took="$(ui_elapsed $(( SECONDS - started )))"; fi
            room=$(( cols - 4 ))
            if [[ -n "$took" ]]; then room=$(( room - ${#took} - 2 )); fi
            _ui_truncate "$label" "$room"
            printf '\r\033[K%s%s %s%s%s' "$DIM" "${_UI_FRAMES[i % count]}" "$_UI_T" "${took:+  $took}" "$NC" >&2
            i=$(( i + 1 ))
            sleep 0.1
        done
    ) &
    _UI_SPINNER_PID=$!
    return 0
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
    if [[ "$UI_AGENT" != 1 && -t 2 ]]; then printf '\033[?25h' >&2; fi
    return 0
}

# Call it plainly to wrap a function of several commands: under `|| die` bash ignores set -e inside, so it runs on past a failure.
ui_run_logged() {
    local label="$1" logfile="$2" started rc errexit=0 took
    shift 2
    [[ $- == *e* ]] && errexit=1
    mkdir -p "$(dirname "$logfile")"
    started=$SECONDS
    spinner_start "$label"
    # Errexit is off around the subshell on purpose: `( ) || rc=$?` would silently disable it inside.
    set +e
    ( set -e; "$@" ) >>"$logfile" 2>&1 </dev/null
    rc=$?
    [[ "$errexit" == 1 ]] && set -e
    spinner_stop
    took="$(ui_elapsed $(( SECONDS - started )))"
    if [[ "$rc" -eq 0 ]]; then
        ui_row ok "$label" "$took"
        return 0
    fi
    ui_row fail "$label" "$took" >&2
    if [[ "$UI_AGENT" == 1 ]]; then
        tail -n "${UI_TAIL_LINES:-30}" "$logfile" >&2
        printf 'Log: %s\n' "$logfile" >&2
    else
        printf '%s' "$DIM" >&2
        tail -n "${UI_TAIL_LINES:-30}" "$logfile" >&2
        printf '%s' "$NC" >&2
        _ui_command_line "    " "Log" "$logfile" >&2
    fi
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

# _UI_LABEL_WIDTH and _UI_MARK_WIDTH: the widest label and mark, so the columns line up.
_ui_label_width() {
    local row width=0 marks=0
    for row in "$@"; do
        _ui_split_row "$row"
        _ui_measure "$_UI_ROW_LABEL"
        (( _UI_W > width )) && width=$_UI_W
        if [[ "$UI_ASCII_MODE" != 1 && -n "$_UI_ROW_EMOJI" ]]; then
            _ui_measure "$_UI_ROW_EMOJI"
            (( _UI_W > marks )) && marks=$_UI_W
        fi
    done
    _UI_LABEL_WIDTH=$width
    _UI_MARK_WIDTH=$marks
}

# One menu row as TerminalUI.rows draws it, cut to <cols> - 1 so it never folds; its drawn width goes in _UI_ROW_WIDTH.
_ui_draw_row() {
    local index="$1" selected="$2" row="$3" cols="$4" mark="" mark_pad=0 label pad note badge="" room used
    _ui_split_row "$row"
    label="$_UI_ROW_LABEL" note="$_UI_ROW_NOTE"
    if (( _UI_MARK_WIDTH > 0 )); then
        mark="$_UI_ROW_EMOJI"
        _ui_measure "$mark"
        mark_pad=$(( _UI_MARK_WIDTH - _UI_W + 2 ))
        used=$(( 4 + _UI_MARK_WIDTH + 2 ))
    else
        used=4
    fi
    [[ "${UI_RECOMMENDED_INDEX:-}" == "$index" ]] && badge=" (Recommended)"
    room=$(( cols - 1 ))
    _ui_measure "$label"
    pad=$(( _UI_LABEL_WIDTH - _UI_W ))
    if (( used + _UI_W > room )); then
        _ui_truncate "$label" $(( room - used ))
        label="$_UI_T" note="" badge="" pad=0
        _ui_measure "$label"
    fi
    used=$(( used + _UI_W ))
    if [[ -n "$badge" ]] && (( used + ${#badge} > room )); then badge=""; fi
    [[ -n "$badge" ]] && room=$(( room - ${#badge} ))
    if [[ -n "$note" ]]; then
        if (( used + pad + 2 + 4 > room )); then
            note=""
        else
            _ui_truncate "$note" $(( room - used - pad - 2 ))
            note="$_UI_T"
            _ui_measure "$note"
            used=$(( used + pad + 2 + _UI_W ))
        fi
    fi
    [[ -n "$badge" ]] && used=$(( used + ${#badge} ))
    _UI_ROW_WIDTH=$used
    local head="$label"
    (( _UI_MARK_WIDTH > 0 )) && head="${mark}$(printf '%*s' "$mark_pad" '')${label}"
    [[ -n "$note" ]] && head="${head}$(printf '%*s' "$pad" '')"
    if [[ "$selected" == 1 ]]; then
        printf '\r  %s%s %s%s%s%s%s%s%s\n' "$GREEN" "$_UI_CURSOR" "$head" "$NC" "${note:+  $DIM}" "$note" "${note:+$NC}" "${badge:+$MAGENTA}" "$badge${badge:+$NC}" >&2
    else
        printf '\r    %s%s%s%s%s%s\n' "$head" "${note:+  $DIM}" "$note" "${note:+$NC}" "${badge:+$MAGENTA}" "$badge${badge:+$NC}" >&2
    fi
}

# Numbered fallback for a stdin that is not a terminal: reads one line, an empty line takes the recommended row.
_ui_select_numbered() {
    local question="$1" count i answer default row
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
    # A piped answer is not echoed, so end the prompt's line for whatever prints next.
    [[ -t 0 ]] || printf '\n' >&2
    if [[ -z "$answer" && -n "$default" ]]; then answer=$(( default + 1 )); fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= count )); then
        SELECTED_INDEX=$(( answer - 1 ))
        return 0
    fi
    return 1
}

# An agent is never asked: the recommended row when there is one, else no answer. Nothing is read from stdin.
_ui_select_agent() {
    local question="$1" index="${UI_RECOMMENDED_INDEX:-}" count
    shift
    count=$#
    if [[ "$index" =~ ^[0-9]+$ ]] && (( index < count )); then
        local rows=("$@")
        _ui_split_row "${rows[index]}"
        SELECTED_INDEX=$index
        printf 'Note: %s Picked %s, the recommended answer, without asking.\n' "$question" "$_UI_ROW_LABEL" >&2
        return 0
    fi
    printf 'Note: %s Not asked: there is no person to answer.\n' "$question" >&2
    return 1
}

select_menu() {
    local question="$1" count cols current i key rest up
    shift
    count=$#
    SELECTED_INDEX=""
    (( count > 0 )) || return 1
    if [[ "$UI_AGENT" == 1 ]]; then
        _ui_select_agent "$question" "$@"
        return $?
    fi
    if [[ ! -t 0 || ! -t 2 ]]; then
        _ui_select_numbered "$question" "$@"
        return $?
    fi
    current=0
    if [[ "${UI_RECOMMENDED_INDEX:-}" =~ ^[0-9]+$ ]] && (( UI_RECOMMENDED_INDEX < count )); then
        current=$UI_RECOMMENDED_INDEX
    fi
    _ui_label_width "$@"
    local rows=("$@") drawn=()
    ui_question "$question"
    printf '\n\033[?25l' >&2
    while :; do
        cols="$(ui_cols)"
        drawn=()
        for (( i = 0; i < count; i++ )); do
            if (( i == current )); then _ui_draw_row "$i" 1 "${rows[i]}" "$cols"; else _ui_draw_row "$i" 0 "${rows[i]}" "$cols"; fi
            drawn[i]=$_UI_ROW_WIDTH
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
        # A resize since the last draw folds the rows; count them at today's width so the erase lands on the first.
        _ui_rows_used "$(ui_cols)" "${drawn[@]}"
        printf '\033[%dA\033[J' "$_UI_ROWS" >&2
    done
    printf '\033[?25h' >&2
    if (( current < 0 )); then return 1; fi
    SELECTED_INDEX=$current
    if [[ "${UI_COLLAPSE:-1}" != 0 ]]; then
        cols="$(ui_cols)"
        _ui_rows_used "$cols" "${_UI_QUESTION_WIDTH:-0}" 0 "${drawn[@]}"
        up=$_UI_ROWS
        printf '\033[%dA\033[J' "$up" >&2
        _ui_split_row "${rows[current]}"
        _ui_truncate "$_UI_ROW_LABEL" $(( cols - 6 ))
        if [[ "$UI_ASCII_MODE" == 1 ]]; then
            printf '%s%s %s%s\n' "$GREEN" "$_UI_OK" "$_UI_T" "$NC" >&2
        else
            printf '%s%s  %s%s\n' "$GREEN" "$_UI_OK" "$_UI_T" "$NC" >&2
        fi
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
