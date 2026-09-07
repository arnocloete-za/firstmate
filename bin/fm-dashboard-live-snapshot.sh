#!/usr/bin/env bash
# fm-dashboard-live-snapshot.sh - read-only LIVE WORK projection for the /dashboard board.
#
# The /dashboard page has two halves. bin/fm-dashboard-snapshot.sh reads every
# registered project's git health; this script reads the work that is running
# right now, one row per live task, so the captain can see which task terminals
# exist and which one is waiting on him instead of hunting through them.
#
# This script parses NO fleet state of its own. bin/fm-fleet-snapshot.sh is the
# canonical structured fleet reader ("Human views must render this output
# instead of parsing state files again"), so this is a view-specific projection
# over `fm-fleet-snapshot.sh --json`: it renames, classifies, ranks, and
# translates that contract into captain-facing words, and never re-derives
# current state, backlog roles, or captain actionability. Every field it reads
# is owned there.
#
# Terminal presence is read through fm_backend_agent_state() from
# bin/fm-backend.sh - the recovery-grade endpoint contract - NOT through the
# canonical snapshot's endpoint.exists. Two reasons: endpoint.agent_alive is
# deliberately "not_checked" for ordinary tasks, and a presentation surface that
# offers "here is how to reach this terminal" has to be right about whether that
# terminal is still there. fm_backend_agent_state requires a successful session
# inventory and reports `missing` only when it omits the exact window, which is
# what makes the presence column honest. This script only reads that verdict; it
# never acts on it (`dead`/`missing` license recovery for supervision, never for
# a board).
#
# Read-only and side-effect free: it observes fleet state and never steers,
# tears down, merges, or mutates a task. The canonical snapshot it shells out to
# may refresh its own parent-side remote-ledger cache; that is that script's
# documented observational write, not this one's.
#
# Freshness: this projection is a point-in-time observation, like the rest of the
# board, and says so. generated_at is this run's own observation time and
# fleet_observed_at is the canonical snapshot's. Live work ages far faster than
# git health - a worker parked on a decision can be working again a minute later
# - so the rendered page states the age of THIS section and degrades visibly
# rather than presenting an old read as current. The template owns that
# presentation.
#
# Output contract: fm-dashboard-live.v1, a single compact JSON object on stdout.
#   {
#     "schema": "fm-dashboard-live.v1",
#     "generated_at": "<ISO-8601 UTC, this run>",
#     "available": true|false,
#     "reason": "<why unavailable>",            (only when available=false)
#     "fleet_observed_at": "<canonical snapshot observation time>",
#     "tasks": [                                (pre-sorted, see RANKS below)
#       {
#         "id": "<task id>",
#         "project": "<the captain's name for the project>",
#         "project_path": "<resolved project path>",
#         "kind": "ship"|"scout"|"secondmate"|...,
#         "title": "<work item title, or null>",
#         "state": "working|parked|paused|blocked|failed|done|conn|unknown",
#         "activity": "<plain words: what it is doing now>",
#         "waiting": {
#           "kind": "failed|blocked|decision|review|gate|external|conn|none|unclear",
#           "label": "<plain-words badge>",
#           "note": "<captain-facing reason, or empty>",
#           "wants_captain": true|false
#         },
#         "terminal": {
#           "target": "<recorded endpoint, or null>",
#           "presence": "live|idle|gone|unclear|remote|unknown",
#           "presence_note": "<plain words>",
#           "command": "<copyable jump command, or null>"
#         },
#         "pr_url": "<recorded PR url, or null>",
#         "rank": <integer sort key>
#       }, ...
#     ]
#   }
#
# A task row is emitted for every live task the canonical snapshot reports (one
# per state/<id>.meta). A task record exists until its work lands and is cleaned
# up, so a finished-but-unlanded task stays on the board - that row is exactly
# the "PR waiting to be approved" case.
#
# RANKS - the board is sorted so whatever wants the captain is at the top:
#   0 failed    the work failed                            (wants captain)
#   1 blocked   stuck, needs him                            (wants captain)
#   2 decision  a decision he owes it                       (wants captain)
#   3 review    finished, waiting to be approved            (wants captain)
#   4 unclear   state could not be read - worth a look
#   5 gate      in its own review; no action from him
#   6 external  a declared wait it expects to clear itself
#   7 conn      he is working in that terminal right now
#   8 none      working; nothing owed
# Ties break on task id so the order is stable between runs.
# wants_captain is deliberately reserved for ranks 0-3. `unclear` sorts above the
# calm rows but does NOT claim him, because a badge that fires on ambiguity stops
# meaning anything.
#
# "Captain has the conn" (the state meaning the captain is personally working in
# that task's terminal) is recognized forward-compatibly and is NOT owned here:
# it is set and expired by its own script and made visible through
# bin/fm-crew-state.sh, which is what the canonical snapshot reads. Until that
# lands nothing sets it and no row reports it. This projection accepts any of
# the three shapes that surfacing can take - a `conn` current state, a
# current_state.conn boolean, or the phrase "captain has the conn" in the state
# detail - and gives it its own rank, so a task he is personally driving never
# reads as stuck and never claims to be waiting on him.
#
# Usage:
#   fm-dashboard-live-snapshot.sh [--fleet-json <file>]
#     --fleet-json <file>  project this already-captured `fm-fleet-snapshot.sh
#                          --json` output instead of running it again. The
#                          /dashboard flow reads the fleet once for its bearings
#                          check, so passing that capture back in avoids paying
#                          for a second full fleet read.
#     -h, --help           usage
#
# An unreadable or unparseable fleet read is reported as available:false with a
# reason rather than failing: the project half of the board must still build.
#
# FM_ROOT_OVERRIDE / FM_HOME follow the same override contract as the rest of
# bin/.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME

FLEET_SNAPSHOT="$SCRIPT_DIR/fm-fleet-snapshot.sh"
FLEET_JSON=""

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-dashboard-live-snapshot: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --fleet-json)
      [ $# -ge 2 ] || fail "--fleet-json requires a value"
      FLEET_JSON=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# unavailable <reason>: emit a well-formed but empty projection. The board's
# project half must still build when the fleet read is unusable.
unavailable() {
  jq -n --arg gen "$NOW" --arg reason "$1" \
    '{schema: "fm-dashboard-live.v1", generated_at: $gen, available: false,
      reason: $reason, fleet_observed_at: null, tasks: []}'
  exit 0
}

# --- 1. obtain the canonical fleet snapshot --------------------------------
FLEET=""
if [ -n "$FLEET_JSON" ]; then
  [ -f "$FLEET_JSON" ] || unavailable "the supplied fleet snapshot does not exist"
  FLEET=$(cat "$FLEET_JSON" 2>/dev/null) || unavailable "the supplied fleet snapshot could not be read"
else
  [ -x "$FLEET_SNAPSHOT" ] || unavailable "the fleet reader is not available"
  FLEET=$("$FLEET_SNAPSHOT" --json 2>/dev/null) || unavailable "the fleet read did not complete"
fi

printf '%s' "$FLEET" | jq -e 'type == "object" and (.tasks | type == "array")' >/dev/null 2>&1 \
  || unavailable "the fleet read did not return a readable fleet snapshot"

# --- 2. honest terminal presence, per task --------------------------------
# fm_backend_agent_state is the recovery-grade endpoint contract (see the header
# note on why endpoint.exists is not used here). Only tmux and herdr have a
# recovery classifier; anything else, and any remote endpoint, reports unknown
# rather than guessing, and gets no jump command it cannot honor.
presence_for() {  # <backend> <target> <remote>
  local backend=$1 target=$2 remote=$3
  if [ -n "$remote" ] && [ "$remote" != null ]; then
    printf 'remote'
    return 0
  fi
  if [ -z "$target" ] || [ "$target" = null ]; then
    printf 'unknown'
    return 0
  fi
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    alive)      printf 'live' ;;
    dead)       printf 'idle' ;;
    missing)    printf 'gone' ;;
    ambiguous)  printf 'unclear' ;;
    *)          printf 'unknown' ;;
  esac
}

# The jump command is composed from the endpoint's own recorded session, never
# from a hardcoded session name: the session is whichever one the primary harness
# runs in, or `firstmate` when it runs outside tmux (docs/tmux-backend.md).
#
# `attach` then `switch-client` covers both places the captain can be standing,
# verified against real tmux 3.4 (docs/verification/runtime-backends.md, tmux):
# from outside tmux `attach -t <session>:<window>` attaches AND selects that
# window; from inside a tmux client it refuses to nest (rc=1, nothing changes)
# and `switch-client` moves his existing client to the window instead. A window
# that is gone fails loudly on both ("can't find window: ..."), so a presence
# read that goes stale by seconds can never silently send him nowhere. No
# command is offered for a terminal already known to be gone, though: `missing`
# is an authoritative verdict (an inventory that cannot be read reports unknown
# instead), and a jump known to fail is worse than plainly saying the terminal
# is gone.
jump_command() {  # <backend> <target> <presence>
  local backend=$1 target=$2 presence=$3
  [ "$backend" = tmux ] || return 0
  [ -n "$target" ] && [ "$target" != null ] || return 0
  case "$presence" in
    remote|unknown|gone) return 0 ;;
  esac
  printf "tmux attach -t '%s' 2>/dev/null || tmux switch-client -t '%s'" "$target" "$target"
}

presence_map='{}'
while IFS=$'\t' read -r id backend target remote; do
  [ -n "$id" ] || continue
  p=$(presence_for "$backend" "$target" "$remote")
  c=$(jump_command "$backend" "$target" "$p")
  presence_map=$(printf '%s' "$presence_map" | jq -c \
    --arg id "$id" --arg presence "$p" --arg command "$c" \
    '.[$id] = {presence: $presence, command: (if $command == "" then null else $command end)}')
done <<EOF
$(printf '%s' "$FLEET" | jq -r '
  .tasks[]
  | [ .id,
      (.backend // ""),
      (.endpoint.target // ""),
      (if .remote == null then "" else (.remote | tostring) end)
    ] | @tsv')
EOF

# --- 3. project the canonical contract into the board's own contract -------
# Everything below is a rename/classification of fields the canonical snapshot
# already decided. Captain-facing wording follows AGENTS.md section 9: the page
# says "stopped at a review point", not "parked at fix_review".
printf '%s' "$FLEET" | jq -c \
  --arg gen "$NOW" \
  --argjson presence "$presence_map" '

def nonempty($s): ($s // "") | if . == "" then null else . end;

# The captain-facing project name: the work item repo when it records one, else
# the last component of the project path. Never the task id.
def project_name:
  (.backlog.repo // null) as $repo
  | if ($repo | type) == "string" and $repo != "" then $repo
    else ((.project // "") | split("/") | map(select(length > 0)) | last) // "unregistered"
    end;

# Recognized forward-compatibly; owned by the captain-has-the-conn work, not
# here. See the header note.
def has_conn:
  (.current_state.state // "") == "conn"
  or (.current_state.conn // false) == true
  or ((.current_state.detail // "") | test("captain has the conn"; "i"));

# What it is doing now, in plain words, from the canonical CURRENT state - never
# from the last status event. The detail vocabulary mapped here is emitted by
# bin/fm-crew-state.sh; an unmapped detail falls back to the state itself rather
# than leaking a pipeline label onto the page.
def activity:
  (.current_state.state // "unknown") as $s
  | (.current_state.detail // "") as $d
  | if has_conn then "You are working in this terminal"
    elif $s == "working" then
      if ($d | test("^ci running")) then "Running its checks"
      elif ($d | test("validating \\(fixing\\)")) then "Fixing what its review found"
      elif ($d | test("validating")) then "Checking its own work"
      elif ($d | test("harness busy")) then "Working"
      elif ($d | test("^run active")) then "Checking its own work"
      elif ($d | length) > 0 then $d
      else "Working"
      end
    elif $s == "parked" then
      if ($d | test("ask-user")) then "Stopped for a decision it cannot make itself"
      else "Stopped at a review point in its own checks"
      end
    elif $s == "paused" then "Idling on a wait it expects to clear"
    elif $s == "blocked" then "Stopped and needs help"
    elif $s == "failed" then "Its work failed"
    elif $s == "done" then
      if ($d | test("merged|closed")) then "Finished and landed"
      elif ($d | test("checks green|ready for review")) then "Finished, checks passed"
      else "Finished"
      end
    else "Could not read what it is doing"
    end;

# The captain-facing reason he is wanted. Preference order is deliberate: a
# captain hold reason is a sentence firstmate already wrote FOR him, so it beats
# any label this projection could compose. Raw current-state detail is never
# used - it is evidence, not captain-facing prose.
def waiting_note:
  nonempty(.backlog.hold_reason)
  // nonempty(.backlog.blocked_reason)
  // (if ((.hints.open_decisions // []) | length) > 0
      then ((.hints.open_decisions // []) | map(tostring) | join("; "))
      else null end)
  // (if ((.current_state.state // "") == "parked"
          and ((.current_state.detail // "") | test("ask-user")))
      then "Its own review raised a call it is not allowed to make."
      elif (.backlog.captain_actionable // false) == true
      then "This work is held for you."
      else null end)
  // "";

# Does a decision sit with the captain? Every input is a canonical decision the
# snapshot already made: its keyed open-decision fold, its captain-hold
# metadata, its own captain-actionability rule, and an ask-user gate (the one
# gate class whose authority is never the worker own).
def owes_decision:
  ((.hints.open_decisions // []) | length) > 0
  or (.hints.pending_decision // false) == true
  or (.backlog.captain_actionable // false) == true
  or (.backlog.hold_kind // "") == "captain"
  or ((.current_state.state // "") == "parked"
      and ((.current_state.detail // "") | test("ask-user")));

def waiting_kind:
  (.current_state.state // "unknown") as $s
  | if has_conn then "conn"
    elif $s == "failed" then "failed"
    elif $s == "blocked" or (.hints.blocked_event // false) == true then "blocked"
    elif owes_decision then "decision"
    elif $s == "done" then "review"
    elif $s == "parked" then "gate"
    elif $s == "paused" then "external"
    elif $s == "working" then "none"
    else "unclear"
    end;

def rank($kind):
  {failed: 0, blocked: 1, decision: 2, review: 3, unclear: 4,
   gate: 5, external: 6, conn: 7, none: 8}[$kind] // 9;

def waiting_label($kind):
  {failed:   "Failed",
   blocked:  "Blocked - needs you",
   decision: "Needs your decision",
   review:   "Ready for your review",
   unclear:  "Unclear - worth a look",
   gate:     "In its own review",
   external: "Waiting on something outside",
   conn:     "You have the conn",
   none:     "Nothing owed"}[$kind] // "Unclear - worth a look";

def presence_note($p):
  {live:    "a worker is in this terminal",
   idle:    "the terminal is open but no worker is in it",
   gone:    "this terminal no longer exists",
   unclear: "cannot tell what is in this terminal",
   remote:  "this work runs on another machine",
   unknown: "terminal state unknown"}[$p] // "terminal state unknown";

{
  schema: "fm-dashboard-live.v1",
  generated_at: $gen,
  available: true,
  fleet_observed_at: (.generated // null),
  tasks: (
    [ .tasks[]
      | . as $t
      | (waiting_kind) as $kind
      | ($presence[$t.id] // {presence: "unknown", command: null}) as $ep
      | {
          id: $t.id,
          project: project_name,
          project_path: nonempty($t.project),
          kind: ($t.kind // null),
          title: nonempty($t.backlog.title),
          state: (if has_conn then "conn" else ($t.current_state.state // "unknown") end),
          activity: activity,
          waiting: {
            kind: $kind,
            label: waiting_label($kind),
            note: waiting_note,
            wants_captain: (rank($kind) <= 3)
          },
          terminal: {
            target: nonempty($t.endpoint.target),
            presence: $ep.presence,
            presence_note: presence_note($ep.presence),
            command: $ep.command
          },
          pr_url: nonempty($t.pr.url),
          rank: rank($kind)
        }
    ]
    | sort_by([.rank, .id])
  )
}'
