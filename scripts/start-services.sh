#!/usr/bin/env bash
# start-services.sh — bring up postgres + redis inside the agent container
# on 127.0.0.1, mirroring a CI runner. Idempotent: re-running is safe.
#
# Why in-container instead of sidecars: Docker Desktop's embedded DNS for
# user-defined bridge networks flakes on macOS, breaking name resolution
# of sidecar service aliases. CI configs typically expect 127.0.0.1
# anyway, so loopback is both more reliable and more familiar.
set -euo pipefail
IFS=$'\n\t'

PG_DATA=${PGDATA:-/var/lib/postgresql/data}
PG_BIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)
PG_CONF="$PG_DATA/postgresql.conf"
PG_LOG=/var/log/postgresql/agent.log

mkdir -p "$(dirname "$PG_LOG")"
chown postgres:postgres "$(dirname "$PG_LOG")" || true

start_postgres() {
    if [[ ! -x "$PG_BIN/postgres" ]]; then
        echo "[start-services] postgresql server binary not found in $PG_BIN" >&2
        return 1
    fi

    # Ensure data dir exists with the right ownership before initdb.
    mkdir -p "$PG_DATA"
    chown -R postgres:postgres "$PG_DATA"
    chmod 700 "$PG_DATA"

    if [[ ! -s "$PG_DATA/PG_VERSION" ]]; then
        echo "[start-services] initialising postgres data dir at $PG_DATA"
        sudo -u postgres "$PG_BIN/initdb" -D "$PG_DATA" \
            --auth-local=trust --auth-host=md5 \
            --username=postgres \
            -E UTF8 >/dev/null
        # Bind to loopback only — no external access.
        {
            echo "listen_addresses = '127.0.0.1'"
            echo "port = 5432"
            echo "max_connections = 100"
            echo "shared_buffers = 128MB"
            echo "fsync = off"
            echo "synchronous_commit = off"
            echo "full_page_writes = off"
        } >> "$PG_CONF"
    fi

    if sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" status >/dev/null 2>&1; then
        echo "[start-services] postgres already running"
    else
        echo "[start-services] starting postgres on 127.0.0.1:5432"
        sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_LOG" \
            -o "-c listen_addresses=127.0.0.1" start
    fi

    # Wait for socket — pg_ctl returns before the server fully accepts.
    for _ in $(seq 1 20); do
        if sudo -u postgres psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done

    # Idempotent role/db creation. We seed two pairs:
    #   postgres / postgres / postgres   — typical CI default
    #   laravel  / laravel  / laravel    — Laravel skeleton default
    psql_admin() { sudo -u postgres psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 "$@"; }
    psql_admin -c "ALTER USER postgres WITH PASSWORD 'postgres';"
    if ! psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='laravel'" | grep -q 1; then
        psql_admin -c "CREATE ROLE laravel WITH LOGIN SUPERUSER PASSWORD 'laravel';"
    fi
    if ! psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='laravel'" | grep -q 1; then
        psql_admin -c "CREATE DATABASE laravel OWNER laravel;"
    fi

    # Allow password auth from the container itself (not just trust on
    # local socket) so apps that open TCP/IP connections work.
    if ! grep -q '^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+127\.0\.0\.1/32' "$PG_DATA/pg_hba.conf"; then
        echo "host    all    all    127.0.0.1/32    md5" >> "$PG_DATA/pg_hba.conf"
        sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" reload >/dev/null
    fi
}

start_redis() {
    if pgrep -f 'redis-server.*127\.0\.0\.1:6379' >/dev/null; then
        echo "[start-services] redis already running"
        return 0
    fi
    echo "[start-services] starting redis on 127.0.0.1:6379"
    redis-server --daemonize yes \
        --bind 127.0.0.1 \
        --port 6379 \
        --logfile /var/log/redis-agent.log \
        --dir /tmp \
        --save '' \
        --appendonly no >/dev/null
}

# Skip individually with NO_POSTGRES=1 / NO_REDIS=1 (set via run.sh
# --no-postgres / --no-redis). Skip both with NO_SERVICES=1.
if [[ "${NO_SERVICES:-0}" != "1" && "${NO_POSTGRES:-0}" != "1" ]]; then
    start_postgres || echo "[start-services] postgres start failed (continuing)" >&2
fi
if [[ "${NO_SERVICES:-0}" != "1" && "${NO_REDIS:-0}" != "1" ]]; then
    start_redis || echo "[start-services] redis start failed (continuing)" >&2
fi
