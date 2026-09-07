# shellcheck shell=bash
# Single owner of the project-directory workspace model used by delivery mode
# `project-branch`. Sourced by bin/fm-spawn.sh (dispatch guards and branch
# establishment) and bin/fm-teardown.sh (cleanup that must leave the directory
# exactly as the captain left it).
# Usage: . bin/fm-project-branch-lib.sh   (requires bin/fm-tangle-lib.sh for
# fm_default_branch, and bin/fm-control-lib.sh for the wiring-path table)
#
# Firstmate's other delivery modes hand a crewmate a disposable isolated copy of
# the project, so a worker can reset, discard, and be torn down with nothing at
# stake. `project-branch` deliberately gives up that isolation: the worker edits
# the captain's OWN registered clone, on the captain's OWN batch branch, while he
# may be working in the same directory. Every guarantee the isolation used to
# provide therefore has to be re-established here, as refusals, and this file is
# where they live so no caller re-derives them:
#
#   1. The directory is never worked on while another task already holds it.
#   2. Work never happens on the default branch.
#   3. The captain is never switched off the branch he has checked out.
#   4. Nothing is stashed, reset, cleaned, or discarded - a directory whose state
#      is not ours is a refusal, never an obstacle to clear.
#   5. Per-task agent wiring never overwrites a file the captain already has.
#
# A batch branch belongs to a BATCH of work, not to a task: several tasks may land
# on one branch over its life. Nothing here derives a branch name from a task id,
# and no caller may.
#
# The model is recorded in a task's metadata as `workspace=project`; an absent
# `workspace=` means the historical isolated copy, so old task records keep their
# meaning. bin/fm-spawn.sh's header owns that field, as it owns every other.

# Is <dir> the root of its own git work tree? Git discovery walks up, so a plain
# directory nested inside another repository would otherwise resolve to the
# enclosing repository and be worked on under this project's label.
fm_project_branch_dir_is_clone_root() {  # <dir>
  local dir=$1 real top top_real
  real=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) || return 1
  top_real=$(CDPATH='' cd -- "$top" 2>/dev/null && pwd -P) || return 1
  [ "$real" = "$top_real" ]
}

# Accept only a branch name git itself accepts, and refuse an option-shaped value
# a later command line could absorb as a flag.
fm_project_branch_name_valid() {  # <name>
  local name=${1-}
  case $name in
    '' | -*) return 1 ;;
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac
  git check-ref-format --branch "$name" >/dev/null 2>&1
}

# Print every OTHER task in <state-dir> whose recorded working directory is
# <dir>, one id per line. A task's meta file exists for exactly as long as the
# task does, so presence - not liveness - is the right test: a directory recorded
# by a task firstmate has not torn down is occupied, and dispatching a second
# worker into it is what this refusal exists to prevent.
fm_project_branch_occupants() {  # <state-dir> <this-task-id> <dir>
  local state=$1 self=$2 dir=$3 meta id recorded recorded_real dir_real
  dir_real=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || dir_real=$dir
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$id" != "$self" ] || continue
    recorded=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$recorded" ] || continue
    recorded_real=$(CDPATH='' cd -- "$recorded" 2>/dev/null && pwd -P) || recorded_real=$recorded
    [ "$recorded_real" = "$dir_real" ] || continue
    printf '%s\n' "$id"
  done
}

# Refuse the dispatch when another task already holds <dir>, naming it so
# firstmate can ask the captain instead of running two workers in one directory.
fm_project_branch_require_unoccupied() {  # <state-dir> <this-task-id> <dir>
  local state=$1 self=$2 dir=$3 occupants
  occupants=$(fm_project_branch_occupants "$state" "$self" "$dir")
  [ -n "$occupants" ] || return 0
  {
    echo "error: project directory $dir is already held by $(printf '%s' "$occupants" | tr '\n' ' ' | sed 's/ $//')"
    echo "A project-branch task works in the captain's own directory, so two workers cannot share it."
    echo "Ask the captain whether to wait for that task, put this work on the same branch after it, or use a different project."
  } >&2
  return 1
}

# Resolve - and where the captain has authorized it, establish - the batch branch
# for <dir>. Prints the resolved branch name on success.
#
# Resolution order, per the captain's own flow:
#   - the branch the directory is already on, when that is not the default branch
#   - otherwise the branch the captain named, created from the clean default
#     checkout
#
# Refusals, none of which a caller may soften:
#   - not a clone root, or no resolvable default branch
#   - detached HEAD (no branch to adopt and none named)
#   - on the default branch with no branch named
#   - a named branch that conflicts with the non-default branch already checked
#     out: the captain's checked-out branch is never switched away from here
#   - a switch that would carry uncommitted changes across
#   - the default branch named as the batch branch
fm_project_branch_resolve() {  # <dir> <requested-branch-or-empty>
  local dir=$1 requested=${2-} default current status
  if ! fm_project_branch_dir_is_clone_root "$dir"; then
    echo "error: $dir is not the root of its own git clone; a project-branch task works in the project's own registered directory" >&2
    return 1
  fi
  if ! default=$(fm_default_branch "$dir"); then
    echo "error: cannot determine the default branch of $dir (expected origin/HEAD, main, or master); refusing rather than guessing which branch is off limits" >&2
    return 1
  fi
  if [ -n "$requested" ] && ! fm_project_branch_name_valid "$requested"; then
    echo "error: '$requested' is not a usable git branch name" >&2
    return 1
  fi
  if [ -n "$requested" ] && [ "$requested" = "$default" ]; then
    echo "error: '$requested' is $dir's default branch; work never happens on the default branch" >&2
    return 1
  fi
  current=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$current" ]; then
    echo "error: $dir is on a detached HEAD, so there is no batch branch to adopt; ask the captain which branch this work belongs on and pass it explicitly" >&2
    return 1
  fi
  if [ "$current" != "$default" ]; then
    if [ -n "$requested" ] && [ "$requested" != "$current" ]; then
      echo "error: $dir is on branch '$current' but this dispatch names '$requested'; the captain's checked-out branch is never switched away from here" >&2
      echo "Confirm with the captain which branch this work belongs on, and dispatch against the branch his directory is actually on." >&2
      return 1
    fi
    printf '%s\n' "$current"
    return 0
  fi
  if [ -z "$requested" ]; then
    echo "error: $dir is on its default branch '$default' and no batch branch was named; work never happens on the default branch" >&2
    echo "Ask the captain which branch this batch of work belongs on and pass it explicitly." >&2
    return 1
  fi
  if ! status=$(git -C "$dir" -c core.quotePath=false status --porcelain 2>/dev/null); then
    echo "error: cannot inspect $dir before moving it onto '$requested'; refusing rather than switching blind" >&2
    return 1
  fi
  if [ -n "$status" ]; then
    echo "error: $dir has uncommitted changes on '$default', so moving it onto '$requested' would carry them across" >&2
    echo "Nothing here stashes, resets, or discards; report the uncommitted changes to the captain and let him decide." >&2
    return 1
  fi
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$requested"; then
    if ! git -C "$dir" checkout --quiet "$requested" 2>/dev/null; then
      echo "error: could not check out existing branch '$requested' in $dir" >&2
      return 1
    fi
  elif ! git -C "$dir" checkout --quiet -b "$requested" 2>/dev/null; then
    echo "error: could not create branch '$requested' in $dir" >&2
    return 1
  fi
  current=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$current" != "$requested" ]; then
    echo "error: $dir is on '${current:-a detached HEAD}' after establishing '$requested'; refusing to launch a worker onto an unverified branch" >&2
    return 1
  fi
  printf '%s\n' "$requested"
}

# Confirm <dir> is still on <branch> and still that project's own clone root.
# Used by a relaunch, which adopts a recorded directory rather than resolving a
# fresh one and must never assume the captain left it where the task started.
fm_project_branch_require_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2 current
  if ! fm_project_branch_dir_is_clone_root "$dir"; then
    echo "error: $dir is no longer the root of its own git clone" >&2
    return 1
  fi
  current=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$current" != "$branch" ]; then
    echo "error: $dir is on '${current:-a detached HEAD}', not this task's branch '$branch'; the captain moved it, so reconcile with him instead of switching it back" >&2
    return 1
  fi
}

# Whether a file at one of the in-directory wiring paths is provably THIS task's
# own agent wiring rather than a file of the captain's that happens to share the
# path. Two independent proofs:
#   - a firstmate-owned basename nothing else uses, or
#   - a shared basename (notably .claude/settings.local.json) whose CONTENT names
#     this task's own state directory.
# Everything else is treated as the captain's: never overwritten on the way in,
# never removed on the way out.
fm_project_branch_wiring_is_ours() {  # <path> <state-real> <task-id>
  local path=$1 state=$2 id=$3
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  case ${path##*/} in
    .fm-grok-turnend | .fm-kimi-turnend | fm-busy-state.js | fm-turn-end.js) return 0 ;;
  esac
  grep -Fq "$state/$id" "$path" 2>/dev/null
}

# Every in-directory agent wiring path for <harness> that currently EXISTS, from
# the single owner of that table in bin/fm-control-lib.sh. This is cleanup's
# enumeration: what is here that this task's harness could have put here.
fm_project_branch_wiring_present() {  # <harness> <dir> <state-dir> <task-id>
  local harness=$1 dir=$2 state=$3 id=$4 path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case $path in "$dir"/*) ;; *) continue ;; esac
    [ -e "$path" ] || [ -L "$path" ] || continue
    printf '%s\n' "$path"
  done <<EOF
$(fm_control_harness_wiring_paths "$(fm_control_harness_family "$harness" || true)" "$dir" "$state" "$id")
EOF
}

# The subset of those that are NOT provably ours. In a disposable copy every one
# of these paths is ours to overwrite; in the captain's own directory a file we
# cannot prove we wrote is his. A leftover from THIS task's own earlier attempt
# is provably ours, so a retried dispatch is never blocked by its own debris.
fm_project_branch_wiring_conflicts() {  # <harness> <dir> <state-real> <task-id>
  local harness=$1 dir=$2 state=$3 id=$4 path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    fm_project_branch_wiring_is_ours "$path" "$state" "$id" && continue
    printf '%s\n' "$path"
  done <<EOF
$(fm_project_branch_wiring_present "$harness" "$dir" "$state" "$id")
EOF
}

fm_project_branch_require_no_wiring_conflict() {  # <harness> <dir> <state-real> <task-id>
  local conflicts
  conflicts=$(fm_project_branch_wiring_conflicts "$@")
  [ -n "$conflicts" ] || return 0
  {
    echo "error: this worker's own agent wiring would overwrite files that already exist in the captain's project directory:"
    printf '%s\n' "$conflicts"
    echo "Nothing here overwrites them. Ask the captain whether those files can be moved aside, or dispatch this work in an isolated copy instead."
  } >&2
  return 1
}
