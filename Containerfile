# SPDX-License-Identifier: Apache-2.0
#
# Sandbox image for running Claude Code in a rootless Podman container.
#
# The image intentionally contains no privilege-escalation helpers (no sudo,
# no setuid binaries beyond what the base image ships) and runs as an
# unprivileged user.  All persistent state lives in /home/claude, which the
# wrapper script mounts from a named volume.

FROM docker.io/library/debian:bookworm-slim

ARG NODE_MAJOR=22
ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Base tooling that Claude Code (and the code it works on) typically needs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        git \
        git-lfs \
        openssh-client \
        bash-completion \
        less \
        nano \
        vim-tiny \
        procps \
        psmisc \
        file \
        tree \
        unzip \
        zip \
        xz-utils \
        tar \
        gzip \
        bzip2 \
        ripgrep \
        fd-find \
        jq \
        diffutils \
        patch \
        make \
        build-essential \
        pkg-config \
        python3 \
        python3-venv \
        python3-pip \
        pipx \
    && rm -rf /var/lib/apt/lists/*

# Node.js from NodeSource - Claude Code is distributed as an npm package.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# `fd` is called `fdfind` on Debian; give it its usual name.
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Claude Code itself, installed system-wide so that rebuilding the image
# (rather than writing into the persistent volume) is how it gets updated.
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# Drop the setuid/setgid bits from everything in the image.  Nothing in this
# sandbox needs them, and the container also runs with --cap-drop=ALL and
# no-new-privileges, so they would be dead weight at best.
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} + || true

RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home \
        --shell /bin/bash "${USERNAME}" \
    && mkdir -p /home/${USERNAME}/.claude \
                /home/${USERNAME}/.config \
                /home/${USERNAME}/.cache \
                /home/${USERNAME}/.local/bin \
                /home/${USERNAME}/.npm-global \
                /workspace \
    && chown -R "${USER_UID}:${USER_GID}" /home/${USERNAME} /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER ${USERNAME}
ENV HOME=/home/${USERNAME} \
    NPM_CONFIG_PREFIX=/home/${USERNAME}/.npm-global \
    PATH=/home/${USERNAME}/.npm-global/bin:/home/${USERNAME}/.local/bin:/usr/local/bin:/usr/bin:/bin \
    DISABLE_AUTOUPDATER=1

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
