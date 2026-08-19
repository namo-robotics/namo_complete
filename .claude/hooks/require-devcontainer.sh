#!/usr/bin/env bash
# Refuse to let Claude Code do anything outside this project's dev container.
#
# .claude/settings.json turns permission prompts off wholesale
# (permissions.defaultMode = bypassPermissions). That is only defensible
# because the container is the blast-radius boundary: nothing of the host is
# visible but /workspace, there is no docker.sock, and every capability is
# dropped. On a host checkout the same setting would hand out unprompted access
# to the whole machine, so this hook denies every tool call there instead.
#
# Wired up as a PreToolUse hook on every tool; exit 2 blocks the call and puts
# the reason in front of Claude. Anything else (including a missing marker file
# read error) falls through to the deny at the bottom -- fail closed.
set -uo pipefail

# Written by .devcontainer/Dockerfile as root, before the USER switch, so a
# session inside the container cannot forge it after the fact.
if [ -f /etc/namo-devcontainer ]; then
  exit 0
fi

# Images built before that marker existed: a container (docker or podman)
# holding the devcontainer's bind mount. Drop this branch once every image has
# been rebuilt.
if { [ -f /.dockerenv ] || [ -f /run/.containerenv ]; } && [ -d /workspace ]; then
  exit 0
fi

cat >&2 <<'EOF'
namo_complete: refusing to run outside the dev container.

This repo's .claude/settings.json disables permission prompts, which is only
safe inside .devcontainer/. Reopen the folder in the container ("Dev Containers:
Reopen in Container"), or delete permissions.defaultMode from
.claude/settings.json if you really mean to work on the host.
EOF
exit 2
