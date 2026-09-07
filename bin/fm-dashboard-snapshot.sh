#!/usr/bin/env bash
# fm-dashboard-snapshot.sh - read-only per-project git status for the /dashboard board.
#
# Iterates every entry in this home's private data/projects.md (the same registry
# bin/fm-project-mode.sh parses) and, for each project whose clone resolves to a
# real filesystem path, gathers: working-tree cleanliness, the last commit's date
# and author, the last few commits, and the current branch versus that repo's own
# default branch. Every git call is read-only (status, log, rev-parse,
# symbolic-ref, show-ref) - this script never fetches, pulls, or otherwise
# mutates any project checkout.
#
# Path resolution: data/projects.md has no structured path field (its format is
# owned by bin/fm-project-mode.sh's header; this script does not touch that
# parser). A project registered under the default layout lives at
# $FM_ROOT/projects/<name>. For a project registered outside that layout, this
# script looks for the literal phrase "clone kept in place at <ABSOLUTE_PATH>"
# in its description and extracts the path from there if present, falling back
# to the default layout path otherwise. This phrase is this script's own
# read-only reading convention, not a contract owned or guaranteed by
# bin/fm-project-mode.sh or the project-management skill (which documents
# "Clone into projects/<name>" for every registered project); a captain who
# wants an out-of-layout project picked up by /dashboard writes this phrase
# into that project's registry description by hand.
#
# One more optional phrase in the same description uses the same reading
# convention, captured up to the next space, ";", or end of line (so a path
# containing a space is truncated, exactly as for the clone-path phrase). Its
# path must be absolute to be read at all: the capture is anchored to a
# leading "/", so prose that happens to contain the words ("no run script at
# present") yields no run script rather than a bogus one, and no Run control
# is offered for it:
#   "run script at <ABSOLUTE_PATH>" - a local script that runs this project;
#     when present, the /dashboard page offers a "Run" control that launches
#     it (bin/fm-dashboard-server.py owns the launch mechanics). Absent for
#     most projects.
#
# Default-branch resolution reuses fm_default_branch() from fm-tangle-lib.sh
# (prefer origin/HEAD, fall back to a local main/master) rather than
# reimplementing that logic.
#
# "mine" detection: last_commit.mine says whether the captain's own identity
# authored the last commit, so the dashboard can tell "I'm working on this"
# apart from "a teammate is working on this". The captain's identity is
# resolved fresh each run, never hardcoded: each project's effective
# `git config user.email` (local override or global fallback), plus, when
# `gh` is authenticated, that GitHub account's noreply-email forms
# (`<login>@users.noreply.github.com` and `<id>+<login>@users.noreply.github.com`,
# the address GitHub attributes to web-authored and merge commits). The `gh
# api user` lookup is a read-only network call, consistent with this script's
# operationally-read-only contract. If no identity resolves at all, every
# commit reads as not-mine rather than guessing.
#
# Output contract: fm-dashboard-snapshot.v1, a single compact JSON object on
# stdout:
#   {
#     "schema": "fm-dashboard-snapshot.v1",
#     "generated_at": "<ISO-8601 timestamp>",
#     "projects": [
#       {
#         "name": "<registry name>",
#         "path": "<resolved absolute path>",
#         "available": true|false,
#         "reason": "<why unavailable>"        (only when available=false)
#         "clean": true|false,
#         "branch": "<current branch or short HEAD if detached>",
#         "default_branch": "<resolved default branch>",
#         "on_default": true|false,
#         "last_commit": {"date": "...", "author": "...", "author_email": "...", "mine": true|false, "subject": "..."},
#         "commits": [{"hash": "...", "date": "...", "author": "...", "subject": "..."}, ...],
#         "run_script": "<ABSOLUTE_PATH>" | null
#       },
#       ...
#     ]
#   }
# run_script is present (possibly null) on every project record, available or
# not, since it comes from the registry description rather than the clone
# itself.
#
# Usage:
#   fm-dashboard-snapshot.sh [--commits N]
#     --commits N   how many recent commits to include per project (default 5,
#                   clamped to 5-10 per the /dashboard captain intent)
#     -h, --help    usage
#
# FM_ROOT_OVERRIDE / FM_HOME / FM_DATA_OVERRIDE follow the same override
# contract as bin/fm-project-mode.sh (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"

# shellcheck source=bin/fm-tangle-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"

COMMIT_LIMIT=5

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-dashboard-snapshot: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --commits)
      [ $# -ge 2 ] || fail "--commits requires a value"
      COMMIT_LIMIT=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$COMMIT_LIMIT" in
  ''|*[!0-9]*) fail "--commits must be a positive integer" ;;
esac
[ "$COMMIT_LIMIT" -ge 5 ] || COMMIT_LIMIT=5
[ "$COMMIT_LIMIT" -le 10 ] || COMMIT_LIMIT=10

command -v jq >/dev/null 2>&1 || fail "jq is required"

# captain_identity_emails: print the captain's known git/GitHub identity
# emails, one per line, lowercased. Resolved fresh each run - see the
# "mine" detection header note.
captain_identity_emails() {
  local e login id
  e=$(git config --global user.email 2>/dev/null || true)
  [ -n "$e" ] && printf '%s\n' "$e"

  if command -v gh >/dev/null 2>&1; then
    login=$(gh api user --jq '.login // empty' 2>/dev/null || true)
    id=$(gh api user --jq '.id // empty' 2>/dev/null || true)
    if [ -n "$login" ]; then
      printf '%s\n' "${login}@users.noreply.github.com"
      [ -n "$id" ] && printf '%s\n' "${id}+${login}@users.noreply.github.com"
    fi
  fi
}
CAPTAIN_EMAILS=$(captain_identity_emails | tr '[:upper:]' '[:lower:]' | sort -u)

# is_mine_email <path> <author_email>: true if author_email matches the
# captain's global/GitHub identity or this project's own effective git
# identity (local config override, or its own global fallback).
is_mine_email() {
  local path=$1 author_email=$2 proj_email candidate
  [ -n "$author_email" ] || { return 1; }
  author_email=$(printf '%s' "$author_email" | tr '[:upper:]' '[:lower:]')
  proj_email=$(git -C "$path" config user.email 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
  [ -n "$proj_email" ] && [ "$proj_email" = "$author_email" ] && return 0
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ "$candidate" = "$author_email" ] && return 0
  done <<EOF
$CAPTAIN_EMAILS
EOF
  return 1
}

# resolve_path <name> <description>: print the project's resolved absolute
# path. Prefers the "clone kept in place at <PATH>" phrase embedded in the
# registry description (this script's own reading convention, not a
# fm-project-mode.sh or project-management-skill contract - see the header
# comment above); falls back to the default projects/<name> layout.
resolve_path() {
  local name=$1 desc=$2 embedded
  embedded=$(printf '%s\n' "$desc" \
    | grep -oE 'clone kept in place at [^ ;]+' \
    | head -n1 \
    | sed 's/^clone kept in place at //')
  if [ -n "$embedded" ]; then
    printf '%s\n' "$embedded"
  else
    printf '%s/projects/%s\n' "$FM_ROOT" "$name"
  fi
}

# resolve_run_script <description>: print the embedded "run script at <PATH>"
# phrase's path, or nothing when absent. See the header comment above.
resolve_run_script() {
  printf '%s\n' "$1" \
    | grep -oE 'run script at /[^ ;]*' \
    | head -n1 \
    | sed 's/^run script at //'
}

# project_json <name> <path> <run_script>: emit one fm-dashboard-snapshot.v1
# project record.
project_json() {
  local name=$1 path=$2 run_script=$3
  local branch default_branch on_default clean_bool last_line last_date last_author last_email last_subject last_mine
  local commits_raw commits_json

  if [ ! -d "$path" ] || ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    jq -n --arg name "$name" --arg path "$path" \
      --arg run_script "$run_script" \
      '{name: $name, path: $path, available: false, reason: "no git checkout at this path",
        run_script: (if $run_script == "" then null else $run_script end)}'
    return 0
  fi

  if [ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    clean_bool=true
  else
    clean_bool=false
  fi

  branch=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$branch" ]; then
    branch="detached@$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  fi

  default_branch=$(fm_default_branch "$path" 2>/dev/null || true)
  if [ -z "$default_branch" ]; then
    default_branch=""
    on_default=null
  elif [ "$branch" = "$default_branch" ]; then
    on_default=true
  else
    on_default=false
  fi

  last_line=$(git -C "$path" log -1 --format='%ad%x1f%an%x1f%ae%x1f%s' --date=iso-strict 2>/dev/null || true)
  last_date=${last_line%%$'\x1f'*}
  last_line=${last_line#*$'\x1f'}
  last_author=${last_line%%$'\x1f'*}
  last_line=${last_line#*$'\x1f'}
  last_email=${last_line%%$'\x1f'*}
  last_subject=${last_line#*$'\x1f'}
  if [ -z "$last_date" ]; then
    last_date=""; last_author=""; last_email=""; last_subject=""
  fi
  if [ -n "$last_email" ] && is_mine_email "$path" "$last_email"; then
    last_mine=true
  else
    last_mine=false
  fi

  commits_raw=$(git -C "$path" log -n "$COMMIT_LIMIT" --format='%h%x1f%ad%x1f%an%x1f%s' --date=iso-strict 2>/dev/null || true)
  commits_json=$(printf '%s\n' "$commits_raw" | jq -R -s '
    split("\n") | map(select(length > 0)) | map(split("\u001f")) |
    map({hash: .[0], date: .[1], author: .[2], subject: (.[3:] | join("\u001f"))})
  ')

  jq -n \
    --arg name "$name" \
    --arg path "$path" \
    --argjson clean "$clean_bool" \
    --arg branch "$branch" \
    --arg default_branch "$default_branch" \
    --argjson on_default "$on_default" \
    --arg last_date "$last_date" \
    --arg last_author "$last_author" \
    --arg last_email "$last_email" \
    --argjson last_mine "$last_mine" \
    --arg last_subject "$last_subject" \
    --argjson commits "$commits_json" \
    --arg run_script "$run_script" \
    '{
      name: $name, path: $path, available: true,
      clean: $clean,
      branch: $branch,
      default_branch: (if $default_branch == "" then null else $default_branch end),
      on_default: $on_default,
      last_commit: {date: $last_date, author: $last_author, author_email: $last_email, mine: $last_mine, subject: $last_subject},
      commits: $commits,
      run_script: (if $run_script == "" then null else $run_script end)
    }'
}

if [ ! -f "$REG" ]; then
  jq -n --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: "fm-dashboard-snapshot.v1", generated_at: $gen, projects: []}'
  exit 0
fi

records=()
while IFS= read -r line; do
  case "$line" in
    '- '*) ;;
    *) continue ;;
  esac
  name=$(printf '%s\n' "$line" | awk '{print $2}')
  [ -n "$name" ] || continue
  path=$(resolve_path "$name" "$line")
  run_script=$(resolve_run_script "$line")
  records+=("$(project_json "$name" "$path" "$run_script")")
done < "$REG"

if [ "${#records[@]}" -eq 0 ]; then
  projects_json='[]'
else
  projects_json=$(printf '%s\n' "${records[@]}" | jq -s '.')
fi

jq -n \
  --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson projects "$projects_json" \
  '{schema: "fm-dashboard-snapshot.v1", generated_at: $gen, projects: $projects}'
