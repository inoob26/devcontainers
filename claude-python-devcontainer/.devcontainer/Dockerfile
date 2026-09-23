# syntax=docker/dockerfile:1

# Development image, not for deployment: it carries the toolchain and Claude
# Code, the code itself arrives via bind mount.

# uv is taken as a binary from the official image, pinned by version.
FROM ghcr.io/astral-sh/uv:0.12.15 AS uv

# The base already has Python 3.14 as `python3`, the `vscode` user (uid 1000),
# sudo, git and make. Change the tag to match your project's Python version.
FROM mcr.microsoft.com/devcontainers/python:3.14-trixie

COPY --from=uv /uv /uvx /usr/local/bin/

# System libraries your project needs at runtime go here, e.g.:
# RUN apt-get update \
#     && apt-get install -y --no-install-recommends libmagic1 \
#     && rm -rf /var/lib/apt/lists/*

# GitHub host keys are pinned and checked against `ssh_keys` from
# https://api.github.com/meta instead of `ssh-keyscan` at build time: otherwise
# the first build on an untrusted network would silently trust whoever answered.
RUN cat >> /etc/ssh/ssh_known_hosts <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
EOF

# A pre-commit git hook remembers the absolute python path of the venv it was
# installed from and, if missing, falls back to `pre-commit` on PATH. A hook
# installed on the host therefore still works inside the container.
RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin \
    uv tool install pre-commit==4.6.0

# A fresh named volume inherits the owner of the directory from the image.
# Without this `~/.claude` is mounted as root and Claude Code can't write to it.
RUN install -d -o vscode -g vscode /home/vscode/.claude /home/vscode/.cache /home/vscode/.cache/uv

# Single Python -- the system one from the base image: uv doesn't download its
# own and can't diverge from the one used by hooks. `copy` because the uv cache
# and `.venv` are on different volumes, so hardlinks are impossible.
ENV UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-system \
    UV_LINK_MODE=copy

USER vscode
