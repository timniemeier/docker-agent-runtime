#!/usr/bin/env bash
# agent-update.sh — refresh the agent CLIs to the latest release on every boot.
#
# Called from post-start.sh AFTER the firewall is up, so it relies on the
# egress allowlist permitting:
#   - downloads.claude.ai   (Claude Code native self-update)
#   - registry.npmjs.org    (Codex npm package)
# Both are seeded in init-firewall.sh.
#
# Deliberately NOT `set -e`: an offline boot or a blocked egress rule must not
# abort container start — we warn and keep whatever version is already baked
# into the image. Disable the whole step with AGENT_AUTO_UPDATE=0.
set -uo pipefail
IFS=$'\n\t'

# shellcheck disable=SC1091
source /usr/local/lib/agent-output.sh

if [[ "${AGENT_AUTO_UPDATE:-1}" != "1" ]]; then
    log_info "Auto-update disabled (AGENT_AUTO_UPDATE=0) — keeping baked versions"
    exit 0
fi

log_section "Updating agent CLIs"

# run.sh mounts agent-claude / agent-npm as SHARED named volumes across every
# parallel container. A mass `docker restart` would otherwise fire N concurrent
# `claude update` / `npm -g install` runs against the same volume state. Take a
# lock on the shared .claude volume so the updates serialize: the first boot
# does the real work, the rest see the already-current version and no-op fast.
# Best-effort — if flock or the lock dir is unavailable we just proceed.
LOCK_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.agent-update.lock"
if command -v flock >/dev/null 2>&1 && { : >"$LOCK_FILE"; } 2>/dev/null; then
    exec 9>"$LOCK_FILE"
    if ! flock -w 120 9; then
        log_warn "Could not acquire update lock within 120s — skipping this boot"
        exit 0
    fi
fi

# Claude Code — native binary self-update. `claude update` pulls the latest
# release from downloads.claude.ai and swaps the launcher in ~/.local/share.
if command -v claude >/dev/null 2>&1; then
    if claude update >/dev/null 2>&1; then
        log_ok "Claude Code: $(claude --version 2>/dev/null || echo 'updated')"
    else
        log_warn "Claude Code update failed (offline or egress blocked?) — keeping current"
    fi
else
    log_warn "claude not on PATH — skipping Claude Code update"
fi

# Codex — npm global. Reinstalls @openai/codex@latest into the (node-owned)
# npm prefix. Idempotent; a no-op when already current.
if command -v npm >/dev/null 2>&1; then
    if npm install -g @openai/codex@latest >/dev/null 2>&1; then
        log_ok "Codex: $(codex --version 2>/dev/null || echo 'updated')"
    else
        log_warn "Codex update failed (offline or egress blocked?) — keeping current"
    fi
else
    log_warn "npm not on PATH — skipping Codex update"
fi
