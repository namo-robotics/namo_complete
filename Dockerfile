# syntax=docker/dockerfile:1
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core tools
    git python3 python3-pip \
    # Quality-of-life tools
    vim less htop wget curl unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Debian packaging tools (scripts/build-deb.sh)
    debhelper devscripts \
    openssh-client \
    sudo \
    bash-completion \
    locales \
    # Cross-compilation to AArch64: toolchain+sysroot to link `sun --target
    # aarch64-linux-gnu -c` output, qemu-user to run the result on x86
    # (qemu-aarch64 -L /usr/aarch64-linux-gnu <binary>)
    g++-aarch64-linux-gnu \
    qemu-user \
    && locale-gen en_US.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Install the rolling Sun compiler together with its matching stdlib and TLS
# bundles. apt resolves the LLVM runtime declared by the package.
RUN curl -fsSL -o /tmp/sun.deb \
      https://github.com/namo-robotics/sun/releases/download/dev/sun_0.dev_amd64.deb \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/sun.deb \
 && sun --version \
 && rm -f /tmp/sun.deb \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# musl cross toolchains (musl.cc): the default link mode is static, and
# static links prefer musl — designed for static linking (no NSS dlopen),
# MIT-licensed, and roughly half the binary size of static glibc. These
# bundles include a musl-built libstdc++ for Sun's exception runtime, which
# Ubuntu's glibc-built libstdc++.a cannot provide.
RUN mkdir -p /opt/cross \
 && curl -sL https://musl.cc/aarch64-linux-musl-cross.tgz | tar xz -C /opt/cross \
 && curl -sL https://musl.cc/x86_64-linux-musl-cross.tgz | tar xz -C /opt/cross
ENV PATH="/opt/cross/aarch64-linux-musl-cross/bin:/opt/cross/x86_64-linux-musl-cross/bin:${PATH}"

# GitHub CLI from the official apt repo (newer than the Ubuntu archive build)
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Grant sudo to existing ubuntu user (UID 1000 already exists in Ubuntu 24.04+)
RUN echo "ubuntu ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

# Eager-load git completion (needed for alias completion)
RUN echo '[ -f /usr/share/bash-completion/completions/git ] && . /usr/share/bash-completion/completions/git' > /etc/profile.d/git-completion.sh

CMD ["/bin/bash"]