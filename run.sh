#!/usr/bin/env bash
# run.sh — start a one-shot agent runtime container against a project dir.
#
# Usage:
#   ./run.sh                       # uses $PWD as the project
#   ./run.sh /path/to/other/repo   # mounts that repo at /workspace
set -euo pipefail
IFS=$'\n\t'

# Fail fast if Docker isn't running — otherwise downstream `docker` calls block
# silently for many minutes waiting on an absent daemon socket.
if ! docker info >/dev/null 2>&1; then
    echo "[run.sh] Docker daemon not reachable. Start Docker Desktop (or your Docker engine) and retry." >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=${1:-$PWD}
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)

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

# Build only when no image exists yet — force a rebuild via `docker build`
# directly when needed.
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "[run.sh] building $IMAGE_TAG (one-time)"
    docker build -t "$IMAGE_TAG" "$SCRIPT_DIR"
fi

# Per-project container name keeps caches isolated and lets multiple
# projects coexist without clobbering each other.
PROJECT_HASH=$(printf '%s\n%s' "$PROJECT_DIR" "${EXTRA_MOUNTS:-}" | shasum | awk '{print substr($1,1,8)}')
CONTAINER_NAME="agent-${PROJECT_HASH}"

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

if [[ -f "$HOME/.gitconfig" ]]; then
    VOLS+=(-v "$HOME/.gitconfig:/home/node/.gitconfig:ro")
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
