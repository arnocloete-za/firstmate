#!/usr/bin/env bash
# tests/fm-dashboard-live-snapshot.test.sh - behavior tests for the /dashboard
# LIVE WORK projection.
#
# Covers the captain-facing project name (never the task id), the waiting
# classification and its wants-captain boundary, wants-first ordering with a
# stable tie-break, plain-words activity translated from canonical current
# state, forward-compatible "captain has the conn" recognition, and graceful
# degradation when the fleet read is unusable.
#
# Terminal presence and the jump command are exercised against a REAL tmux
# server on a private socket, because that half of the projection is only worth
# anything if it is right about whether a window still exists: the naive
# `tmux display-message -t <window>` read silently falls back to the CURRENT
# window and reports success for a window that is gone, which is exactly the
# lie that would send the captain into the wrong terminal.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVE="$ROOT/bin/fm-dashboard-live-snapshot.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-dashboard-live-snapshot)
FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state"
export FM_HOME

# fleet_fixture: write a canonical fm-fleet-snapshot.v1 shaped document. Only
# the fields this projection reads are populated; bin/fm-fleet-snapshot.sh owns
# the full contract.
fleet_fixture() {  # <path> <tasks-json>
  jq -n --argjson tasks "$2" \
    '{schema: "fm-fleet-snapshot.v1", generated: "2026-01-01T00:00:00Z", tasks: $tasks}' \
    > "$1"
}

# task_json: one canonical task row.
task_json() {  # <id> <project> <repo|null> <state> <detail> <extra-json>
  jq -n \
    --arg id "$1" --arg project "$2" --arg state "$4" --arg detail "$5" \
    --argjson repo "$3" --argjson extra "$6" \
    '{
       id: $id, kind: "ship", project: $project, backend: "tmux", remote: null,
       current_state: {state: $state, source: "run-step", detail: $detail},
       endpoint: {target: null, exists: true},
       pr: {url: null},
       hints: {pending_decision: false, blocked_event: false, open_decisions: []},
       backlog: {repo: $repo, title: null, hold_kind: null, hold_reason: null,
                 blocked_reason: null, captain_actionable: false}
     } * $extra'
}

# --- the captain's name for the project, never the task id ----------------
FLEET="$TMP_ROOT/fleet-names.json"
fleet_fixture "$FLEET" "$(jq -n \
  --argjson a "$(task_json alpha-task /opt/repos/firstmate '"firstmate"' working "harness busy" '{}')" \
  --argjson b "$(task_json yt-player-scout /opt/repos/firstmate/projects/yt-player null working "harness busy" '{}')" \
  '[$a, $b]')"

OUT=$("$LIVE" --fleet-json "$FLEET") || fail "projection failed: $OUT"
echo "$OUT" | jq -e '.schema == "fm-dashboard-live.v1" and .available == true' >/dev/null \
  || fail "wrong schema or availability: $OUT"
echo "$OUT" | jq -e '.fleet_observed_at == "2026-01-01T00:00:00Z"' >/dev/null \
  || fail "the canonical snapshot's own observation time was not carried through: $OUT"
pass "the projection carries the fm-dashboard-live.v1 schema and the fleet observation time"

row() {  # <id> -> that task's JSON object
  echo "$OUT" | jq -c --arg id "$1" '.tasks[] | select(.id == $id)'
}

row alpha-task | jq -e '.project == "firstmate"' >/dev/null \
  || fail "a recorded work-item repo should name the project: $(row alpha-task)"
row yt-player-scout | jq -e '.project == "yt-player"' >/dev/null \
  || fail "with no recorded repo the project path should name the project: $(row yt-player-scout)"
echo "$OUT" | jq -e '[.tasks[] | select(.project == .id)] | length == 0' >/dev/null \
  || fail "a task id must never be used as the project name: $OUT"
pass "rows are named by the captain's project name, never by the task id"

# --- waiting classification and the wants-captain boundary ----------------
FLEET_W="$TMP_ROOT/fleet-waiting.json"
fleet_fixture "$FLEET_W" "$(jq -n \
  --argjson failed "$(task_json t-failed /p '"proj"' failed "run failed" '{}')" \
  --argjson blocked "$(task_json t-blocked /p '"proj"' blocked "stopped" '{}')" \
  --argjson askuser "$(task_json t-askuser /p '"proj"' parked "parked at review: 2 finding(s) (ask-user: authority decision)" '{}')" \
  --argjson hold "$(task_json t-hold /p '"proj"' paused "idling" '{"backlog":{"hold_kind":"captain","hold_reason":"Try the new landing screen and say what you think."}}')" \
  --argjson keyed "$(task_json t-keyed /p '"proj"' working "harness busy" '{"hints":{"open_decisions":["which-auth-provider"]}}')" \
  --argjson actionable "$(task_json t-actionable /p '"proj"' working "harness busy" '{"backlog":{"captain_actionable":true}}')" \
  --argjson review "$(task_json t-review /p '"proj"' 'done' "checks green: PR ready for review" '{"pr":{"url":"https://example.invalid/pr/1"}}')" \
  --argjson gate "$(task_json t-gate /p '"proj"' parked "parked at document: 1 finding(s)" '{}')" \
  --argjson external "$(task_json t-external /p '"proj"' paused "waiting for the nightly export" '{}')" \
  --argjson working "$(task_json t-working /p '"proj"' working "validating (fixing)" '{}')" \
  --argjson unclear "$(task_json t-unclear /p '"proj"' unknown "" '{}')" \
  '[$failed,$blocked,$askuser,$hold,$keyed,$actionable,$review,$gate,$external,$working,$unclear]')"

OUT=$("$LIVE" --fleet-json "$FLEET_W") || fail "projection failed: $OUT"

expect_kind() {  # <id> <kind> <wants_captain>
  row "$1" | jq -e --arg k "$2" --argjson w "$3" \
    '.waiting.kind == $k and .waiting.wants_captain == $w' >/dev/null \
    || fail "$1 should classify as $2 (wants_captain=$3): $(row "$1")"
}

expect_kind t-failed     failed   true
expect_kind t-blocked    blocked  true
expect_kind t-askuser    decision true
expect_kind t-hold       decision true
expect_kind t-keyed      decision true
expect_kind t-actionable decision true
expect_kind t-review     review   true
pass "failures, blockers, captain decisions, and a finished PR all read as waiting on the captain"

expect_kind t-gate     gate     false
expect_kind t-external external false
expect_kind t-working  none     false
pass "a run at its own gate, a declared external wait, and ordinary work never claim the captain"

# An unreadable state is worth a look but must NOT wear the badge that means
# "he owes this one something" - a badge that fires on ambiguity stops meaning
# anything.
expect_kind t-unclear unclear false
pass "an unreadable state sorts for attention without claiming to be waiting on the captain"

# Every row must carry a captain-facing label and a reason where one exists.
echo "$OUT" | jq -e '[.tasks[] | select((.waiting.label | length) == 0)] | length == 0' >/dev/null \
  || fail "every row needs a plain-words waiting label: $OUT"
row t-hold | jq -e '.waiting.note == "Try the new landing screen and say what you think."' >/dev/null \
  || fail "a captain hold reason is the sentence to show him: $(row t-hold)"
row t-askuser | jq -e '(.waiting.note | length) > 0' >/dev/null \
  || fail "an ask-user gate must say what the decision is about: $(row t-askuser)"
row t-review | jq -e '.pr_url == "https://example.invalid/pr/1"' >/dev/null \
  || fail "a review row must carry its PR url: $(row t-review)"
pass "each row carries a plain-words label, a reason when one exists, and its PR url"

# --- ordering: whatever wants him first, stable on ties -------------------
echo "$OUT" | jq -e '[.tasks[].rank] == ([.tasks[].rank] | sort)' >/dev/null \
  || fail "tasks must be emitted already sorted by rank: $(echo "$OUT" | jq -c '[.tasks[] | {id, rank}]')"
echo "$OUT" | jq -e '.tasks[0].waiting.kind == "failed"' >/dev/null \
  || fail "a failure belongs at the top: $(echo "$OUT" | jq -c '.tasks[0]')"
echo "$OUT" | jq -e '
  ([.tasks[] | select(.waiting.wants_captain)] | length) as $w
  | [.tasks[:$w][] | select(.waiting.wants_captain | not)] | length == 0' >/dev/null \
  || fail "every wants-captain row must precede every calm row: $(echo "$OUT" | jq -c '[.tasks[] | {id, rank}]')"
pass "rows are pre-sorted so whatever wants the captain is at the top"

# Ties break on id, so the board does not reshuffle between two runs.
FLEET_TIE="$TMP_ROOT/fleet-tie.json"
fleet_fixture "$FLEET_TIE" "$(jq -n \
  --argjson c "$(task_json zeta /p '"proj"' working "harness busy" '{}')" \
  --argjson a "$(task_json alpha /p '"proj"' working "harness busy" '{}')" \
  --argjson b "$(task_json mid /p '"proj"' working "harness busy" '{}')" \
  '[$c, $a, $b]')"
TIE=$("$LIVE" --fleet-json "$FLEET_TIE") || fail "projection failed: $TIE"
echo "$TIE" | jq -e '[.tasks[].id] == ["alpha","mid","zeta"]' >/dev/null \
  || fail "equal-rank rows should order by id: $(echo "$TIE" | jq -c '[.tasks[].id]')"
pass "equal-rank rows break ties on task id so the order is stable between runs"

# --- plain words, not pipeline labels -------------------------------------
OUT=$("$LIVE" --fleet-json "$FLEET_W") || fail "projection failed"
echo "$OUT" | jq -e '[.tasks[] | select(.activity | test("parked|ask-user|fix_review|awaiting_approval"))] | length == 0' >/dev/null \
  || fail "activity must not leak an internal gate label: $(echo "$OUT" | jq -c '[.tasks[].activity]')"
echo "$OUT" | jq -e '[.tasks[] | select((.activity | length) == 0)] | length == 0' >/dev/null \
  || fail "every row must say what the work is doing: $OUT"
row t-working | jq -e '.activity == "Fixing what its review found"' >/dev/null \
  || fail "a fixing run should read in plain words: $(row t-working)"
pass "activity is translated into plain words rather than repeating a pipeline label"

# --- "captain has the conn": recognized, calm, and never mistaken for stuck -
# The flag itself belongs to the captain-pane-conversation work and surfaces
# through bin/fm-crew-state.sh; this projection only has to give it a place.
# All three shapes that surfacing can take must be honored.
for shape in state field detail; do
  case "$shape" in
    state)  extra='{"current_state":{"state":"conn","detail":"captain present"}}' ;;
    field)  extra='{"current_state":{"conn":true}}' ;;
    detail) extra='{"current_state":{"detail":"captain has the conn for 3m"}}' ;;
  esac
  FLEET_C="$TMP_ROOT/fleet-conn-$shape.json"
  fleet_fixture "$FLEET_C" "$(jq -n \
    --argjson t "$(task_json t-conn /p '"proj"' working "harness busy" "$extra")" '[$t]')"
  CONN=$("$LIVE" --fleet-json "$FLEET_C") || fail "projection failed for conn shape $shape"
  echo "$CONN" | jq -e '.tasks[0].waiting.kind == "conn"' >/dev/null \
    || fail "conn shape '$shape' was not recognized: $(echo "$CONN" | jq -c '.tasks[0]')"
  echo "$CONN" | jq -e '.tasks[0].waiting.wants_captain == false' >/dev/null \
    || fail "a task the captain is driving must not claim to be waiting on him ($shape)"
  echo "$CONN" | jq -e '.tasks[0].state == "conn"' >/dev/null \
    || fail "conn shape '$shape' should report a conn state: $(echo "$CONN" | jq -c '.tasks[0]')"
  echo "$CONN" | jq -e '.tasks[0].waiting.kind != "unclear" and .tasks[0].rank > 3' >/dev/null \
    || fail "a conn row must sort below the rows that want him ($shape)"
done
pass "captain-has-the-conn is recognized in all three surfacing shapes, and never reads as stuck or as wanting him"

# --- graceful degradation: the project half must still build --------------
MISSING=$("$LIVE" --fleet-json "$TMP_ROOT/not-here.json") || fail "a missing fleet read should not fail the command"
echo "$MISSING" | jq -e '.schema == "fm-dashboard-live.v1" and .available == false and (.reason | length) > 0 and (.tasks | length) == 0' >/dev/null \
  || fail "a missing fleet read should report available:false with a reason: $MISSING"
pass "a missing fleet read degrades to available:false with a reason instead of failing"

printf 'not json at all\n' > "$TMP_ROOT/garbage.json"
GARBAGE=$("$LIVE" --fleet-json "$TMP_ROOT/garbage.json") || fail "an unparseable fleet read should not fail the command"
echo "$GARBAGE" | jq -e '.available == false and (.reason | length) > 0' >/dev/null \
  || fail "an unparseable fleet read should report available:false: $GARBAGE"
pass "an unparseable fleet read degrades to available:false with a reason"

EMPTY_FLEET="$TMP_ROOT/fleet-empty.json"
fleet_fixture "$EMPTY_FLEET" '[]'
EMPTY=$("$LIVE" --fleet-json "$EMPTY_FLEET") || fail "an empty fleet should succeed"
echo "$EMPTY" | jq -e '.available == true and (.tasks | length) == 0' >/dev/null \
  || fail "an empty fleet is available with no rows, not unavailable: $EMPTY"
pass "an empty fleet reads as available with no rows, distinct from a failed read"

# --- terminal presence and the jump command, against a real tmux ----------
if ! command -v tmux >/dev/null 2>&1; then
  echo "skip: tmux not found - terminal presence assertions skipped"
  echo "ALL TESTS PASSED"
  exit 0
fi

REAL_TMUX=$(command -v tmux)
SOCKET="fm-dashboard-live-$$"
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-live-shim.XXXXXX")
tmux_cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  # kill-server leaves the socket inode behind; remove it so repeated runs do
  # not accumulate dead sockets in the shared tmux socket directory.
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
  rm -rf "$SHIM_DIR"
  fm_test_cleanup
}
trap tmux_cleanup EXIT INT TERM

# A `tmux` shim on PATH redirecting every call to a private socket, so the
# projection's own bare `tmux` reads never touch the host's real sessions.
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

tmux new-session -d -s crew -n other 2>/dev/null || { echo "skip: cannot start a private tmux server"; echo "ALL TESTS PASSED"; exit 0; }
# A window with a live shell in it. The shell is what makes the endpoint
# readable; whether it counts as an agent is bin/backends/tmux.sh's business.
tmux new-window -t crew -n fm-present
# Deliberately NOT created: crew:fm-vanished.

FLEET_T="$TMP_ROOT/fleet-terminals.json"
fleet_fixture "$FLEET_T" "$(jq -n \
  --argjson present "$(task_json t-present /p '"proj"' working "harness busy" \
    '{"endpoint":{"target":"crew:fm-present","exists":true}}')" \
  --argjson vanished "$(task_json t-vanished /p '"proj"' working "harness busy" \
    '{"endpoint":{"target":"crew:fm-vanished","exists":true}}')" \
  --argjson remote "$(task_json t-remote /p '"proj"' working "harness busy" \
    '{"remote":"builder.invalid","endpoint":{"target":"crew:fm-remote","exists":true}}')" \
  '[$present, $vanished, $remote]')"

OUT=$("$LIVE" --fleet-json "$FLEET_T") || fail "projection failed: $OUT"

# The window that exists must not read as gone, and must carry a jump command
# naming its own recorded session - never a hardcoded session name.
row t-present | jq -e '.terminal.presence != "gone" and .terminal.presence != "unknown"' >/dev/null \
  || fail "a window that exists must not read as gone: $(row t-present)"
row t-present | jq -e '.terminal.command | test("crew:fm-present")' >/dev/null \
  || fail "the jump command must target the recorded endpoint: $(row t-present)"
row t-present | jq -e '.terminal.command | test("switch-client")' >/dev/null \
  || fail "the jump command must also work from inside tmux: $(row t-present)"
pass "a window that exists reads as reachable and gets a jump command built from its own recorded session"

# The critical assertion. `endpoint.exists` in the fixture says true for BOTH
# rows, exactly as the canonical snapshot's cheap read reports it, because
# `tmux display-message -t <missing window>` silently answers for the current
# window instead of failing. The projection must still tell these two apart.
row t-vanished | jq -e '.terminal.presence == "gone"' >/dev/null \
  || fail "a window that no longer exists must read as gone even though the cheap endpoint read claims it exists: $(row t-vanished)"
row t-vanished | jq -e '.terminal.command == null' >/dev/null \
  || fail "a terminal known to be gone must not offer a jump command: $(row t-vanished)"
row t-vanished | jq -e '.terminal.presence_note | length > 0' >/dev/null \
  || fail "a gone terminal must say so in plain words: $(row t-vanished)"
pass "a vanished window reads as gone with no jump command, despite the cheap endpoint read reporting it exists"

row t-remote | jq -e '.terminal.presence == "remote" and .terminal.command == null' >/dev/null \
  || fail "a remote endpoint is not a local terminal to walk into: $(row t-remote)"
pass "a remote endpoint reports as remote and is offered no local jump command"

echo "ALL TESTS PASSED"
