#!/usr/bin/env bash
# host-worktree-prompt.sh — host-side bootstrap prompt for run.sh.
#
# Sourced by run.sh when invoked with no PROJECT_PATH from inside a git
# repo. Asks the user whether to open an existing worktree first. If not, asks
# whether to spin up a fresh worktree, then either checks out an existing remote
# branch or creates a branch for an issue under ./.worktrees/<branch>, exporting
# PROJECT_DIR so the rest of run.sh mounts the selected worktree at /workspace.
#
# Pure host-side. Targets bash 3.2 (macOS default) — no mapfile, no
# associative arrays, no ${var,,}.

# Slugify stdin → stdout. Lowercase, non-alnum runs collapse to '-',
# trim leading/trailing '-'.
_slugify() {
    tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

_branch_exists() {
    git show-ref --verify --quiet "refs/heads/$1"
}

_remote_branch_exists() {
    git show-ref --verify --quiet "refs/remotes/origin/$1"
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

_remote_branches() {
    git ls-remote --heads origin 2>/dev/null \
        | sed -E 's#^[[:xdigit:]]+[[:space:]]+refs/heads/##' \
        | LC_ALL=C sort
}

_existing_worktrees() {
    local path="" branch="" detached=0 bare=0 line

    _emit_worktree() {
        local label state
        [[ -n "$path" ]] || return 0
        if [[ "$bare" == "1" ]]; then
            state="bare"
        elif [[ "$detached" == "1" ]]; then
            state="detached"
        elif [[ -n "$branch" ]]; then
            state="$branch"
        else
            state="unknown"
        fi
        label="$path ($state)"
        printf '%s\t%s\n' "$path" "$label"
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            _emit_worktree
            path=""
            branch=""
            detached=0
            bare=0
            continue
        fi

        case "$line" in
            worktree\ *) path="${line#worktree }" ;;
            branch\ refs/heads/*) branch="${line#branch refs/heads/}" ;;
            branch\ *) branch="${line#branch }" ;;
            detached) detached=1 ;;
            bare) bare=1 ;;
        esac
    done < <(git worktree list --porcelain)
    _emit_worktree
}

_open_issues() {
    command -v gh >/dev/null 2>&1 || return 1
    gh issue list --state open --limit 1000 --json number,title \
        --jq '.[] | [.number, .title] | @tsv' 2>/dev/null
}

_clear_menu() {
    local lines="$1"
    while [[ "$lines" -gt 0 ]]; do
        printf '\033[1A\r\033[2K' >/dev/tty
        lines=$((lines - 1))
    done
}

_tty_cols() {
    local _rows cols
    if read -r _rows cols < <(stty size </dev/tty 2>/dev/null) && [[ -n "$cols" ]]; then
        echo "$cols"
    else
        echo 80
    fi
}

_fit_menu_label() {
    local label="$1" cols="$2"
    local max_width=$((cols - 6))

    [[ "$max_width" -lt 10 ]] && max_width=10
    if [[ "${#label}" -gt "$max_width" ]]; then
        printf '%.*s...' $((max_width - 3)) "$label"
    else
        printf '%s' "$label"
    fi
}

# Arrow-key selector for host TTYs. Args: prompt, result-index-var, options...
_select_index() {
    local prompt="$1" result_var="$2"
    shift 2

    local options=("$@")
    local total="${#options[@]}"
    local selected=0 drawn=0 old_stty=""
    local height="${WORKTREE_PROMPT_MENU_HEIGHT:-15}"
    local cols start end row label display_label key second third

    [[ "$total" -gt 0 ]] || return 1
    [[ "$height" =~ ^[0-9]+$ ]] || height=15
    [[ "$height" -lt 3 ]] && height=3
    [[ "$height" -gt "$total" ]] && height="$total"

    old_stty=$(stty -g </dev/tty) || return 1
    stty -echo -icanon min 1 time 0 </dev/tty || return 1
    printf '\033[?25l' >/dev/tty

    while :; do
        [[ "$drawn" -gt 0 ]] && _clear_menu "$drawn"
        cols=$(_tty_cols)

        start=$((selected - height / 2))
        [[ "$start" -lt 0 ]] && start=0
        if [[ $((start + height)) -gt "$total" ]]; then
            start=$((total - height))
        fi
        [[ "$start" -lt 0 ]] && start=0
        end=$((start + height - 1))
        [[ "$end" -ge "$total" ]] && end=$((total - 1))

        printf '  %s\n' "$prompt" >/dev/tty
        drawn=1

        if [[ "$start" -gt 0 ]]; then
            printf '    ... %s more above\n' "$start" >/dev/tty
            drawn=$((drawn + 1))
        fi

        row="$start"
        while [[ "$row" -le "$end" ]]; do
            label="${options[$row]}"
            display_label=$(_fit_menu_label "$label" "$cols")
            if [[ "$row" -eq "$selected" ]]; then
                printf '  \033[7m> %s\033[0m\n' "$display_label" >/dev/tty
            else
                printf '    %s\n' "$display_label" >/dev/tty
            fi
            drawn=$((drawn + 1))
            row=$((row + 1))
        done

        if [[ "$end" -lt $((total - 1)) ]]; then
            printf '    ... %s more below\n' $((total - end - 1)) >/dev/tty
            drawn=$((drawn + 1))
        fi

        IFS= read -r -s -n 1 key </dev/tty || {
            stty "$old_stty" </dev/tty
            printf '\033[?25h' >/dev/tty
            return 1
        }
        case "$key" in
            ""|$'\r'|$'\n')
                _clear_menu "$drawn"
                stty "$old_stty" </dev/tty
                printf '\033[?25h' >/dev/tty
                printf -v "$result_var" '%s' "$selected"
                return 0
                ;;
            $'\003')
                _clear_menu "$drawn"
                stty "$old_stty" </dev/tty
                printf '\033[?25h' >/dev/tty
                return 130
                ;;
            $'\033')
                second=""
                third=""
                stty -echo -icanon min 0 time 2 </dev/tty
                IFS= read -r -s -n 1 second </dev/tty || true
                IFS= read -r -s -n 1 third </dev/tty || true
                stty -echo -icanon min 1 time 0 </dev/tty
                case "$second$third" in
                    "[A"|"OA") selected=$((selected - 1)) ;;
                    "[B"|"OB") selected=$((selected + 1)) ;;
                esac
                ;;
            k)
                selected=$((selected - 1))
                ;;
            j)
                selected=$((selected + 1))
                ;;
        esac

        [[ "$selected" -lt 0 ]] && selected=$((total - 1))
        [[ "$selected" -ge "$total" ]] && selected=0
    done
}

_pick_branch_action() {
    local result_var="$1"
    local options=("[create new branch]")
    local branch idx

    while IFS= read -r branch; do
        [[ -n "$branch" ]] && options+=("$branch")
    done < <(_remote_branches)

    if [[ "${#options[@]}" -eq 1 ]]; then
        echo "  no remote branches found on origin — aborting worktree creation" >&2
        return 1
    fi

    _select_index "Select branch for the new worktree:" idx "${options[@]}" || return 1
    printf -v "$result_var" '%s' "${options[$idx]}"
}

_pick_existing_worktree() {
    local result_var="$1"
    local paths=()
    local options=()
    local path label idx

    while IFS=$'\t' read -r path label; do
        [[ -n "$path" && -n "$label" ]] || continue
        paths+=("$path")
        options+=("$label")
    done < <(_existing_worktrees)

    if [[ "${#options[@]}" -eq 0 ]]; then
        echo "  no git worktrees found — continuing with current directory" >&2
        return 1
    fi

    _select_index "Select existing worktree for the container:" idx "${options[@]}" || return 1
    printf -v "$result_var" '%s' "${paths[$idx]}"
}

_pick_new_branch_name() {
    local result_var="$1"
    local options=("[Enter custom branch name]")
    local issue_numbers=("")
    local issue_titles=("")
    local issues num title idx slug chosen_branch

    if issues=$(_open_issues); then
        if [[ -n "$issues" ]]; then
            while IFS=$'\t' read -r num title; do
                [[ -n "$num" && -n "$title" ]] || continue
                issue_numbers+=("$num")
                issue_titles+=("$title")
                options+=("#$num $title")
            done <<< "$issues"
        fi
    else
        echo "  gh issue list failed (not installed / not authed / no remote issues)" >&2
    fi

    _select_index "Select issue for the new branch:" idx "${options[@]}" || return 1
    if [[ "$idx" -eq 0 ]]; then
        _prompt "Branch name" chosen_branch
    else
        num="${issue_numbers[$idx]}"
        title="${issue_titles[$idx]}"
        slug=$(printf '%s' "$title" | _slugify)
        chosen_branch="${num}-${slug}"
        echo "  gh: '#$num $title' -> branch '$chosen_branch'" >&2
    fi

    printf -v "$result_var" '%s' "$chosen_branch"
}

_link_main_env_file() {
    local repo_root="$1" wt_dir="$2"

    if [[ -e "$wt_dir/.env" ]]; then
        return 0
    fi

    if [[ -f "$repo_root/.env" || -L "$repo_root/.env" ]]; then
        ln -s "$repo_root/.env" "$wt_dir/.env"
        echo "  linked .env from main worktree" >&2
        return 0
    fi

    echo "  warn: .env missing in main worktree; tests or pre-push hooks may fail until you create $wt_dir/.env" >&2
}

# Prompt after the launched container exits and optionally remove the worktree
# created/selected by maybe_prompt_worktree during this same run.sh session.
maybe_prompt_remove_launched_worktree() {
    [[ "${AGENT_LAUNCHER_WORKTREE:-0}" == "1" ]] || return 0

    # Match the launch prompt: non-interactive callers should never block.
    [[ -t 0 ]] || return 0

    local repo_root="${AGENT_WORKTREE_REPO_ROOT:-}"
    local wt_dir="${AGENT_WORKTREE_DIR:-}"
    local branch="${AGENT_WORKTREE_BRANCH:-}"

    [[ -n "$repo_root" && -n "$wt_dir" ]] || return 0
    [[ -e "$wt_dir" ]] || return 0

    local ans
    read -r -p "  Remove worktree $wt_dir${branch:+ (branch: $branch)}? [y/N]: " ans </dev/tty || return 0
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    case "$ans" in
        y|yes) ;;
        *) return 0 ;;
    esac

    local dirty=""
    dirty=$(git -C "$wt_dir" status --porcelain 2>/dev/null || true)
    if [[ -n "$dirty" ]]; then
        echo "  worktree has uncommitted or untracked changes:" >&2
        git -C "$wt_dir" status --short >&2 || true

        local force_ans
        read -r -p "  Force remove dirty worktree? This discards those changes. [y/N]: " force_ans </dev/tty || return 0
        force_ans=$(printf '%s' "$force_ans" | tr '[:upper:]' '[:lower:]')
        case "$force_ans" in
            y|yes)
                git -C "$repo_root" worktree remove --force "$wt_dir" \
                    || echo "  warn: failed to remove worktree: $wt_dir" >&2
                ;;
            *) return 0 ;;
        esac
    else
        git -C "$repo_root" worktree remove "$wt_dir" \
            || echo "  warn: failed to remove worktree: $wt_dir" >&2
    fi
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
    read -r -p "  Checkout an existing worktree for this container? [y/N]: " ans </dev/tty || return 0
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    case "$ans" in
        y|yes)
            local existing_wt_dir
            _pick_existing_worktree existing_wt_dir || return 0
            PROJECT_DIR="$existing_wt_dir"
            export PROJECT_DIR
            echo "[run.sh] using existing worktree → $existing_wt_dir" >&2
            return 0
            ;;
    esac

    read -r -p "  Create a new worktree for an issue? [y/N]: " ans </dev/tty || return 0
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    case "$ans" in
        y|yes) ;;
        *) return 0 ;;
    esac

    local action branch create_new=0
    _pick_branch_action action || return 0
    if [[ "$action" == "[create new branch]" ]]; then
        create_new=1
        _pick_new_branch_name branch || return 0
    else
        branch="$action"
    fi

    if [[ -z "$branch" ]]; then
        echo "  branch name is empty — aborting" >&2
        return 1
    fi

    local default_branch
    default_branch=$(_default_branch)

    local wt_dir="$repo_root/.worktrees/$branch"
    if [[ -e "$wt_dir" ]]; then
        echo "  worktree path already exists: $wt_dir" >&2
        echo "  remove it first or pick a different branch — aborting" >&2
        return 1
    fi

    mkdir -p "$(dirname "$wt_dir")"

    if [[ "$create_new" == "1" ]]; then
        local base="$default_branch"
        if ! _branch_exists "$default_branch"; then
            git -C "$repo_root" fetch origin "$default_branch:refs/remotes/origin/$default_branch" || return 1
            base="origin/$default_branch"
        fi
        git -C "$repo_root" worktree add -b "$branch" "$wt_dir" "$base" || return 1
    elif _branch_exists "$branch"; then
        echo "  branch '$branch' already exists locally — re-using it for the worktree" >&2
        git -C "$repo_root" worktree add "$wt_dir" "$branch" || return 1
    else
        git -C "$repo_root" fetch origin "$branch:refs/remotes/origin/$branch" || return 1
        if ! _remote_branch_exists "$branch"; then
            echo "  remote branch 'origin/$branch' missing after fetch — aborting" >&2
            return 1
        fi
        git -C "$repo_root" worktree add --track -b "$branch" "$wt_dir" "origin/$branch" || return 1
    fi
    _link_main_env_file "$repo_root" "$wt_dir"

    # Suggest .gitignore hygiene without auto-editing the user's repo.
    if [[ -f "$repo_root/.gitignore" ]] \
        && ! grep -qE '^\.worktrees(/|$)' "$repo_root/.gitignore"; then
        echo "  hint: add '.worktrees/' to $repo_root/.gitignore to keep it untracked" >&2
    fi

    PROJECT_DIR="$wt_dir"
    AGENT_LAUNCHER_WORKTREE=1
    AGENT_WORKTREE_REPO_ROOT="$repo_root"
    AGENT_WORKTREE_DIR="$wt_dir"
    AGENT_WORKTREE_BRANCH="$branch"
    export PROJECT_DIR
    echo "[run.sh] worktree ready → $wt_dir (branch: $branch)" >&2
}
