#!/usr/bin/env bash
# agent-export.sh — push container Claude session writes back to a host
# bind-mount so they survive container destroy / `docker volume rm`.
#
# Source this script (bash or zsh) to expose the agent_export_sessions()
# function. The companion zsh hooks live in agent-prompt.zsh; the manual
# user-facing command lives at /usr/local/bin/agent-export.
#
# Mount layout (set up by run.sh when --resume / --export is on):
#   /host-claude-export      → host's $HOME/.claude-runtime-export/projects (rw)
#   RESUME_HOST_PROJECT_PATH  set in env, used to derive the host-side dir name
#
# The export dir is a *separate* tree from the host's real ~/.claude — the
# import path stays read-only so an agent inside the container can never
# corrupt the user's Claude history. Sync into the host's real dir is a
# manual user choice.

# Throttle: skip if we synced within this many seconds. zsh's precmd fires
# after every command line; for a session with many quick prompts we don't
# want to rsync on every keystroke return. 30s gives roughly one sync per
# Claude turn and only adds a noticeable cost when the JSONL has actually
# grown.
: ${AGENT_EXPORT_THROTTLE:=30}

agent_export_sessions() {
    local force=${1:-0}

    # Bail silently if export isn't enabled (no mount, no key set).
    [[ -d /host-claude-export ]] || return 0
    [[ -n "${RESUME_HOST_PROJECT_PATH:-}" ]] || return 0

    local now last
    now=$(date +%s)
    last=${AGENT_LAST_EXPORT:-0}
    if (( force == 0 )) && (( now - last < AGENT_EXPORT_THROTTLE )); then
        return 0
    fi
    AGENT_LAST_EXPORT=$now

    local host_key="${RESUME_HOST_PROJECT_PATH//\//-}"
    local src=$HOME/.claude/projects/-workspace
    local dst=/host-claude-export/$host_key

    [[ -d "$src" ]] || return 0
    mkdir -p "$dst" 2>/dev/null || return 0

    # rsync with --inplace so JSONL appends update incrementally (claude
    # appends each turn). No --delete: we never want host-export to lose
    # data if the container's local copy is somehow shorter (e.g. partial
    # transient state during a fresh import).
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --inplace "$src/" "$dst/" 2>/dev/null
    else
        # Fallback for environments without rsync. cp -u updates only when
        # source mtime is newer; skips files already current.
        cp -ru "$src/." "$dst/" 2>/dev/null
    fi
}
