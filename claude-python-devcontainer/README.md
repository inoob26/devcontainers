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
| GitHub CLI | `gh`, also used by git for GitHub over HTTPS. No SSH keys in the container |
| Skills | installed from `skills-list.txt` and copied from your host `~/.claude` |
| Guardrails | a Claude Code hook, an egress firewall, no general sudo, CPU/memory/PID limits |

Persistent named volumes:

- `.venv`: kept separate from the host's `.venv`, so neither breaks the other
- `~/.claude`: Claude login, settings and history survive rebuilds
- `~/.config/gh`: the `gh` login survives rebuilds
- `~/.cache/uv`: shared uv cache

## Usage

1. Copy the `.devcontainer/` folder into the root of your project.
2. Open the project in VS Code (or any Dev Containers–compatible tool) and run
   **Dev Containers: Reopen in Container**.
3. After the build, `post-create.sh` runs `uv sync` if the project has a
   `pyproject.toml`.
4. In the container terminal, run `claude` and log in once. The login is kept in
   a volume.
5. Log in to GitHub with a fine-grained token (see [GitHub access](#github-access)).

To skip permission prompts inside the container:

```bash
claude --dangerously-skip-permissions
```

### Without VS Code

The [Dev Containers CLI](https://github.com/devcontainers/cli) reads the same
`devcontainer.json`, including features, mounts, `runArgs` and lifecycle
commands. Run these from the project root:

```bash
npm install -g @devcontainers/cli

# Build and start the container: runs `initializeCommand` on the host, then
# `post-create.sh`, the firewall and the skill import.
devcontainer up --workspace-folder .

# Open a shell, or start Claude directly.
devcontainer exec --workspace-folder . bash
devcontainer exec --workspace-folder . claude --dangerously-skip-permissions
```

To rebuild after changing `.devcontainer/`, add `--remove-existing-container`
to `devcontainer up`, and `--build-no-cache` to skip Docker's layer cache. To
only check that the image builds, run `devcontainer build --workspace-folder .`.

The CLI has no `down` command. Remove the container with Docker; the named
volumes are kept:

```bash
docker rm -f $(docker ps -aq --filter label=devcontainer.local_folder="$PWD")
```

The CLI doesn't forward your host's git credentials or ssh-agent the way VS
Code does, so it's the stricter way to run the container.

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

## Guardrails

### Claude Code hook

`claude-guard.py` is a `PreToolUse` hook, installed as Claude Code managed
settings in `/etc/claude-code/`. Project and user settings can't override it,
and it also works with `--dangerously-skip-permissions`. It denies:

- reading `.env`, `.env.*` and `*.env` files through Read, Grep or Bash.
  Files ending in `.example` (such as `.env.example`) are allowed.
- `gh repo delete`, and `DELETE` requests to `repos/<owner>/<repo>` through
  `gh api`, `curl` and similar tools.
- force-pushing to or deleting `main`/`master`, and `git push --mirror`.
- `git reset --hard` and `git clean -f`.
- `rm -r` outside the project, of the project root itself or of `.git`.
  `/tmp` is allowed.

The hook catches mistakes but isn't a security boundary. It only reads command
text, so an obfuscated command (`bash -c '...'`, a script file) gets through.

### Network firewall

On every start, `init-firewall.sh` sets iptables rules that block outgoing
traffic except to GitHub and the domains in `firewall-allowlist.txt`. The
rules cover the inner Docker daemon's containers too. This stops leaked
secrets or prompt-injected code from reaching arbitrary servers.

- The allowlist is baked into the image. After editing it, rebuild the
  container.
- Domains are resolved to IPs at start. If an allowed site stops working
  later, rerun `sudo /usr/local/sbin/init-firewall.sh`.
- Claude's WebFetch and WebSearch, MCP servers, and any other hosts are
  blocked until you add them.
- With `DEVCONTAINER_HTTPS_PROXY` set, traffic that goes through the proxy is
  limited only by the proxy.

### No general sudo

`vscode` can run only `init-firewall.sh` and `fix-venv-owner.sh` as root. With
full sudo, Claude could turn off the firewall and the hook. The container
starts as root so that the docker-in-docker entrypoint can start `dockerd`.

`vscode` is in the `docker` group, and the inner daemon is privileged. While
docker-in-docker is enabled, Claude can still get root inside the container
through `docker run`. Remove the feature if the project doesn't need Docker.

### Resource limits

`runArgs` caps the container at 8 GB of memory, 4 CPUs and 4096 processes.
Tune them to your machine.

## GitHub access

The host ssh-agent is not forwarded: it would give Claude every key you have.
Git reaches GitHub over HTTPS with the `gh` token instead. SSH remote URLs
(`git@github.com:...`) are rewritten to HTTPS automatically.

Create a [fine-grained token](https://github.com/settings/personal-access-tokens/new)
that is limited to this repository:

- **Repository access:** only select repositories, just this one.
- **Permissions:** Contents: read and write. Pull requests: read and write.
  Add Workflows only if Claude should edit `.github/workflows`.
- Don't grant **Administration**. Without it, GitHub itself refuses to
  delete the repository or change branch protection.

Then, in the container:

```bash
gh auth login --with-token <<< 'github_pat_...'
```

Also turn on branch protection for `main` on GitHub, so that force-pushes and
deletion are blocked on the server too.

VS Code forwards your host's git credentials and ssh-agent into dev containers
on its own. Turn this off in your host VS Code user settings:

```json
"dev.containers.gitCredentialHelperConfigLocation": "none"
```

Check inside the container that no host credentials got through:
`ssh-add -l` should fail, and `git config --show-origin --get-all credential.helper`
should list only `gh`.

## Customization

- **Python version:** change the base image tag in `Dockerfile`.
- **System packages:** add an `apt-get install` step in `Dockerfile`, where the
  comment shows one.
- **Claude Code version:** pin it in `devcontainer.json`, for example
  `"version": "2.1.280"`.
- **No Docker needed:** remove the `docker-in-docker` feature.
- **Allowed domains:** edit `firewall-allowlist.txt` and rebuild.
- **Resource limits:** change `--memory`, `--cpus` and `--pids-limit` in
  `runArgs`.
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
