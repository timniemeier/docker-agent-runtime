#!/usr/bin/env bash
# Container entrypoint. Seeds user config, applies the firewall, then execs
# whatever was passed (default: zsh). Compose's `command: sleep infinity`
# bypasses this; the firewall runs from post-start.sh in that case.
set -euo pipefail
IFS=$'\n\t'

if [[ -x /usr/local/bin/post-create.sh ]]; then
    /usr/local/bin/post-create.sh || true
fi

if [[ -x /usr/local/bin/post-start.sh ]]; then
    /usr/local/bin/post-start.sh || true
fi

exec "$@"
