#!/usr/bin/env bash
# tests/fm-dashboard-serve.test.sh - behavior tests for building and serving
# the /dashboard project-status board.
#
# Covers schema validation refusal, template-injection round-trip (the built
# page carries a readable fm-dashboard-snapshot.v1 payload), HTTP
# reachability of the served content, idempotent reuse of an already-running
# server across a rebuild, and `stop`.
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

DATA="$TMP_ROOT/snapshot.json"
cat > "$DATA" <<'JSON'
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
      "commits": [{"hash": "abc1234", "date": "2026-01-01T00:00:00Z", "author": "alice", "subject": "init"}]
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

echo "ALL TESTS PASSED"
