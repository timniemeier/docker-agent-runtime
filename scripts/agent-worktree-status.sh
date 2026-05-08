#!/usr/bin/env bash
# Sourceable git context line for interactive runtime shells.

agent_print_worktree_status() {
    [[ -t 1 ]] || return 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    local top git_dir branch worktree_path worktree
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || git_dir=""
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) \
        || branch="detached@$(git rev-parse --short HEAD 2>/dev/null || printf '?')"

    worktree_path="$top"
    if [[ "$top" == "/workspace" && -n "${AGENT_PROJECT_DIR:-}" ]]; then
        worktree_path="$AGENT_PROJECT_DIR"
    fi

    case "$worktree_path" in
        */.worktrees/*) worktree="${worktree_path#*/.worktrees/}" ;;
        *)
            case "$git_dir" in
                */.git/worktrees/*) worktree="${git_dir##*/}" ;;
                *) worktree="${worktree_path##*/}" ;;
            esac
            ;;
    esac

    printf '\033[2m[%s]\033[0m worktree: \033[1m%s\033[0m  branch: \033[1m%s\033[0m\n' \
        "git" "$worktree" "$branch"
}
