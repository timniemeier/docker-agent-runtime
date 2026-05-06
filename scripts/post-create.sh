#!/usr/bin/env bash
# Runs once when a devcontainer/container is first created. Idempotent so
# rebuilds don't clobber existing user state in the named volumes.
set -euo pipefail
IFS=$'\n\t'

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"

mkdir -p "$CLAUDE_DIR" "$CODEX_DIR"

# Seed default settings only when the volume is empty so a re-build does not
# overwrite the user's customised configs / login tokens.
if [[ ! -f "$CLAUDE_DIR/settings.json" ]] && [[ -f /etc/agent-runtime/claude-settings.json ]]; then
    cp /etc/agent-runtime/claude-settings.json "$CLAUDE_DIR/settings.json"
    echo "[post-create] seeded default Claude settings.json"
fi

if [[ ! -f "$CODEX_DIR/config.toml" ]] && [[ -f /etc/agent-runtime/codex-config.toml ]]; then
    cp /etc/agent-runtime/codex-config.toml "$CODEX_DIR/config.toml"
    echo "[post-create] seeded default Codex config.toml"
fi

# Banner. Single-quoted heredoc keeps the \033 literals intact; printf %b
# then expands them to real ANSI escape bytes at print time.
printf '%b' "$(cat <<'BANNER'

\033[1;36m╭────────────────────────────────────────────────────────────╮\033[0m
\033[1;36m│\033[0m                                                            \033[1;36m│\033[0m
\033[1;36m│\033[0m   🚀  \033[1mAgent Runtime Ready\033[0m                                  \033[1;36m│\033[0m
\033[1;36m│\033[0m                                                            \033[1;36m│\033[0m
\033[1;36m│\033[0m   Laravel project detected                                 \033[1;36m│\033[0m
\033[1;36m│\033[0m   Enabled: \033[32mPostgreSQL\033[0m · \033[32mRedis\033[0m                              \033[1;36m│\033[0m
\033[1;36m│\033[0m                                                            \033[1;36m│\033[0m
\033[1;36m╰────────────────────────────────────────────────────────────╯\033[0m

  \033[1mFirst run\033[0m

    \033[90m1.\033[0m Authenticate AI tools
       \033[36mclaude login\033[0m
       \033[36mcodex login\033[0m

    \033[90m2.\033[0m Authenticate GitHub
       \033[36mgh auth login\033[0m

    \033[90m3.\033[0m Start working
       \033[36mai claude\033[0m
       \033[36mai codex\033[0m

    \033[90m4.\033[0m Review firewall rules
       \033[36mcat /usr/local/bin/init-firewall.sh\033[0m


  \033[1mBundled MCP servers\033[0m

    \033[32m✓\033[0m playwright        Browser automation
    \033[32m✓\033[0m context7          Fresh library docs
    \033[32m✓\033[0m chrome-devtools   Chrome DevTools Protocol
    \033[32m✓\033[0m github            Repo, PR, and issue tools


  \033[1mLaravel Boost\033[0m

    \033[36mcomposer require laravel/boost --dev\033[0m
    \033[36mphp artisan boost:install\033[0m


  \033[90mDisable sidecars with:\033[0m
    --no-postgres  --no-redis  --no-sidecars

BANNER
)"
