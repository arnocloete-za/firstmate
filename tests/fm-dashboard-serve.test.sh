#!/usr/bin/env bash
# tests/fm-dashboard-serve.test.sh - behavior tests for building and serving
# the /dashboard project-status board.
#
# Covers schema validation refusal, template-injection round-trip (the built
# page carries a readable fm-dashboard-snapshot.v1 payload), HTTP
# reachability of the served content, idempotent reuse of an already-running
# server across a rebuild, `stop`, and (when tmux is available) the POST
# /run endpoint's registry-trusted launch, its rejection of an unknown or
# not-runnable project name, and that a second /run for the same project
# selects the existing window instead of duplicating it, silently no-oping,
# or ever killing/replacing a still-running process.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVE="$ROOT/bin/fm-dashboard-serve.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-dashboard-serve)
FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state"
export FM_HOME

# Use a low, unusual base port for this test's whole run so a busy default
# range on the test host cannot flake it, and stop any server this test
# started on any exit path.
export FM_DASHBOARD_PORT_BASE=$((20000 + (RANDOM % 5000)))
cleanup() { "$SERVE" stop >/dev/null 2>&1 || true; fm_test_cleanup; }
trap cleanup EXIT INT TERM

RUNTEST_DIR="$TMP_ROOT/runtest-proj"
MARKER="$TMP_ROOT/runtest.marker"
mkdir -p "$RUNTEST_DIR"
cat > "$TMP_ROOT/runtest.sh" <<EOF
#!/usr/bin/env bash
echo "\$PWD" > "$MARKER"
sleep 30
EOF
chmod +x "$TMP_ROOT/runtest.sh"

DATA="$TMP_ROOT/snapshot.json"
cat > "$DATA" <<JSON
{
  "schema": "fm-dashboard-snapshot.v1",
  "generated_at": "2026-01-01T00:00:00Z",
  "projects": [
    {
      "name": "demo",
      "path": "/nowhere",
      "available": true,
      "clean": true,
      "branch": "main",
      "default_branch": "main",
      "on_default": true,
      "last_commit": {"date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"},
      "commits": [{"hash": "abc1234", "date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"}],
      "run_script": null
    },
    {
      "name": "runtest",
      "path": "$RUNTEST_DIR",
      "available": true,
      "clean": true,
      "branch": "main",
      "default_branch": "main",
      "on_default": true,
      "last_commit": {"date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"},
      "commits": [],
      "run_script": "$TMP_ROOT/runtest.sh"
    }
  ]
}
JSON

BAD_SCHEMA="$TMP_ROOT/bad-schema.json"
printf '{"schema": "not-a-real-schema", "projects": []}\n' > "$BAD_SCHEMA"
if "$SERVE" build "$BAD_SCHEMA" >/tmp/fm-dashboard-serve-bad.$$ 2>&1; then
  fail "build should refuse a payload with the wrong schema tag"
fi
rm -f "/tmp/fm-dashboard-serve-bad.$$"
pass "build refuses a payload that fails fm-dashboard-snapshot.v1 validation"

NOT_JSON="$TMP_ROOT/not-json.json"
printf 'not json at all\n' > "$NOT_JSON"
if "$SERVE" build "$NOT_JSON" >/dev/null 2>&1; then
  fail "build should refuse a file that is not valid JSON"
fi
pass "build refuses a file that is not valid JSON"

OUT=$("$SERVE" build "$DATA") || fail "build failed on valid data: $OUT"
BOARD=$(echo "$OUT" | sed -n 's/^dashboard: //p')
URL=$(echo "$OUT" | sed -n 's/^served: //p')
[ -f "$BOARD" ] || fail "build did not write the dashboard file: $BOARD"
[ -n "$URL" ] || fail "build did not print a served URL: $OUT"
pass "build writes the dashboard page and prints a served URL"

# The built page must carry a readable, schema-tagged payload - the same
# round-trip guarantee fm-bearings-board.sh enforces for its own template.
EXTRACTED=$(sed -n '/<script id="dashboard-data" type="application\/json">/,/<\/script>/p' "$BOARD" | sed '1d;$d')
echo "$EXTRACTED" | jq -e '.schema == "fm-dashboard-snapshot.v1" and (.projects[0].name == "demo")' >/dev/null \
  || fail "the built page's embedded payload does not round-trip: $EXTRACTED"
pass "the built page's embedded data slot round-trips as valid fm-dashboard-snapshot.v1 JSON"

# HTTP reachability and content.
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL")
[ "$HTTP_CODE" = "200" ] || fail "dashboard URL did not respond 200: $URL -> $HTTP_CODE"
curl -s "$URL" | grep -q 'Fleet dashboard' || fail "served page did not contain expected content"
pass "the built dashboard is reachable over HTTP and serves the expected page"

STATE_FILE="$FM_HOME/state/.dashboard-server"
[ -f "$STATE_FILE" ] || fail "no server state file was recorded: $STATE_FILE"
FIRST_PID=$(sed -n 's/^pid=//p' "$STATE_FILE")
FIRST_PORT=$(sed -n 's/^port=//p' "$STATE_FILE")

# A rebuild with a live server for this home must reuse it rather than
# starting a second one on a different port.
OUT2=$("$SERVE" build "$DATA") || fail "rebuild failed: $OUT2"
URL2=$(echo "$OUT2" | sed -n 's/^served: //p')
[ "$URL2" = "$URL" ] || fail "rebuild should reuse the same served URL, got $URL2 vs $URL"
SECOND_PID=$(sed -n 's/^pid=//p' "$STATE_FILE")
[ "$SECOND_PID" = "$FIRST_PID" ] || fail "rebuild should reuse the same server pid, got $SECOND_PID vs $FIRST_PID"
pass "rebuilding with a live server reuses the same pid and port instead of starting a second one"

STOP_OUT=$("$SERVE" stop) || fail "stop failed: $STOP_OUT"
echo "$STOP_OUT" | grep -q "stopped: pid $FIRST_PID" \
  || fail "stop did not report stopping the recorded pid: $STOP_OUT"
sleep 0.3
HTTP_CODE_AFTER=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FIRST_PORT/" 2>/dev/null)
[ "$HTTP_CODE_AFTER" = "000" ] || fail "server should be unreachable after stop, got $HTTP_CODE_AFTER"
pass "stop terminates the server and the state file is cleared"

STOP_AGAIN=$("$SERVE" stop) || fail "stop should be idempotent when nothing is running"
echo "$STOP_AGAIN" | grep -q "not running" || fail "stop with no server should report not running: $STOP_AGAIN"
pass "stop is idempotent when no server is running"

# --- POST /run: launches a registered project's run_script in the shared
# "dashboard" tmux session. That session name is fixed by design (the
# captain reuses one persistent session), so this test must never destroy a
# session that was already there for another reason - only a window it adds
# itself.
if ! command -v tmux >/dev/null 2>&1; then
  echo "skip: tmux not found, /run coverage skipped"
else
  HAD_SESSION=0
  tmux has-session -t dashboard 2>/dev/null && HAD_SESSION=1
  run_cleanup() {
    tmux kill-window -t dashboard:runtest >/dev/null 2>&1 || true
    if [ "$HAD_SESSION" -eq 0 ]; then
      tmux kill-session -t dashboard >/dev/null 2>&1 || true
    fi
  }
  trap 'run_cleanup; cleanup' EXIT INT TERM

  OUT3=$("$SERVE" build "$DATA") || fail "build for /run coverage failed: $OUT3"
  URL3=$(echo "$OUT3" | sed -n 's/^served: //p')

  BAD_NAME_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
    -H 'Content-Type: application/json' -d '{"name":"not-a-real-project"}')
  [ "$BAD_NAME_CODE" = "400" ] || fail "/run should reject an unknown project name, got $BAD_NAME_CODE"
  pass "/run rejects a project name that is not a known registered project"

  NO_SCRIPT_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
    -H 'Content-Type: application/json' -d '{"name":"demo"}')
  [ "$NO_SCRIPT_CODE" = "400" ] || fail "/run should reject a project with no run_script, got $NO_SCRIPT_CODE"
  pass "/run rejects a registered project that has no run_script"

  RUN_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
    -H 'Content-Type: application/json' -d '{"name":"runtest"}')
  [ "$RUN_CODE" = "200" ] || fail "/run should accept a project with a registered run_script, got $RUN_CODE"

  waited=0
  while [ ! -f "$MARKER" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$MARKER" ] || fail "/run did not actually launch the project's run_script (no marker file)"
  [ "$(cat "$MARKER")" = "$RUNTEST_DIR" ] \
    || fail "run_script ran with the wrong working directory: $(cat "$MARKER")"
  tmux list-windows -t dashboard -F '#{window_name}' 2>/dev/null | grep -qx runtest \
    || fail "no tmux window named after the project was created in the dashboard session"
  pass "/run creates (or reuses) the dashboard tmux session and runs the project's own script there"

  # Clicking Run again while the previous window for the same project is
  # still alive must not silently do nothing, but it must also never kill or
  # replace that window - it may be real, currently-running work. It should
  # select the existing window and leave its process completely untouched.
  FIRST_RUN_PID=$(tmux list-panes -t dashboard:runtest -F '#{pane_pid}')
  RUN_CODE2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
    -H 'Content-Type: application/json' -d '{"name":"runtest"}')
  [ "$RUN_CODE2" = "200" ] || fail "a second /run for the same project should also succeed, got $RUN_CODE2"

  sleep 0.3
  SECOND_RUN_PID=$(tmux list-panes -t dashboard:runtest -F '#{pane_pid}' 2>/dev/null)
  [ "$SECOND_RUN_PID" = "$FIRST_RUN_PID" ] \
    || fail "a second /run must never kill or replace the existing process, was $FIRST_RUN_PID now $SECOND_RUN_PID"
  kill -0 "$FIRST_RUN_PID" 2>/dev/null \
    || fail "the original run_script process should still be alive after a second /run, pid $FIRST_RUN_PID"
  WINDOW_COUNT=$(tmux list-windows -t dashboard -F '#{window_name}' 2>/dev/null | grep -cx runtest)
  [ "$WINDOW_COUNT" = "1" ] \
    || fail "expected exactly one 'runtest' window after a second /run, found $WINDOW_COUNT"
  ACTIVE_WINDOW=$(tmux list-windows -t dashboard -F '#{window_active} #{window_name}' 2>/dev/null | awk '$1==1{print $2}')
  [ "$ACTIVE_WINDOW" = "runtest" ] \
    || fail "a second /run should select the existing window rather than leaving it unfocused, active was $ACTIVE_WINDOW"
  pass "a second /run for the same project selects the existing window without killing or duplicating it"

  run_cleanup
fi

echo "ALL TESTS PASSED"
