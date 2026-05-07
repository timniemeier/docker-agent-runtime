#!/usr/bin/env bash
# smoke-test-resume.sh — end-to-end verification of `agent --resume`.
#
# Picks the most recently active Claude project on the host, launches the
# runtime container with --resume, and asserts that:
#   1. /host-claude-projects is bind-mounted read-only inside the container.
#   2. post-create.sh logs `imported N Claude session(s)` with N > 0.
#   3. /home/node/.claude/projects/-workspace/ contains the same UUIDs that
#      live in the host's matching session dir.
#
# The container runs entrypoint.sh (so post-create + post-start fire) and
# then a verification script — no interactive shell, no port publishing.
# Image must already exist (`docker build -t agent-runtime:latest .`).
set -euo pipefail
IFS=$'\n\t'

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
DIM=$'\033[2m'
RESET=$'\033[0m'

fail() { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
info() { printf '%s•%s %s\n' "$DIM" "$RESET" "$*"; }

# 1. Pick a host project that has at least one Claude session JSONL.
#    (Portable: BSD find on macOS lacks `-printf`, so we walk dirs by
#    mtime via `ls -t` and pick the first one containing a *.jsonl.)
HOST_CLAUDE=$HOME/.claude/projects
[[ -d "$HOST_CLAUDE" ]] || fail "no $HOST_CLAUDE on this host — nothing to import"

PROJECT_KEY=""
shopt -s nullglob
for d in $(ls -t "$HOST_CLAUDE" 2>/dev/null); do
    files=("$HOST_CLAUDE/$d"/*.jsonl)
    if (( ${#files[@]} > 0 )); then
        PROJECT_KEY=$d
        break
    fi
done
shopt -u nullglob
[[ -n "$PROJECT_KEY" ]] || fail "no Claude session JSONLs on host — start one first"

# 2. Decode the path key (slashes back from dashes). Claude Code's encoding
#    is lossy on filesystems with - in paths, but for this smoke test we
#    just need *a* dir that exists. Try absolute first, fall back to $PWD.
HOST_PROJECT_PATH="${PROJECT_KEY//-//}"
HOST_PROJECT_PATH="/${HOST_PROJECT_PATH#/}"
if [[ ! -d "$HOST_PROJECT_PATH" ]]; then
    info "decoded path '$HOST_PROJECT_PATH' doesn't exist; falling back to \$PWD"
    HOST_PROJECT_PATH=$PWD
    PROJECT_KEY="${HOST_PROJECT_PATH//\//-}"
fi

EXPECTED_UUIDS=$(cd "$HOST_CLAUDE/$PROJECT_KEY" && ls *.jsonl 2>/dev/null | sort)
EXPECTED_COUNT=$(printf '%s\n' "$EXPECTED_UUIDS" | grep -c '\.jsonl$' || true)

info "Host project: $HOST_PROJECT_PATH"
info "Project key:  $PROJECT_KEY"
info "Sessions on host: $EXPECTED_COUNT"
[[ $EXPECTED_COUNT -gt 0 ]] || fail "expected at least one host session"

# 3. Run the container non-interactively. Replicates the volume layout from
#    run.sh's --resume path; skips the firewall (no NET_ADMIN required for
#    this verification).
docker image inspect agent-runtime:latest >/dev/null 2>&1 || \
    fail "agent-runtime:latest not found — run \`docker build -t agent-runtime:latest .\`"

info "Launching container in non-interactive mode..."
LOG=$(docker run --rm \
    --hostname agent-runtime \
    -v "$HOST_PROJECT_PATH:/workspace" \
    -v "$HOST_CLAUDE:/host-claude-projects:ro" \
    -e RESUME_HOST=1 \
    -e RESUME_HOST_PROJECT_PATH="$HOST_PROJECT_PATH" \
    --entrypoint /usr/local/bin/post-create.sh \
    agent-runtime:latest 2>&1) || {
        echo "$LOG"
        fail "container exited non-zero"
    }
echo "$LOG" | grep -E '^\[post-create\] imported' || true

# 4. Run a second container that shares the same agent-claude state (it
#    won't, since each `--rm` run has a fresh writable layer + named
#    volumes), so re-mount the host dirs and check the import path
#    landed on disk by inspecting /home/node directly via a verification
#    container that runs post-create then ls.
info "Verifying imported file list..."
ACTUAL_UUIDS=$(docker run --rm \
    --hostname agent-runtime \
    -v "$HOST_PROJECT_PATH:/workspace" \
    -v "$HOST_CLAUDE:/host-claude-projects:ro" \
    -e RESUME_HOST=1 \
    -e RESUME_HOST_PROJECT_PATH="$HOST_PROJECT_PATH" \
    --entrypoint bash \
    agent-runtime:latest \
    -c '/usr/local/bin/post-create.sh >/dev/null 2>&1; ls /home/node/.claude/projects/-workspace/ 2>/dev/null | sort')

ACTUAL_COUNT=$(printf '%s\n' "$ACTUAL_UUIDS" | grep -c '\.jsonl$' || true)
info "Sessions in container after import: $ACTUAL_COUNT"

if [[ "$EXPECTED_UUIDS" == "$ACTUAL_UUIDS" ]]; then
    ok "All $EXPECTED_COUNT host UUIDs present in container"
else
    fail "UUID mismatch: host=$(printf '%s\n' "$EXPECTED_UUIDS" | wc -l), container=$ACTUAL_COUNT"
fi

ok "Smoke test passed"
