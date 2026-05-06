#!/usr/bin/env bash
#
# init-firewall.sh — egress allowlist for the agent runtime container.
#
# The whole point of this script is "fail closed". Default OUTPUT policy is
# DROP; only traffic to a curated ipset of resolved IPs (plus loopback, DNS,
# and SSH) is allowed out. We resolve names at firewall-init time rather
# than relying on runtime DNS interception, because the agents and their
# tooling rotate through a lot of CDNs and dig is the only reliable shared
# truth.
#
# Re-running this script must restore a clean, known-good state — Tim runs
# it via `ai firewall` whenever something looks wrong. So we always flush
# rules first and rebuild the ipset from scratch.

set -euo pipefail
IFS=$'\n\t'

# Treat a curl failure during validation at the end as fatal, but allow
# individual `dig` lookups to come back empty without aborting the whole
# script — some domains return empty over IPv6-only resolvers.

log() { printf '[firewall] %s\n' "$*" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log "must run as root (use sudo)"
        exit 1
    fi
}

# Preserve Docker's embedded DNS resolver address before we flush. Docker
# rewrites /etc/resolv.conf to point at 127.0.0.11 and intercepts traffic to
# that address; if we flush nat rules naively we break name resolution
# inside the container.
preserve_docker_dns() {
    if grep -q '127\.0\.0\.11' /etc/resolv.conf 2>/dev/null; then
        DOCKER_DNS_PRESENT=1
    else
        DOCKER_DNS_PRESENT=0
    fi
}

flush_all() {
    # Flush filter and nat tables; reset built-in chain policies to ACCEPT
    # while we're rebuilding. We DROP again at the end.
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    # IPv6 is blocked entirely. Many of the allowlisted hosts have AAAA
    # records and Docker-Desktop's IPv6 stack varies wildly; the simplest
    # safe answer is to drop v6 outright.
    ip6tables -F
    ip6tables -X
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP

    # Replace any prior allowlist set with a fresh empty one.
    if ipset list -n 2>/dev/null | grep -q '^allowed-domains$'; then
        ipset destroy allowed-domains
    fi
    ipset create allowed-domains hash:net family inet
}

allow_baseline() {
    # Loopback always: many tools (composer, php-fpm dev server) talk to
    # 127.0.0.1 and would otherwise be unreachable.
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # DNS — UDP and TCP. We need this BEFORE we DROP outbound, because the
    # ipset population below relies on dig. Allowlist whatever nameservers
    # /etc/resolv.conf points at: on Linux Docker that's 127.0.0.11, on
    # Docker Desktop for macOS it's typically 192.168.65.x. Hard-coding
    # 127.0.0.11 broke DNS entirely on macOS.
    local nameservers
    nameservers=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
    if [[ -z "$nameservers" ]]; then
        log "warn: no nameservers in /etc/resolv.conf — falling back to 127.0.0.11"
        nameservers="127.0.0.11"
    fi
    while IFS= read -r ns; do
        [[ -z "$ns" ]] && continue
        log "allow DNS to $ns"
        iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
        iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
    done <<< "$nameservers"

    # No unconditional TCP 22 — SSH to allowlisted IPs is handled by the ipset rule below

    # Established/related: replies to anything we sent out are fine.
    iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
}

# Add an A record to the allowlist. Silent if the lookup returns nothing —
# we collect failures and warn at the end rather than aborting, because a
# transient DNS hiccup on one CDN host shouldn't kill the whole bring-up.
add_domain() {
    local domain=$1
    local ips
    # `\s` is a Perl-ism; mawk treats it as a literal `s`, which silently
    # drops every line and leaves the allowlist empty. Match by field
    # position instead — dig's +answer rows are: NAME TTL CLASS TYPE RDATA.
    ips=$(dig +noall +answer +time=3 +tries=2 A "$domain" 2>/dev/null \
            | awk '$4 == "A" {print $5}' | grep -E '^[0-9.]+$' || true)
    if [[ -z "$ips" ]]; then
        log "warn: no A records resolved for $domain"
        return 0
    fi
    while IFS= read -r ip; do
        ipset add allowed-domains "$ip" -exist
    done <<< "$ips"
}

add_github_meta() {
    # GitHub publishes its CIDR blocks. Take web/api/git unions and
    # aggregate so we don't blow past ipset's max-elem default.
    local meta
    meta=$(curl --retry 2 --max-time 10 -fsSL https://api.github.com/meta || true)
    if [[ -z "$meta" ]]; then
        log "warn: api.github.com/meta unreachable; GitHub IPs not seeded"
        return 0
    fi
    local cidrs
    cidrs=$(printf '%s' "$meta" \
        | jq -r '(.web + .api + .git)[] | select(test(":") | not)' \
        | aggregate -q || true)
    if [[ -z "$cidrs" ]]; then
        log "warn: GitHub meta CIDRs empty after aggregate"
        return 0
    fi
    while IFS= read -r cidr; do
        ipset add allowed-domains "$cidr" -exist
    done <<< "$cidrs"
}

populate_allowlist() {
    # Anthropic API surface — Claude Code talks here, plus the statsig
    # feature-flag service and Sentry for crash reports.
    add_domain api.anthropic.com
    add_domain statsig.anthropic.com
    add_domain statsig.com
    add_domain sentry.io

    # OpenAI / Codex — auth, chat backend, API.
    add_domain api.openai.com
    add_domain auth.openai.com
    add_domain chatgpt.com

    # NPM (registry only — installer downloads tarballs from here).
    add_domain registry.npmjs.org

    # Composer / Packagist — PHP package install.
    add_domain repo.packagist.org
    add_domain packagist.org
    add_domain getcomposer.org

    # PyPI — for any MCP / tooling that pip-installs.
    add_domain pypi.org
    add_domain files.pythonhosted.org

    # Rust crates — only matter if a Codex SDK pulls them. Leave on
    # because Codex has shipped Rust components in the past.
    add_domain crates.io
    add_domain index.crates.io
    add_domain static.crates.io
    add_domain static.rust-lang.org

    # Playwright browser blobs.
    add_domain cdn.playwright.dev
    add_domain playwright.azureedge.net
    # Hugging Face is ONLY needed if a Playwright-MCP variant pulls models;
    # commented out by default — uncomment if you hit a download error.
    # add_domain cdn-lfs.huggingface.co

    # MCP servers seeded into config/claude-settings.json.
    # Context7 — library docs lookup.
    add_domain mcp.context7.com
    add_domain context7.com
    # chrome-devtools-mcp downloads Chrome-for-Testing on first launch.
    add_domain storage.googleapis.com
    add_domain googlechromelabs.github.io
    add_domain edgedl.me.gvt1.com

    # Custom deploy target.
    add_domain auth.scalingo.com
    add_domain cli-dl.scalingo.com
    add_domain api.osc-fr1.scalingo.com
    add_domain api.osc-secnum-fr1.scalingo.com
    add_domain scalingo.com

    # VSCode marketplace + update channel — needed by devcontainer mode so
    # extensions can install inside the container.
    add_domain marketplace.visualstudio.com
    add_domain vscode.blob.core.windows.net
    add_domain update.code.visualstudio.com

    # GitHub raw / objects / codeload — needed for `gh repo clone`,
    # raw.githubusercontent.com fetches, and release tarballs.
    # release-assets.githubusercontent.com is GitHub's newer host for binary
    # release artefacts (gitstatusd, etc.) — without it p10k bring-up fails.
    add_domain raw.githubusercontent.com
    add_domain objects.githubusercontent.com
    add_domain release-assets.githubusercontent.com
    add_domain codeload.github.com

    # Bulk GitHub IP blocks (web/api/git).
    add_github_meta

    # User extension point: any space-separated list provided in
    # OPENAI_ALLOWED_DOMAINS at runtime gets appended. This matches the
    # convention from openai/codex's secure profile.
    if [[ -n "${OPENAI_ALLOWED_DOMAINS:-}" ]]; then
        for d in $OPENAI_ALLOWED_DOMAINS; do
            if [[ "$d" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                log "extra allowlist domain: $d"
                add_domain "$d"
            else
                echo "warn: skipping invalid domain in OPENAI_ALLOWED_DOMAINS: $d" >&2
            fi
        done
    fi
}

allow_local_bridge() {
    # When the runtime is attached to a Docker bridge network with sidecars
    # (e.g. the Laravel postgres+redis profile, or run.sh --with-postgres),
    # the agent must be able to reach the sidecar IPs. Those IPs sit in the
    # bridge's private CIDR (typically 172.16/12). We detect every
    # non-default route on a docker bridge interface and allowlist its
    # subnet. This intentionally does NOT widen public egress because the
    # ranges are RFC1918 and not routable upstream.
    local route_lines
    route_lines=$(ip -4 route show | awk '$1 != "default" && $1 ~ /\// && $3 == "dev" {print $1}')
    if [[ -z "$route_lines" ]]; then
        return 0
    fi
    while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        log "allow local bridge subnet: $cidr"
        ipset add allowed-domains "$cidr" -exist
    done <<< "$route_lines"
}

apply_policy() {
    # OUTPUT: only allow the curated set, then default DROP at the bottom.
    iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

    # INPUT: drop by default. Loopback and established are already accepted
    # above, so nothing else gets in.
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP
}

validate() {
    # Sanity probes. We don't fail the script on these — Tim might be
    # offline temporarily — but we surface them so misconfigurations are
    # obvious in the post-start log. We only care that the TCP+TLS
    # handshake completes; HTTP 4xx on the bare host root is fine and
    # was previously misreported as "NOT reachable" because of `-f`.
    probe() {
        local label=$1 url=$2
        local code
        code=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
        if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
            log "ok: $label reachable (HTTP $code)"
        else
            log "warn: $label NOT reachable"
        fi
    }
    probe "api.anthropic.com" https://api.anthropic.com/
    probe "api.openai.com"    https://api.openai.com/
    # Negative control: a non-allowlisted host MUST be blocked. The
    # firewall drops outbound, so curl will time out — `code` ends up 000.
    local control
    control=$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null || echo 000)
    if [[ "$control" == "000" ]]; then
        log "ok: control test (example.com) blocked"
    else
        log "FAIL: example.com is reachable (HTTP $control) — firewall is leaky"
        exit 1
    fi
}

main() {
    require_root
    preserve_docker_dns
    flush_all
    allow_baseline
    populate_allowlist
    allow_local_bridge
    apply_policy
    validate
    log "firewall initialized"
}

main "$@"
