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
        openssh-client \
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

# Marker for anything that needs to assert "we are inside the dev container".
# Written as root, before the USER switch, so nothing running in the container
# can forge it later.
RUN touch /etc/namo-devcontainer

USER ${USERNAME}
WORKDIR /workspace

# XDG dirs namo_complete uses for its cache and its 0600 curl config.
ENV XDG_CACHE_HOME=/home/${USERNAME}/.cache \
    XDG_RUNTIME_DIR=/home/${USERNAME}/.runtime \
    PATH=/home/${USERNAME}/.local/bin:${PATH}

RUN mkdir -p /home/${USERNAME}/.cache /home/${USERNAME}/.runtime /home/${USERNAME}/.local/bin \
    && chmod 700 /home/${USERNAME}/.runtime

# Git over SSH. No private key ever enters this container: VS Code forwards the
# host's ssh-agent socket and sets SSH_AUTH_SOCK, so signing happens on the host
# and only the signature crosses in. All this image needs is the ssh client
# (installed above) plus GitHub's host keys, so the first connection does not
# fail host-key verification with nobody around to answer the prompt.
#
# Keys are GitHub's published set (https://api.github.com/meta -> .ssh_keys),
# pinned here rather than ssh-keyscan'd at build time so the value is reviewable
# in the diff instead of trusted-on-first-use from whatever answered at build.
RUN mkdir -p /home/${USERNAME}/.ssh \
    && chmod 700 /home/${USERNAME}/.ssh \
    && printf '%s\n' \
        'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
        'github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=' \
        'github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=' \
        > /home/${USERNAME}/.ssh/known_hosts \
    && chmod 600 /home/${USERNAME}/.ssh/known_hosts

CMD ["bash"]
