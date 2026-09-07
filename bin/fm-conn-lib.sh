#!/usr/bin/env bash
# fm-conn-lib.sh - the per-task "captain has the conn" flag (one owner).
#
# WHY. Firstmate launches the work, but the captain reads and steers it in that
# one task's OWN terminal (AGENTS.md hard rule 4). While he is standing there,
# supervision must not also be driving that worker: a re-rung instruction, a
# stale-pane nag, or a firstmate steer arriving mid-conversation means two
# supervisors on one worker. This flag is how a worker tells its home that the
# captain is present, and how every supervision surface learns to stand off
# that ONE task without standing off the fleet.
#
# CONTRACT.
#   - Flag file: $STATE/<task>.conn, one line holding the epoch second of the
#     captain's most recent message in that pane. Nothing else is in the file.
#   - WRITERS. The worker is the only reliable detector of the captain's
#     presence, so the worker sets and refreshes it on every unmarked human
#     message in its pane; the brief scaffold (bin/fm-brief.sh) renders the
#     exact `date +%s > '<path>'` command, the same way it renders the status
#     append, so a worker needs neither this repo on its PATH nor a resolvable
#     firstmate home from inside a foreign worktree. Firstmate sets and clears
#     it by hand through bin/fm-conn.sh. bin/fm-teardown.sh removes it with the
#     task's other runtime records.
#   - REFRESH, NOT ACCUMULATION. A refresh replaces the single line, so the
#     file records only how long ago the captain last spoke, never a history.
#   - BOUNDED EXPIRY IS MANDATORY. The flag is held only while its recorded
#     epoch is within FM_CONN_IDLE_SECS (default below). A captain who walks
#     away therefore returns the task to ordinary supervision on its own, with
#     nobody having to remember to clear the flag: a flag that stuck on
#     silently would leave a live task unsupervised, which is worse than the
#     interleaving it prevents. Expiry is purely a function of time, so every
#     read is idempotent and no read ever writes - an expired record is left in
#     place so `bin/fm-conn.sh status` can still say how long ago it lapsed.
#   - FAILS TOWARD SUPERVISION. Absent, unreadable, a symlink, not a regular
#     file, empty, non-numeric, future-dated, or expired all read as NOT held.
#     Every uncertainty therefore resumes supervision rather than suppressing
#     it, and a partially written refresh costs at most one poll of ordinary
#     supervision instead of a silent supervision hole.
#
# WHAT THE FLAG DOES NOT DO. It suppresses supervision's own initiative
# (bin/fm-watch.sh stops re-ringing that task's steering inbox and stops
# raising its stale and wedge escalations; AGENTS.md section 8 owns firstmate's
# matching restraint). It never weakens cleanup safety, unlanded-work
# protection, merge authority, PR guards, or record keeping, and it is never
# authority to act on a captain ruling that is not in that task's durable
# record: what the captain settles in a pane reaches firstmate through the
# worker's own status append, never by reading his conversation there.
#
# Read-only on source, no side effects, `set -u` safe, Bash 3.2 compatible.
# The command surface is bin/fm-conn.sh; the supervision consequences are
# bin/fm-watch.sh's; the visible surfaces are bin/fm-crew-state.sh,
# bin/fm-session-start.sh, bin/fm-fleet-snapshot.sh, and
# bin/fm-bearings-snapshot.sh. None of them restates this contract.
#
# Tunables (env):
#   FM_CONN_IDLE_SECS   default 900; the bounded idle window before expiry

# The bounded idle window. Fifteen minutes is long enough for the captain to
# read a worker's reply and think before typing again, and short enough that a
# terminal he has abandoned rejoins supervision inside one heartbeat cycle.
FM_CONN_IDLE_SECS_DEFAULT=900

fm_conn_idle_secs() {
  local secs=${FM_CONN_IDLE_SECS:-$FM_CONN_IDLE_SECS_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*) secs=$FM_CONN_IDLE_SECS_DEFAULT ;;
  esac
  printf '%s' "$secs"
}

fm_conn_path() {  # <state-dir> <task-id>
  printf '%s/%s.conn' "$1" "$2"
}

# Recorded epoch of the captain's last message, or nothing. A record that is
# not a plain readable regular file, or whose single line is not a bare epoch,
# prints nothing and fails - the fails-toward-supervision rule above.
fm_conn_recorded_epoch() {  # <state-dir> <task-id>
  local f epoch
  f=$(fm_conn_path "$1" "$2")
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  epoch=$(LC_ALL=C command head -1 "$f" 2>/dev/null) || return 1
  epoch=${epoch%$'\r'}
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$epoch"
}

# Seconds since the captain's last message in that pane, printed only while the
# flag is HELD (exit 0). Prints nothing and exits 1 when there is no record,
# the record is unusable, its epoch is in the future, or the idle window has
# elapsed.
fm_conn_age() {  # <state-dir> <task-id>
  local epoch now age
  epoch=$(fm_conn_recorded_epoch "$1" "$2") || return 1
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$epoch" -le "$now" ] || return 1
  age=$((now - epoch))
  [ "$age" -lt "$(fm_conn_idle_secs)" ] || return 1
  printf '%s' "$age"
}

# 0 while the captain holds this task's terminal, 1 otherwise. Prints nothing.
fm_conn_held() {  # <state-dir> <task-id>
  fm_conn_age "$1" "$2" >/dev/null 2>&1
}

# The ONE captain-at-the-conn phrase every firstmate-facing surface prints, so
# the digest, the current-state read, and the command surface cannot describe
# the same fact three different ways. Exits 1 and prints nothing when the flag
# is not held.
fm_conn_label() {  # <state-dir> <task-id>
  local age
  age=$(fm_conn_age "$1" "$2") || return 1
  printf 'captain has the conn (%ss)' "$age"
}

# Take or refresh the flag. Idempotent: the record is one line, so a refresh
# replaces it. Writes through a temp file in the same directory and renames, so
# a concurrent reader sees either the previous epoch or the new one.
fm_conn_set() {  # <state-dir> <task-id>
  local state=$1 task=$2 f tmp
  f=$(fm_conn_path "$state" "$task")
  [ -d "$state" ] || return 1
  tmp=$(umask 077; mktemp "$state/.fm-conn.XXXXXX") || return 1
  if ! date +%s > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$f"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Release the flag. Removing a flag nobody holds is a silent success, so a
# retry after a partial failure is safe.
fm_conn_clear() {  # <state-dir> <task-id>
  rm -f -- "$(fm_conn_path "$1" "$2")"
}
