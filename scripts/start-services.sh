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
PG_BIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)
PG_CONF="$PG_DATA/postgresql.conf"
PG_LOG=/var/log/postgresql/agent.log

mkdir -p "$(dirname "$PG_LOG")"
chown postgres:postgres "$(dirname "$PG_LOG")" || true

log() { printf '[start-services] %s\n' "$*" >&2; }

start_postgres() {
    if [[ -z "$PG_BIN" || ! -x "$PG_BIN/postgres" ]]; then
        log "postgresql server binary not found under /usr/lib/postgresql/*"
        return 1
    fi

    # Ensure data dir exists with the right ownership before initdb. The
    # mounted named volume comes up owned by root on first attach.
    mkdir -p "$PG_DATA"
    chown -R postgres:postgres "$PG_DATA"
    chmod 700 "$PG_DATA"

    # If the dir has files but no PG_VERSION, an earlier initdb crashed
    # halfway. initdb refuses to run on a non-empty dir, and pg_ctl can't
    # start without PG_VERSION — wipe the partial state and start fresh.
    if [[ -d "$PG_DATA" ]] && [[ ! -s "$PG_DATA/PG_VERSION" ]] && [[ -n "$(ls -A "$PG_DATA" 2>/dev/null)" ]]; then
        log "found partial postgres data dir without PG_VERSION; cleaning $PG_DATA"
        find "$PG_DATA" -mindepth 1 -delete
    fi

    if [[ ! -s "$PG_DATA/PG_VERSION" ]]; then
        log "initialising postgres data dir at $PG_DATA"
        # Force a locale that's always present (C.UTF-8) regardless of
        # whatever LC_* the parent shell happens to have set, so initdb
        # doesn't bail with "invalid locale settings".
        if ! sudo -u postgres env \
                LC_ALL=C.UTF-8 LANG=C.UTF-8 LANGUAGE=C.UTF-8 \
                "$PG_BIN/initdb" -D "$PG_DATA" \
                    --locale=C.UTF-8 \
                    --encoding=UTF8 \
                    --auth-local=trust --auth-host=md5 \
                    --username=postgres >/dev/null; then
            log "initdb failed — see output above"
            return 1
        fi
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

    # Clean up a stale postmaster.pid from a previous container that didn't
    # shut down cleanly. pg_ctl warns "another server might be running" and
    # bails out otherwise. Safe because we're inside a fresh container — no
    # other postgres process can be alive across container restarts.
    if [[ -f "$PG_DATA/postmaster.pid" ]]; then
        local pid
        pid=$(head -1 "$PG_DATA/postmaster.pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            log "removing stale postmaster.pid (pid $pid not alive)"
            rm -f "$PG_DATA/postmaster.pid"
        fi
    fi

    if sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" status >/dev/null 2>&1; then
        log "postgres already running"
    else
        log "starting postgres on 127.0.0.1:5432"
        if ! sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_LOG" \
                -o "-c listen_addresses=127.0.0.1" -w start >/dev/null; then
            log "pg_ctl start failed — see $PG_LOG"
            return 1
        fi
    fi

    # All admin SQL goes via the local unix socket (auth-local=trust set at
    # initdb time). Using -h 127.0.0.1 would force TCP host auth (md5) which
    # demands a password and hangs the script. Apps that connect from
    # outside the script see md5 + the seeded password.
    psql_admin() {
        sudo -u postgres env -u PGHOST -u PGPORT \
            psql -U postgres -v ON_ERROR_STOP=1 "$@"
    }

    # Wait for the socket — pg_ctl -w should already guarantee this, but
    # the lock file race occasionally lags by a fraction of a second.
    local attempts=0
    until psql_admin -tAc 'select 1' >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if (( attempts > 20 )); then
            log "postgres did not become ready within 10s"
            return 1
        fi
        sleep 0.5
    done

    # Idempotent role/db creation:
    #   postgres / postgres / postgres   — typical CI default
    #   laravel  / laravel  / laravel    — Laravel skeleton default
    psql_admin -c "ALTER USER postgres WITH PASSWORD 'postgres';" >/dev/null
    if ! psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='laravel'" | grep -q 1; then
        psql_admin -c "CREATE ROLE laravel WITH LOGIN SUPERUSER PASSWORD 'laravel';" >/dev/null
    fi
    if ! psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='laravel'" | grep -q 1; then
        psql_admin -c "CREATE DATABASE laravel OWNER laravel;" >/dev/null
    fi

    # Allow password auth from the container itself (not just trust on
    # local socket) so apps that open TCP/IP connections work.
    if ! grep -q '^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+127\.0\.0\.1/32' "$PG_DATA/pg_hba.conf"; then
        echo "host    all    all    127.0.0.1/32    md5" >> "$PG_DATA/pg_hba.conf"
        sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" reload >/dev/null
    fi
    log "postgres ready on 127.0.0.1:5432 (roles: postgres, laravel)"
    return 0
}

start_redis() {
    if pgrep -f 'redis-server.*127\.0\.0\.1:6379' >/dev/null; then
        log "redis already running"
        return 0
    fi
    log "starting redis on 127.0.0.1:6379"
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
    start_postgres || log "postgres start failed (continuing)"
fi
if [[ "${NO_SERVICES:-0}" != "1" && "${NO_REDIS:-0}" != "1" ]]; then
    start_redis || log "redis start failed (continuing)"
fi
