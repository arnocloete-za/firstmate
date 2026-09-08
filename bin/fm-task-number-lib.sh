#!/usr/bin/env bash
# fm-task-number-lib.sh - the captain's project numbers (one owner).
#
# WHY. The captain reads a number aloud and expects to know instantly which
# piece of work it is, across several messages with unrelated noise between
# them. A name he has to match letter by letter does not survive that; a
# number does. So every surface that shows him work - the board's project
# cards, the board's live rows, the task's own terminal, and the fleet snapshot
# firstmate reads before it writes to him - must show the SAME number for the
# same thing. That is only possible if exactly one place computes it, which is
# this file.
#
# THE SCHEME.
#   - A project's number is its position in REGISTRY ORDER within its own
#     board, offset by that board's base: the work board starts at 1, the
#     personal board at 50. Registry order is what the captain arranged, so a
#     number never moves because a project's status changed.
#   - ONE NUMBER PER PROJECT, by the captain's own ruling. His one-piece-of-
#     work-at-a-time rule means a project's number identifies its live work
#     with no suffix, and numbers are reused over time to stay small.
#   - Work on anything else - a project he never registered - takes the LOWEST
#     FREE number from the 100 pool when that work starts, and gives it back
#     when the work finishes. Reuse is what keeps the numbers he says aloud
#     two or three digits instead of ever-climbing.
#   - Firstmate's own repository is RESERVED number 0 and is never counted in
#     any board's ordinal run. Zero cannot collide with a board position or a
#     pool number, so the ship's own number is stable whether or not firstmate
#     is ever registered as a project - and registering it can never renumber
#     the captain's board underneath him.
#
# WHY 0 AND NOT A HIGH NUMBER. Any number inside a board's run (11, say) is one
# new project away from colliding, and any number just under the pool base is
# one long board away. Zero is the only value that is provably free of both,
# and "the ship itself, before the fleet" is how it reads aloud.
#
# THE POOL'S QUARANTINE. A finished pool number is not handed straight to the
# next piece of work. It is held for FM_TASK_NUMBER_QUARANTINE_SECS (default 12
# hours), because the captain's whole complaint is a number he said a few
# messages ago; if #100 became different work inside that window, the number
# would be actively misleading rather than merely reused. Above 100 the pool is
# unbounded, so holding a number back costs at most one larger number, and the
# quarantine drains on its own with no cleanup step to forget.
#
# WHAT IS DERIVED AND WHAT IS RECORDED. A registered project's number is pure
# derivation from data/projects.md, so no record of it can go stale. A pool
# number is an ALLOCATION, so it is recorded in the task's own meta at spawn
# (bin/fm-spawn.sh) and released at cleanup (bin/fm-teardown.sh). A recorded
# number always wins over derivation, which is what freezes the number in a
# task's terminal name for the life of that terminal even if the registry is
# rearranged underneath it.
#
# THE TERMINAL NAME. fm_task_number_label is the single owner of a task's
# endpoint label, the `fm-...` name its terminal carries and every backend
# verifies against. A numbered task's label is fm-<number>-<id>; a task with no
# number keeps the historical fm-<id>, so every task record written before this
# existed still validates unchanged.
#
# WHAT THIS FILE DOES NOT DO. It never decides a board's PRESENTATION (page,
# title, command: bin/fm-dashboard.mjs's board table), never reads current
# state, and never renders captain-facing prose. Board MEMBERSHIP is here,
# because which board a project sits on and which number it gets are one
# decision; fm_task_number_table is the interface for both. Two tasks sharing one
# number is a display problem, not a numbering one: bin/fm-fleet-snapshot.sh
# owns the disambiguating suffix, because only a whole-fleet read can see that
# the collision exists.
#
# Read-only on source except for the two explicitly mutating functions
# (fm_task_number_allocate, fm_task_number_release). `set -u` safe, Bash 3.2
# compatible.
#
# Tunables (env):
#   FM_TASK_NUMBER_QUARANTINE_SECS   default 43200; the pool's hold window

# Board bases and the reserved numbers. These four constants are the scheme.
FM_TASK_NUMBER_WORK_BASE=1
FM_TASK_NUMBER_PERSONAL_BASE=50
FM_TASK_NUMBER_POOL_BASE=100
FM_TASK_NUMBER_FIRSTMATE=0
FM_TASK_NUMBER_QUARANTINE_SECS_DEFAULT=43200

# The annotation flag that moves a project off the work board, and the board it
# moves onto. The flag rides in the same bracket as the registered delivery
# posture (bin/fm-project-mode.sh's header owns that bracket's format), which
# reads flags it does not know as flags rather than as a mode.
FM_TASK_NUMBER_PERSONAL_MARKER='+personal'
FM_TASK_NUMBER_WORK_BOARD=work
FM_TASK_NUMBER_PERSONAL_BOARD=personal

# This firstmate's own code root, so the reserved-ship test can recognize a
# task working on firstmate itself by path and not only by name. Resolved once,
# at source time, from this file's own location.
FM_TASK_NUMBER_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}

fm_task_number_quarantine_secs() {
  local secs=${FM_TASK_NUMBER_QUARANTINE_SECS:-$FM_TASK_NUMBER_QUARANTINE_SECS_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*) secs=$FM_TASK_NUMBER_QUARANTINE_SECS_DEFAULT ;;
  esac
  printf '%s' "$secs"
}

fm_task_number_quarantine_path() {  # <state-dir>
  printf '%s/number-quarantine' "$1"
}

# The reserved-project test. Firstmate's own repository is the ship, not one of
# the captain's projects, so it is recognized by identity rather than by being
# registered: the name firstmate answers to, or a clone path that IS this
# firstmate's code root or operational home.
fm_task_number_is_firstmate() {  # <project-name-or-path>
  local subject=$1 name
  [ -n "$subject" ] || return 1
  name=${subject##*/}
  [ "$name" = firstmate ] && return 0
  [ -n "${FM_TASK_NUMBER_ROOT:-}" ] && [ "$subject" = "$FM_TASK_NUMBER_ROOT" ] && return 0
  [ -n "${FM_HOME:-}" ] && [ "$subject" = "${FM_HOME:-}" ] && return 0
  return 1
}

# The whole numbering table, one TSV row per registered project in registry
# order: "<name>\t<board>\t<number>\t<display>". Every consumer takes board
# membership, the number, AND the way it is written from this one read rather
# than re-deriving any of them, so a card and a live row can never disagree
# about what #7 is or how it is spelled.
#
# A board whose ordinal run would reach the next band's base emits an EMPTY
# number for the overflowing project and says so on stderr. A number shown
# twice would be worse than no number, so the overflow is visible instead.
fm_task_number_table() {  # <data-dir>
  local registry=$1/projects.md
  [ -f "$registry" ] && [ -r "$registry" ] || return 0
  awk -v work_board="$FM_TASK_NUMBER_WORK_BOARD" \
      -v personal_board="$FM_TASK_NUMBER_PERSONAL_BOARD" \
      -v work_base="$FM_TASK_NUMBER_WORK_BASE" \
      -v personal_base="$FM_TASK_NUMBER_PERSONAL_BASE" \
      -v pool_base="$FM_TASK_NUMBER_POOL_BASE" \
      -v firstmate_number="$FM_TASK_NUMBER_FIRSTMATE" \
      -v marker="$FM_TASK_NUMBER_PERSONAL_MARKER" '
    function display(n) { return n < 10 ? "0" n : "" n }
    BEGIN {
      next_work = work_base
      next_personal = personal_base
    }
    $1 != "-" || NF < 2 { next }
    {
      name = $2
      board = work_board
      # The annotation slot is the bracket immediately after the name, read the
      # way bin/fm-project-mode.sh (the format owner) reads it, so a bracket
      # appearing later in the free-form description is never mistaken for one
      # of these flags.
      if ($3 ~ /^\[/) {
        bracket = ""
        for (i = 3; i <= NF; i++) {
          bracket = bracket (bracket == "" ? "" : " ") $i
          if ($i ~ /\]$/) break
        }
        sub(/^\[/, "", bracket)
        sub(/\]$/, "", bracket)
        if (index(" " bracket " ", " " marker " ") > 0) board = personal_board
      }
      # The reserved ship number is board-independent and is never counted in a
      # board run, so registering firstmate cannot shift any other project.
      if (name == "firstmate") {
        printf "%s\t%s\t%s\t%s\n", name, board, firstmate_number, display(firstmate_number)
        next
      }
      if (board == personal_board) {
        if (next_personal >= pool_base) {
          printf "fm-task-number: the personal board has outgrown its number band; %s gets no number\n", name > "/dev/stderr"
          printf "%s\t%s\t\t\n", name, board
          next
        }
        printf "%s\t%s\t%s\t%s\n", name, board, next_personal, display(next_personal)
        next_personal++
        next
      }
      if (next_work >= personal_base) {
        printf "fm-task-number: the work board has outgrown its number band; %s gets no number\n", name > "/dev/stderr"
        printf "%s\t%s\t\t\n", name, board
        next
      }
      printf "%s\t%s\t%s\t%s\n", name, board, next_work, display(next_work)
      next_work++
    }
  ' "$registry"
}

# One project's derived number. Prints nothing and fails when the project is
# neither registered nor the reserved ship, which is the honest answer: work
# outside the registry is numbered from the pool, and only an allocation can
# say which pool number it holds.
fm_task_number_of_project() {  # <data-dir> <project-name-or-path>
  local data=$1 subject=$2 name row
  [ -n "$subject" ] || return 1
  name=${subject##*/}
  if fm_task_number_is_firstmate "$subject"; then
    printf '%s' "$FM_TASK_NUMBER_FIRSTMATE"
    return 0
  fi
  row=$(fm_task_number_table "$data" 2>/dev/null \
    | awk -F'\t' -v n="$name" '$1 == n { print $3; exit }')
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# The number RECORDED in a task's own record, or nothing. A record that is not
# a plain readable regular file, or whose number line is not a bare integer,
# prints nothing: an unreadable record means "no recorded number", never a
# guessed one.
fm_task_number_recorded_in() {  # <meta-path>
  local meta=$1 lines value
  [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || return 1
  lines=$(LC_ALL=C sed -n 's/^number=//p' "$meta" 2>/dev/null) || return 1
  # Exactly one number line, or none. Two would make the task's own label
  # ambiguous, and a guessed label is what would send a cleanup at the wrong
  # terminal, so an ambiguous record reads as no recorded number and the
  # endpoint validator refuses on the mismatch.
  case "$lines" in
    ''|*$'\n'*) return 1 ;;
  esac
  value=${lines%$'\r'}
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$value"
}

fm_task_number_recorded() {  # <state-dir> <task-id>
  fm_task_number_recorded_in "$1/$2.meta"
}

# The project a task is working on, as the registry would name it: the last
# component of its recorded project path.
fm_task_number_project_of_task() {  # <state-dir> <task-id>
  local meta=$1/$2.meta value
  [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || return 1
  value=$(LC_ALL=C sed -n 's/^project=//p' "$meta" 2>/dev/null | tail -1) || return 1
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# A task's number: what its record holds, else what its project derives. A
# recorded number wins so that a pool allocation, and the terminal name frozen
# around it, survive any later change to the registry.
fm_task_number_of_task() {  # <data-dir> <state-dir> <task-id>
  local data=$1 state=$2 id=$3 number project
  if number=$(fm_task_number_recorded "$state" "$id"); then
    printf '%s' "$number"
    return 0
  fi
  project=$(fm_task_number_project_of_task "$state" "$id") || return 1
  fm_task_number_of_project "$data" "$project"
}

# The number as the captain reads it: two digits so a board of them lines up,
# and its own width past ninety-nine.
fm_task_number_display() {  # <number>
  local number=$1
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%02d' "$number"
}

# THE endpoint label for a task - the `fm-...` name its terminal carries, that
# every backend verifies against, and that the captain reads in his terminal
# list. Numbered work leads with its number so finding a terminal is reading a
# number; an unnumbered task keeps the historical form, so every task record
# written before numbering existed still validates unchanged.
#
# The label carries the plain number and never a collision suffix: it is frozen
# for the life of the terminal, while a suffix exists only for as long as two
# tasks share a number.
fm_task_number_label() {  # <task-id> [number]
  local id=$1 number=${2:-} display
  if display=$(fm_task_number_display "$number" 2>/dev/null); then
    printf 'fm-%s-%s' "$display" "$id"
    return 0
  fi
  printf 'fm-%s' "$id"
}

# The label for a task that already has a record, resolved through its recorded
# number so it matches the terminal that exists rather than the registry as it
# reads today.
fm_task_label_of_meta() {  # <meta-path> <task-id>
  local number
  number=$(fm_task_number_recorded_in "$1" 2>/dev/null) || number=
  fm_task_number_label "$2" "$number"
}

fm_task_label() {  # <state-dir> <task-id>
  fm_task_label_of_meta "$1/$2.meta" "$2"
}

# Pool numbers already spoken for: every number at or above the pool base that
# a live task record holds, plus every number still inside its quarantine
# window. Both are read fresh, so a crashed task keeps its number until its
# record is cleaned up and a drained quarantine needs no sweeping.
fm_task_number_pool_in_use() {  # <state-dir>
  local state=$1 meta now cutoff
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    LC_ALL=C sed -n 's/^number=//p' "$meta" 2>/dev/null | tail -1
  done | awk -v base="$FM_TASK_NUMBER_POOL_BASE" '/^[0-9]+$/ && $1 >= base { print }'
  now=$(date +%s 2>/dev/null) || now=
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  cutoff=$((now - $(fm_task_number_quarantine_secs)))
  [ -f "$(fm_task_number_quarantine_path "$state")" ] || return 0
  awk -v cutoff="$cutoff" -v base="$FM_TASK_NUMBER_POOL_BASE" \
    '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $1 >= base && $2 > cutoff { print $1 }' \
    "$(fm_task_number_quarantine_path "$state")"
}

# The lowest free pool number. MUTATES nothing itself; the caller records the
# result in the task's own record, which is what makes the number taken.
fm_task_number_pool_lowest_free() {  # <state-dir>
  local state=$1
  fm_task_number_pool_in_use "$state" | LC_ALL=C sort -n -u \
    | awk -v n="$FM_TASK_NUMBER_POOL_BASE" '
      { if ($1 == n) n++ ; else if ($1 > n) { print n; found = 1; exit } }
      END { if (!found) print n }
    '
}

# The number a starting piece of work takes: its project's, when the registry
# or the reserved ship gives it one, and otherwise the lowest free pool number.
# Prints the number; the caller is what records it.
fm_task_number_allocate() {  # <data-dir> <state-dir> <project-name-or-path>
  local data=$1 state=$2 subject=$3 number
  if number=$(fm_task_number_of_project "$data" "$subject"); then
    printf '%s' "$number"
    return 0
  fi
  fm_task_number_pool_lowest_free "$state"
}

# Give a finished pool number back, held for its quarantine window. A number
# the registry derives is not the pool's to release, and releasing one nobody
# holds is a silent success, so a retried cleanup is safe.
fm_task_number_release() {  # <state-dir> <number>
  local state=$1 number=${2:-} path now
  case "$number" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$number" -ge "$FM_TASK_NUMBER_POOL_BASE" ] || return 0
  [ -d "$state" ] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  path=$(fm_task_number_quarantine_path "$state")
  printf '%s %s\n' "$number" "$now" >> "$path" 2>/dev/null || return 0
  # Entries older than one full window can never gate an allocation again, so
  # prune them here rather than leaving an append-only file to grow forever.
  fm_task_number_quarantine_prune "$state"
}

fm_task_number_quarantine_prune() {  # <state-dir>
  local state=$1 path now cutoff tmp
  path=$(fm_task_number_quarantine_path "$state")
  [ -f "$path" ] && [ -r "$path" ] && [ ! -L "$path" ] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  cutoff=$((now - $(fm_task_number_quarantine_secs)))
  tmp=$(umask 077; mktemp "$state/.fm-task-number.XXXXXX" 2>/dev/null) || return 0
  if awk -v cutoff="$cutoff" \
      '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 > cutoff { print $1, $2 }' \
      "$path" > "$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$path" 2>/dev/null || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  return 0
}
