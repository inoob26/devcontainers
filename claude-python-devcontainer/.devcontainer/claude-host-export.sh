#!/usr/bin/env bash
# Runs ON THE HOST before every container start (`initializeCommand`): copies
# your personal Claude Code skills, agents and commands from `~/.claude` into
# `.devcontainer/.claude-host/`, which the container mounts read-only.
#
# A copy instead of bind-mounting `~/.claude/skills` directly: skills and agents
# are often symlinks with absolute host paths that would dangle inside the
# container. `cp -L` resolves them into files. It also keeps the container,
# where Claude may run without permission prompts, from writing to the host's
# `~/.claude`.
set -uo pipefail

src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dst="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.claude-host"

rm -rf "$dst"
mkdir -p "$dst"/{skills,agents,commands}

for kind in skills agents commands; do
    [[ -d "$src/$kind" ]] || continue
    for item in "$src/$kind"/*; do
        [[ -e "$item" ]] || continue   # empty dir or dangling symlink
        # `skills/synced` -- skills Claude syncs with the account itself; inside
        # the container it does that after login.
        [[ "$kind" == skills && "$(basename "$item")" == synced ]] && continue
        cp -rL "$item" "$dst/$kind/" \
            || echo "claude-host-export: failed to copy $item" >&2
    done
done
# Personal skills must never block the container from starting.
exit 0
