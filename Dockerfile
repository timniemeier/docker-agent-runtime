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
# Upstream dandavison/delta does not publish a SHA256SUMS file with releases,
# so these were computed locally against the GitHub release artefacts. Bump
# them when bumping GIT_DELTA_VERSION:
#   curl -fsSL -o /tmp/d.deb https://github.com/dandavison/delta/releases/download/${VERSION}/git-delta_${VERSION}_amd64.deb && sha256sum /tmp/d.deb
ARG GIT_DELTA_SHA256_AMD64=1658c7b61825d411b50734f34016101309e4b6e7f5799944cf8e4ac542cebd7f
ARG GIT_DELTA_SHA256_ARM64=937781aa7788e1510858743fff6c9a8b4a69fe0a22a7c8a69493e633227939a9
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
        postgresql \
        postgresql-contrib \
        redis-server \
        locales \
        tzdata \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen \
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
COPY scripts/init-firewall.sh   /usr/local/bin/init-firewall.sh
COPY scripts/post-create.sh     /usr/local/bin/post-create.sh
COPY scripts/post-start.sh      /usr/local/bin/post-start.sh
COPY scripts/start-services.sh  /usr/local/bin/start-services.sh
COPY scripts/ai                 /usr/local/bin/ai
COPY scripts/mcp-github         /usr/local/bin/mcp-github
COPY scripts/entrypoint.sh      /usr/local/bin/entrypoint.sh
COPY config/claude-settings.json /etc/agent-runtime/claude-settings.json
COPY config/codex-config.toml    /etc/agent-runtime/codex-config.toml

# start-services needs to run postgres as root (to chown the data dir) and
# then sudo -u postgres for the actual server. Allow that without a password.
# SETENV: lets post-start.sh pass NO_POSTGRES/NO_REDIS/NO_SERVICES via `sudo -E`.
RUN echo "node ALL=(root) NOPASSWD: SETENV: /usr/local/bin/start-services.sh" \
        >> /etc/sudoers.d/agent-firewall \
    && echo "node ALL=(postgres) NOPASSWD: ALL" \
        >> /etc/sudoers.d/agent-firewall

RUN chown root:root /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
    && chmod 0755 \
        /usr/local/bin/init-firewall.sh \
        /usr/local/bin/post-create.sh \
        /usr/local/bin/post-start.sh \
        /usr/local/bin/start-services.sh \
        /usr/local/bin/ai \
        /usr/local/bin/mcp-github \
        /usr/local/bin/entrypoint.sh

# --- Playwright browsers (chromium only) -------------------------------------
# OS deps must be installed as root (apt). Browsers themselves install as the
# `node` user so the cache lands at the path mounted as a named volume in
# devcontainer.json / docker-compose.yml. `--with-deps` would try to sudo from
# the build shell where no tty exists, so split the two steps explicitly.
ENV PLAYWRIGHT_BROWSERS_PATH=/home/${USERNAME}/.cache/ms-playwright
RUN npx --yes playwright@latest install-deps chromium \
    && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}
RUN npx --yes playwright@latest install chromium

# --- User shell env -----------------------------------------------------------
ENV CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude
ENV CODEX_HOME=/home/${USERNAME}/.codex
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV DEVCONTAINER=true

# oh-my-zsh + powerlevel10k via zsh-in-docker. We pin the script's SHA-256 and
# verify before piping to sh — same threat model as the git-delta install.
ARG ZSH_IN_DOCKER_VERSION=1.2.0
ARG ZSH_IN_DOCKER_SHA256=f74e5b08c295b6c3886654bb63c688e5ea16c58a4209435c4ddbab2c42fe9b41
RUN curl -fsSL -o /tmp/zsh-in-docker.sh \
        "https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh" && \
    echo "${ZSH_IN_DOCKER_SHA256}  /tmp/zsh-in-docker.sh" | sha256sum -c - && \
    sh /tmp/zsh-in-docker.sh \
        -p git \
        -p fzf \
        -p https://github.com/zsh-users/zsh-autosuggestions \
        -p https://github.com/zsh-users/zsh-syntax-highlighting \
        -a 'source /usr/share/doc/fzf/examples/key-bindings.zsh' \
        -a 'source /usr/share/doc/fzf/examples/completion.zsh' \
        -a 'export HISTFILE=/commandhistory/.zsh_history' \
        -a 'export HISTSIZE=10000' \
        -a 'export SAVEHIST=10000' \
        -a 'setopt INC_APPEND_HISTORY SHARE_HISTORY' \
        -a 'eval "$(direnv hook zsh)"' \
        -a 'export PATH=/usr/local/share/npm-global/bin:$HOME/.composer/vendor/bin:$HOME/.local/bin:$PATH' \
        -x && \
    rm /tmp/zsh-in-docker.sh

# Persistent bash history (zsh history is wired into .zshrc above by -a flags).
RUN { \
        echo 'export HISTFILE=/commandhistory/.bash_history'; \
        echo 'export HISTSIZE=10000'; \
        echo 'export HISTFILESIZE=20000'; \
        echo 'export PROMPT_COMMAND="history -a; ${PROMPT_COMMAND:-}"'; \
    } >> /home/${USERNAME}/.bashrc

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh"]
