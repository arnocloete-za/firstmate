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
# Default-branch resolution reuses fm_default_branch() from fm-tangle-lib.sh
# (prefer origin/HEAD, fall back to a local main/master) rather than
# reimplementing that logic.
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
#         "last_commit": {"date": "...", "author": "...", "subject": "..."},
#         "commits": [{"hash": "...", "date": "...", "author": "...", "subject": "..."}, ...]
#       },
#       ...
#     ]
#   }
#
# Usage:
#   fm-dashboard-snapshot.sh [--commits N]
#     --commits N   how many recent commits to include per project (default 8,
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

COMMIT_LIMIT=8

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

# project_json <name> <path>: emit one fm-dashboard-snapshot.v1 project record.
project_json() {
  local name=$1 path=$2
  local branch default_branch on_default clean_bool last_line last_date last_author last_subject
  local commits_raw commits_json

  if [ ! -d "$path" ] || ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    jq -n --arg name "$name" --arg path "$path" \
      '{name: $name, path: $path, available: false, reason: "no git checkout at this path"}'
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

  last_line=$(git -C "$path" log -1 --format='%ad%x1f%an%x1f%s' --date=iso-strict 2>/dev/null || true)
  last_date=${last_line%%$'\x1f'*}
  last_line=${last_line#*$'\x1f'}
  last_author=${last_line%%$'\x1f'*}
  last_subject=${last_line#*$'\x1f'}
  if [ -z "$last_date" ]; then
    last_date=""; last_author=""; last_subject=""
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
    --arg last_subject "$last_subject" \
    --argjson commits "$commits_json" \
    '{
      name: $name, path: $path, available: true,
      clean: $clean,
      branch: $branch,
      default_branch: (if $default_branch == "" then null else $default_branch end),
      on_default: $on_default,
      last_commit: {date: $last_date, author: $last_author, subject: $last_subject},
      commits: $commits
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
  records+=("$(project_json "$name" "$path")")
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
