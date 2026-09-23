# claude-python-devcontainer

A [Dev Container](https://containers.dev/) template for Python projects with
[uv](https://docs.astral.sh/uv/) and [Claude Code](https://docs.claude.com/en/docs/claude-code)
preinstalled. Claude Code runs in an isolated container, so you can let it work
without permission prompts and it still can't touch your host.

## What's inside

| Component | Details |
|---|---|
| Base image | `mcr.microsoft.com/devcontainers/python:3.14-trixie` |
| Python tooling | `uv` (pinned), `pre-commit` |
| Claude Code | official `anthropics/devcontainer-features/claude-code` feature |
| Node.js | LTS (required by Claude Code) |
| Docker | docker-in-docker: a daemon of its own, not the host socket |
| GitHub CLI | `gh` |
| SSH | host ssh-agent forwarded, GitHub host keys pinned |
| Skills | installed from `skills-list.txt` and copied from your host `~/.claude` |

Persistent named volumes:

- `.venv`: kept separate from the host's `.venv`, so neither breaks the other
- `~/.claude`: Claude login, settings and history survive rebuilds
- `~/.cache/uv`: shared uv cache

## Usage

1. Copy the `.devcontainer/` folder into the root of your project.
2. Open the project in VS Code (or any Dev Containers–compatible tool) and run
   **Dev Containers: Reopen in Container**.
3. After the build, `post-create.sh` runs `uv sync` if the project has a
   `pyproject.toml`.
4. In the container terminal, run `claude` and log in once. The login is kept in
   a volume.

To skip permission prompts inside the container:

```bash
claude --dangerously-skip-permissions
```

## Claude Code skills

Skills reach the container in two ways. Both run on every container start.

### 1. `skills-list.txt`: shared with your team

List skills as GitHub URLs in `.devcontainer/skills-list.txt`, one per line:

```text
# a folder containing SKILL.md
https://github.com/jeffallan/claude-skills/tree/main/skills/devops-engineer
# pin to a tag or commit SHA for reproducibility
https://github.com/jeffallan/claude-skills/tree/<sha>/skills/golang-pro
# a repo with SKILL.md at its root
https://github.com/<owner>/<repo>
```

`install-skills.sh` fetches only the listed folders (shallow, sparse git
fetch) into `~/.claude/skills/<folder-name>`. Remove a line and the skill is
removed on the next start. Skills you install any other way are left alone.
A failed download is reported but never blocks the container start.

The template ships with a starter list of MIT-licensed skills from
[jeffallan/claude-skills](https://github.com/jeffallan/claude-skills) and
[softaworks/agent-toolkit](https://github.com/softaworks/agent-toolkit). Edit
it to fit your project.

### 2. From your host: personal

Before each start, `claude-host-export.sh` runs on the host and copies
`~/.claude/{skills,agents,commands}` into `.devcontainer/.claude-host/`, which
is git-ignored. Inside the container, `claude-host-import.sh` copies them into
`~/.claude`. On a name clash, the host version wins over `skills-list.txt`. The
container never gets write access to your host's `~/.claude`.

## Customization

- **Python version:** change the base image tag in `Dockerfile`.
- **System packages:** add an `apt-get install` step in `Dockerfile`, where the
  comment shows one.
- **Claude Code version:** pin it in `devcontainer.json`, for example
  `"version": "2.1.280"`.
- **No Docker needed:** remove the `docker-in-docker` feature.
- **No ssh-agent:** remove the `/ssh-agent` mount and `SSH_AUTH_SOCK` from
  `devcontainer.json`. The mount fails when `SSH_AUTH_SOCK` isn't set on the
  host.
- **Proxy:** on the host, set
  `DEVCONTAINER_HTTPS_PROXY=http://host.docker.internal:<port>`. The proxy must
  listen on the docker bridge address.
- **Extra setup:** add one-time steps to `post-create.sh`.

## Notes

- The project is mounted at the **same absolute path** as on the host, not
  under `/workspaces/...`. Absolute paths written by git worktrees, pre-commit
  and `.claude/settings.local.json` then stay valid on both sides.
- The container runs as `vscode`, not root, because Claude Code refuses
  `--dangerously-skip-permissions` as root.

## License

[MIT](../LICENSE). Skills downloaded from `skills-list.txt` keep their own
upstream licenses.
