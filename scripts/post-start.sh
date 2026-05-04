#!/usr/bin/env bash
# Runs every time the container starts. Re-applies the firewall (rules don't
# survive a stop/start) and prints a one-line health summary.
set -euo pipefail
IFS=$'\n\t'

if command -v sudo >/dev/null 2>&1; then
    sudo /usr/local/bin/init-firewall.sh || {
        echo "[post-start] firewall init failed — egress is unrestricted!" >&2
        exit 1
    }
fi

echo "[post-start] container ready. Run \`ai help\` for launchers."
