#!/bin/bash
# Shows and creates the E2E devices (Offsider_E2E, Offsider_E2E_Fold, Offsider Duo) through e2e-devices-core.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SCRIPT_DIR/e2e-devices-core.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/ui.sh"
trap ui_cleanup EXIT

usage() {
    cat <<EOF
Usage: $0 [status|create]

  (none)   Show the E2E devices and offer to create the missing ones.
  status   Show the E2E devices.
  create   Create the missing ones without asking. Nothing is booted.
EOF
}

command -v jq >/dev/null 2>&1 || die "jq is not installed." "brew install jq"

show_status() {
    local status="$1" name kind profile exists emoji
    while IFS=$'\t' read -r name kind profile exists; do
        emoji="📱"
        [[ "$kind" == avd ]] && emoji="🤖"
        if [[ "$exists" == true ]]; then
            print_success "$(_ui_glyph "$emoji")$name ${DIM}($profile)${NC}"
        else
            print_warning "$(_ui_glyph "$emoji")$name is missing ${DIM}($profile)${NC}"
        fi
    done < <(jq -r '.devices[] | [.name, .kind, .profile, (.exists | tostring)] | @tsv' <<<"$status")
}

create_missing() {
    local result rc errors
    errors="$(mktemp "${TMPDIR:-/tmp}/offsider-e2e-devices.XXXXXX")"
    spinner_start "Creating missing devices"
    result="$("$CORE" create 2>"$errors")"
    rc=$?
    spinner_stop
    if [[ -n "$result" ]]; then
        while IFS= read -r name; do print_success "Created $name"; done < <(jq -r '.created[]' <<<"$result")
        while IFS=$'\t' read -r name error; do print_error "$name: $error"; done < <(jq -r '.failed[] | [.name, .error] | @tsv' <<<"$result")
    fi
    if [[ "$rc" -ne 0 ]]; then
        log "$(cat "$errors")"
        rm -f "$errors"
        die "Some devices could not be created." "$0 create"
    fi
    rm -f "$errors"
    ui_next "./test-runner.sh"
}

status="$("$CORE" status)" || die "Could not read the E2E devices." "$CORE status"
case "${1:-}" in
    status)
        show_status "$status"
        ;;
    create)
        create_missing
        ;;
    "")
        ui_banner "🧪" "Offsider E2E devices"
        show_status "$status"
        echo ""
        if [[ "$(jq '.missing | length' <<<"$status")" == 0 ]]; then
            print_success "All set."
            ui_next "./test-runner.sh"
            exit 0
        fi
        if confirm "Create the missing ones?"; then
            create_missing
        else
            log "Nothing created."
        fi
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
