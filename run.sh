#!/usr/bin/env bash
# run.sh — start a one-shot agent runtime container against a project dir.
#
# Usage:
#   ./run.sh                                    # uses $PWD as the project
#   ./run.sh /path/to/other/repo                # mounts that repo at /workspace
#   ./run.sh --with-postgres [/path/to/repo]    # also start a postgres sidecar
#                                               # reachable at postgres:5432
#                                               # creds: laravel/laravel/laravel
#
# Env knobs:
#   EXTRA_MOUNTS=...        Extra bind mounts (comma-separated)
#   AUTO_WORKTREE_MOUNT=0   Disable auto-mount of a worktree's parent repo
#   WITH_POSTGRES=1         Same as --with-postgres
#   WITH_REDIS=1            Also start a redis sidecar at redis:6379
#   RESUME_HOST=1           Same as --resume — import host Claude/Codex sessions
set -euo pipefail
IFS=$'\n\t'

usage() {
    cat <<'EOF'
Usage: agent [OPTIONS] [PROJECT_PATH]

Launch a sandboxed Docker runtime that mounts PROJECT_PATH (default: $PWD)
at /workspace and drops you into zsh with Claude Code + Codex CLI ready.

Options:
  --with-postgres       Start postgres on 127.0.0.1:5432 (auto-on for Laravel)
  --with-redis          Start redis on 127.0.0.1:6379 (auto-on for Laravel)
  --with-laravel        Both postgres and redis
  --no-postgres         Force postgres off
  --no-redis            Force redis off
  --no-sidecars         Force both off
  --resume              Import host Claude/Codex sessions for the project
                        AND mirror in-container session writes back to
                        ~/.claude-runtime-export/projects/ on the host so
                        conversations survive container destroy/rebuild.
                        Host's real ~/.claude tree stays read-only.
  --no-export           Disable the export half of --resume (import only).
  -h, --help            Show this help and exit

Env knobs (override the flags above):
  EXTRA_MOUNTS=path[,path...]   Extra bind mounts (same path host→container,
                                or host:container[:ro] explicit)
  AUTO_WORKTREE_MOUNT=0         Disable git-worktree parent-repo auto-mount
  RESUME_HOST=1                 Same as --resume

Examples:
  agent                                  # mount $PWD
  agent ~/projects/myrepo                # mount that path
  agent --resume ~/projects/laravel      # also import host sessions
  agent --no-sidecars ~/projects/foo     # bare runtime, no DB

Inside the container, run `ai help` for Claude/Codex launchers.
EOF
}

# Argument parsing — pull recognised flags out before treating remaining args
# as a project path. Sidecars default to "auto" and get enabled below if the
# project looks like a Laravel app. Explicit flags override the auto-detect.
WITH_POSTGRES=${WITH_POSTGRES:-auto}
WITH_REDIS=${WITH_REDIS:-auto}
RESUME_HOST=${RESUME_HOST:-0}
# Export defaults to "paired" — auto-on whenever --resume is on. --no-export
# splits the pair so you can import without writing back to the host.
EXPORT_HOST=${EXPORT_HOST:-auto}
_args=()
for arg in "$@"; do
    case "$arg" in
        --with-postgres) WITH_POSTGRES=1 ;;
        --with-redis)    WITH_REDIS=1 ;;
        --with-laravel)  WITH_POSTGRES=1; WITH_REDIS=1 ;;
        --no-postgres)   WITH_POSTGRES=0 ;;
        --no-redis)      WITH_REDIS=0 ;;
        --no-sidecars)   WITH_POSTGRES=0; WITH_REDIS=0 ;;
        --resume)        RESUME_HOST=1 ;;
        --no-export)     EXPORT_HOST=0 ;;
        -h|--help)       usage; exit 0 ;;
        *) _args+=("$arg") ;;
    esac
done
set -- "${_args[@]:-}"

# Fail fast if Docker isn't running — otherwise downstream `docker` calls block
# silently for many minutes waiting on an absent daemon socket.
if ! docker info >/dev/null 2>&1; then
    echo "[run.sh] Docker daemon not reachable. Start Docker Desktop (or your Docker engine) and retry." >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${1:-${PWD}}
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)

# Auto-detect Laravel: presence of artisan + composer.json with
# laravel/framework is the canonical signal. If it looks like Laravel,
# enable postgres + redis sidecars by default; explicit --no-* still wins.
is_laravel_project() {
    [[ -f "$PROJECT_DIR/artisan" ]] || return 1
    if [[ -f "$PROJECT_DIR/composer.json" ]]; then
        grep -q '"laravel/framework"' "$PROJECT_DIR/composer.json" && return 0
    fi
    return 1
}
LARAVEL_DETECTED=0
if is_laravel_project; then
    LARAVEL_DETECTED=1
    [[ "$WITH_POSTGRES" == "auto" ]] && WITH_POSTGRES=1
    [[ "$WITH_REDIS"    == "auto" ]] && WITH_REDIS=1
fi
[[ "$WITH_POSTGRES" == "auto" ]] && WITH_POSTGRES=0
[[ "$WITH_REDIS"    == "auto" ]] && WITH_REDIS=0

# Auto-detect git worktrees: if PROJECT_DIR/.git is a *file* of the form
# `gitdir: /abs/path/to/main/.git/worktrees/<name>`, the parent repo lives at
# `/abs/path/to/main` and must be mounted at the same absolute path inside the
# container or git resolution breaks. Append it to EXTRA_MOUNTS automatically.
# Set AUTO_WORKTREE_MOUNT=0 to disable.
if [[ "${AUTO_WORKTREE_MOUNT:-1}" == "1" ]] && [[ -f "$PROJECT_DIR/.git" ]]; then
    _gitdir=$(awk '/^gitdir:/ {print $2}' "$PROJECT_DIR/.git" || true)
    if [[ -n "$_gitdir" && "$_gitdir" == */.git/worktrees/* ]]; then
        _main_repo=${_gitdir%/.git/worktrees/*}
        if [[ -d "$_main_repo" ]]; then
            echo "[run.sh] worktree detected; auto-mounting parent repo: $_main_repo" >&2
            if [[ -n "${EXTRA_MOUNTS:-}" ]]; then
                EXTRA_MOUNTS="$EXTRA_MOUNTS,$_main_repo"
            else
                EXTRA_MOUNTS="$_main_repo"
            fi
        else
            echo "[run.sh] warn: worktree references missing main repo: $_main_repo" >&2
        fi
    fi
fi

IMAGE_TAG="agent-runtime:latest"
GHCR_IMAGE="ghcr.io/timniemeier/agent-runtime:latest"

# When the local image is missing, try pulling from GHCR first — a published
# release shaves first-launch time from ~3 min build to ~30 sec download. Tag
# the pulled image as agent-runtime:latest so downstream code (compose,
# devcontainer, this script's run command) keeps using the same name. Force a
# rebuild by deleting the local tag and re-running, or by `docker build`ing
# directly. AGENT_FORCE_BUILD=1 skips the pull and builds locally — useful for
# testing Dockerfile changes against an unreleased commit.
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    if [[ "${AGENT_FORCE_BUILD:-0}" != "1" ]] && docker pull "$GHCR_IMAGE" 2>/dev/null; then
        echo "[run.sh] pulled $GHCR_IMAGE → tagging as $IMAGE_TAG"
        docker tag "$GHCR_IMAGE" "$IMAGE_TAG"
    else
        echo "[run.sh] no published image found (or AGENT_FORCE_BUILD=1) — building $IMAGE_TAG locally (one-time)"
        docker build -t "$IMAGE_TAG" "$SCRIPT_DIR"
    fi
fi

# Per-project container name keeps caches isolated and lets multiple
# projects coexist without clobbering each other. Sidecar flags are
# included in the hash so toggling --with-postgres allocates a new
# container instead of trying to graft a network onto an existing one.
PROJECT_HASH=$(printf '%s\n%s\n%s\n%s' \
    "$PROJECT_DIR" "${EXTRA_MOUNTS:-}" "$WITH_POSTGRES" "$WITH_REDIS" \
    | shasum | awk '{print substr($1,1,8)}')
CONTAINER_NAME="agent-${PROJECT_HASH}"

# --- Postgres + Redis: in-container on 127.0.0.1 ------------------------------
# Earlier we started sidecar containers on a custom bridge network. That fell
# over because Docker Desktop's embedded DNS for user-defined bridges flakes
# on macOS, so service-name resolution (postgres → IP) intermittently failed.
# CI configs typically expect 127.0.0.1 anyway, so we now start postgres and
# redis as services *inside* the agent container at loopback. start-services.sh
# (invoked from post-start.sh) does the actual bring-up. Here we just toggle
# the env vars and mount a per-project postgres data volume so DB state
# persists across container restarts.
PG_VOL=""
if [[ "$WITH_POSTGRES" == "1" ]]; then
    # Renamed from agent-postgres-* (prior sidecar era used postgres:16-alpine
    # volumes that the in-container debian postgres can't read). Old volumes
    # can be `docker volume rm`'d manually.
    PG_VOL="agent-pgdata-${PROJECT_HASH}"
fi

CAPS=(
    --cap-add=NET_ADMIN
    --cap-add=NET_RAW
    --cap-add=SYS_ADMIN
    --cap-add=SYS_CHROOT
    --cap-add=SETUID
    --cap-add=SETGID
    --cap-add=SYS_PTRACE
    --security-opt=seccomp=unconfined
    --security-opt=apparmor=unconfined
)

# Public DNS resolvers. Docker Desktop's macOS host-side resolver
# (192.168.65.7) is unreliable and frequently times out; pinning to
# Cloudflare + Google sidesteps that and gives the firewall a stable
# DNS target to allow.
DNS_FLAGS=(--dns 1.1.1.1 --dns 8.8.8.8)

LIMITS=(--memory=8g --pids-limit=4096 --cpus=4)

ENVS=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ENVS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
fi
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    ENVS+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
fi
ENVS+=(-e "TZ=Europe/Berlin")

# Inform the in-container welcome banner of the actual project shape so
# it doesn't lie about Laravel detection or which services are running.
ENVS+=(
    -e "AGENT_LARAVEL_DETECTED=$LARAVEL_DETECTED"
    -e "AGENT_WITH_POSTGRES=$WITH_POSTGRES"
    -e "AGENT_WITH_REDIS=$WITH_REDIS"
)

# Tell start-services.sh which services to skip via the same flags users
# already understand. Default is "start them all".
if [[ "$WITH_POSTGRES" == "0" ]]; then
    ENVS+=(-e "NO_POSTGRES=1")
fi
if [[ "$WITH_REDIS" == "0" ]]; then
    ENVS+=(-e "NO_REDIS=1")
fi

# Standard libpq + Laravel + Redis env vars so PHP / artisan / phpunit / psql
# / cache code find the in-container services on loopback without any
# further configuration. Anything already set by the user wins via runtime
# `export` inside the shell.
if [[ "$WITH_POSTGRES" == "1" ]]; then
    ENVS+=(
        -e "PGHOST=127.0.0.1"
        -e "PGPORT=5432"
        -e "PGUSER=laravel"
        -e "PGPASSWORD=laravel"
        -e "PGDATABASE=laravel"
        -e "DB_CONNECTION=pgsql"
        -e "DB_HOST=127.0.0.1"
        -e "DB_PORT=5432"
        -e "DB_DATABASE=laravel"
        -e "DB_USERNAME=laravel"
        -e "DB_PASSWORD=laravel"
    )
fi
if [[ "$WITH_REDIS" == "1" ]]; then
    ENVS+=(
        -e "REDIS_HOST=127.0.0.1"
        -e "REDIS_PORT=6379"
    )
fi

# Forward the host SSH agent if present so git operations over ssh work
# without copying private keys into the container.
SSH_MOUNT=()
if [[ -n "${SSH_AUTH_SOCK:-}" ]] && [[ -S "$SSH_AUTH_SOCK" ]]; then
    SSH_MOUNT+=(-v "$SSH_AUTH_SOCK:/ssh-agent" -e "SSH_AUTH_SOCK=/ssh-agent")
fi

VOLS=(
    -v "$PROJECT_DIR:/workspace"
    -v "agent-claude:/home/node/.claude"
    -v "agent-codex:/home/node/.codex"
    -v "agent-gh:/home/node/.config/gh"
    -v "agent-history:/commandhistory"
    -v "agent-npm:/home/node/.npm"
    -v "agent-composer:/home/node/.composer"
    -v "agent-pip:/home/node/.cache/pip"
    -v "agent-playwright:/home/node/.cache/ms-playwright"
)

if [[ -n "$PG_VOL" ]]; then
    VOLS+=(-v "$PG_VOL:/var/lib/postgresql/data")
fi

if [[ -f "$HOME/.gitconfig" ]]; then
    VOLS+=(-v "$HOME/.gitconfig:/home/node/.gitconfig:ro")
fi

# Resolve EXPORT_HOST=auto → on when --resume is on, off otherwise.
[[ "$EXPORT_HOST" == "auto" ]] && EXPORT_HOST=$RESUME_HOST

# --resume: forward the host's Claude / Codex session stores (read-only) so
# post-create.sh can copy the matching project's transcripts into the
# container's session dirs.
#
# Pairing: --resume also enables export-on-write (unless --no-export). The
# export tree lives at $HOME/.claude-runtime-export/projects (a separate
# location from the user's real ~/.claude/projects, which stays untouched).
# A zsh precmd hook + zshexit + manual `agent-export` keep it in sync, so
# in-container conversations survive container destroy / `docker volume rm
# agent-claude` and can be re-imported by the next --resume launch.
if [[ "$RESUME_HOST" == "1" ]]; then
    if [[ -d "$HOME/.claude/projects" ]]; then
        VOLS+=(-v "$HOME/.claude/projects:/host-claude-projects:ro")
    fi
    if [[ -d "$HOME/.codex/sessions" ]]; then
        VOLS+=(-v "$HOME/.codex/sessions:/host-codex-sessions:ro")
    fi
    ENVS+=(
        -e "RESUME_HOST=1"
        -e "RESUME_HOST_PROJECT_PATH=$PROJECT_DIR"
    )
    echo "[run.sh] --resume on: importing host Claude/Codex sessions for $PROJECT_DIR" >&2
fi

if [[ "$EXPORT_HOST" == "1" ]]; then
    EXPORT_DIR="$HOME/.claude-runtime-export/projects"
    mkdir -p "$EXPORT_DIR"
    VOLS+=(-v "$EXPORT_DIR:/host-claude-export:rw")
    # RESUME_HOST_PROJECT_PATH may already be set by --resume above; export
    # needs it too (to derive the host-side dir name). Set defensively in
    # case --no-export-paired-with-resume edge cases come up later.
    ENVS+=(
        -e "EXPORT_HOST=1"
        -e "RESUME_HOST_PROJECT_PATH=$PROJECT_DIR"
    )
    echo "[run.sh] --export on: container session writes mirror to $EXPORT_DIR/" >&2
fi

# Optional extra bind mounts for cases like git worktrees, where the project
# directory references absolute paths outside /workspace (e.g. the parent
# repo's .git dir). Format: comma-separated list, each entry either
#   /host/path                       -> mount at same path inside container, rw
#   /host/path:/container/path       -> custom container path
#   /host/path:/container/path:ro    -> read-only
if [[ -n "${EXTRA_MOUNTS:-}" ]]; then
    IFS=',' read -ra _extra <<< "$EXTRA_MOUNTS"
    for entry in "${_extra[@]}"; do
        entry=${entry# }; entry=${entry% }
        [[ -z "$entry" ]] && continue
        if [[ "$entry" == *:* ]]; then
            VOLS+=(-v "$entry")
        else
            VOLS+=(-v "$entry:$entry")
        fi
    done
    IFS=$'\n\t'
fi

# Reuse the container if it already exists, otherwise launch a fresh one.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker start "$CONTAINER_NAME" >/dev/null
    # iptables/ipset rules are wiped on container stop and don't survive a
    # restart — re-run init-firewall.sh as root before handing the user a
    # shell, otherwise the reused container has no egress allowlist at all.
    docker exec --user root "$CONTAINER_NAME" /usr/local/bin/init-firewall.sh
    exec docker exec -it "$CONTAINER_NAME" zsh
fi

exec docker run -it --rm \
    --name "$CONTAINER_NAME" \
    --hostname agent-runtime \
    --init \
    "${CAPS[@]}" \
    "${DNS_FLAGS[@]}" \
    "${LIMITS[@]}" \
    "${ENVS[@]}" \
    "${SSH_MOUNT[@]}" \
    "${VOLS[@]}" \
    -w /workspace \
    "$IMAGE_TAG" \
    zsh
