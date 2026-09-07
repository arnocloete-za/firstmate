#!/usr/bin/env bash
# fm-conn.sh - set, release, and inspect the per-task "captain has the conn"
# flag.
#
# The flag's contract - file format, who writes it, the bounded idle expiry,
# and the fails-toward-supervision read rule - is owned by
# bin/fm-conn-lib.sh. This is the command surface firstmate uses when it must
# set or release the flag by hand, and the read a human uses to see which task
# the captain is working in.
#
# The worker does NOT need this command: its brief renders the exact one-line
# write instead, because a crewmate lives in a foreign worktree with no
# firstmate home in its environment (bin/fm-brief.sh).
#
# Usage:
#   fm-conn.sh set <task-id>
#       Record that the captain is working in that task's terminal, or refresh
#       an existing record. Idempotent.
#   fm-conn.sh clear <task-id>
#       Release the flag. Releasing one nobody holds is a silent no-op.
#   fm-conn.sh check <task-id>
#       Exit 0 while the flag is held, 1 otherwise. Prints nothing, so
#       supervision scripts and hooks can branch on it.
#   fm-conn.sh status [<task-id>]
#       One line per task. With a task id, print that task's line; without
#       one, print a line for every task that has a record, or "(none)".
#
# Status lines:
#   <task>: captain has the conn (<age>s, <remaining>s before it lapses)
#   <task>: no conn record
#   <task>: conn record lapsed <age>s ago (idle window <window>s)
#   <task>: conn record unusable - reads as no conn
#
# Exit codes: 0 ok, 1 check-miss, 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-conn-lib.sh
. "$SCRIPT_DIR/fm-conn-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { echo "error: $1" >&2; exit 2; }

# A task id must name one record inside this home's state directory, never a
# path that escapes it.
require_task_id() {  # <task-id>
  [ -n "${1:-}" ] || die "a task id is required"
  case "$1" in
    */*|.|..|-*) die "'$1' is not a task id" ;;
  esac
}

status_line() {  # <task-id>
  local task=$1 age epoch window remaining
  window=$(fm_conn_idle_secs)
  if age=$(fm_conn_age "$STATE" "$task"); then
    remaining=$((window - age))
    printf '%s: captain has the conn (%ss, %ss before it lapses)\n' "$task" "$age" "$remaining"
    return 0
  fi
  # A dangling symlink is a record that EXISTS and cannot be read, which is a
  # different thing to report than no record at all, so test for the link too.
  if ! [ -e "$(fm_conn_path "$STATE" "$task")" ] \
    && ! [ -L "$(fm_conn_path "$STATE" "$task")" ]; then
    printf '%s: no conn record\n' "$task"
    return 1
  fi
  if epoch=$(fm_conn_recorded_epoch "$STATE" "$task"); then
    printf '%s: conn record lapsed %ss ago (idle window %ss)\n' \
      "$task" "$(( $(date +%s) - epoch ))" "$window"
  else
    printf '%s: conn record unusable - reads as no conn\n' "$task"
  fi
  return 1
}

CMD=${1:-}
case "$CMD" in
  -h|--help) usage; exit 0 ;;
  set)
    require_task_id "${2:-}"
    [ $# -eq 2 ] || die "set takes exactly one task id"
    fm_conn_set "$STATE" "$2" \
      || die "could not record the conn for $2 in $STATE"
    status_line "$2" || true
    ;;
  clear)
    require_task_id "${2:-}"
    [ $# -eq 2 ] || die "clear takes exactly one task id"
    fm_conn_clear "$STATE" "$2" || die "could not release the conn for $2"
    printf '%s: conn released\n' "$2"
    ;;
  check)
    require_task_id "${2:-}"
    [ $# -eq 2 ] || die "check takes exactly one task id"
    fm_conn_held "$STATE" "$2" || exit 1
    ;;
  status)
    if [ $# -ge 2 ]; then
      require_task_id "$2"
      [ $# -eq 2 ] || die "status takes at most one task id"
      status_line "$2" || exit 1
    else
      FOUND=0
      HELD=0
      for f in "$STATE"/*.conn; do
        # A record that exists but cannot be read must be LISTED as unusable
        # rather than skipped into invisibility, so a dangling link counts.
        [ -e "$f" ] || [ -L "$f" ] || continue
        FOUND=1
        ID=$(basename "$f" .conn)
        if status_line "$ID"; then HELD=1; fi
      done
      [ "$FOUND" -eq 1 ] || printf '(none)\n'
      [ "$HELD" -eq 1 ] || exit 1
    fi
    ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command '$CMD'" ;;
esac
