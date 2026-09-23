#!/usr/bin/env bash
# Runs once after the container is created: brings the project's `.venv` to a
# working state. Add your own one-time setup at the end.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# `.venv` is a named volume on top of the bind mount and is created as root.
sudo chown "$(id -u):$(id -g)" .venv

if [[ ! -f pyproject.toml ]]; then
    echo "post-create: no pyproject.toml -- skipping uv sync (run 'uv init' to start)" >&2
    exit 0
fi

# With a lockfile install exactly what's locked; without one, resolve and
# create it.
if [[ -f uv.lock ]]; then
    echo "post-create: uv sync --locked --all-extras" >&2
    uv sync --locked --all-extras
else
    echo "post-create: uv sync --all-extras (no uv.lock yet)" >&2
    uv sync --all-extras
fi

echo "post-create: done" >&2
