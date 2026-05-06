#!/usr/bin/env bash
# Runs once when a devcontainer/container is first created. Idempotent so
# rebuilds don't clobber existing user state in the named volumes.
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC1091
source /usr/local/lib/agent-output.sh

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"

mkdir -p "$CLAUDE_DIR" "$CODEX_DIR"

# Seed default settings only when the volume is empty so a re-build does not
# overwrite the user's customised configs / login tokens.
if [[ ! -f "$CLAUDE_DIR/settings.json" ]] && [[ -f /etc/agent-runtime/claude-settings.json ]]; then
    cp /etc/agent-runtime/claude-settings.json "$CLAUDE_DIR/settings.json"
fi

if [[ ! -f "$CODEX_DIR/config.toml" ]] && [[ -f /etc/agent-runtime/codex-config.toml ]]; then
    cp /etc/agent-runtime/codex-config.toml "$CODEX_DIR/config.toml"
fi

# Writable runtime gitconfig (GIT_CONFIG_GLOBAL). It pulls in the user's
# host-side ~/.gitconfig (which we bind-mount read-only at /home/node/
# .gitconfig) so name/email/aliases still apply, but tools like
# `gh auth setup-git` write *here* — the host file stays untouched.
RUNTIME_GITCONFIG=$HOME/.gitconfig-runtime
if [[ ! -f "$RUNTIME_GITCONFIG" ]]; then
    {
        if [[ -f "$HOME/.gitconfig" ]]; then
            echo '[include]'
            echo "    path = $HOME/.gitconfig"
        fi
    } > "$RUNTIME_GITCONFIG"
fi

# If gh is logged in, wire up the credential helper for HTTPS git
# operations (git push / fetch over https://github.com/...). Idempotent:
# gh writes a single credential.helper line, so re-running is fine.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh auth setup-git >/dev/null 2>&1 || true
fi

# --- Welcome banner ---------------------------------------------------------
# Builds a fixed-width box (60 cols inner) whose middle rows reflect the
# actual project shape and which services run.sh decided to start. Falls
# back to plain ASCII when not on a TTY (AR_* vars from agent-output.sh
# are empty in that case).
BOX_W=60

box_top()   { printf '%b╭%b%b\n' "$AR_CYAN" "$(printf '─%.0s' $(seq 1 $BOX_W))" "╮${AR_RESET}"; }
box_bot()   { printf '%b╰%b%b\n' "$AR_CYAN" "$(printf '─%.0s' $(seq 1 $BOX_W))" "╯${AR_RESET}"; }
box_blank() { printf '%b│%b%*s%b│%b\n' "$AR_CYAN" "$AR_RESET" "$BOX_W" '' "$AR_CYAN" "$AR_RESET"; }

# Prints one box row. $1 = plain content (no escapes, used to compute
# padding), $2 = same content with optional escapes (defaults to $1).
# 🚀 is one character but two terminal columns; subtract 1 from pad when
# present.
box_line() {
    local plain=$1
    local colored=${2:-$1}
    local n=${#plain}
    [[ "$plain" == *🚀* ]] && n=$((n + 1))
    local pad=$((BOX_W - n))
    (( pad < 0 )) && pad=0
    # %b on $colored too — it carries `\033[...]` escapes that need to be
    # interpreted. Previously this used %s and the literal backslashes
    # leaked to the terminal.
    printf '%b│%b%b%*s%b│%b\n' "$AR_CYAN" "$AR_RESET" "$colored" "$pad" '' "$AR_CYAN" "$AR_RESET"
}

# Build the dynamic "Enabled: ..." row from real flags (set by run.sh).
build_services_line() {
    local plain="" colored=""
    if [[ "${AGENT_WITH_POSTGRES:-0}" == "1" ]]; then
        plain="PostgreSQL"
        colored="${AR_GREEN}PostgreSQL${AR_RESET}"
    fi
    if [[ "${AGENT_WITH_REDIS:-0}" == "1" ]]; then
        if [[ -n "$plain" ]]; then
            plain+=" · Redis"
            colored+=" · ${AR_GREEN}Redis${AR_RESET}"
        else
            plain="Redis"
            colored="${AR_GREEN}Redis${AR_RESET}"
        fi
    fi
    if [[ -n "$plain" ]]; then
        SERVICES_PLAIN="   Enabled: $plain"
        SERVICES_COLORED="   Enabled: $colored"
    fi
}

SERVICES_PLAIN=""
SERVICES_COLORED=""
build_services_line

echo
box_top
box_blank
box_line "   🚀  Agent Runtime Ready" "   🚀  ${AR_BOLD}Agent Runtime Ready${AR_RESET}"
box_blank
if [[ "${AGENT_LARAVEL_DETECTED:-0}" == "1" ]]; then
    box_line "   Laravel project detected"
fi
if [[ -n "$SERVICES_PLAIN" ]]; then
    box_line "$SERVICES_PLAIN" "$SERVICES_COLORED"
fi
if [[ "${AGENT_LARAVEL_DETECTED:-0}" == "1" ]] || [[ -n "$SERVICES_PLAIN" ]]; then
    box_blank
fi
box_bot

# --- Body ------------------------------------------------------------------
printf '%b' "
  ${AR_BOLD}First run${AR_RESET}

    ${AR_DIM}1.${AR_RESET} Authenticate AI tools
       ${AR_CYAN}claude login${AR_RESET}
       ${AR_CYAN}codex login${AR_RESET}

    ${AR_DIM}2.${AR_RESET} Authenticate GitHub
       ${AR_CYAN}gh auth login${AR_RESET}

    ${AR_DIM}3.${AR_RESET} Start working
       ${AR_CYAN}ai claude${AR_RESET}
       ${AR_CYAN}ai codex${AR_RESET}

    ${AR_DIM}4.${AR_RESET} Review firewall rules
       ${AR_CYAN}cat /usr/local/bin/init-firewall.sh${AR_RESET}


  ${AR_BOLD}Bundled MCP servers${AR_RESET}

    ${AR_GREEN}✓${AR_RESET} playwright        Browser automation
    ${AR_GREEN}✓${AR_RESET} context7          Fresh library docs
    ${AR_GREEN}✓${AR_RESET} chrome-devtools   Chrome DevTools Protocol
    ${AR_GREEN}✓${AR_RESET} github            Repo, PR, and issue tools
"

# Laravel Boost recipe is only relevant inside an actual Laravel project.
if [[ "${AGENT_LARAVEL_DETECTED:-0}" == "1" ]]; then
    printf '%b' "

  ${AR_BOLD}Laravel Boost${AR_RESET}

    ${AR_CYAN}composer require laravel/boost --dev${AR_RESET}
    ${AR_CYAN}php artisan boost:install${AR_RESET}
"
fi

printf '%b' "

  ${AR_BOLD}Sidecars${AR_RESET}

    ${AR_DIM}Disable with:${AR_RESET}
    --no-postgres  --no-redis  --no-sidecars
"
