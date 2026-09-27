#!/usr/bin/env bash
# Runs as root from `post-create.sh`, via sudo: the `.venv` named volume is
# created as root, this hands it to `vscode`.
#
# Takes no arguments on purpose: `vscode` may run it via sudo, so it must not
# chown a path it's given. The `.venv` volume is the only mount point named
# `.venv`, and `vscode` can't create mount points.
set -euo pipefail

findmnt -rn -o TARGET | while read -r target; do
    # `findmnt -r` escapes spaces as `\x20`.
    target="$(printf '%b' "$target")"
    if [[ "$target" == */.venv ]]; then
        chown vscode:vscode "$target"
    fi
done
