#!/usr/bin/env bash
# Runs IN THE CONTAINER on every start (`postStartCommand`), after
# `install-skills.sh`: copies what `claude-host-export.sh` collected on the host
# into `~/.claude`. On a name clash with a skill from `skills-list.txt` the host
# version wins.
#
# Copied into the volume rather than mounted over `~/.claude/skills`: Claude
# itself writes `skills/synced` there, which a read-only mount would break.
set -euo pipefail

src=/opt/claude-host
dst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# What came from the host last time: items removed on the host are removed here
# too, while things installed manually inside the container are left alone.
manifest="$dst/.from-host"

if [[ -f "$manifest" ]]; then
    while IFS= read -r rel; do
        [[ -n "$rel" ]] && rm -rf "${dst:?}/$rel"
    done < "$manifest"
fi
: > "$manifest"

for kind in skills agents commands; do
    mkdir -p "$dst/$kind"
    for item in "$src/$kind"/*; do
        [[ -e "$item" ]] || continue
        name="$(basename "$item")"
        rm -rf "${dst:?}/$kind/$name"
        cp -r "$item" "$dst/$kind/$name"
        echo "$kind/$name" >> "$manifest"
    done
done
echo "claude-host-import: imported $(wc -l < "$manifest") skills/agents/commands from host" >&2
