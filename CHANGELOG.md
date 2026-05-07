# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/). Most recent first.

## [1.0.0] — 2026-05-07

First tagged release. Image published to `ghcr.io/timniemeier/agent-runtime:v1.0.0` and `:latest` (linux/arm64 only).

**Added**
- GHCR pull-then-build path in `run.sh`: missing local image triggers `docker pull ghcr.io/timniemeier/agent-runtime:latest` first, falling back to local `docker build` if the pull fails. Override with `AGENT_FORCE_BUILD=1` to always build.
- `.github/workflows/release.yml` — on `v*` tag push, builds and publishes to GHCR via `docker/build-push-action@v6`.

### What's in v1.0

Pulled from the README changelog block, with cross-references to the dated entries.

**Runtime + sandbox**
- Sandboxed image with Claude Code + Codex CLI side-by-side, `bwrap` available for Codex's nested sandbox.
- iptables/ipset egress allowlist with re-runnable `ai firewall` helper. Default policy `DROP`, IPv6 disabled. (2026-05-04 initial; firewall fixes 2026-05-05.)
- 8 GB memory / 4096 PID / 4 CPU limits. AppArmor + seccomp unconfined for nested user namespaces.
- Public DNS pinned to 1.1.1.1 / 8.8.8.8 to sidestep Docker Desktop's flaky host resolver. (2026-05-05.)

**Services**
- In-container postgres + redis on 127.0.0.1, with libpq + Laravel env vars pre-injected. Replaces the earlier sidecar-on-bridge approach. Roles seeded: `postgres`/`postgres` and `laravel`/`laravel`. (2026-05-05.)
- Laravel auto-detect: `artisan` + `laravel/framework` in `composer.json` enables the sidecars by default. (2026-05-05.)

**MCP servers**
- Bundled in seeded `claude-settings.json`: `playwright`, `context7`, `chrome-devtools`, `github`, `laravel-boost`. The `github` wrapper pulls the token from `gh auth token` at MCP launch — no PAT in config. (2026-05-05.)

**Workflow**
- Devcontainer, Compose, and `run.sh` entry points. Per-project container name (hash of project path + sidecar flags) keeps caches isolated.
- `--resume` imports host Claude/Codex sessions read-only into the container. One-way; smoke test under `scripts/smoke-test-resume.sh`. (See README "Q: Can I resume…" entry.)
- Host-side `agent` alias installer (`scripts/install-host-alias.sh`), idempotent across `~/.zshrc` / `~/.bashrc` / `~/.bash_profile`. (2026-05-05.)
- Visual runtime markers (powerlevel10k segment, window/tab title prefix, iTerm2 badge, `agent-runtime` hostname) so it's obvious whether you're inside the sandbox.

**Caches / persistence (named volumes)**
- `agent-claude`, `agent-codex`, `agent-gh` (logins), `agent-history`, `agent-npm`, `agent-composer`, `agent-pip`, `agent-playwright`, `agent-pgdata-<hash>`.

### Known accepted tradeoffs

See README "Accepted tradeoffs" — unpinned `claude-code` / `codex` / Playwright versions, read-only `~/.gitconfig` bind, and unencrypted credentials in named volumes.

### Out of scope for v1.0

- Multi-arch (`linux/amd64`). Add when a Linux contributor needs it.
- Auto-update / image refresh on `agent` invocation. `docker pull` is manual or `AGENT_FORCE_BUILD=1`.
