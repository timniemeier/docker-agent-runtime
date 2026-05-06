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

# Welcome banner. printf %b expands the AR_* color vars (empty when not a
# TTY or NO_COLOR is set) so plain log files don't pick up any escape codes.
printf '%b' "
${AR_CYAN}╭────────────────────────────────────────────────────────────╮${AR_RESET}
${AR_CYAN}│${AR_RESET}                                                            ${AR_CYAN}│${AR_RESET}
${AR_CYAN}│${AR_RESET}   🚀  ${AR_BOLD}Agent Runtime Ready${AR_RESET}                                  ${AR_CYAN}│${AR_RESET}
${AR_CYAN}│${AR_RESET}                                                            ${AR_CYAN}│${AR_RESET}
${AR_CYAN}│${AR_RESET}   Laravel project detected                                 ${AR_CYAN}│${AR_RESET}
${AR_CYAN}│${AR_RESET}   Enabled: ${AR_GREEN}PostgreSQL${AR_RESET} · ${AR_GREEN}Redis${AR_RESET}                              ${AR_CYAN}│${AR_RESET}
${AR_CYAN}│${AR_RESET}                                                            ${AR_CYAN}│${AR_RESET}
${AR_CYAN}╰────────────────────────────────────────────────────────────╯${AR_RESET}

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


  ${AR_BOLD}Laravel Boost${AR_RESET}

    ${AR_CYAN}composer require laravel/boost --dev${AR_RESET}
    ${AR_CYAN}php artisan boost:install${AR_RESET}


  ${AR_BOLD}Sidecars${AR_RESET}

    ${AR_DIM}Disable with:${AR_RESET}
    --no-postgres  --no-redis  --no-sidecars
"
