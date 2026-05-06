#!/usr/bin/env bash
# install-host-alias.sh — add a host-side `agent` alias that runs run.sh
# from anywhere. Idempotent: re-running won't duplicate the block.
set -euo pipefail
IFS=$'\n\t'

ALIAS_NAME=${ALIAS_NAME:-agent}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUN_SH="$SCRIPT_DIR/run.sh"
MARKER="# >>> docker-agent-runtime alias >>>"
END_MARKER="# <<< docker-agent-runtime alias <<<"

if [[ ! -x "$RUN_SH" ]]; then
    echo "[install] $RUN_SH not found or not executable" >&2
    exit 1
fi

block=$(cat <<EOF
$MARKER
# Auto-installed by docker-agent-runtime/scripts/install-host-alias.sh.
# '$ALIAS_NAME' launches the agent runtime against the current directory
# (or a given path), forwarding any --with-postgres / --no-sidecars / etc.
alias $ALIAS_NAME='$RUN_SH'
$END_MARKER
EOF
)

install_into() {
    local rc=$1
    [[ ! -f "$rc" ]] && return 0
    if grep -qF "$MARKER" "$rc"; then
        # Replace the existing block in-place so a moved repo path is picked up.
        local tmp
        tmp=$(mktemp)
        awk -v start="$MARKER" -v end="$END_MARKER" '
            $0 == start {skip=1; next}
            $0 == end   {skip=0; next}
            !skip {print}
        ' "$rc" > "$tmp"
        printf '\n%s\n' "$block" >> "$tmp"
        mv "$tmp" "$rc"
        echo "[install] refreshed alias block in $rc"
    else
        printf '\n%s\n' "$block" >> "$rc"
        echo "[install] appended alias block to $rc"
    fi
}

installed=0
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [[ -f "$rc" ]]; then
        install_into "$rc"
        installed=1
    fi
done

if [[ "$installed" == "0" ]]; then
    echo "[install] no shell rc found; copy this line into your shell config:" >&2
    printf '\nalias %s=%q\n\n' "$ALIAS_NAME" "$RUN_SH" >&2
    exit 1
fi

echo
echo "Done. Open a new shell (or run: source ~/.zshrc) then try:"
echo "  $ALIAS_NAME --help        # not yet implemented; defaults to current dir"
echo "  $ALIAS_NAME ~/some/repo   # mount that repo"
