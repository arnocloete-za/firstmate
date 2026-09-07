#!/usr/bin/env bash
# tests/fm-dashboard-serve.test.sh - behavior tests for building and serving
# the /dashboard project-status board.
#
# Covers schema validation refusal, template-injection round-trip (the built
# page carries a readable fm-dashboard-snapshot.v1 payload), HTTP
# reachability of the served content, idempotent reuse of an already-running
# server across a rebuild, and `stop`.
#
# Also covers the optional LIVE WORK half: an omitted --live fills its slot
# with JSON null so the project board still builds, a supplied payload
# round-trips as fm-dashboard-live.v1 into the same single page, a payload
# failing that schema is refused, and the built page's own scripts parse (a
# template whose JavaScript is broken serves a blank section, so the syntax
# check is part of the build being correct, not a style preference).
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

# --- the optional LIVE WORK half ------------------------------------------
# Omitting --live must leave a page that still carries the project board. The
# live slot is filled with JSON null, which the page reads as "no live read was
# taken" rather than "nothing is running".
LIVE_SLOT=$(sed -n '/<script id="dashboard-live" type="application\/json">/,/<\/script>/p' "$BOARD" | sed '1d;$d')
echo "$LIVE_SLOT" | jq -e '. == null' >/dev/null \
  || fail "with no --live the live slot should hold JSON null, got: $LIVE_SLOT"
pass "building without --live fills the live slot with null and still builds the project board"

LIVE_DATA="$TMP_ROOT/live.json"
cat > "$LIVE_DATA" <<'JSON'
{
  "schema": "fm-dashboard-live.v1",
  "generated_at": "2026-01-01T00:00:00Z",
  "available": true,
  "fleet_observed_at": "2026-01-01T00:00:00Z",
  "tasks": [
    {
      "id": "demo-task",
      "project": "demo",
      "project_path": "/nowhere",
      "kind": "ship",
      "title": "A demo task",
      "state": "parked",
      "activity": "Stopped for a decision it cannot make itself",
      "waiting": {"kind": "decision", "label": "Needs your decision", "note": "why", "wants_captain": true},
      "terminal": {"target": "crew:fm-demo-task", "presence": "live", "presence_note": "a worker is in this terminal", "command": "tmux attach -t 'crew:fm-demo-task'"},
      "pr_url": null,
      "rank": 2
    }
  ]
}
JSON

BAD_LIVE="$TMP_ROOT/bad-live.json"
printf '{"schema": "not-a-real-schema", "tasks": []}\n' > "$BAD_LIVE"
if "$SERVE" build "$DATA" --live "$BAD_LIVE" >/dev/null 2>&1; then
  fail "build should refuse a live payload with the wrong schema tag"
fi
pass "build refuses a live payload that fails fm-dashboard-live.v1 validation"

if "$SERVE" build "$DATA" --live "$TMP_ROOT/no-such-live.json" >/dev/null 2>&1; then
  fail "build should refuse a --live file that does not exist"
fi
pass "build refuses a --live file that does not exist"

OUT_LIVE=$("$SERVE" build "$DATA" --live "$LIVE_DATA") || fail "build with --live failed: $OUT_LIVE"
BOARD_LIVE=$(echo "$OUT_LIVE" | sed -n 's/^dashboard: //p')
[ "$BOARD_LIVE" = "$BOARD" ] || fail "the live half must land in the same page, got $BOARD_LIVE vs $BOARD"

PROJ_SLOT=$(sed -n '/<script id="dashboard-data" type="application\/json">/,/<\/script>/p' "$BOARD_LIVE" | sed '1d;$d')
echo "$PROJ_SLOT" | jq -e '.schema == "fm-dashboard-snapshot.v1" and (.projects[0].name == "demo")' >/dev/null \
  || fail "the project payload must survive alongside the live one: $PROJ_SLOT"
LIVE_SLOT=$(sed -n '/<script id="dashboard-live" type="application\/json">/,/<\/script>/p' "$BOARD_LIVE" | sed '1d;$d')
echo "$LIVE_SLOT" | jq -e '.schema == "fm-dashboard-live.v1" and (.tasks[0].id == "demo-task")' >/dev/null \
  || fail "the built page's live slot does not round-trip: $LIVE_SLOT"
pass "both payloads round-trip into one page at the same path - the board stays a single surface"

grep -q '__FM_DASHBOARD_DATA__' "$BOARD_LIVE" && fail "the project data slot survived injection"
grep -q '__FM_DASHBOARD_LIVE__' "$BOARD_LIVE" && fail "the live data slot survived injection"
pass "neither data slot placeholder survives into the built page"

# The template is shared and actively edited, so a slot going missing or being
# duplicated must refuse rather than silently ship a page with no live half.
NO_SLOT="$TMP_ROOT/template-no-live-slot.html"
sed '/__FM_DASHBOARD_LIVE__/d' "$ROOT/.agents/skills/dashboard/assets/dashboard-template.html" > "$NO_SLOT"
if FM_DASHBOARD_TEMPLATE="$NO_SLOT" "$SERVE" build "$DATA" --live "$LIVE_DATA" >/dev/null 2>&1; then
  fail "build should refuse a template that lost its live-work slot"
fi
DUP_SLOT="$TMP_ROOT/template-dup-live-slot.html"
sed 's/^__FM_DASHBOARD_LIVE__$/__FM_DASHBOARD_LIVE__\n__FM_DASHBOARD_LIVE__/' \
  "$ROOT/.agents/skills/dashboard/assets/dashboard-template.html" > "$DUP_SLOT"
if FM_DASHBOARD_TEMPLATE="$DUP_SLOT" "$SERVE" build "$DATA" --live "$LIVE_DATA" >/dev/null 2>&1; then
  fail "build should refuse a template carrying more than one live-work slot"
fi
pass "build refuses a template whose live-work slot is missing or duplicated"

# A refused build must not leave staged temporary pages in the served directory.
STRAY=$(find "$FM_HOME/.dashboard" -maxdepth 1 -name '.index.*' 2>/dev/null | wc -l)
[ "$STRAY" -eq 0 ] || fail "a refused build left $STRAY staged page(s) in the served directory"
pass "a refused build leaves no staged temporary page in the served directory"

# A built page whose inline JavaScript does not parse renders an empty section
# with no visible error, so the page is only correct if its scripts parse.
if command -v node >/dev/null 2>&1; then
  SCRIPT_DIR_JS="$TMP_ROOT/js"
  mkdir -p "$SCRIPT_DIR_JS"
  python3 - "$BOARD_LIVE" "$SCRIPT_DIR_JS" <<'PYEOF'
import os, pathlib, re, sys
html = open(sys.argv[1], encoding='utf-8').read()
outdir = sys.argv[2]
blocks = re.findall(r'<script(?![^>]*type="application/json")[^>]*>(.*?)</script>', html, re.S)
for i, block in enumerate(blocks):
    pathlib.Path(os.path.join(outdir, 'block%d.js' % i)).write_text(block, encoding='utf-8')
PYEOF
  BLOCKS=$(find "$SCRIPT_DIR_JS" -name 'block*.js' | wc -l)
  [ "$BLOCKS" -ge 2 ] || fail "expected at least two inline script blocks in the built page, found $BLOCKS"
  for js in "$SCRIPT_DIR_JS"/block*.js; do
    node --check "$js" >/dev/null 2>&1 || fail "an inline script in the built page does not parse: $js"
  done
  pass "every inline script in the built page parses as JavaScript"
else
  echo "skip: node not found - inline script syntax check skipped"
fi

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
