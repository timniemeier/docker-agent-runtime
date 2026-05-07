#!/usr/bin/env bash
# host-worktree-prompt.sh — host-side bootstrap prompt for run.sh.
#
# Sourced by run.sh when invoked with no PROJECT_PATH from inside a git
# repo. Asks the user whether to spin up a fresh worktree for an issue,
# then creates the branch (if missing) and the worktree under
# ./.worktrees/<branch>, exporting PROJECT_DIR so the rest of run.sh
# mounts the new worktree at /workspace.
#
# Pure host-side. Targets bash 3.2 (macOS default) — no mapfile, no
# associative arrays, no ${var,,}.

# Try `gh issue view <NUM>` and echo the title. Returns non-zero on any
# failure (gh missing, not authed, issue not found, network error).
_gh_issue_title() {
    local num="$1"
    command -v gh >/dev/null 2>&1 || return 1
    gh issue view "$num" --json title -q .title 2>/dev/null
}

# Slugify stdin → stdout. Lowercase, non-alnum runs collapse to '-',
# trim leading/trailing '-'.
_slugify() {
    tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

_branch_exists() {
    git show-ref --verify --quiet "refs/heads/$1"
}

# Echo the repo's default branch (e.g. main / master). Falls back to
# 'main' if origin/HEAD isn't configured.
_default_branch() {
    local ref
    ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
    if [[ -n "$ref" ]]; then
        # ref is "origin/main" — strip the remote prefix
        echo "${ref#origin/}"
        return
    fi
    # Fallback: pick whichever of main/master exists, else current HEAD.
    if _branch_exists main; then echo main; return; fi
    if _branch_exists master; then echo master; return; fi
    git rev-parse --abbrev-ref HEAD
}

# Read a non-empty value from the user (host TTY). Args: prompt, varname,
# optional default. The result is assigned to varname in the caller's scope.
_prompt() {
    local msg="$1" varname="$2" default="${3:-}"
    local input
    if [[ -n "$default" ]]; then
        read -r -p "  $msg [$default]: " input </dev/tty
        input="${input:-$default}"
    else
        while :; do
            read -r -p "  $msg: " input </dev/tty
            [[ -n "$input" ]] && break
        done
    fi
    printf -v "$varname" '%s' "$input"
}

# Bash select over branches + custom + new-from-default. Echoes the
# resolved base branch name (must already exist by the time we return).
_pick_base_branch() {
    local default_branch="$1"
    local branches=()
    local b
    while IFS= read -r b; do
        [[ -n "$b" ]] && branches+=("$b")
    done < <(git branch --format='%(refname:short)')

    echo "  Pick base branch (default: $default_branch):" >&2
    local opt picked=""
    PS3="  > "
    select opt in "${branches[@]}" "<type a custom name>" "<use default: $default_branch>"; do
        case "$opt" in
            "")
                continue
                ;;
            "<type a custom name>")
                local custom
                _prompt "Base branch name" custom
                if _branch_exists "$custom"; then
                    picked="$custom"
                else
                    echo "  branch '$custom' doesn't exist locally — will be created from $default_branch" >&2
                    git branch "$custom" "$default_branch" >&2
                    picked="$custom"
                fi
                break
                ;;
            "<use default: $default_branch>")
                picked="$default_branch"
                break
                ;;
            *)
                picked="$opt"
                break
                ;;
        esac
    done </dev/tty
    echo "$picked"
}

# Main entry. Mutates PROJECT_DIR in caller scope iff the user opts in.
maybe_prompt_worktree() {
    # Skip silently when not inside a git work tree.
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    # Need a TTY to prompt. Non-interactive callers (CI, pipes) get the
    # fall-through behaviour for free.
    [[ -t 0 ]] || return 0

    local repo_root
    repo_root=$(git rev-parse --show-toplevel)

    local ans
    read -r -p "  Create a new worktree for an issue? [y/N]: " ans </dev/tty || return 0
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    case "$ans" in
        y|yes) ;;
        *) return 0 ;;
    esac

    local issue_num
    while :; do
        _prompt "Issue #" issue_num
        [[ "$issue_num" =~ ^[0-9]+$ ]] && break
        echo "  not a number — try again" >&2
    done

    # Branch name — try gh, fall back to manual.
    local title slug branch
    if title=$(_gh_issue_title "$issue_num") && [[ -n "$title" ]]; then
        slug=$(printf '%s' "$title" | _slugify)
        branch="${issue_num}-${slug}"
        echo "  gh: '$title' → branch '$branch'" >&2
        local override
        _prompt "Branch name" override "$branch"
        branch="$override"
    else
        echo "  gh issue lookup failed (not installed / not authed / no such issue)" >&2
        _prompt "Branch name" branch "issue-${issue_num}"
    fi

    local default_branch
    default_branch=$(_default_branch)

    # Decide base branch only if the target branch doesn't already exist.
    # If it does exist, base is irrelevant — we just attach a worktree to it.
    local base=""
    if ! _branch_exists "$branch"; then
        base=$(_pick_base_branch "$default_branch")
        if ! _branch_exists "$base"; then
            echo "  base branch '$base' still missing — aborting" >&2
            return 1
        fi
    else
        echo "  branch '$branch' already exists — re-using it for the worktree" >&2
    fi

    local wt_dir="$repo_root/.worktrees/$branch"
    if [[ -e "$wt_dir" ]]; then
        echo "  worktree path already exists: $wt_dir" >&2
        echo "  remove it first or pick a different branch — aborting" >&2
        return 1
    fi

    mkdir -p "$repo_root/.worktrees"

    if _branch_exists "$branch"; then
        git -C "$repo_root" worktree add "$wt_dir" "$branch"
    else
        git -C "$repo_root" worktree add -b "$branch" "$wt_dir" "$base"
    fi

    # Suggest .gitignore hygiene without auto-editing the user's repo.
    if [[ -f "$repo_root/.gitignore" ]] \
        && ! grep -qE '^\.worktrees(/|$)' "$repo_root/.gitignore"; then
        echo "  hint: add '.worktrees/' to $repo_root/.gitignore to keep it untracked" >&2
    fi

    PROJECT_DIR="$wt_dir"
    export PROJECT_DIR
    echo "[run.sh] worktree ready → $wt_dir (branch: $branch)" >&2
}
