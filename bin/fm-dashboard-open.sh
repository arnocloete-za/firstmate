#!/usr/bin/env bash
# fm-dashboard-open.sh - the captain's `dashboard` command: open one board and
# leave it refreshing itself.
#
# bin/fm-install-dashboard-command.sh puts this on PATH as `dashboard`, which is
# the name every message here uses. Nothing about the board is decided in this
# file: bin/fm-dashboard.mjs owns the page, the board table, the read-only
# contract, and the watch interval's own validity, and this command only decides
# WHICH board, opens it, and keeps exactly one refresh loop alive per board.
#
# Usage:
#   dashboard                     the work board
#   dashboard personal            the personal board
#   dashboard --stop              stop that board's refresh loop
#   dashboard --status            is a loop refreshing that board? (exit 0 yes)
#   dashboard --interval <n>      seconds between refreshes of a loop it starts
#   dashboard -h, --help          this usage
#
# The refresh loop runs detached, so the terminal comes straight back and the
# loop is the captain's own process rather than one firstmate holds. Re-running
# the command REUSES a loop that is already refreshing that board instead of
# starting a second one, and always regenerates the page first so what opens is
# current rather than up to one interval old.
#
# A loop this command did NOT start - one he ran by hand, one an older launcher
# left - is reported and left to him rather than joined: it names the pid, says
# how to end it, and starts nothing, because two loops rewriting one page every
# interval is a mess nobody can manage. This command never signals a process it
# did not start. competing_pids owns how such a loop is found, and on what
# platform.
#
# DASHBOARD_INTERVAL sets the interval too; --interval wins. The default is
# PINNED here at 30 because the captain asked for 30 - deliberately not
# inherited from the generator's own default, so it cannot move under him if
# that default ever changes. Anything else about the value - its floor, its
# rejection - belongs to the generator and is surfaced from its own log.
#
# Why the liveness check looks the way it does
# --------------------------------------------
# The first version of this command decided whether a loop was running by
# pattern-matching the process list. That matched a CREWMATE, because a
# crewmate's launch brief quotes this very command, so it reported a loop that
# did not exist and the captain read a board nothing was refreshing.
#
# So nothing here ever searches the process table. A loop is identified by the
# pid recorded in $FM_HOME/.dashboard/<board>.watch.pid, and confirmed by
# fm_pid_identity (bin/fm-wake-lib.sh, the single owner of process identity in
# this repository) over THAT ONE PID: its own start time plus its own full argv,
# compared against the identity recorded when this command started it. Another
# process cannot enter that comparison however its command line reads, and a
# recycled pid fails it, which also means --stop can only ever signal a process
# this command started. An unconfirmed record is treated as no loop at all, so
# the check errs toward starting a refresh rather than toward a stale board.
# A record from a launcher older than this one carries no identity to compare;
# adoptable_watch says on what narrow proof one may still be adopted, and that
# proof is exact argv WORDS, which the command line behind the original false
# positive cannot satisfy.
#
# The pid is recorded by the very process that becomes the loop: it writes its
# own $$ and then execs the generator, which keeps that pid. So the record is
# exact whether or not setsid forks, and this command never has to guess which
# process its background job became.
set -uo pipefail

SELF=${BASH_SOURCE[0]}
# Installed as a symlink, so resolve the link chain before locating the repo.
# `pwd -P` alone resolves directory symlinks, never a symlinked script file.
HOPS=0
while [ -L "$SELF" ]; do
  HOPS=$((HOPS + 1))
  if [ "$HOPS" -gt 40 ]; then
    printf 'dashboard: cannot resolve my own path: symlink loop at %s\n' "$SELF" >&2
    exit 1
  fi
  LINK=$(readlink -- "$SELF") || {
    printf 'dashboard: cannot read the symlink %s\n' "$SELF" >&2
    exit 1
  }
  case "$LINK" in
    /*) SELF=$LINK ;;
    *) SELF=$(dirname -- "$SELF")/$LINK ;;
  esac
done
BIN=$(CDPATH='' cd -- "$(dirname -- "$SELF")" 2>/dev/null && pwd -P) || {
  printf 'dashboard: cannot resolve my own directory\n' >&2
  exit 1
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$BIN/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$BIN/fm-wake-lib.sh"

GEN="$FM_ROOT/bin/fm-dashboard.mjs"
GROUP=work
STOP=0
STATUS=0
INTERVAL=${DASHBOARD_INTERVAL:-30}

usage() {
  sed -n '10,18p' "$SELF" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'dashboard: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    # The generator's board table is the owner of what a board IS; these are
    # only the two names the captain types.
    work | personal) GROUP=$1 ;;
    --stop) STOP=1 ;;
    --status) STATUS=1 ;;
    --interval)
      shift
      INTERVAL=${1:-}
      [ -n "$INTERVAL" ] || die "--interval needs a number of seconds"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'dashboard: unknown argument %s\n' "'$1'" >&2
      exit 2
      ;;
  esac
  shift
done

case "$INTERVAL" in
  '' | *[!0-9]*) die "the interval must be a whole number of seconds, not '$INTERVAL'" ;;
esac

DIR="$FM_HOME/.dashboard"
RECORD="$DIR/$GROUP.watch.pid"
LOG="$DIR/$GROUP.watch.log"
SPAWN="$DIR/$GROUP.watch.spawning"
# How the captain names this board back to this command.
BOARD_ARG=''
[ "$GROUP" = work ] || BOARD_ARG=" $GROUP"

# One pid's own argv, space-joined. Used ONLY by the spawn handshake below, to
# see that the process this call just started has finished exec'ing into the
# generator, and only ever on the pid that process itself recorded. Never the
# liveness authority, and never a read of any pid but the one asked for.
pid_argv_joined() { # <pid>
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
  else
    LC_ALL=C ps -p "$1" -o args= 2>/dev/null
  fi
}

# True when the pid this call just spawned has become the generator refreshing
# this board, rather than the wrapper that recorded it a moment ago.
spawn_settled() { # <pid>
  local argv
  argv=$(pid_argv_joined "$1") || return 1
  [ -n "$argv" ] || return 1
  case "$argv" in *"$SPAWN"*) return 1 ;; esac
  case "$argv" in *"$GEN"*) ;; *) return 1 ;; esac
  case "$argv" in *' --watch'*) ;; *) return 1 ;; esac
  case "$argv" in *" --group $GROUP"*) ;; *) return 1 ;; esac
}

# One pid's own argv as separate WORDS, one per line. The NUL-separated form is
# the only one that can prove a word stands alone: the crewmate command line
# that produced the original false positive quotes this entire command INSIDE a
# single argument, so it satisfies every substring test and no exact-word test.
# Unavailable off Linux, and a failure here simply means no adoption.
pid_argv_words() { # <pid>
  [ -r "/proc/$1/cmdline" ] || return 1
  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null
}

# May a record that carries no identity - written by a launcher older than this
# one - be adopted as this board's refresh loop? Only on proof from that pid's
# own argv words. Anything less is not adopted, which costs one duplicate loop
# at worst and never a board that reports itself refreshed by a stranger.
adoptable_watch() { # <pid>
  local words
  words=$(pid_argv_words "$1") || return 1
  printf '%s\n' "$words" | grep -qxF -- "$GEN" || return 1
  printf '%s\n' "$words" | grep -qxF -- '--watch' || return 1
  printf '%s\n' "$words" | grep -qxF -- '--group' || return 1
  printf '%s\n' "$words" | grep -qxF -- "$GROUP" || return 1
}

# Every refresh loop for THIS board that this command did not start: one the
# captain ran by hand, or one an older launcher left behind. Finding those means
# enumerating processes, because there is no record naming them - but what is
# enumerated is PIDS ONLY, and every verdict still comes from reading that one
# pid's own NUL-separated argv WORDS, where a word either stands alone or does
# not count. A rendered `ps` line is never read, let alone searched: deciding
# from text that quotes this command is the entire defect this file exists to
# avoid. On the captain's own machine a substring search of these same processes
# matches six command lines; the word test matches only the two real loops.
#
# The board is read positionally, exactly as the generator parses it, so a loop
# started without --group counts as the work board just as the generator treats
# it. A loop carrying --out writes somewhere else and is not competing.
#
# Identity here is the generator and the board, so a second firstmate home
# running this same generator on the same board would be reported too - a fair
# thing to tell him, and his to decide about.
#
# Linux only: the argv-word form exists nowhere else, and where it is missing
# this scan reports nothing rather than guess from joined text.
competing_pids() { # <our-own-pid-or-empty>
  local ours=$1 dir pid
  [ -r /proc/self/cmdline ] || return 0
  for dir in /proc/[0-9]*; do
    pid=${dir#/proc/}
    [ "$pid" != "$ours" ] || continue
    [ "$pid" != "$$" ] || continue
    argv_words_are_this_boards_watch "$pid" || continue
    printf '%s\n' "$pid"
  done
}

# Read one pid's own argv words - no subprocess, because this runs for every
# process on the machine - and say whether they name the generator watching
# THIS board's own page.
argv_words_are_this_boards_watch() { # <pid>
  local file="/proc/$1/cmdline" word prev='' gen=0 watch=0 board=''
  [ -r "$file" ] || return 1
  while IFS= read -r -d '' word; do
    case "$word" in
      "$GEN") gen=1 ;;
      --watch) watch=1 ;;
      --out) return 1 ;;
    esac
    [ "$prev" != --group ] || board=$word
    prev=$word
  done < "$file" 2> /dev/null || return 1
  [ "$gen" -eq 1 ] && [ "$watch" -eq 1 ] || return 1
  # The generator's own default board when --group is not given.
  [ -n "$board" ] || board=work
  [ "$board" = "$GROUP" ]
}

# Tell him about a loop this command cannot manage, and leave the deciding to
# him: this command never signals a process it did not start.
report_competing() { # <newline-separated pids, as competing_pids prints them>
  local pids
  pids=$(printf '%s' "$1" | tr '\n' ' ')
  pids=${pids%% }
  [ -n "$pids" ] || return 1
  printf 'dashboard: another refresh loop is already running for the %s board, and this command did not start it (pid %s)\n' \
    "$GROUP" "${pids// /, }"
  printf 'dashboard: it is yours to end - stop it with  kill %s\n' "$pids"
}

write_record() { # <pid> <identity>
  local tmp="$RECORD.$$.tmp"
  (umask 077 && printf '%s\t%s\n' "$1" "$2" > "$tmp") || return 1
  mv -f "$tmp" "$RECORD" || {
    rm -f "$tmp"
    return 1
  }
}

# Print the pid of the loop refreshing this board, or fail. The whole liveness
# question is answered here: recorded pid, alive, and identical in process
# identity to what was recorded. A record carrying no identity - written by a
# launcher older than this one - is adopted once, on the narrow proof in
# adoptable_watch, so switching to this command need not orphan a loop the
# captain already has running.
watch_pid() {
  local record pid identity current
  # A plain, unlinked file only: --stop signals what this record names, so a
  # symlink pointing somewhere else must read as no loop rather than be followed.
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] && [ -r "$RECORD" ] || return 1
  record=$(cat "$RECORD" 2>/dev/null) || return 1
  IFS=$'\t' read -r pid identity <<< "$record"
  case "$pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  fm_pid_alive "$pid" || return 1
  if [ -z "$identity" ]; then
    adoptable_watch "$pid" || return 1
    identity=$(fm_pid_identity "$pid") || return 1
    write_record "$pid" "$identity" || return 1
  else
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ] || return 1
  fi
  printf '%s\n' "$pid"
}

report_log() {
  [ -s "$LOG" ] || return 0
  printf 'dashboard: the last of what it wrote:\n' >&2
  tail -n 5 "$LOG" >&2
}

start_watch() {
  local -a detach=()
  local pid='' deadline
  command -v setsid > /dev/null 2>&1 && detach=(setsid)
  if [ ! -d "$DIR" ]; then
    mkdir -p "$DIR" || return 1
    chmod 700 "$DIR" || return 1
  fi
  rm -f "$SPAWN"
  # Single quotes deliberately: $$ and $@ must expand in the launched shell,
  # not here, so the pid recorded is the process that becomes the refresh loop.
  # shellcheck disable=SC2016
  nohup "${detach[@]+${detach[@]}}" bash -c \
    'umask 077; printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
    _ "$SPAWN" "$GEN" --group "$GROUP" --watch --interval "$INTERVAL" \
    > "$LOG" 2>&1 < /dev/null &
  disown 2>/dev/null || true

  deadline=$(($(date +%s) + 10))
  while :; do
    # Only read the pid once the whole line is there. A command substitution
    # strips one trailing newline, so an empty last byte means the record the
    # loop wrote about itself is complete rather than half seen.
    if [ -z "$pid" ] && [ -s "$SPAWN" ] && [ -z "$(tail -c 1 "$SPAWN" 2>/dev/null)" ]; then
      pid=$(tr -dc '0-9' < "$SPAWN" 2>/dev/null)
    fi
    if [ -n "$pid" ] && fm_pid_alive "$pid" && spawn_settled "$pid"; then
      break
    fi
    # `exec` keeps the pid, so a pid this call recorded and that is now gone is
    # a loop that died rather than one still starting: say so at once instead of
    # waiting out the window.
    if [ -n "$pid" ] && ! fm_pid_alive "$pid"; then
      rm -f "$SPAWN" "$RECORD"
      printf 'dashboard: the refresh loop stopped as soon as it started; the page above is current as of now\n' >&2
      report_log
      return 1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # Never leave a half-started loop behind: kill it only when its own argv
      # proves it is the process this call just spawned.
      if [ -n "$pid" ] && fm_pid_alive "$pid"; then
        case "$(pid_argv_joined "$pid")" in
          *"$SPAWN"* | *"$GEN"*) kill "$pid" 2> /dev/null || true ;;
        esac
      fi
      rm -f "$SPAWN" "$RECORD"
      printf 'dashboard: the refresh loop did not start; the page above is still current as of now\n' >&2
      report_log
      return 1
    fi
    sleep 0.1
  done

  local identity
  identity=$(fm_pid_identity "$pid") || {
    kill "$pid" 2> /dev/null || true
    rm -f "$SPAWN" "$RECORD"
    die "cannot read the refresh loop's own process identity, so it was stopped rather than left untracked"
  }
  write_record "$pid" "$identity" || {
    kill "$pid" 2> /dev/null || true
    rm -f "$SPAWN"
    die "cannot record the refresh loop at $RECORD, so it was stopped rather than left untracked"
  }
  rm -f "$SPAWN"
  printf 'dashboard: refreshing every %ss (pid %s)\n' "$INTERVAL" "$pid"
}

if [ "$STATUS" -eq 1 ]; then
  pid=$(watch_pid) || pid=''
  competing=$(competing_pids "$pid")
  if [ -n "$pid" ]; then
    printf 'dashboard: the %s board is refreshing itself (pid %s)\n' "$GROUP" "$pid"
    report_competing "$competing" || true
    exit 0
  fi
  if [ -n "$competing" ]; then
    report_competing "$competing"
    exit 0
  fi
  printf 'dashboard: nothing is refreshing the %s board\n' "$GROUP"
  exit 1
fi

if [ "$STOP" -eq 1 ]; then
  if pid=$(watch_pid); then
    if kill "$pid" 2> /dev/null; then
      # The generator stops cleanly on SIGTERM and tells the open page it is
      # over, so wait briefly and say what actually happened.
      deadline=$(($(date +%s) + 5))
      while fm_pid_alive "$pid" && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 0.1
      done
      if fm_pid_alive "$pid"; then
        printf 'dashboard: asked the %s board refresh (pid %s) to stop; it has not finished yet\n' \
          "$GROUP" "$pid"
        exit 0
      fi
      rm -f "$RECORD"
      printf 'dashboard: stopped refreshing the %s board\n' "$GROUP"
      report_competing "$(competing_pids "$pid")" || true
      exit 0
    fi
    die "cannot stop the $GROUP board refresh (pid $pid)"
  fi
  rm -f "$RECORD"
  printf 'dashboard: nothing was refreshing the %s board\n' "$GROUP"
  report_competing "$(competing_pids '')" || true
  exit 0
fi

[ -x "$GEN" ] || die "cannot find the board itself at $GEN"

# Generate and open first, so the page he gets is current this second rather
# than as of the running loop's last pass. The generator owns the page, the
# opener, and the `dashboard:`/`open:` lines it prints.
"$GEN" --group "$GROUP" --open || die "could not generate the $GROUP board"

pid=$(watch_pid) || pid=''
competing=$(competing_pids "$pid")
if [ -n "$pid" ]; then
  printf 'dashboard: already refreshing itself (pid %s)\n' "$pid"
  report_competing "$competing" || true
elif [ -n "$competing" ]; then
  # Something is already rewriting this page every interval. Adding a second
  # loop is what left three of them fighting over one file, so say what is
  # there and let him hand it over rather than joining in.
  report_competing "$competing"
  printf 'dashboard: nothing new was started, so this board has one refresh and not two\n'
  printf 'dashboard: stop that one and run  dashboard%s  again for a refresh this command can manage\n' \
    "$BOARD_ARG"
  exit 0
else
  start_watch || exit 1
fi
printf 'dashboard: stop refreshing with  dashboard%s --stop\n' "$BOARD_ARG"
