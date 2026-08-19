# Ubuntu 26.04 dev container for namo_complete.
#
# The point of this container is blast-radius containment: an agent working in
# here can only reach /workspace and the container filesystem, never the host.
# Keep it that way -- do not add a docker.sock mount or a host $HOME mount.

FROM ubuntu:26.04

ARG SUN_DEB_URL=https://github.com/namo-robotics/sun/releases/download/dev/sun_0.dev_amd64.deb
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive
ENV SUN_PATH=/usr/lib/sun

# Runtime + build tooling. `curl` is a hard runtime dependency of
# namo_complete itself (Sun has no TLS, so HTTPS goes through curl).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        git \
        bash \
        less \
        file \
        procps \
        xz-utils \
        build-essential \
        libllvm20 \
        libstdc++6 \
        libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*

# Sun toolchain (~152 MB .deb).
RUN curl -fsSL -o /tmp/sun.deb "${SUN_DEB_URL}" \
    && apt-get update \
    && (dpkg -i /tmp/sun.deb || apt-get install -y -f --no-install-recommends) \
    && rm -f /tmp/sun.deb \
    && rm -rf /var/lib/apt/lists/* \
    && sun --version

# Node + Claude Code, so the agent runs inside the container rather than on the host.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# Non-root user owning the workspace.
RUN if getent group ${USER_GID} >/dev/null; then \
        groupmod -n ${USERNAME} "$(getent group ${USER_GID} | cut -d: -f1)"; \
    else \
        groupadd --gid ${USER_GID} ${USERNAME}; \
    fi \
    && if getent passwd ${USER_UID} >/dev/null; then \
        usermod -l ${USERNAME} -d /home/${USERNAME} -m \
            "$(getent passwd ${USER_UID} | cut -d: -f1)"; \
    else \
        useradd --uid ${USER_UID} --gid ${USER_GID} -m ${USERNAME}; \
    fi \
    && mkdir -p /workspace \
    && chown -R ${USER_UID}:${USER_GID} /workspace /home/${USERNAME}

# The marker .claude/hooks/require-devcontainer.sh looks for. The repo's
# .claude/settings.json turns Claude Code's permission prompts off, and that
# hook blocks every tool call unless this file is present -- so the prompt-free
# setting takes effect in here and nowhere else. Written as root, before the
# USER switch, so nothing running in the container can forge it later.
RUN touch /etc/namo-devcontainer

USER ${USERNAME}
WORKDIR /workspace

# XDG dirs namo_complete uses for its cache and its 0600 curl config.
ENV XDG_CACHE_HOME=/home/${USERNAME}/.cache \
    XDG_RUNTIME_DIR=/home/${USERNAME}/.runtime \
    PATH=/home/${USERNAME}/.local/bin:${PATH}

RUN mkdir -p /home/${USERNAME}/.cache /home/${USERNAME}/.runtime /home/${USERNAME}/.local/bin \
    && chmod 700 /home/${USERNAME}/.runtime

# Claude Code's config dir. devcontainer.json mounts a named volume here so the
# OAuth credentials survive a rebuild; this mkdir is what makes that volume come
# up owned by ${USERNAME}, since Docker seeds a new volume from whatever the
# image has at the mount point (and creates it root-owned if that is nothing).
# Deliberately empty otherwise: the prompt-free settings live in the repo, at
# /workspace/.claude/settings.json, where a PreToolUse hook holds them to this
# container. Do not put a settings.json in here -- it would be unguarded, and
# the volume would pin its first version forever.
RUN mkdir -p /home/${USERNAME}/.claude

CMD ["bash"]
