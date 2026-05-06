#!/usr/bin/env bash
# Runs every time the container starts. Re-applies the firewall (rules don't
# survive a stop/start) and brings up the in-container postgres+redis services
# so artisan/phpunit/CI tooling can reach them at 127.0.0.1.
set -euo pipefail
IFS=$'\n\t'

# shellcheck disable=SC1091
source /usr/local/lib/agent-output.sh

log_section "Boot checks"

if command -v sudo >/dev/null 2>&1; then
    sudo /usr/local/bin/init-firewall.sh || {
        log_warn "Firewall init failed — egress is unrestricted!"
        exit 1
    }
fi

# Honours NO_POSTGRES / NO_REDIS / NO_SERVICES env vars from run.sh
# (set via --no-postgres etc.).
if command -v sudo >/dev/null 2>&1; then
    sudo -E /usr/local/bin/start-services.sh || \
        log_warn "Services failed to start (continuing)"
fi

log_ready "Container ready. Run: ai help"
