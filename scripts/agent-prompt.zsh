# agent-prompt.zsh — visual marker that this shell is inside the Agent
# Runtime container. Sourced from .zshrc by zsh-in-docker's -a hook.
#
# Three layered cues so it's hard to miss regardless of which terminal
# emulator is in use:
#
#   1. Powerlevel10k segment: red "🐳 RUNTIME" prefix on the left
#      prompt. Always visible at the start of each command line.
#   2. Window / tab title: "🐳 Agent Runtime — <cwd>". iTerm2,
#      Terminal.app, VS Code, Warp all surface this.
#   3. iTerm2 badge: large faint "AGENT RUNTIME" text overlaid in the
#      corner of the pane. iTerm-only; harmless in other terminals.

# 1. Custom p10k segment — only defined when p10k is loaded.
if (( ${+functions[p10k]} )); then
    function prompt_runtime_marker() {
        p10k segment -f black -B red -t '🐳 RUNTIME'
    }
    # Prepend to the left-prompt elements array, idempotently.
    if [[ -z "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[(r)runtime_marker]}" ]]; then
        typeset -ga POWERLEVEL9K_LEFT_PROMPT_ELEMENTS
        POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(runtime_marker $POWERLEVEL9K_LEFT_PROMPT_ELEMENTS)
    fi
fi

# 2. Window/tab title — refresh on every prompt so cd is reflected.
function _runtime_set_title() {
    print -Pn "\e]0;🐳 Agent Runtime — %~\a"
}

# 3. iTerm2 badge. Skipped silently if not iTerm2 (other terminals just
#    treat the OSC 1337 sequence as no-op).
function _runtime_set_badge() {
    local badge_b64
    badge_b64=$(printf '%s' "AGENT RUNTIME" | base64 | tr -d '\n')
    print -Pn "\e]1337;SetBadgeFormat=$badge_b64\a"
}

# Hook into precmd. Idempotent: precmd_functions is a uniqued array.
typeset -ga precmd_functions
precmd_functions+=(_runtime_set_title)
precmd_functions+=(_runtime_set_badge)

# 4. Session export. When run.sh launched with --resume / --export, the
#    host's session-export dir is bind-mounted at /host-claude-export.
#    Mirror the container's writable session dir back there on every
#    prompt (throttled, see agent-export.sh) so a container destroy or
#    `docker volume rm agent-claude` doesn't lose in-flight conversations.
if [[ -f /usr/local/lib/agent-export.sh ]]; then
    source /usr/local/lib/agent-export.sh
    precmd_functions+=(agent_export_sessions)
    typeset -ga zshexit_functions
    # Force a final sync on shell exit (force=1 bypasses the 30s throttle).
    function _agent_export_on_exit() { agent_export_sessions 1; }
    zshexit_functions+=(_agent_export_on_exit)
fi
