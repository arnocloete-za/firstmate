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
# killing/replacing a still-running process, that the first Run creates the
# session carrying only the project's own window, and that concurrent Runs can
# neither duplicate a window nor collide creating the session.
#
# It also proves its own blast radius: the run below is wrapped in a parent
# phase that parks a canary session on the default tmux socket, runs this
# whole file - teardown included - as a child, and requires the canary to
# still be there afterwards. FM_DASHBOARD_SERVE_PHASE picks the phase:
# "parent" (the default) runs the proof around a "supervised" child and owns
# the final ALL TESTS PASSED line; "standalone" is the phase the parent execs
# into when no canary can be parked, and it owns that line itself. Whichever
# phase actually runs the assertions prints it exactly once.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVE="$ROOT/bin/fm-dashboard-serve.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

# --- blast-radius proof (parent phase) --------------------------------------
#
# The claim under test is structural: this suite's teardown can only ever
# reach the private socket it created itself. Park a canary session on the
# default socket - where the captain's own sessions live - run the whole suite
# as a child with $TMUX pointed at that same server (so a suite that relied on
# TMUX_TMPDIR would resolve straight onto it), and require the canary to
# survive.
#
# Every call in this phase names its socket with `-L`, the same explicit
# selection the child's shim uses, because an inherited $TMUX otherwise wins
# over every other selector: against a stale one, `new-session` quietly builds
# a phantom server at that dead path (or prints "error creating" and still
# exits 0) while `display-message` and `has-session` fail outright, so the
# proof would measure the wrong server or redden the whole suite over an
# environment variable. Parking is best-effort for the same reason - if no
# canary can be parked the suite runs standalone rather than failing - and
# this phase only ever kills its own pid-named session, never a server.
PHASE=${FM_DASHBOARD_SERVE_PHASE:-parent}
if [ "$PHASE" = "parent" ]; then
  PARENT_TMUX=$(command -v tmux 2>/dev/null || true)
  CANARY="fm-dashboard-canary-$$"
  CANARY_SOCKET=
  if [ -n "$PARENT_TMUX" ]; then
    "$PARENT_TMUX" -L default new-session -d -s "$CANARY" -n keepalive 'sleep 600' \
      >/dev/null 2>&1 || true
    CANARY_SOCKET=$("$PARENT_TMUX" -L default \
      display-message -p -t "=$CANARY" '#{socket_path}' 2>/dev/null || true)
  fi
  if [ -z "$CANARY_SOCKET" ]; then
    echo "notice: no canary session could be parked on the default tmux socket; running the suite without the blast-radius proof"
    FM_DASHBOARD_SERVE_PHASE=standalone exec bash "$0"
  fi
  canary_cleanup() {
    "$PARENT_TMUX" -L default kill-session -t "=$CANARY" >/dev/null 2>&1 || true
    fm_test_cleanup
  }
  trap canary_cleanup EXIT INT TERM

  FM_DASHBOARD_SERVE_PHASE=supervised TMUX="$CANARY_SOCKET,0,0" bash "$0"
  CHILD_RC=$?

  "$PARENT_TMUX" -L default has-session -t "=$CANARY" 2>/dev/null \
    || fail "the suite teardown reached a tmux server it does not own: the canary session on $CANARY_SOCKET is gone"
  canary_cleanup
  trap - EXIT INT TERM
  [ "$CHILD_RC" -eq 0 ] || exit "$CHILD_RC"
  pass "a full suite run, teardown included, leaves an unrelated tmux server on the default socket untouched"
  echo "ALL TESTS PASSED"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-dashboard-serve)
FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state"
export FM_HOME

# Use a low, unusual base port for this test's whole run so a busy default
# range on the test host cannot flake it, and stop any server this test
# started on any exit path.
export FM_DASHBOARD_PORT_BASE=$((20000 + (RANDOM % 5000)))
# /run drives a real tmux, and the session name it uses ("dashboard") is fixed
# by design - the captain reuses one persistent session. This suite must be
# structurally incapable of reaching a tmux server it did not create, so it
# owns a private socket named with its own pid and reaches tmux only through a
# PATH shim that pins every call to that socket - the same idiom as
# tests/fm-backend-tmux-smoke.test.sh. `-L` overrides $TMUX, so the shim holds
# even when the suite runs from inside the captain's own tmux; TMUX_TMPDIR
# does not (tmux honours $TMUX over it, and silently falls back to the real
# default socket when the directory is missing), so it must not be used here.
# The shim is inherited through PATH by the dashboard server this suite
# launches, whose own tmux calls are bare `tmux`. Every teardown, kill-server
# included, is scoped to that one socket by construction.
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
TMUX_SOCKET="fm-dashboard-$$"
SHIM_DIR=
if [ -n "$REAL_TMUX" ]; then
  SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-shim.XXXXXX") \
    || fail "cannot stage the tmux shim directory"
  cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TMUX_SOCKET" "\$@"
SH
  chmod +x "$SHIM_DIR/tmux"
  PATH="$SHIM_DIR:$PATH"
  export PATH
fi
cleanup() {
  "$SERVE" stop >/dev/null 2>&1 || true
  if [ -n "$REAL_TMUX" ]; then
    "$REAL_TMUX" -L "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  fi
  [ -n "$SHIM_DIR" ] && rm -rf "$SHIM_DIR"
  fm_test_cleanup
}
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

# Concurrency fixture: a project no other check launches, so a burst of
# simultaneous Runs starts from a known-clean window set.
cat > "$TMP_ROOT/conctest.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$TMP_ROOT/conctest.sh"

# tmux exits 0 for a command that cannot run, and the window vanishes, so only
# the server can tell the captain that a registered run script is gone or is
# not executable.
# A relative run script that really does resolve against the server's own cwd
# (the repo root this suite runs from), which is the wrong base: tmux resolves
# the command against the project directory it is handed instead, so the two
# disagree and tmux still exits 0.
RELATIVE_SCRIPT=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1]))' \
  "$ROOT/bin/fm-dashboard-server.py" 2>/dev/null || true)
case "$RELATIVE_SCRIPT" in
  ''|/*) fail "could not derive a relative run-script fixture from the suite's cwd: '$RELATIVE_SCRIPT'" ;;
esac
[ -x "$RELATIVE_SCRIPT" ] \
  || fail "the relative run-script fixture does not resolve from the suite's cwd: $RELATIVE_SCRIPT"

MISSING_SCRIPT="$TMP_ROOT/missing-run.sh"
NOEXEC_SCRIPT="$TMP_ROOT/noexec-run.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$NOEXEC_SCRIPT"
chmod 0644 "$NOEXEC_SCRIPT"

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
      "name": "conctest",
      "path": "$RUNTEST_DIR",
      "available": true,
      "clean": true,
      "branch": "main",
      "default_branch": "main",
      "on_default": true,
      "last_commit": {"date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"},
      "commits": [],
      "run_script": "$TMP_ROOT/conctest.sh"
    },
    {
      "name": "relativescript",
      "path": "$RUNTEST_DIR",
      "available": true,
      "clean": true,
      "branch": "main",
      "default_branch": "main",
      "on_default": true,
      "last_commit": {"date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"},
      "commits": [],
      "run_script": "$RELATIVE_SCRIPT"
    },
    {
      "name": "missingscript",
      "path": "$RUNTEST_DIR",
      "available": true,
      "clean": true,
      "branch": "main",
      "default_branch": "main",
      "on_default": true,
      "last_commit": {"date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"},
      "commits": [],
      "run_script": "$MISSING_SCRIPT"
    },
    {
      "name": "noexecscript",
      "path": "$RUNTEST_DIR",
      "available": true,
      "clean": true,
      "branch": "main",
      "default_branch": "main",
      "on_default": true,
      "last_commit": {"date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"},
      "commits": [],
      "run_script": "$NOEXEC_SCRIPT"
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

# Same false-success class for the script itself: tmux would exit 0 and the
# window would vanish, so the click would report Started with nothing running.
[ ! -e "$MISSING_SCRIPT" ] || fail "test fixture error: $MISSING_SCRIPT should not exist"
MISSING_SCRIPT_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
  -H 'Content-Type: application/json' -d '{"name":"missingscript"}')
[ "$MISSING_SCRIPT_CODE" = "400" ] \
  || fail "/run should reject a project whose run script does not exist, got $MISSING_SCRIPT_CODE"
NOEXEC_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
  -H 'Content-Type: application/json' -d '{"name":"noexecscript"}')
[ "$NOEXEC_CODE" = "400" ] \
  || fail "/run should reject a project whose run script is not executable, got $NOEXEC_CODE"
RELATIVE_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
  -H 'Content-Type: application/json' -d '{"name":"relativescript"}')
[ "$RELATIVE_CODE" = "400" ] \
  || fail "/run should reject a project whose run script is a relative path, got $RELATIVE_CODE"
pass "/run rejects a project whose run script is missing, relative, or not executable instead of reporting it started"

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
  dashboard_windows() {  # -> "<window id>\t<window name>" per window
    tmux list-windows -t '=dashboard' -F $'#{window_id}\t#{window_name}' 2>/dev/null
  }
  dashboard_window_ids() {  # <window name> -> matching tmux window ids
    dashboard_windows | awk -F'\t' -v n="$1" '$2 == n { print $1 }'
  }
  active_dashboard_window() {
    tmux list-windows -t '=dashboard' -F $'#{window_active}\t#{window_name}' 2>/dev/null \
      | awk -F'\t' '$1 == 1 { print $2 }'
  }

  # This test's private tmux starts with no dashboard session at all, so the
  # first Run has to create one - and it must come up carrying only the
  # project's own window, with no stray bare shell alongside it.
  if tmux has-session -t '=dashboard' 2>/dev/null; then
    fail "the private test tmux should start with no dashboard session"
  fi

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
  FIRST_WINDOW_SET=$(dashboard_windows | grep -c .)
  [ "$FIRST_WINDOW_SET" = "1" ] \
    || fail "the first /run should create the session carrying only the project's window, got $FIRST_WINDOW_SET: $(dashboard_windows | tr '\n' ' ')"
  pass "the first /run creates the dashboard tmux session carrying only the project's own window and runs its script there"

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

  # <project name> <label>: fire six /run requests at once. Every one must
  # answer 200, and exactly one window must exist afterwards - an unserialized
  # launch has them all miss the window and create it several times over.
  assert_concurrent_run() {
    local name=$1 label=$2 dir i code count
    dir="$TMP_ROOT/conc-$label"
    mkdir -p "$dir"
    for i in 1 2 3 4 5 6; do
      curl -s -o /dev/null -w '%{http_code}' -X POST "$URL3/run" \
        -H 'Content-Type: application/json' -d "{\"name\":\"$name\"}" > "$dir/$i" &
    done
    wait
    for i in 1 2 3 4 5 6; do
      code=$(cat "$dir/$i")
      [ "$code" = "200" ] \
        || fail "concurrent /run $i for '$name' ($label) should succeed, got $code"
    done
    sleep 0.3
    count=$(dashboard_window_ids "$name" | grep -c .)
    [ "$count" = "1" ] \
      || fail "six concurrent /run for '$name' ($label) must leave exactly one window, found $count"
  }

  assert_concurrent_run conctest session-present
  pass "concurrent /run requests for one project cannot duplicate its window"

  # The same burst with no dashboard session at all: every request sees no
  # session, so an unserialized launch has them all race to create it and all
  # but one fail with tmux's own "duplicate session".
  tmux kill-session -t '=dashboard' >/dev/null 2>&1 || true
  if tmux has-session -t '=dashboard' 2>/dev/null; then
    fail "could not clear the private dashboard session for the creation-race check"
  fi
  assert_concurrent_run conctest session-missing
  pass "concurrent /run requests with no dashboard session yet cannot collide creating it"
fi

[ "$PHASE" = "supervised" ] || echo "ALL TESTS PASSED"
