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

cat <<'EOF'

------------------------------------------------------------
  Agent runtime ready.

  First-run checklist:
    1. Log in:   `claude login`   and   `codex login`
       (credentials persist in named volumes across rebuilds.)
    2. GitHub:   `gh auth login`  to enable PR/issue tooling.
    3. Try:      `ai claude`  or  `ai codex`
    4. Review the firewall: `cat /usr/local/bin/init-firewall.sh`
------------------------------------------------------------
EOF
