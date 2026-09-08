# shellcheck shell=bash
# Single owner of WHERE a registered project's work happens, in both directions:
# the project-directory workspace model used by delivery mode `project-branch`,
# and the matching refusal to run a registered project's ship work in a
# disposable copy instead. Sourced by bin/fm-spawn.sh (dispatch guards and branch
# establishment), bin/fm-promote.sh (the scout-to-ship entry to the same
# decision), and bin/fm-teardown.sh (cleanup that must leave the directory
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
#   1. A project that is not on its own default branch is OCCUPIED, full stop.
#      The captain's rule: "we assume another agent is still busy or I'm still busy
#      on it and it should block it and inform me that it is blocked." So the gate
#      is the project's own git state, never firstmate's bookkeeping, and it
#      deliberately does NOT distinguish a crewmate holding the branch from the
#      captain holding it - the second case is the one bookkeeping would miss.
#   2. Work never happens on the default branch.
#   3. Nothing is stashed, reset, cleaned, or discarded - a directory whose state
#      is not ours is a refusal, never an obstacle to clear.
#   4. Per-task agent wiring never overwrites a file the captain already has.
#
# The default branch is resolved per project by fm_default_branch() from
# bin/fm-tangle-lib.sh - the same single resolver bin/fm-dashboard.mjs
# uses - because registered projects sit on master, main, develop and test alike
# and nothing here may assume one name.
#
# A batch branch belongs to a BATCH of work, not to a task: several tasks may land
# on one branch over its life. Nothing here derives a branch name from a task id,
# and no caller may.
#
# The model is recorded in a task's metadata as `workspace=project`; an absent
# `workspace=` means the historical isolated copy, so old task records keep their
# meaning. bin/fm-spawn.sh's header owns that field, as it owns every other.

# --- The disposable copy is not a fallback ------------------------------------
#
# Every other refusal in this file protects the captain's own directory. This one
# protects the model itself, and it exists because those refusals alone protected
# nothing: when an in-place dispatch stopped because the project was occupied,
# dispatching the SAME work with any other delivery mode was still legal, and it
# allocated a disposable copy - the exact thing the in-place model replaced. A
# guard that is walked around by choosing a different flag is decoration, so the
# other side of the choice has to refuse too.
#
# The line, decided once here:
#
#   SHIP work aimed at one of the captain's OWN registered projects runs in that
#   project's directory, on a branch he can see. A disposable copy of a
#   registered project is available for a piece of ship work only when the
#   captain has authorized THAT piece of work, and only from a record on disk.
#
# What is deliberately left alone:
#   - Scouts. Investigation and throwaway experiments are exactly the work that
#     should never touch the captain's directory, and a scout produces a report
#     rather than a project change, so it can carry no shipping work around this
#     gate. `project-branch` is ship-only for the same reason.
#   - Projects the captain never registered - firstmate's own repo among them.
#     They are not his working copies to protect.
#   - A relaunch, which adopts an existing task's recorded directory and creates
#     nothing; the gate belongs on the dispatch that allocates.
#
# The authorization is a per-task record written by bin/fm-isolated-authorize.sh
# and never by a flag, because a flag is the walk-around this guard exists to
# close: it would live in whichever agent chose it, and firstmate inferring that
# the captain "would have wanted" the copy is the failure being fixed. The record
# names the task and the project, so it authorizes one piece of work on one
# project and expires with the task.

fm_project_branch_isolation_record() {  # <state-dir> <task-id>
  printf '%s/%s.isolated-authorized\n' "$1" "$2"
}

# The project the captain authorized a disposable copy for on <task-id>, or
# nothing when no usable record exists. A record that names another task is not
# this task's authorization and is reported as absent.
fm_project_branch_isolation_authorized_project() {  # <state-dir> <task-id>
  local state=$1 id=$2 record recorded_task recorded_project
  record=$(fm_project_branch_isolation_record "$state" "$id")
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  recorded_task=$(grep '^task=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$recorded_task" = "$id" ] || return 0
  recorded_project=$(grep '^project=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$recorded_project" ] || return 0
  printf '%s\n' "$recorded_project"
}

# Refuse a disposable-copy dispatch of ship work aimed at a registered project.
#
# <mode-script> is bin/fm-project-mode.sh, the single owner of registry parsing;
# an unregistered project passes straight through. The refusal is written to be
# relayed to the captain as it stands, so it names the project in his own terms,
# says what is blocking it, and states his options - AGENTS.md section 9 governs
# that wording, and an internal noun in here would reach him.
fm_project_branch_require_isolation_authorized() {  # <mode-script> <state-dir> <task-id> <project-dir> [<project-name>]
  local mode_script=$1 state=$2 id=$3 dir=$4 name=${5-}
  local authorized current default
  [ -n "$name" ] || name=$(basename "$dir")
  "$mode_script" --registered "$name" >/dev/null 2>&1 || return 0

  authorized=$(fm_project_branch_isolation_authorized_project "$state" "$id")
  if [ -n "$authorized" ]; then
    if [ "$authorized" = "$name" ]; then
      echo "notice: $id runs in a throwaway copy of $name on the captain's own recorded say-so" >&2
      return 0
    fi
    echo "error: HALTED: the captain's recorded say-so for this piece of work names $authorized, not $name" >&2
    echo "Nothing was created. Confirm with him which project this work is for before dispatching it." >&2
    return 1
  fi

  current=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  default=$(fm_default_branch "$dir" 2>/dev/null || true)
  {
    echo "error: HALTED: work on $name runs in the captain's own copy of the project, on a branch he can see - never in a throwaway copy."
    if [ -n "$current" ] && [ -n "$default" ] && [ "$current" != "$default" ]; then
      echo "$name is on branch '$current' rather than '$default', so something is already working on it."
      echo "Nothing was created. Take this to the captain: he can finish or set aside what is on '$current', or tell you this one piece of work may run in a throwaway copy."
    elif [ -z "$current" ] && [ -n "$default" ]; then
      echo "$name is not sitting on '$default' at all, so something is already working on it."
      echo "Nothing was created. Take this to the captain: he can put the project back on '$default', or tell you this one piece of work may run in a throwaway copy."
    else
      echo "Nothing was created. Run this work in the project's own directory on a branch the captain names, or ask him whether this one piece of work may run in a throwaway copy."
    fi
    echo "Only once he has said so, for this piece of work: bin/fm-isolated-authorize.sh grant $id $name --captain \"<his words>\""
  } >&2
  return 1
}

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
# firstmate can ask the captain about a specific piece of work.
#
# This runs BEFORE the git-state gate and is strictly additional to it: the
# authoritative occupancy signal is the project's own branch, and this only adds
# the better message available when firstmate does have a record of the task
# holding the directory. It can never substitute for the git-state gate, which is
# what catches the captain holding the project himself.
fm_project_branch_require_unoccupied() {  # <state-dir> <this-task-id> <dir>
  local state=$1 self=$2 dir=$3 occupants
  occupants=$(fm_project_branch_occupants "$state" "$self" "$dir")
  [ -n "$occupants" ] || return 0
  {
    echo "error: OCCUPIED: project directory $dir is already held by $(printf '%s' "$occupants" | tr '\n' ' ' | sed 's/ $//')"
    echo "One piece of work at a time per project, so two workers cannot share it."
    echo "Nothing was created or changed. Ask the captain whether to wait for that task or use a different project."
  } >&2
  return 1
}

# Establish the batch branch for <dir>, printing its name on success.
#
# The captain's loop is one branch at a time: branch off the default, finish it,
# merge it, branch again. So this refuses unless the project is sitting on its own
# default branch with a clean tree, and then creates or checks out the named batch
# branch from there. Being off the default branch is not drift to reconcile - it is
# the signal that this project is already occupied, by a crewmate or by the captain
# himself, and the only correct response is to stop and say so.
#
# Refusals, none of which a caller may soften:
#   - not a clone root, or no resolvable default branch
#   - already on any branch other than the default one, or at a detached HEAD:
#     OCCUPIED, reported with the branch that holds it
#   - uncommitted changes on the default branch (see below)
#   - the default branch named as the batch branch
#   - an unusable branch name, or a branch that cannot be established
#
# Dirty-on-default is a deliberate refusal rather than an oversight. `checkout -b`
# carries uncommitted changes onto the new branch, so proceeding would silently mix
# the captain's in-progress work into the crew's batch branch and into the PR he
# later reviews, and the alternative - stashing it aside - is exactly what this
# model may never do. It is reported as its own condition, not as occupancy.
fm_project_branch_resolve() {  # <dir> <requested-branch>
  local dir=$1 requested=${2-} default current status
  if ! fm_project_branch_dir_is_clone_root "$dir"; then
    echo "error: $dir is not the root of its own git clone; a project-branch task works in the project's own registered directory" >&2
    return 1
  fi
  if ! default=$(fm_default_branch "$dir"); then
    echo "error: cannot determine the default branch of $dir (expected origin/HEAD, main, or master); refusing rather than guessing which branch is off limits" >&2
    return 1
  fi
  if [ -z "$requested" ]; then
    echo "error: no batch branch was named for $dir; resolve it at intake and pass it explicitly" >&2
    return 1
  fi
  if ! fm_project_branch_name_valid "$requested"; then
    echo "error: '$requested' is not a usable git branch name" >&2
    return 1
  fi
  if [ "$requested" = "$default" ]; then
    echo "error: '$requested' is $dir's default branch; work never happens on the default branch" >&2
    return 1
  fi
  current=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$current" ]; then
    echo "error: OCCUPIED: $dir is not on its default branch '$default' - it is at a detached HEAD" >&2
    echo "A project that is not on its default branch is treated as already busy, whether a worker or the captain has it." >&2
    echo "Nothing was created or changed. Report this to the captain and let him say how to proceed." >&2
    return 1
  fi
  if [ "$current" != "$default" ]; then
    echo "error: OCCUPIED: $dir is on branch '$current', not its default branch '$default'" >&2
    echo "A project that is not on its default branch is treated as already busy, whether a worker or the captain has it." >&2
    echo "Nothing was created or changed. Tell the captain this project is occupied by branch '$current' and let him say how to proceed." >&2
    return 1
  fi
  if ! status=$(git -C "$dir" -c core.quotePath=false status --porcelain 2>/dev/null); then
    echo "error: cannot inspect $dir before moving it onto '$requested'; refusing rather than switching blind" >&2
    return 1
  fi
  if [ -n "$status" ]; then
    echo "error: $dir has uncommitted changes on its default branch '$default', so creating '$requested' here would carry them onto the batch branch" >&2
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
    echo "Nothing here overwrites them. Ask the captain whether those files can be moved aside; a disposable copy is not the way around this, and needs his own say-so for this piece of work."
  } >&2
  return 1
}
