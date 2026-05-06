#!/usr/bin/env bash
# agent-output.sh — sourced by the runtime's startup scripts to get
# TTY-aware ANSI colors and a small set of consistent log helpers.
#
#   source /usr/local/lib/agent-output.sh
#   log_info "DNS allowed: 1.1.1.1"
#   log_ok   "Firewall initialized"
#   log_warn "No A records resolved for foo.example"
#
# When stdout is a TTY and NO_COLOR is unset, the helpers emit cyan/green/
# yellow/dim escapes. Otherwise the color vars are empty strings so log
# files and non-interactive callers see plain ASCII without any escape
# noise.

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    AR_BOLD='\033[1m'
    AR_DIM='\033[2m'
    AR_CYAN='\033[36m'
    AR_GREEN='\033[32m'
    AR_YELLOW='\033[33m'
    AR_RESET='\033[0m'
else
    AR_BOLD=''
    AR_DIM=''
    AR_CYAN=''
    AR_GREEN=''
    AR_YELLOW=''
    AR_RESET=''
fi

# Indented status lines (two-space margin matches the banner).
log_info() { printf '  %b•%b %s\n' "$AR_DIM" "$AR_RESET" "$*"; }
log_ok()   { printf '  %b✓%b %s\n' "$AR_GREEN" "$AR_RESET" "$*"; }
log_warn() { printf '  %b!%b %s\n' "$AR_YELLOW" "$AR_RESET" "$*"; }

# Section header — used between banner and boot-check lines.
log_section() {
    local title=$1
    local rule="──────────────────────────────────────────────────────────────"
    printf '\n%b%s%b\n' "$AR_CYAN" "$rule" "$AR_RESET"
    printf '%b  %s%b\n' "$AR_BOLD" "$title" "$AR_RESET"
    printf '%b%s%b\n\n' "$AR_CYAN" "$rule" "$AR_RESET"
}

# Final "Container ready" footer.
log_ready() { printf '\n  %s\n' "$*"; }
