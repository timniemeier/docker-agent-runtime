# syntax=docker/dockerfile:1.7

# Agent Runtime image: Claude Code + Codex CLI + Laravel toolchain.
# Base on node:22-bookworm so npm globals install cleanly and the image stays
# close to the upstream Anthropic/OpenAI devcontainer setups.
FROM node:22-bookworm

ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG PHP_VERSION=8.5
ARG TZ=Europe/Berlin
ARG USERNAME=node
ARG GIT_DELTA_VERSION=0.18.2
# TODO(security): pin SHA-256 — upstream dandavison/delta does not publish a
# SHA256SUMS file with releases. Compute the hashes once locally:
#   curl -fsSL -o /tmp/d.deb https://github.com/dandavison/delta/releases/download/0.18.2/git-delta_0.18.2_amd64.deb && sha256sum /tmp/d.deb
#   curl -fsSL -o /tmp/d.deb https://github.com/dandavison/delta/releases/download/0.18.2/git-delta_0.18.2_arm64.deb && sha256sum /tmp/d.deb
# then replace the placeholders below. Until then, the build will fail with a
# checksum mismatch (intentional — a build that silently skipped the check
# would be worse than one that loudly fails).
ARG GIT_DELTA_SHA256_AMD64=REPLACE_ME_AMD64
ARG GIT_DELTA_SHA256_ARM64=REPLACE_ME_ARM64
ARG COMPOSER_VERSION=2.7.7

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=${TZ}

# --- Base system packages -----------------------------------------------------
# iptables/ipset/aggregate: required by init-firewall.sh for the egress
# allowlist. bubblewrap: needed for Codex's nested sandbox profile (made
# setuid below). The rest is the everyday dev shell Tim expects.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg2 \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        iptables \
        ipset \
        iproute2 \
        dnsutils \
        aggregate \
        bubblewrap \
        git \
        gh \
        ripgrep \
        fd-find \
        bat \
        jq \
        less \
        fzf \
        zsh \
        man-db \
        unzip \
        tmux \
        direnv \
        nano \
        vim \
        procps \
        sudo \
        python3 \
        python3-pip \
        python3-venv \
        tzdata \
    && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

# bubblewrap must be setuid for unprivileged user-namespace sandboxing.
RUN chmod u+s /usr/bin/bwrap

# --- git-delta (pinned + checksum verified) ----------------------------------
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) EXPECTED_SHA="$GIT_DELTA_SHA256_AMD64" ;; \
      arm64) EXPECTED_SHA="$GIT_DELTA_SHA256_ARM64" ;; \
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/git-delta.deb "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    echo "$EXPECTED_SHA  /tmp/git-delta.deb" | sha256sum -c - && \
    dpkg -i /tmp/git-delta.deb && \
    rm /tmp/git-delta.deb

# --- PHP from deb.sury.org ----------------------------------------------------
RUN curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/sury-php.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-pgsql \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-sqlite3 \
        php${PHP_VERSION}-gd \
    && update-alternatives --set php /usr/bin/php${PHP_VERSION} || true \
    && rm -rf /var/lib/apt/lists/*

# --- Composer (verified installer) -------------------------------------------
# Pull the published SHA, verify, then install pinned version to a stable path.
RUN EXPECTED_SIG=$(curl -fsSL https://composer.github.io/installer.sig) \
    && curl -fsSL -o /tmp/composer-setup.php https://getcomposer.org/installer \
    && ACTUAL_SIG=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');") \
    && if [ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]; then echo "Composer installer checksum mismatch" >&2; exit 1; fi \
    && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --version=${COMPOSER_VERSION} \
    && rm /tmp/composer-setup.php

# --- npm globals --------------------------------------------------------------
# Move the global prefix out of /usr/lib/node_modules so it lives under a
# writable, easy-to-mount location and doesn't fight with the base image's npm.
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/usr/local/share/npm-global/bin:/home/${USERNAME}/.composer/vendor/bin:/home/${USERNAME}/.local/bin:${PATH}
RUN mkdir -p ${NPM_CONFIG_PREFIX} \
    && npm install -g \
        @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
        @openai/codex@${CODEX_VERSION} \
        @playwright/mcp \
    && npm cache clean --force

# --- User & directory layout --------------------------------------------------
# Reuse the base image's `node` user (UID 1000). Pre-create the dirs we'll
# either mount as named volumes or seed from /etc/agent-runtime/.
RUN mkdir -p \
        /workspace \
        /home/${USERNAME}/.claude \
        /home/${USERNAME}/.codex \
        /home/${USERNAME}/.config/gh \
        /home/${USERNAME}/.composer \
        /home/${USERNAME}/.cache/ms-playwright \
        /home/${USERNAME}/.local/bin \
        /commandhistory \
        /etc/agent-runtime \
    && touch /commandhistory/.bash_history /commandhistory/.zsh_history \
    && chown -R ${USERNAME}:${USERNAME} \
        /workspace \
        /home/${USERNAME}/.claude \
        /home/${USERNAME}/.codex \
        /home/${USERNAME}/.config \
        /home/${USERNAME}/.composer \
        /home/${USERNAME}/.cache \
        /home/${USERNAME}/.local \
        /commandhistory

# Sudoers: only the firewall init script, nothing else. Tim's the auditor here
# so the rule is intentionally narrow.
RUN echo "${USERNAME} ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
        > /etc/sudoers.d/agent-firewall \
    && chmod 0440 /etc/sudoers.d/agent-firewall

# --- Copy scripts and config templates ---------------------------------------
COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY scripts/post-create.sh   /usr/local/bin/post-create.sh
COPY scripts/post-start.sh    /usr/local/bin/post-start.sh
COPY scripts/ai               /usr/local/bin/ai
COPY scripts/entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY config/claude-settings.json /etc/agent-runtime/claude-settings.json
COPY config/codex-config.toml    /etc/agent-runtime/codex-config.toml

RUN chown root:root /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
    && chmod 0755 \
        /usr/local/bin/init-firewall.sh \
        /usr/local/bin/post-create.sh \
        /usr/local/bin/post-start.sh \
        /usr/local/bin/ai \
        /usr/local/bin/entrypoint.sh

# --- Playwright browsers (chromium only) -------------------------------------
# Install as the `node` user so the cache lands at the path mounted as a named
# volume in devcontainer.json / docker-compose.yml.
ENV PLAYWRIGHT_BROWSERS_PATH=/home/${USERNAME}/.cache/ms-playwright
USER ${USERNAME}
RUN npx --yes playwright@latest install --with-deps chromium

# --- User shell env -----------------------------------------------------------
ENV CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude
ENV CODEX_HOME=/home/${USERNAME}/.codex
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV DEVCONTAINER=true

# Persistent shell history lives on a named volume so it survives rebuilds.
RUN { \
        echo 'export HISTFILE=/commandhistory/.bash_history'; \
        echo 'export HISTSIZE=10000'; \
        echo 'export HISTFILESIZE=20000'; \
        echo 'export PROMPT_COMMAND="history -a; ${PROMPT_COMMAND:-}"'; \
    } >> /home/${USERNAME}/.bashrc \
    && { \
        echo 'export HISTFILE=/commandhistory/.zsh_history'; \
        echo 'export HISTSIZE=10000'; \
        echo 'export SAVEHIST=10000'; \
        echo 'setopt INC_APPEND_HISTORY SHARE_HISTORY'; \
        echo 'eval "$(direnv hook zsh)"'; \
        echo 'export PATH=/usr/local/share/npm-global/bin:$HOME/.composer/vendor/bin:$HOME/.local/bin:$PATH'; \
    } >> /home/${USERNAME}/.zshrc

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh"]
