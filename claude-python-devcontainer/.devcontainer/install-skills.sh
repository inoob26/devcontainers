#!/usr/bin/env bash
# Runs IN THE CONTAINER on every start (`postStartCommand`): downloads the
# skills listed in `skills-list.txt` into `~/.claude/skills`.
#
# Each repo is fetched once, shallow and sparse: only the listed folders are
# downloaded, not the whole history or tree. A failed skill (no network, typo in
# the URL) is reported and skipped -- it never blocks the container start.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list="$here/skills-list.txt"
dst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
# What this script installed last time: skills removed from the list are
# removed here too, while skills installed any other way are left alone.
manifest="$dst/.from-skills-list"

mkdir -p "$dst"
if [[ -f "$manifest" ]]; then
    while IFS= read -r name; do
        [[ -n "$name" ]] && rm -rf "${dst:?}/$name"
    done < "$manifest"
fi
: > "$manifest"

[[ -f "$list" ]] || { echo "install-skills: no $list, nothing to install" >&2; exit 0; }

# "<owner>/<repo> <ref>" -> newline-separated skill paths within the repo.
declare -A paths=()
failed=()

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -n "$line" ]] || continue
    if [[ "$line" =~ ^https://github\.com/([^/]+)/([^/]+)/tree/([^/]+)/(.+[^/])/?$ ]]; then
        repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; ref="${BASH_REMATCH[3]}"; path="${BASH_REMATCH[4]}"
    elif [[ "$line" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
        repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"; ref=HEAD; path=.
    else
        echo "install-skills: unsupported URL, skipping: $line" >&2
        failed+=("$line")
        continue
    fi
    paths["$repo $ref"]+="$path"$'\n'
done < "$list"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for key in "${!paths[@]}"; do
    read -r repo ref <<< "$key"
    mapfile -t wanted < <(printf '%s' "${paths[$key]}")
    work="$tmp/${repo//\//__}__$ref"

    git init -q "$work"
    git -C "$work" remote add origin "https://github.com/$repo.git"
    if [[ " ${wanted[*]} " != *" . "* ]]; then
        git -C "$work" sparse-checkout set --no-cone "${wanted[@]/%//}"
    fi
    if ! git -C "$work" fetch -q --depth 1 --filter=blob:none origin "$ref" \
        || ! git -C "$work" checkout -q FETCH_HEAD; then
        echo "install-skills: failed to fetch $repo@$ref" >&2
        failed+=("${wanted[@]/#/$repo@$ref:}")
        continue
    fi

    for path in "${wanted[@]}"; do
        src="$work/$path"
        if [[ ! -f "$src/SKILL.md" ]]; then
            echo "install-skills: no SKILL.md in $repo@$ref:$path" >&2
            failed+=("$repo@$ref:$path")
            continue
        fi
        name="$(basename "$( [[ "$path" == . ]] && echo "$repo" || echo "$path" )")"
        rm -rf "${dst:?}/$name"
        cp -r "$src" "$dst/$name"
        rm -rf "$dst/$name/.git"
        echo "$name" >> "$manifest"
    done
done

echo "install-skills: installed $(wc -l < "$manifest") skills into $dst" >&2
if ((${#failed[@]})); then
    echo "install-skills: FAILED: ${failed[*]}" >&2
fi
exit 0
