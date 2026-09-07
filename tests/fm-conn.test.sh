#!/usr/bin/env bash
# tests/fm-conn.test.sh - the per-task "captain has the conn" flag
# (bin/fm-conn-lib.sh, driven through bin/fm-conn.sh).
#
# The flag says the captain is working in one task's own terminal, so
# supervision stands off that task. Two properties carry the whole safety
# argument and are pinned here:
#
#   - it EXPIRES on a bounded idle window, refreshed by each captain message,
#     so a terminal he walked away from cannot stay silently unsupervised; and
#   - every uncertain read - absent, unreadable, a symlink, empty, non-numeric,
#     future-dated - reads as NOT held, so uncertainty resumes supervision
#     rather than suppressing it.
#
# The watcher consequences (no steering-inbox re-ring, no stale or wedge
# escalation) live in fm-watch-triage.test.sh; the visible surfaces in
# fm-crew-state.test.sh, fm-session-start.test.sh, and
# fm-bearings-snapshot.test.sh; the worker's side of the contract in
# fm-brief.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONN="$ROOT/bin/fm-conn.sh"
TMP_ROOT=$(fm_test_tmproot fm-conn-tests)

# A fresh state dir per case, so one case's records cannot leak into another.
make_state() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

conn() {  # <state> <args...>
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$CONN" "$@"
}

test_help_includes_entire_header() {
  local out
  out=$(FM_STATE_OVERRIDE="$(make_state help)" "$CONN" --help)
  assert_contains "$out" "fm-conn.sh set <task-id>" "help must document set"
  assert_contains "$out" "fm-conn.sh clear <task-id>" "help must document clear"
  assert_contains "$out" "fm-conn.sh check <task-id>" "help must document check"
  assert_contains "$out" "fm-conn.sh status [<task-id>]" "help must document status"
  pass "fm-conn: --help prints the whole command surface"
}

test_set_check_clear_round_trip() {
  local state out rc
  state=$(make_state round-trip)

  conn "$state" check demo && fail "check reported a conn nobody has taken"

  out=$(conn "$state" set demo)
  assert_contains "$out" "demo: captain has the conn" "set must report the taken conn"
  conn "$state" check demo || fail "check did not see the conn just taken"

  # Idempotent: taking it again is a refresh, not a second record.
  conn "$state" set demo >/dev/null
  conn "$state" check demo || fail "a refresh dropped the conn"

  out=$(conn "$state" clear demo)
  assert_contains "$out" "demo: conn released" "clear must report the release"
  conn "$state" check demo && fail "check still saw a released conn"

  # Releasing what nobody holds is a silent success, so a retry after a partial
  # failure is safe.
  out=$(conn "$state" clear demo); rc=$?
  expect_code 0 "$rc" "clearing an unheld conn must succeed"

  pass "fm-conn: set, check, clear round-trip is idempotent in both directions"
}

# The mandatory half. A flag that stuck on would leave a live task
# unsupervised, which is worse than the interleaving it prevents.
test_conn_expires_on_the_bounded_idle_window() {
  local state now
  state=$(make_state expiry)
  now=$(date +%s)

  # Just inside the window: still held.
  printf '%s\n' "$((now - 100))" > "$state/inside.conn"
  FM_CONN_IDLE_SECS=200 conn "$state" check inside \
    || fail "a conn inside its idle window was not held"

  # Past the window: not held, and the record is deliberately left in place so
  # a human can still see when it lapsed. Nothing about a read may write.
  printf '%s\n' "$((now - 300))" > "$state/lapsed.conn"
  FM_CONN_IDLE_SECS=200 conn "$state" check lapsed \
    && fail "a conn past its idle window was still held"
  assert_present "$state/lapsed.conn" "a lapsed record must not be removed by a read"
  assert_contains "$(FM_CONN_IDLE_SECS=200 conn "$state" status lapsed || true)" \
    "conn record lapsed" "status must say a record lapsed rather than call it absent"

  # A captain message refreshes it, which is the only thing that extends the
  # window.
  conn "$state" set lapsed >/dev/null
  FM_CONN_IDLE_SECS=200 conn "$state" check lapsed \
    || fail "a refresh did not restore a lapsed conn"

  # The default window is a real bound, not "forever": a record older than it
  # is not held with no override in play.
  printf '%s\n' "$((now - 100000))" > "$state/ancient.conn"
  conn "$state" check ancient \
    && fail "the default idle window did not expire a very old record"

  pass "fm-conn: the conn expires on a bounded idle window and only a captain message refreshes it"
}

# Every uncertainty must resume supervision. A supervision hole that opens
# because a record could not be parsed is exactly the failure mode the flag is
# not allowed to have.
test_unusable_records_read_as_no_conn() {
  local state now
  state=$(make_state unusable)
  now=$(date +%s)

  : > "$state/empty.conn"
  conn "$state" check empty && fail "an empty record was treated as a held conn"

  printf 'right now\n' > "$state/prose.conn"
  conn "$state" check prose && fail "a non-numeric record was treated as a held conn"

  printf '%s\n' "$((now + 3600))" > "$state/future.conn"
  conn "$state" check future && fail "a future-dated record was treated as a held conn"

  mkdir -p "$state/dir.conn"
  conn "$state" check dir && fail "a directory was treated as a held conn"

  printf '%s\n' "$now" > "$state/real-target"
  ln -s "$state/real-target" "$state/link.conn"
  conn "$state" check link && fail "a symlinked record was treated as a held conn"

  ln -s "$state/no-such-target" "$state/dangling.conn"
  conn "$state" check dangling && fail "a dangling symlink was treated as a held conn"

  # A record that exists and cannot be read must stay VISIBLE as unusable
  # rather than vanish from the listing, whether asked for by name or not.
  assert_contains "$(conn "$state" status prose || true)" "unusable" \
    "status must name an unusable record rather than silently reporting no conn"
  assert_contains "$(conn "$state" status dangling || true)" "unusable" \
    "status must name a dangling record as unusable, not as absent"
  assert_contains "$(conn "$state" status || true)" "dangling: conn record unusable" \
    "the full listing must include an unreadable record rather than skipping it"

  pass "fm-conn: empty, non-numeric, future-dated, directory, and symlink records all read as no conn and stay visible"
}

# The age is measured when the read happens, not when the record was written,
# so assert the shape plus bounds rather than exact seconds - the two numbers
# must always account for the whole configured window between them.
test_status_reports_age_and_remaining_window() {
  local state now out age remaining
  state=$(make_state status-detail)
  now=$(date +%s)
  printf '%s\n' "$((now - 60))" > "$state/held.conn"
  out=$(FM_CONN_IDLE_SECS=300 conn "$state" status held)
  assert_contains "$out" "held: captain has the conn (" \
    "status must report how long the captain has held the terminal"
  assert_contains "$out" "before it lapses" \
    "status must report how long is left before the conn lapses"
  age=$(printf '%s\n' "$out" | sed -n 's/.*conn (\([0-9]*\)s, .*/\1/p')
  remaining=$(printf '%s\n' "$out" | sed -n 's/.*, \([0-9]*\)s before it lapses.*/\1/p')
  case "$age$remaining" in
    ''|*[!0-9]*) fail "status did not report a numeric age and remaining window: $out" ;;
  esac
  [ "$age" -ge 60 ] || fail "status under-reported the held age: ${age}s"
  [ "$((age + remaining))" -eq 300 ] \
    || fail "age ${age}s plus remaining ${remaining}s must account for the whole 300s window"
  pass "fm-conn: status reports both the held age and the remaining window"
}

test_status_without_a_task_lists_every_record() {
  local state now out rc
  state=$(make_state status-all)
  now=$(date +%s)

  out=$(conn "$state" status); rc=$?
  assert_contains "$out" "(none)" "status on an empty home must say so explicitly"
  expect_code 1 "$rc" "status must exit 1 when no task holds the conn"

  printf '%s\n' "$now" > "$state/alpha.conn"
  printf '%s\n' "$((now - 100000))" > "$state/beta.conn"
  out=$(conn "$state" status); rc=$?
  expect_code 0 "$rc" "status must exit 0 while any task holds the conn"
  assert_contains "$out" "alpha: captain has the conn" "status must list the held task"
  assert_contains "$out" "beta: conn record lapsed" "status must list a lapsed record too"
  pass "fm-conn: status with no task lists every record and distinguishes held from lapsed"
}

test_task_ids_cannot_escape_the_state_directory() {
  local state out rc
  state=$(make_state escape)
  for bad in '../escape' 'a/b' '.' '..'; do
    out=$(conn "$state" set "$bad" 2>&1); rc=$?
    expect_code 2 "$rc" "set must refuse the task id '$bad'"
    assert_contains "$out" "is not a task id" "set must say why '$bad' was refused"
  done
  assert_absent "$TMP_ROOT/escape.conn" "a refused id must not have written outside the state dir"
  pass "fm-conn: a task id that is a path is refused instead of writing outside the state dir"
}

test_usage_errors_are_loud() {
  local rc out
  local state
  state=$(make_state usage)
  conn "$state" 2>/dev/null; rc=$?
  expect_code 2 "$rc" "no command must be a usage error"
  out=$(conn "$state" wobble 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown command must be a usage error"
  assert_contains "$out" "unknown command" "an unknown command must name itself"
  out=$(conn "$state" set 2>&1); rc=$?
  expect_code 2 "$rc" "set with no task id must be a usage error"
  out=$(conn "$state" set a b 2>&1); rc=$?
  expect_code 2 "$rc" "set with two task ids must be a usage error"
  pass "fm-conn: missing, unknown, and over-supplied arguments are usage errors"
}

# The worker writes the flag directly (its brief renders the exact command)
# because a crewmate's worktree has no firstmate home in its environment. That
# write and the library's own must be the same record.
test_the_worker_write_form_is_the_same_record() {
  local state
  state=$(make_state worker-write)
  date +%s > "$state/worker.conn"
  conn "$state" check worker \
    || fail "the plain 'date +%s > <path>' form the brief renders was not read as a held conn"
  assert_contains "$(conn "$state" status worker)" "worker: captain has the conn" \
    "the worker's own write must read identically to fm-conn.sh set"
  pass "fm-conn: the one-line write a brief renders produces exactly the same record"
}

test_help_includes_entire_header
test_set_check_clear_round_trip
test_conn_expires_on_the_bounded_idle_window
test_unusable_records_read_as_no_conn
test_status_reports_age_and_remaining_window
test_status_without_a_task_lists_every_record
test_task_ids_cannot_escape_the_state_directory
test_usage_errors_are_loud
test_the_worker_write_form_is_the_same_record
