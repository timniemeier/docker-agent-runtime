# Docker Agent Runtime

A sandboxed Docker image that runs **Claude Code** and **Codex CLI** side-by-side, tuned for working on the `clever.hr` Laravel project (and similar Laravel/Node/Playwright stacks). Network egress is restricted to a curated allowlist; no host secrets are bind-mounted; named volumes keep agent logins, npm/composer caches, and Playwright browsers around between rebuilds.

## Prerequisites

- Docker Desktop (macOS/Windows) or Docker Engine 24+ (Linux), **running** — not just installed. Smoke-test with `docker info`; if it hangs or errors, start Docker Desktop before continuing. Otherwise `docker build` and `docker run` will block silently waiting for an absent daemon.
- ~8 GB free disk for the image and Playwright browsers.
- (Optional) An `ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` exported in your shell. You can skip these and use interactive `claude login` / `codex login` instead — credentials persist in named volumes.
- (Optional, macOS) An SSH agent on the host (`ssh-add -l` should not error). Docker Desktop on macOS does not natively forward `SSH_AUTH_SOCK` from the host, so `run.sh` mounts it explicitly. If git-over-ssh fails inside the container, see *Known limitations* below.

## Quick start

There are three supported entry points. Pick whichever matches your workflow.

### 1. VSCode / Cursor devcontainer

```bash
# Open the project in VSCode / Cursor, then:
#   Cmd-Shift-P → "Dev Containers: Reopen in Container"
```

The devcontainer picks up `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` from your local shell environment via `${localEnv:...}` substitution. It also bind-mounts `~/.gitconfig` read-only so commits keep your name/email.

### 2. Docker Compose

```bash
cd docker-agent-runtime
docker compose up -d
docker compose exec agent zsh

# Optional Postgres + Redis sidecars on a private network:
docker compose --profile laravel up -d
```

### 3. One-shot launcher

```bash
cd docker-agent-runtime
./run.sh                        # mount $PWD at /workspace
./run.sh /path/to/other/repo    # mount that repo instead
```

`run.sh` builds the image on first invocation, names the container by a hash of the project path (so different repos don't collide), forwards your SSH agent socket if available, and drops you into `zsh` after the firewall initialises.

## Authentication

Inside the container, run once and the credentials persist in the named volumes:

```bash
claude login          # Anthropic OAuth or paste API key
codex login           # OpenAI OAuth or paste API key
gh auth login         # GitHub CLI (lives in /home/node/.config/gh volume)
```

You can also export `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` on the host; both are forwarded into the container and override interactive login.

## The `ai` launcher

Single entry point with sensible defaults, plus YOLO toggles when you want them:

```bash
ai claude              # claude with default permission prompts
ai claude --yolo       # claude --dangerously-skip-permissions
ai codex               # codex --sandbox workspace-write --ask-for-approval on-request
ai codex --yolo        # codex --sandbox danger-full-access --ask-for-approval never
ai both                # tmux split: Claude left, Codex right
ai firewall            # re-run egress allowlist (sudo)
ai help
```

YOLO modes print a red warning to stderr before launching.

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
docker run -e OPENAI_ALLOWED_DOMAINS="example.com fly.io" ... agent-runtime:latest
```

## Adding MCP servers

- **Claude:** edit `config/claude-settings.json` (the file is seeded into `~/.claude/settings.json` on first start; subsequent edits to your live settings.json are not overwritten).
- **Codex:** edit `config/codex-config.toml` (same lifecycle).

The image ships with `@playwright/mcp` only. If you add an MCP server that fetches from a new domain, remember to extend the firewall allowlist.

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

## Credits

Firewall pattern adapted from the `anthropics/claude-code` and `openai/codex` reference devcontainers. Codex TOML schema verified against `codex-rs/config/src/config_toml.rs` and `codex-rs/config/src/mcp_types.rs` upstream.
