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

# Bring up postgres + redis on loopback so artisan/phpunit/CI tooling can
# reach them at 127.0.0.1 without any network config. Honours NO_POSTGRES /
# NO_REDIS / NO_SERVICES env vars from run.sh (set via --no-postgres etc.).
if command -v sudo >/dev/null 2>&1; then
    sudo -E /usr/local/bin/start-services.sh || \
        echo "[post-start] services failed to start (continuing)" >&2
fi

echo "[post-start] container ready. Run \`ai help\` for launchers."
