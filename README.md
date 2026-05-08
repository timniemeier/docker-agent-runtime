# Docker Agent Runtime

[![Release](https://img.shields.io/github/v/release/timniemeier/docker-agent-runtime?sort=semver)](https://github.com/timniemeier/docker-agent-runtime/releases)
[![Container](https://img.shields.io/badge/GHCR-agent--runtime-blue)](https://github.com/timniemeier/docker-agent-runtime/pkgs/container/agent-runtime)
[![Docker](https://img.shields.io/badge/runtime-Docker-2496ED)](https://www.docker.com/)

<p align="center">
  <img src="readme-image.png" alt="Docker Agent Runtime — contain. control. execute." width="600">
</p>

Run AI coding agents in a disposable, batteries-included development runtime instead of your host shell.

Docker Agent Runtime packages **Claude Code**, **Codex CLI**, GitHub tooling, Playwright browsers, MCP servers, Laravel-friendly services, and a guarded network policy into one repeatable container. Your project is mounted at `/workspace`; agent credentials and package caches live in Docker volumes; host cloud credentials stay off the filesystem.

Use it when you want the speed of local agents with cleaner boundaries: predictable tools, constrained egress, per-project containers, resumable sessions, and no mystery setup every time you spin up a branch.

## Highlights

| What you get | Why it matters |
| --- | --- |
| Claude Code + Codex CLI together | Switch models and workflows without maintaining two local toolchains. |
| Curated egress allowlist | Agents can reach the services they need; random outbound traffic is blocked by default. |
| Laravel / Node / Playwright ready | PHP, Composer, Node, npm, Playwright browsers, postgres, and redis are already wired. |
| Worktree-first workflow | Create issue branches under `./.worktrees`, mount them automatically, link `.env`, and clean them up on exit. |
| Persistent agent state | Logins, shell history, package caches, Playwright browsers, and optional session exports survive rebuilds. |
| MCPs preloaded | Playwright, Context7, Chrome DevTools, and GitHub MCP are configured out of the box. |
| Clear runtime markers | Prompt segment, window title, iTerm badge, and git context line make it obvious when you are inside the container. |

## Quick Start

```bash
git clone https://github.com/timniemeier/docker-agent-runtime.git
cd docker-agent-runtime
./run.sh /path/to/your/project
```

On first launch, `run.sh` tries to pull `ghcr.io/timniemeier/agent-runtime:latest` and falls back to a local build if no compatible image is available. You land in `zsh` with `/workspace` mounted to your project.

Inside the container:

```bash
claude login          # or forward ANTHROPIC_API_KEY from your host shell
codex login           # or forward OPENAI_API_KEY from your host shell
gh auth login         # enables GitHub CLI + GitHub MCP
ai help               # see the agent launcher commands
```

For the shortest daily workflow, install the host alias once:

```bash
./scripts/install-host-alias.sh
exec $SHELL

agent ~/projects/my-app
```

## Requirements

- Docker Desktop (macOS/Windows) or Docker Engine 24+ (Linux), **running**. Check with `docker info`.
- About 8 GB free disk for the image, browser binaries, and caches.
- Optional: `ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` exported on the host, or use interactive logins inside the container.
- Optional on macOS: an active SSH agent (`ssh-add -l`) for git-over-SSH forwarding.

## Choose Your Entry Point

Pick the mode that matches how you work:

| Mode | Best for | Command |
| --- | --- | --- |
| One-shot launcher | Daily agent sessions in any repo | `./run.sh /path/to/repo` |
| Global alias | Launching from any project directory | `agent` |
| Devcontainer | VS Code / Cursor users | `Dev Containers: Reopen in Container` |
| Docker Compose | Long-running local runtime | `docker compose up -d && docker compose exec agent zsh` |

### One-Shot Launcher

```bash
./run.sh                                       # mount $PWD at /workspace
./run.sh /path/to/other/repo                   # mount that repo instead
./run.sh --no-sidecars /path/to/repo           # skip auto-started services
./run.sh --with-postgres /path/to/repo         # force postgres on for non-Laravel
./run.sh --with-laravel  /path/to/repo         # force postgres + redis
./run.sh --resume /path/to/repo                # import host Claude/Codex sessions
./run.sh --no-worktree-prompt                  # skip the issue/worktree prompt
./run.sh --rebuild /path/to/repo               # rebuild the local runtime image
./run.sh --help                                # full flag list
```

### Global `agent` Alias

```bash
./scripts/install-host-alias.sh
# pick a different name with: ALIAS_NAME=dar ./scripts/install-host-alias.sh
exec $SHELL

agent                                  # mount $PWD
agent ~/projects/my-laravel-app        # auto-detects Laravel, starts services
agent --no-sidecars ~/projects/foo     # all run.sh flags work
```

The installer detects your shell rc (`~/.zshrc`, `~/.bashrc`, `~/.bash_profile`) and maintains an idempotent block, so re-running it after moving this repo updates the alias in place.

### VS Code / Cursor Devcontainer

Open this repo in VS Code or Cursor, then run:

```text
Cmd-Shift-P -> Dev Containers: Reopen in Container
```

The devcontainer picks up `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` from your local shell environment and bind-mounts `~/.gitconfig` read-only so commits keep your name and email.

### Docker Compose

```bash
docker compose up -d
docker compose exec agent zsh

# Optional Postgres + Redis sidecars on a private network:
docker compose --profile laravel up -d
```

## Worktree Mode

Run `agent` or bare `./run.sh` from inside a git repo and the launcher can create or open a worktree before the container starts:

- Choose `[create new branch]` or an existing remote branch from an arrow-key selector.
- Create branches from GitHub issues with names like `42-fix-login-redirect`.
- Place worktrees under `./.worktrees/<branch>` and mount the selected worktree at `/workspace`.
- Symlink `.env` from the main worktree when present so hooks and tests do not fail from missing local config.
- Auto-mount the parent repo so git works correctly inside the container.
- Ask on exit whether to remove the launcher-created worktree; dirty worktrees require a second confirmation before `git worktree remove --force`.

Skip the startup prompt with `--no-worktree-prompt` or `WORKTREE_PROMPT=0`. Passing an explicit project path bypasses both startup and cleanup prompts.

## Built For Laravel And Full-Stack Apps

If the project contains `artisan` and `composer.json` requires `laravel/framework`, the one-shot launcher starts postgres and redis automatically inside the agent container on loopback:

- Postgres: `127.0.0.1:5432`
- Redis: `127.0.0.1:6379`
- Seeded database roles: `postgres`/`postgres` and `laravel`/`laravel`
- Pre-injected Laravel and libpq env vars so `php artisan migrate`, `phpunit`, `psql`, and app code work without hand-wiring
- Laravel Boost is installed and configured automatically if the project does not already have it

```bash
psql -h 127.0.0.1 -U postgres -c 'CREATE DATABASE myapp_testing;'
```

Override service detection with `--no-postgres`, `--no-redis`, `--no-sidecars`, `--with-postgres`, `--with-redis`, or `--with-laravel`.

## Runtime Experience

Every interactive shell makes the container state visible:

- Red `RUNTIME` powerlevel10k prompt segment.
- Window/tab title prefixed with `Agent Runtime`.
- iTerm2 badge overlaid in the pane.
- Git worktree and branch line above each prompt in zsh and bash.

Use the `ai` launcher for common agent flows:

```bash
ai claude              # Claude with default permission prompts
ai codex               # Codex with workspace-write sandbox
ai both                # tmux split: Claude left, Codex right
ai firewall            # re-run egress allowlist
ai help
```

Astro dev servers should keep using port `4321` inside the container. The one-shot launcher prefers `127.0.0.1:4321` on the host, but if that host port is already busy it automatically publishes the container port on the next free host port and prints the actual URL before the shell starts.

```bash
npm run dev -- --host 0.0.0.0 --port 4321
```

Then open the URL printed by `run.sh`, for example `http://127.0.0.1:4321` or `http://127.0.0.1:4322`. To force a specific host port, launch with `AGENT_DEV_HOST_PORT=5173 agent ...`; to always choose a free port, use `AGENT_DEV_HOST_PORT=auto`.

## Project Status

The published v1 image is currently `linux/arm64` first, tuned for Apple Silicon development. On `linux/amd64`, `run.sh` falls back to a local Docker build. Public hardening docs live in the Security model and Accepted tradeoffs sections below; a standalone license file has not been published yet.

## Authentication

Inside the container, run once and the credentials persist in the named volumes:

```bash
claude login          # Anthropic OAuth or paste API key
codex login           # OpenAI OAuth or paste API key
gh auth login         # GitHub CLI (lives in /home/node/.config/gh volume)
```

You can also export `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` on the host; both are forwarded into the container and override interactive login.

If `~/.claude/CLAUDE.md` exists on the host, `run.sh` bind-mounts it read-only directly at the container's `~/.claude/CLAUDE.md`, so the host file stays canonical. Edits show up the next time the container starts — Claude Code re-reads the file each invocation, so a fresh `claude` launch is enough; no rebuild or volume reset needed. The named `agent-claude` volume still holds sessions, credentials, and history; only `CLAUDE.md` is shadowed by the bind.

## The `ai` launcher

Single entry point with sensible defaults, plus YOLO toggles when you want them:

```bash
ai claude              # claude with default permission prompts
ai claude --yolo       # claude --dangerously-skip-permissions
ai codex               # codex --enable goals --sandbox workspace-write --ask-for-approval on-request
ai codex --yolo        # codex --enable goals --sandbox danger-full-access --ask-for-approval never
ai both                # tmux split: Claude left, Codex right
ai firewall            # re-run egress allowlist (sudo)
ai help
```

YOLO modes print a red warning to stderr before launching.

Codex Goals are enabled by default. In an interactive Codex session, use `/goal <objective>` to keep Codex working toward a long-running objective across turns. Use `/goal pause`, `/goal resume`, or `/goal clear` to manage the lifecycle.

## Security model

| Aspect | Status | Notes |
| --- | --- | --- |
| Network egress | restricted | iptables + ipset allowlist applied at container start, re-runnable via `ai firewall`. Default policy is `DROP`. IPv6 is disabled outright. |
| Host SSH / GPG / AWS keys | not mounted | Forwarded only via `SSH_AUTH_SOCK` (no key material on disk inside the container). |
| Host cloud creds | not mounted | No `~/.aws`, no `~/.docker/config.json`, no `~/.ssh`. |
| Memory / PID limits | yes | 8 GB memory, 4096 PIDs, 4 CPU. |
| Codex bubblewrap nested sandbox | available | `bwrap` is setuid root inside the image. |
| Workspace | read-write bind mount | The agent can modify any file in your project directory. |
| GitHub egress | allowed | The agent can `git push` once `gh auth login` has been completed. |
| Linux capabilities | NET_ADMIN, NET_RAW, SYS_ADMIN, SYS_CHROOT, SETUID, SETGID, SYS_PTRACE | Required for the firewall and bubblewrap; expands attack surface vs. a default container. Not equivalent to `--privileged`. |
| AppArmor / seccomp | unconfined | Required for nested user namespaces. |

### Accepted tradeoffs

These are known security gaps that are **deliberately not fixed** in v1. Each is a conscious tradeoff between hardening cost and practical usability. If your threat model changes, revisit them.

- **Unpinned `@anthropic-ai/claude-code` and `@openai/codex` versions.** The Dockerfile resolves `latest` at build time so you stay current with security and feature fixes upstream. A compromised npm publish would land in the next rebuild. Mitigation: rebuild deliberately (not on a schedule), and pin a known-good version via the `CLAUDE_CODE_VERSION` / `CODEX_VERSION` build args before a high-stakes session.
- **Unpinned Playwright version.** Same reasoning as above. Pin via the build arg if you need reproducible builds.
- **`~/.gitconfig` is bind-mounted read-only.** Convenient for keeping your name/email/aliases, but a `[credential] helper = ...` entry pointing at a host binary or file path may leak tokens or fail loudly. **Audit your `~/.gitconfig` for `credential.helper` and `[includeIf]` entries before first use.** The bind is read-only so the agent cannot modify it, but it can read it.
- **Named volumes hold unencrypted credentials.** `claude login`, `codex login`, and `gh auth login` tokens persist in Docker named volumes (`agent-claude`, `agent-codex`, `agent-gh`). These are stored unencrypted on the host under `/var/lib/docker/volumes/`. Anyone with Docker daemon access on the host (root, the `docker` group, or another container with the daemon socket mounted) can extract them with `docker run --rm -v agent-claude:/data alpine cat /data/...`. Treat host Docker access as equivalent to having your AI API keys and GitHub OAuth tokens.

## Customising the allowlist

Edit `scripts/init-firewall.sh` and rebuild. The list is grouped by purpose (Anthropic, OpenAI, NPM, Composer, PyPI, Crates, Playwright, custom deploy target, VSCode, GitHub) so it's easy to add or comment-out a domain. You can also pass extra domains at runtime without rebuilding:

```bash
AGENT_ALLOWED_DOMAINS="example.com fly.io" ./run.sh /path/to/repo
```

`OPENAI_ALLOWED_DOMAINS` is still accepted for compatibility with Codex's secure-profile convention. For Hugging Face model downloads, pass the required domains and token from the host:

```bash
AGENT_ALLOWED_DOMAINS="huggingface.co cdn-lfs.huggingface.co hf.co cas-bridge.xethub.hf.co transfer.xethub.hf.co cas-server.xethub.hf.co" \
HF_TOKEN=hf_... \
./run.sh /path/to/repo
```

The one-shot launcher, Compose file, and devcontainer forward `HF_TOKEN`, `HUGGINGFACE_HUB_TOKEN`, and `HUGGING_FACE_HUB_TOKEN`. Hugging Face downloads are cached in the `agent-huggingface` Docker volume at `/home/node/.cache/huggingface`.

## Bundled MCP Servers

Claude is pre-wired through `config/claude-settings.json` with core MCP servers that work across projects, plus a Laravel Boost entry that becomes active once a Laravel workspace is bootstrapped:

| Server | Package | Purpose |
| --- | --- | --- |
| `playwright` | `@playwright/mcp` | Drive a real browser (chromium baked into the image) |
| `context7` | `@upstash/context7-mcp` | Up-to-date library docs lookup |
| `chrome-devtools` | `chrome-devtools-mcp` | Chrome DevTools Protocol — inspect pages, traces, console |
| `github` | `@modelcontextprotocol/server-github` (via `/usr/local/bin/mcp-github`) | GitHub repo / PR / issue tooling |
| `laravel-boost` | `laravel/boost` | Laravel-aware app context, docs, and framework tooling |

The `github` MCP gets its token automatically from the `gh` CLI — run `gh auth login` once and the wrapper script picks up the token at MCP launch. No PAT to manage.

The firewall already allowlists the domains these servers reach (Context7, Chrome-for-Testing CDN, GitHub).

### Laravel Boost

When a Laravel project is mounted, `post-create.sh` automatically runs the equivalent of `composer require laravel/boost --dev --no-interaction` when `laravel/boost` is missing, then runs `php artisan boost:install --no-interaction` if the project does not already expose a `laravel-boost` MCP entry in `.mcp.json`.

Set `AGENT_AUTO_LARAVEL_BOOST=0` to skip this startup bootstrap.

### Adding more

- **Claude:** edit `config/claude-settings.json` and rebuild, or edit `~/.claude/settings.json` live (not overwritten on rebuild).
- **Codex:** edit `config/codex-config.toml` (same lifecycle). Goals are enabled there via `[features] goals = true`.

If a new MCP fetches from a new domain, extend `scripts/init-firewall.sh` and re-run `ai firewall`.

## Laravel sidecar profile

```bash
docker compose --profile laravel up -d
```

Adds a Postgres 16 container (user/db `laravel`, password `laravel`) and a Redis 7 container on the private `agent-net` network. Inside the agent container, reach them at `postgres:5432` and `redis:6379`. These are only accessible from the agent — no host port publishing.

## Known limitations

- **Architecture:** the image is built on `node:22-bookworm`, which is multi-arch. On Apple Silicon, build natively (`docker build --platform linux/arm64 ...`) for speed; some `apt` packages (notably `bubblewrap`) work fine on arm64 but Playwright chromium is faster on amd64.
- **Playwright browsers:** ~300 MB are baked into the image during build to avoid a slow first run. They live in the `agent-playwright` named volume after first start.
- **macOS SSH agent:** Docker Desktop on macOS forwards `SSH_AUTH_SOCK` only via the `magic` socket workaround. `run.sh` will mount whatever path is in `SSH_AUTH_SOCK`; if you see `Permission denied (publickey)` for git-over-ssh, restart Docker Desktop or fall back to HTTPS + `gh auth`.
- **Firewall + corporate proxies:** if your network requires an HTTPS proxy, you'll need to allowlist the proxy CIDR and set `HTTPS_PROXY` inside the container.
- **`--cap-add SYS_ADMIN`:** required for bubblewrap and for the iptables/ipset rules; this image is **not** suitable for running untrusted third-party code on shared hardware.

## FAQ / Troubleshooting

**Q: I edited a script but my changes aren't visible inside the container.**
`run.sh` only builds the image when there is none — and it'll prefer pulling from GHCR over building. After changing anything in `Dockerfile`, `scripts/`, or `config/`, rebuild before launching:
```bash
./run.sh --rebuild /path/to/project
```
The command asks for confirmation first because it downloads current upstream packages and replaces the local `agent-runtime:latest` image tag used by future launches. Docker volumes with logins, caches, history, and project data are not removed.

**Q: Powerlevel10k icons show as `[?]` in my terminal.**
Install MesloLGS NF and select it as your terminal font. One-liner:
```bash
mkdir -p ~/Library/Fonts && cd ~/Library/Fonts && \
  for s in Regular Bold Italic 'Bold Italic'; do \
    curl -fLO "https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20${s// /%20}.ttf"; \
  done
```
Then in iTerm2 / Terminal.app / VS Code: Preferences → Profile / Font → "MesloLGS NF".

**Q: `[firewall] warn: no A records resolved for ...` for every domain.**
Docker Desktop's DNS forwarding has stalled. The runtime auto-falls back to `1.1.1.1` / `8.8.8.8` (added to `/etc/resolv.conf` if only `127.0.0.11` is present). If it still fails:
```bash
# inside the container
cat /etc/resolv.conf
dig @1.1.1.1 github.com
```
If `dig @1.1.1.1` fails, restart Docker Desktop (Quit → reopen) — the macOS network stack frequently wedges.

**Q: `psql: Connection refused` on `127.0.0.1:5432`.**
Postgres failed to come up. Diagnose:
```bash
sudo /usr/local/bin/start-services.sh    # re-run, watch the output
sudo cat /var/log/postgresql/agent.log | tail -40
```
If `start-services` reports a partial / corrupt data dir from an earlier failed init:
```bash
exit
docker volume rm $(docker volume ls -q --filter name='agent-pgdata-')
agent ~/path/to/your/repo                 # fresh volume on next boot
```

**Q: `No space left on device` during build or inside the container.**
Docker Desktop's VM disk is full. Reclaim:
```bash
docker rm -f $(docker ps -aq --filter name=agent-) 2>/dev/null
docker container prune -f
docker builder prune -a -f
docker image prune -a -f
docker system df            # verify
```
If still > 80% used, bump **Docker Desktop → Settings → Resources → Disk image size** to 100 GB+.

**Q: Bundled MCPs (`context7`, `chrome-devtools`, `github`) don't show up in Claude.**
You have an existing `agent-claude` volume from an earlier image; `post-create` doesn't overwrite an existing `~/.claude/settings.json`. Either re-seed (loses Claude login):
```bash
docker volume rm agent-claude
```
…or open `~/.claude/settings.json` inside the container and merge the `mcpServers` block from `/etc/agent-runtime/claude-settings.json` manually.

**Q: `gh auth login` works on the host but the GitHub MCP says "no token".**
The MCP wrapper reads from the container's `gh` CLI, which lives in the `agent-gh` named volume — separate from your host's `gh`. Run `gh auth login` *inside* the container once.

**Q: Git is broken inside the container ("not a git repository") for a worktree.**
The launcher auto-detects worktrees and mounts the parent repo. If you bypassed `run.sh` (e.g. used compose), pass the parent explicitly:
```bash
EXTRA_MOUNTS=/Users/you/path/to/main-repo ./run.sh /path/to/worktree
```

**Q: Is `--resume` actually working?**
Run the included smoke test from the runtime repo root on the host:
```bash
./scripts/smoke-test-resume.sh
```
It picks the most recently active host Claude project, runs the container non-interactively with `--resume`, and asserts that every host JSONL UUID lands in the container's `~/.claude/projects/-workspace/`. Exits 0 on pass.

**Q: Can I resume a Claude / Codex session I started on the host inside the container?**
Yes — launch with `--resume`:
```bash
agent --resume ~/projects/my-laravel-app
```
`run.sh` bind-mounts your host's `~/.claude/projects` and `~/.codex/sessions` read-only and copies the matching project's transcripts into the container's session store on first start. Then `claude --resume` (or `claude -c` for continue-most-recent) and `codex --resume` list them.

**Q: I rebuilt the runtime image / dropped the agent-claude volume. How do I keep my running conversation?**
`--resume` also turns on an **export** half: the container's session writes are mirrored back to `~/.claude-runtime-export/projects/<encoded-project-path>/` on the host (a separate tree from your real `~/.claude` — your real Claude history stays read-only). A zsh `precmd` hook syncs after each command (throttled to ~30 s), and the same sync runs on shell exit. Manual flush before destroying the container:
```bash
agent-export   # inside the container, forces an immediate rsync
```
On the next `agent --resume`, `post-create.sh` imports from the export tree first (most-recent appended turns), then fills in anything missing from the host's pristine tree. Net: `claude --resume` shows the conversation right where you left it, even after `docker volume rm agent-claude` and a full rebuild.

Disable the export half with `agent --resume --no-export <project>` if you only want import (host's `~/.claude-runtime-export/` stays empty, container writes don't escape).

**Q: How do I tell at a glance whether I'm inside the runtime or on the host?**
Inside the container the runtime adds three visual markers that don't exist on the host:
- A red **🐳 RUNTIME** segment on the left of the powerlevel10k prompt.
- The window/tab title is prefixed with **🐳 Agent Runtime — `<cwd>`**.
- iTerm2 shows an **AGENT RUNTIME** badge overlaid in the pane corner.
- The container's hostname is `agent-runtime`, so `prompt %m` / `whoami@host` differs from your laptop's hostname.

**Q: My terminal is mangled — every keypress shows `c9;1:3u` or similar gibberish.**
A TUI process (usually `ai claude` or `ai codex`) exited without popping the kitty keyboard protocol off the terminal stack. New shells in the runtime now pop the stack defensively on startup, so opening a fresh iTerm tab (or any new container) clears it. To unstick the *current* shell without closing the tab, paste this and hit Enter:

```
printf '\e[<u' && reset
```

**Q: `git fetch` over SSH says "Host key verification failed" or HTTPS asks for a username.**
The runtime now ships GitHub's SSH host keys pre-seeded in `/etc/ssh/ssh_known_hosts`, and `post-create.sh` runs `gh auth setup-git` automatically once you've done `gh auth login` — so both `git@github.com:…` and `https://github.com/…` should work after a single login. If you see `Device or resource busy` writing `/home/node/.gitconfig`, that's the host gitconfig bind-mounted read-only. The runtime works around it with `GIT_CONFIG_GLOBAL=/home/node/.gitconfig-runtime`, which `[include]`s the host config but is itself writable. If you customised your gitconfig before this fix shipped, rebuild the image and re-launch to pick it up.

**Q: I want to bring my own postgres on a host port.**
Disable the in-container service and reach the host:
```bash
WITH_POSTGRES=0 agent ~/your/repo
# inside: connect to host.docker.internal:5432
```
You'll also need to add `host.docker.internal` to `scripts/init-firewall.sh` (or its IP).

## Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/). Most recent first.

### 2026-05-07 (latest)

**Added**
- `run.sh` / `agent` now prompts on bare invocations from inside a git repo: `Create a new worktree for an issue? [y/N]`. On opt-in, it opens an arrow-key selector with `[create new branch]` and all remote branches from `origin`; existing branches are checked out into `./.worktrees/<branch>`, while new branches are created from either a selected open GitHub issue (`<num>-<slug>`) or a manually entered branch name. Skipped on non-TTY, when an explicit project path is passed, or under `--no-worktree-prompt` / `WORKTREE_PROMPT=0`. (#11)

**Fixed**
- `run.sh` no longer treats no-arg invocations as a single empty positional. Previously `set -- "${_args[@]:-}"` collapsed an empty parsed-args array to `""`, making `$#` always ≥ 1 — the new bootstrap branches on `${#_args[@]}` before that collapse. (#11)

### 2026-05-05

**Changed**
- Postgres + Redis now run **inside** the agent container on `127.0.0.1` instead of as separate sidecar containers on a custom bridge network. The bridge approach kept tripping over Docker Desktop's embedded DNS (service-name resolution stalled intermittently on macOS). Loopback is reliable, matches CI, and removes a whole class of "postgres unreachable" failures. New volume name: `agent-pgdata-<hash>` (was `agent-postgres-<hash>` — the old volumes are unreadable by the in-container postgres because the prior sidecar used `postgres:16-alpine` while bookworm ships PG 15; `docker volume rm` the old ones).
- Two roles seeded automatically: `postgres`/`postgres` (superuser) and `laravel`/`laravel`.

**Added**
- `scripts/start-services.sh` — idempotent service-bringup invoked from `post-start.sh`. Honours `NO_POSTGRES=1`, `NO_REDIS=1`, `NO_SERVICES=1`.
- `scripts/install-host-alias.sh` — host-side installer that adds an idempotent `agent` alias (override with `ALIAS_NAME=…`) to `~/.zshrc` / `~/.bashrc` / `~/.bash_profile`. Re-running replaces the existing block in place, so moving the repo just needs one re-run.
- Laravel auto-detect: when `run.sh` sees an `artisan` file and `laravel/framework` in `composer.json`, it now starts postgres + redis by default. Override with `--no-postgres`, `--no-redis`, or `--no-sidecars`.
- `run.sh --with-postgres`, `--with-redis`, `--with-laravel` — explicitly start sidecars on a project-scoped bridge network and connect the agent. Postgres is reachable at `postgres:5432` (creds `laravel/laravel/laravel`); redis at `redis:6379`. Standard libpq + Laravel env vars are auto-injected. Data persists in `agent-postgres-<hash>` / `agent-redis-<hash>` volumes.
- Firewall auto-allows the agent's local bridge subnet (RFC1918) so traffic to sidecar IPs gets through the egress allowlist. Public-internet egress is unchanged.

### 2026-05-05 (earlier)

**Added**
- Bundled MCP servers in the seeded `claude-settings.json`: `playwright`, `context7`, `chrome-devtools`, and `github`. Previously only `playwright` was pre-configured.
- `/usr/local/bin/mcp-github` wrapper that pulls the GitHub token from `gh auth token` at MCP launch — no PAT in config files.
- Firewall allowlist extended for the new MCPs: `mcp.context7.com`, `context7.com`, `storage.googleapis.com`, `googlechromelabs.github.io`, `edgedl.me.gvt1.com`.
- First-run banner now lists the bundled MCPs and points at the `laravel-boost` per-project recipe.

### 2026-05-05

**Fixed**
- Firewall allowlist was always empty under `mawk`: the previous `dig` filter used a Perl-style `\s` regex that mawk treats as a literal `s`, so no IPs were ever added. Replaced with a positional `$4 == "A"` match.
- Firewall validator falsely reported `api.anthropic.com` and `api.openai.com` as unreachable: the probe used `curl -f`, which fails on HTTP 4xx — both APIs return 404 on their bare root URL even when reachable. Now any 1xx–5xx response counts as a successful connection.
- Firewall hard-coded DNS to `127.0.0.11`. Docker Desktop on macOS uses a different resolver address, so DNS broke entirely on Mac. Now allows whatever nameservers `/etc/resolv.conf` lists.
- Playwright build step failed in the no-tty Docker build shell because `playwright install --with-deps` tried to escalate via `sudo`. Split into two layers: `install-deps` as `root` (apt), then browser binaries as the `node` user.

**Added**
- `release-assets.githubusercontent.com` to the egress allowlist — GitHub's new host for binary release artefacts (needed for the powerlevel10k `gitstatusd` download, among others).
- `run.sh` pins container DNS to `1.1.1.1` + `8.8.8.8` (override `DNS_FLAGS` to change), sidestepping Docker Desktop's flaky host resolver.
- `run.sh` accepts `EXTRA_MOUNTS=/host/path[,host:container[:ro]]…` for ad-hoc bind mounts.
- `run.sh` auto-detects git worktrees: if `PROJECT_DIR/.git` is a file pointing at a parent repo, the parent is bind-mounted at its absolute host path so git resolves cleanly. Disable with `AUTO_WORKTREE_MOUNT=0`.
- Codex Goals enabled by default (`--enable goals` in the `ai codex` launcher and `[features] goals = true` in `config/codex-config.toml`). Use `/goal <objective>` in an interactive Codex session; `/goal pause|resume|clear` for lifecycle.

### 2026-05-04

**Added**
- oh-my-zsh + powerlevel10k via `zsh-in-docker` (script SHA-256 pinned).
- `git-delta` 0.18.2 with verified SHA-256 for both `amd64` and `arm64`.

**Fixed**
- `ai both --yolo` now propagates `--yolo` to both agents in the tmux split (previously only Claude got it).
- `run.sh` fails fast with a clear error when the Docker daemon isn't reachable, instead of hanging on the daemon socket.
- `run.sh` permissions restored (`+x`).

### 2026-05-04 — initial release

- Sandboxed image with Claude Code + Codex CLI side-by-side.
- iptables/ipset egress allowlist with re-runnable `ai firewall` helper.
- Named volumes for agent logins, npm/composer/pip/playwright caches.
- Devcontainer, Compose, and `run.sh` entry points.
- Optional Laravel sidecar profile (Postgres 16 + Redis 7).

## Credits

Firewall pattern adapted from the `anthropics/claude-code` and `openai/codex` reference devcontainers. Codex TOML schema verified against `codex-rs/config/src/config_toml.rs` and `codex-rs/config/src/mcp_types.rs` upstream.
