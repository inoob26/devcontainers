#!/usr/bin/env python3
"""Claude Code `PreToolUse` hook, wired up in `managed-settings.json`.

Denies:
  - reading `.env` files (`.env`, `.env.local`, `prod.env`, ...) via Read, Grep
    or any Bash command that mentions one; templates ending in `.example` are
    allowed;
  - deleting a GitHub repository via `gh repo delete` or a `DELETE` request to
    the `repos/<owner>/<repo>` API endpoint (`gh api`, `curl`, ...);
  - force-pushing to or deleting `main`/`master`, and `git push --mirror`;
  - `git reset --hard` and `git clean -f`: they throw away uncommitted work;
  - `rm -r` outside the project, of the project root itself or of its `.git`;
    `/tmp` is allowed.

A guardrail against mistakes, not a sandbox: an obfuscated command (`cat .e*`,
`bash -c '...'`, a script file) gets through. It also runs under
`--dangerously-skip-permissions`.
"""

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path, PurePosixPath

PROTECTED_BRANCHES = {"main", "master"}

# Words of a shell command that may be file names or globs.
SHELL_WORD = re.compile(r"[\w.*?\[\]-]+")

GH_REPO_DELETE = re.compile(r"\bgh\s+repo\s+delete\b")
DELETE_METHOD = re.compile(r"\bDELETE\b", re.IGNORECASE)
# `repos/<owner>/<repo>` with nothing after it: deleting the repo itself, not a
# branch, label or comment inside it.
REPO_ENDPOINT = re.compile(r"(?:^|[\s'\"/])repos/[^/\s'\"?#]+/[^/\s'\"?#]+/?(?=$|[\s'\"?#])")

# Leading words that run the rest of the line as a command: `FOO=1 sudo rm ...`.
ASSIGNMENT = re.compile(r"^[A-Za-z_]\w*=")
WRAPPERS = {"command", "env", "exec", "nice", "nohup", "sudo", "time"}
# `-rf`, `-uf`: a cluster of short flags.
SHORT_FLAGS = re.compile(r"-[A-Za-z]+")
# Global git options that take a separate value: `git -C dir push`.
GIT_OPTS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
PUSH_OPTS_WITH_VALUE = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


def is_secret_env(name: str) -> bool:
    if name.endswith(".example"):
        return False
    if name.startswith(".env") and any(c in name for c in "*?["):
        return True
    return name == ".env" or name.startswith(".env.") or name.endswith(".env")


def has_flag(args: list[str], letters: str, long: tuple[str, ...]) -> bool:
    return any(
        a.startswith(long) if a.startswith("--") else SHORT_FLAGS.fullmatch(a) and any(c in a for c in letters)
        for a in args
    )


def split_commands(command: str) -> list[list[str]]:
    """`FOO=1 a x && b | c` -> [["a", "x"], ["b"], ["c"]]."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:  # unbalanced quotes
        tokens = command.split()

    commands: list[list[str]] = [[]]
    for token in tokens:
        if token and all(c in "();<>|&" for c in token):
            commands.append([])
        else:
            commands[-1].append(token)

    result = []
    for words in commands:
        while words and (ASSIGNMENT.match(words[0]) or words[0] in WRAPPERS):
            words = words[1:]
        if words:
            result.append(words)
    return result


def current_branch(workdir: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", workdir, "symbolic-ref", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout.strip()


def check_path(path: str | None) -> str | None:
    if path and is_secret_env(PurePosixPath(path).name):
        return f"Reading `{path}` is blocked: .env files hold secrets. Use `.env.example` or ask the user."
    return None


def check_push(args: list[str], workdir: str) -> str | None:
    if "--mirror" in args:
        return "`git push --mirror` is blocked: it overwrites and deletes remote branches."

    positional = []
    words = iter(args)
    for a in words:
        if a in PUSH_OPTS_WITH_VALUE:
            next(words, None)
        elif not a.startswith("-"):
            positional.append(a)
    refspecs = positional[1:]  # the first one is the remote

    force = has_flag(args, "f", ("--force",)) or any(r.startswith("+") for r in refspecs)
    delete = has_flag(args, "d", ("--delete",)) or any(r.startswith(":") for r in refspecs)
    if not (force or delete):
        return None

    if "--all" in args or "--branches" in args:
        targets = set(PROTECTED_BRANCHES)
    elif refspecs:
        targets = set()
        for r in refspecs:
            dst = r.lstrip("+").split(":")[-1].removeprefix("refs/heads/")
            targets.add(current_branch(workdir) if dst == "HEAD" else dst)
    else:
        targets = {current_branch(workdir)}

    if hit := targets & PROTECTED_BRANCHES:
        return f"Force-pushing to or deleting `{', '.join(sorted(hit))}` is blocked. Ask the user to do it."
    return None


def check_git(words: list[str], cwd: str) -> str | None:
    workdir = cwd
    i = 1
    while i < len(words) and words[i].startswith("-"):
        if words[i] in GIT_OPTS_WITH_VALUE:
            if words[i] == "-C" and i + 1 < len(words):
                workdir = os.path.join(workdir, words[i + 1])
            i += 2
        else:
            i += 1
    if i >= len(words):
        return None
    sub, args = words[i], words[i + 1:]

    if sub == "push":
        return check_push(args, workdir)
    if sub == "reset" and "--hard" in args:
        return "`git reset --hard` is blocked: it discards uncommitted work. Use `git stash` or ask the user."
    if sub == "clean" and has_flag(args, "f", ("--force",)):
        return "`git clean -f` is blocked: it deletes untracked files. List them with `git clean -n` and ask the user."
    return None


def check_rm(args: list[str], cwd: str, project: Path) -> str | None:
    if not has_flag(args, "rR", ("--recursive",)):
        return None

    if "--" in args:
        paths = args[args.index("--") + 1:]
    else:
        paths = [a for a in args if not a.startswith("-")]

    for raw in paths:
        path = os.path.expandvars(os.path.expanduser(raw))
        if "$" in path:
            return f"`rm -r {raw}` is blocked: can't tell where `{raw}` points."
        # For a glob, check the directory it expands in: `build/*` -> `build`.
        if glob := re.search(r"[*?\[]", path):
            path = os.path.dirname(path[: glob.start()]) or "."
        full = Path(os.path.normpath(os.path.join(cwd, path)))
        # Resolve symlinks in the parent only: `rm -r link` removes the link.
        full = full.parent.resolve() / full.name if full.name else full

        in_project = full.is_relative_to(project) and full != project and not full.is_relative_to(project / ".git")
        in_tmp = full.is_relative_to("/tmp") and full != Path("/tmp")
        if not (in_project or in_tmp):
            return f"`rm -r {raw}` is blocked: only paths inside the project (not its root or `.git`) or `/tmp` may be removed."
    return None


def check_bash(command: str, cwd: str, project: Path) -> str | None:
    for word in SHELL_WORD.findall(command):
        if is_secret_env(PurePosixPath(word).name):
            return f"Command touches `{word}`: .env files hold secrets. Use `.env.example` or ask the user."
    if GH_REPO_DELETE.search(command) or (DELETE_METHOD.search(command) and REPO_ENDPOINT.search(command)):
        return "Deleting a GitHub repository is blocked. Ask the user to do it themselves."

    for words in split_commands(command):
        name = PurePosixPath(words[0]).name
        if name == "git":
            reason = check_git(words, cwd)
        elif name == "rm":
            reason = check_rm(words[1:], cwd, project)
        else:
            reason = None
        if reason:
            return reason
    return None


def main() -> None:
    event = json.load(sys.stdin)
    tool = event.get("tool_name")
    args = event.get("tool_input") or {}
    cwd = event.get("cwd") or os.getcwd()
    project = Path(os.environ.get("CLAUDE_PROJECT_DIR") or cwd).resolve()

    if tool == "Read":
        reason = check_path(args.get("file_path"))
    elif tool == "Grep":
        reason = check_path(args.get("path")) or check_path(args.get("glob"))
    elif tool == "Bash":
        reason = check_bash(args.get("command", ""), cwd, project)
    else:
        reason = None

    if reason:
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            },
            sys.stdout,
        )


if __name__ == "__main__":
    main()
