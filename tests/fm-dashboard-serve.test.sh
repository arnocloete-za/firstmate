#!/usr/bin/env bash
# tests/fm-dashboard-serve.test.sh - behavior tests for building and serving
# the /dashboard project-status board.
#
# Covers schema validation refusal, template-injection round-trip (the built
# page carries a readable fm-dashboard-snapshot.v1 payload), HTTP
# reachability of the served content, idempotent reuse of an already-running
# server across a rebuild, `stop`, that one idle connection cannot wedge the
# server for everyone else, the POST /run endpoint's rejection of an unknown
# project name, of a project with no run_script, of a project whose path is
# not a directory, and of a cross-site or non-JSON request, and (when tmux is
# available) its registry-trusted launch plus that a second /run for the same
# project - including one whose name contains a "." - selects the existing
# window instead of duplicating it, silently no-oping, or ever
# killing/replacing a still-running process.
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

# A second project whose name contains a "." - a tmux target built by
# interpolating "dashboard:<name>" parses that as a pane suffix and fails, so
# the re-run path must resolve the window by its tmux window id instead.
DOTTED_MARKER="$TMP_ROOT/dotted.marker"
cat > "$TMP_ROOT/dottedtest.sh" <<EOF
#!/usr/bin/env bash
echo "\$PWD" > "$DOTTED_MARKER"
sleep 30
EOF
chmod +x "$TMP_ROOT/dottedtest.sh"

GONE_DIR="$TMP_ROOT/gone-proj"

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
    },
    {
      "name": "run.test",
      "path": "$RUNTEST_DIR",
      "available": true,
      "clean": true,
      "branch": "main",
      "default_branch": "main",
      "on_default": true,
      "last_commit": {"date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"},
      "commits": [],
      "run_script": "$TMP_ROOT/dottedtest.sh"
    },
    {
      "name": "gone",
      "path": "$GONE_DIR",
      "available": false,
      "reason": "clone is missing",
      "clean": true,
      "branch": "main",
      "default_branch": "main",
      "on_default": true,
      "last_commit": null,
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

# --- POST /run. The request-trust checks need no tmux, so they run
# unconditionally; the launch checks below need a real tmux. The "dashboard"
# session name is fixed by design (the captain reuses one persistent
# session), so this test must never destroy a session that was already there
# for another reason - only the windows it adds itself.
OUT3=$("$SERVE" build "$DATA") || fail "build for /run coverage failed: $OUT3"
URL3=$(echo "$OUT3" | sed -n 's/^served: //p')
PORT3=$(echo "$URL3" | sed -n 's#^http://127\.0\.0\.1:\([0-9]*\)/*$#\1#p')
[ -n "$PORT3" ] || fail "could not read the served port out of $URL3"

# One connection that opens and sends nothing - what a browser preconnect
# does - must not wedge the board for every other request.
python3 -c "
import socket, time
s = socket.create_connection(('127.0.0.1', $PORT3))
time.sleep(5)
" &
IDLE_PID=$!
sleep 0.4
CONCURRENT_CODE=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$URL3")
kill "$IDLE_PID" 2>/dev/null || true
wait "$IDLE_PID" 2>/dev/null || true
[ "$CONCURRENT_CODE" = "200" ] \
  || fail "an idle connection wedged the server; a concurrent request got $CONCURRENT_CODE"
pass "an idle connection does not wedge the server for concurrent requests"

BAD_NAME_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
  -H 'Content-Type: application/json' -d '{"name":"not-a-real-project"}')
[ "$BAD_NAME_CODE" = "400" ] || fail "/run should reject an unknown project name, got $BAD_NAME_CODE"
pass "/run rejects a project name that is not a known registered project"

NO_SCRIPT_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
  -H 'Content-Type: application/json' -d '{"name":"demo"}')
[ "$NO_SCRIPT_CODE" = "400" ] || fail "/run should reject a project with no run_script, got $NO_SCRIPT_CODE"
pass "/run rejects a registered project that has no run_script"

# A project whose clone is gone still renders a Run control and still carries
# a run_script, so /run itself must refuse it rather than launch that script
# from whatever directory tmux falls back to.
[ ! -e "$GONE_DIR" ] || fail "test fixture error: $GONE_DIR should not exist"
GONE_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
  -H 'Content-Type: application/json' -d '{"name":"gone"}')
[ "$GONE_CODE" = "400" ] || fail "/run should reject a project whose path is not a directory, got $GONE_CODE"
pass "/run rejects a project whose registered path is not a directory instead of launching it elsewhere"

# Only the served page's own same-origin requests may launch anything: any
# other page the captain has open must not be able to use this loopback port.
CROSS_SITE_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
  -H 'Content-Type: application/json' -H 'Sec-Fetch-Site: cross-site' -d '{"name":"runtest"}')
[ "$CROSS_SITE_CODE" = "403" ] || fail "/run should refuse a cross-site request, got $CROSS_SITE_CODE"
CROSS_ORIGIN_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
  -H 'Content-Type: application/json' -H 'Origin: http://evil.example' -d '{"name":"runtest"}')
[ "$CROSS_ORIGIN_CODE" = "403" ] || fail "/run should refuse a foreign Origin, got $CROSS_ORIGIN_CODE"
FORM_TYPE_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" -d '{"name":"runtest"}')
[ "$FORM_TYPE_CODE" = "403" ] || fail "/run should refuse a non-JSON content type, got $FORM_TYPE_CODE"
[ ! -f "$MARKER" ] || fail "a refused /run must not have launched anything: $MARKER exists"
pass "/run refuses a cross-site, foreign-Origin, or non-JSON request without launching anything"

# A malformed Content-Length must answer 400 like every other bad request,
# not drop the connection with no HTTP response at all.
BAD_LENGTH_STATUS=$(python3 -c "
import socket
s = socket.create_connection(('127.0.0.1', $PORT3))
s.sendall(b'POST /run HTTP/1.1\r\nHost: 127.0.0.1:$PORT3\r\nContent-Type: application/json\r\nContent-Length: abc\r\n\r\n')
print(s.recv(4096).split(b'\r\n')[0].decode('latin-1'))
")
case "$BAD_LENGTH_STATUS" in
  *" 400 "*) : ;;
  *) fail "a non-numeric Content-Length should answer 400, got: $BAD_LENGTH_STATUS" ;;
esac
pass "/run answers 400 to a malformed Content-Length instead of dropping the connection"

if ! command -v tmux >/dev/null 2>&1; then
  echo "skip: tmux not found, /run launch coverage skipped"
else
  # Every tmux target below is an exact session name or a tmux window id, for
  # the same reason the server uses them: a bare "dashboard" prefix-matches
  # other sessions, and "dashboard:run.test" parses "test" as a pane.
  dashboard_window_ids() {  # <window name> -> matching tmux window ids
    tmux list-windows -t '=dashboard' -F $'#{window_id}\t#{window_name}' 2>/dev/null \
      | awk -F'\t' -v n="$1" '$2 == n { print $1 }'
  }
  active_dashboard_window() {
    tmux list-windows -t '=dashboard' -F $'#{window_active}\t#{window_name}' 2>/dev/null \
      | awk -F'\t' '$1 == 1 { print $2 }'
  }

  HAD_SESSION=0
  tmux has-session -t '=dashboard' 2>/dev/null && HAD_SESSION=1
  run_cleanup() {
    local wid
    for wid in $(dashboard_window_ids runtest) $(dashboard_window_ids run.test); do
      tmux kill-window -t "$wid" >/dev/null 2>&1 || true
    done
    if [ "$HAD_SESSION" -eq 0 ]; then
      tmux kill-session -t '=dashboard' >/dev/null 2>&1 || true
    fi
  }
  trap 'run_cleanup; cleanup' EXIT INT TERM

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
  RUN_WID=$(dashboard_window_ids runtest)
  [ -n "$RUN_WID" ] \
    || fail "no tmux window named after the project was created in the dashboard session"
  pass "/run creates (or reuses) the dashboard tmux session and runs the project's own script there"

  # Clicking Run again while the previous window for the same project is
  # still alive must not silently do nothing, but it must also never kill or
  # replace that window - it may be real, currently-running work. It should
  # select the existing window and leave its process completely untouched.
  FIRST_RUN_PID=$(tmux list-panes -t "$RUN_WID" -F '#{pane_pid}')
  RUN_CODE2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
    -H 'Content-Type: application/json' -d '{"name":"runtest"}')
  [ "$RUN_CODE2" = "200" ] || fail "a second /run for the same project should also succeed, got $RUN_CODE2"

  sleep 0.3
  SECOND_RUN_PID=$(tmux list-panes -t "$RUN_WID" -F '#{pane_pid}' 2>/dev/null)
  [ "$SECOND_RUN_PID" = "$FIRST_RUN_PID" ] \
    || fail "a second /run must never kill or replace the existing process, was $FIRST_RUN_PID now $SECOND_RUN_PID"
  kill -0 "$FIRST_RUN_PID" 2>/dev/null \
    || fail "the original run_script process should still be alive after a second /run, pid $FIRST_RUN_PID"
  WINDOW_COUNT=$(dashboard_window_ids runtest | grep -c .)
  [ "$WINDOW_COUNT" = "1" ] \
    || fail "expected exactly one 'runtest' window after a second /run, found $WINDOW_COUNT"
  [ "$(active_dashboard_window)" = "runtest" ] \
    || fail "a second /run should select the existing window rather than leaving it unfocused, active was $(active_dashboard_window)"
  pass "a second /run for the same project selects the existing window without killing or duplicating it"

  # Same guarantee for a project name containing a ".": a
  # "dashboard:run.test" target parses "test" as a pane and fails, so the
  # second click would report success while focusing nothing.
  DOT_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
    -H 'Content-Type: application/json' -d '{"name":"run.test"}')
  [ "$DOT_CODE" = "200" ] || fail "/run should accept a project whose name contains a '.', got $DOT_CODE"
  waited=0
  while [ ! -f "$DOTTED_MARKER" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$DOTTED_MARKER" ] || fail "/run did not launch the dotted project's run_script (no marker file)"
  DOT_WID=$(dashboard_window_ids run.test)
  [ -n "$DOT_WID" ] || fail "no tmux window was created for the dotted project name"
  DOT_PID=$(tmux list-panes -t "$DOT_WID" -F '#{pane_pid}')

  # Focus another window first, so a re-run that quietly focuses nothing is
  # distinguishable from one that really selects the existing window.
  tmux select-window -t "$RUN_WID" >/dev/null 2>&1 \
    || fail "could not move focus off the dotted window to set up the re-run check"
  DOT_CODE2=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
    -H 'Content-Type: application/json' -d '{"name":"run.test"}')
  [ "$DOT_CODE2" = "200" ] || fail "a second /run for the dotted project should also succeed, got $DOT_CODE2"
  sleep 0.3
  [ "$(dashboard_window_ids run.test | grep -c .)" = "1" ] \
    || fail "a second /run for a dotted project name duplicated its window"
  [ "$(tmux list-panes -t "$DOT_WID" -F '#{pane_pid}' 2>/dev/null)" = "$DOT_PID" ] \
    || fail "a second /run for a dotted project name replaced its running process"
  [ "$(active_dashboard_window)" = "run.test" ] \
    || fail "a second /run for a dotted project name should focus its existing window, active was $(active_dashboard_window)"
  pass "a second /run for a project name containing a '.' selects its existing window instead of quietly focusing nothing"

  run_cleanup
fi

echo "ALL TESTS PASSED"
