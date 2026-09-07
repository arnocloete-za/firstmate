#!/usr/bin/env bash
# tests/fm-dashboard.test.sh - behavior tests for the read-only /dashboard page.
#
# Everything is asserted through the generated page, the command's only public
# surface: the numbering the captain reads aloud, the git-health signals, one
# commit on the card with five on hover, the live-work classification and its
# wants-captain boundary, and the absence of any way for the page to act on the
# fleet.
#
# Terminal presence and the jump command are exercised against a REAL tmux
# server on a private socket, because that half is only worth anything if it is
# right about whether a window still exists: the naive
# `tmux display-message -t <window>` read silently falls back to the CURRENT
# window and reports success for a window that is gone, which is exactly the
# lie that would send the captain into the wrong terminal.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DASH="$ROOT/bin/fm-dashboard.mjs"
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-dashboard)
FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/data" "$FM_HOME/state"
export FM_HOME
PAGE="$TMP_ROOT/index.html"

generate() {  # <extra-args...>
  "$DASH" --out "$PAGE" "$@" > "$TMP_ROOT/out.txt" 2> "$TMP_ROOT/err.txt" \
    || fail "generate failed: $(cat "$TMP_ROOT/err.txt")"
}

# card <n>: print the nth project card's markup (1-based, page order).
card() {  # <n>
  awk -v want="$1" '
    /^<div class="card[ "]/ { seen++ }
    seen == want { print }
    seen > want { exit }
  ' "$PAGE"
}

# row <task-id>: print the live row carrying that task id.
row() {  # <id>
  awk -v id="$1" '
    /^<div class="row[ "]/ { block = $0; next }
    block != "" { block = block "\n" $0 }
    /^<\/div>$/ { if (block ~ ">" id "<") print block; block = "" }
  ' "$PAGE"
}

# --- fixtures --------------------------------------------------------------
# make_repo <path> <default-branch>: a real git checkout with five commits.
make_repo() {  # <path> <branch>
  local path=$1 branch=$2 i
  mkdir -p "$path"
  git -C "$path" init -q -b "$branch"
  git -C "$path" config user.email crew@example.invalid
  git -C "$path" config user.name "Test Crew"
  for i in 1 2 3 4 5 6; do
    printf 'line %s\n' "$i" >> "$path/file.txt"
    git -C "$path" add file.txt
    git -C "$path" commit -q -m "commit number $i"
  done
}

REPOS="$TMP_ROOT/repos"
make_repo "$REPOS/alpha" main
make_repo "$REPOS/bravo" main
make_repo "$REPOS/charlie" main
git -C "$REPOS/charlie" checkout -q -b feature/wip
printf 'unstaged\n' >> "$REPOS/bravo/file.txt"

cat > "$FM_HOME/data/projects.md" <<REG
# Projects

- alpha [no-mistakes] - clone kept in place at $REPOS/alpha (added 2026-01-01)
- bravo [no-mistakes] - clone kept in place at $REPOS/bravo (added 2026-01-01)
- charlie [no-mistakes] - clone kept in place at $REPOS/charlie (added 2026-01-01)
- delta [local-only] - clone kept in place at $TMP_ROOT/nowhere (added 2026-01-01)
REG

EMPTY_FLEET="$TMP_ROOT/fleet-empty.json"
jq -n '{schema: "fm-fleet-snapshot.v1", generated: "2026-01-01T00:00:00Z", tasks: []}' \
  > "$EMPTY_FLEET"

# --- the page is one static file the command names ------------------------
generate --fleet-json "$EMPTY_FLEET"
[ -f "$PAGE" ] || fail "no page was written"
grep -q "dashboard: $PAGE" "$TMP_ROOT/out.txt" \
  || fail "the command must print the page it wrote: $(cat "$TMP_ROOT/out.txt")"
grep -q "^open: file://$PAGE\$" "$TMP_ROOT/out.txt" \
  || fail "the command must print an openable link: $(cat "$TMP_ROOT/out.txt")"
pass "one command writes one static page and prints the link to open it"

# --- display only: nothing on the page can act on the fleet ---------------
for forbidden in '<form' 'method="post"' 'fetch(' 'XMLHttpRequest' 'http://127.0.0.1' 'http://localhost'; do
  grep -qiF "$forbidden" "$PAGE" \
    && fail "the page must not carry '$forbidden' - it is display only"
done
grep -qiE '>[^<]*(run|start|stop|steer|merge|refresh)[^<]*</button>' "$PAGE" \
  && fail "the page must offer no button that acts on anything: $(grep -oiE '<button[^>]*>[^<]*</button>' "$PAGE")"
pass "the generated page has no form, no request back to any server, and no button that acts on anything"

# --- the numbering the captain reads aloud --------------------------------
card 1 | grep -q '>alpha<'   || fail "card 1 should be the first registry entry: $(card 1)"
card 2 | grep -q '>bravo<'   || fail "card 2 should be the second registry entry: $(card 2)"
card 3 | grep -q '>charlie<' || fail "card 3 should be the third registry entry: $(card 3)"
card 4 | grep -q '>delta<'   || fail "card 4 should be the fourth registry entry: $(card 4)"
card 1 | grep -q 'class="num">01<' || fail "card 1 should carry the number 01: $(card 1)"
card 4 | grep -q 'class="num">04<' || fail "card 4 should carry the number 04: $(card 4)"
pass "projects are numbered in registry order, so a number is a stable handle for a project"

# The whole point of registry order: a project's number must not move when its
# status changes. bravo is already uncommitted and charlie already off-default;
# make alpha the worst one too and assert nothing reorders.
printf 'churn\n' >> "$REPOS/alpha/file.txt"
generate --fleet-json "$EMPTY_FLEET"
card 1 | grep -q '>alpha<' \
  || fail "a project's number moved when its status changed: $(card 1)"
card 1 | grep -q 'uncommitted' \
  || fail "alpha should now read uncommitted: $(card 1)"
git -C "$REPOS/alpha" checkout -q -- file.txt
pass "a project keeps its number when its status changes - the board never sorts worst-first"

# --- git health -----------------------------------------------------------
generate --fleet-json "$EMPTY_FLEET"
card 1 | grep -q 'chip clean">clean<' || fail "a clean checkout should read clean: $(card 1)"
card 1 | grep -q '>main<'             || fail "the current branch should be shown: $(card 1)"
card 1 | grep -q 'off-default'        && fail "a project on its default branch is not off-default: $(card 1)"
card 2 | grep -q 'chip uncommitted">uncommitted<' \
  || fail "a checkout with local changes should read uncommitted: $(card 2)"
card 3 | grep -q 'off-default' \
  || fail "a checkout off its own default branch should be flagged: $(card 3)"
card 3 | grep -q '>feature/wip<' \
  || fail "the off-default branch should be named: $(card 3)"
card 4 | grep -q 'unavailable' \
  || fail "a registry entry with no checkout should render as unavailable: $(card 4)"
card 4 | grep -q 'no git checkout at this path' \
  || fail "an unavailable project should say why: $(card 4)"
pass "each card reports cleanliness, its current branch against that repo's own default, and its last commit"

# --- one commit on the card, five on hover --------------------------------
[ "$(card 1 | grep -o 'class="subject"' | wc -l)" -eq 1 ] \
  || fail "a card body should show exactly one commit: $(card 1)"
[ "$(card 1 | sed -n '/class="history"/,$p' | grep -o '<li>' | wc -l)" -eq 5 ] \
  || fail "the hover history should carry the last five commits: $(card 1)"
card 1 | grep -q 'commit number 6' \
  || fail "the card should show the newest commit: $(card 1)"
pass "one commit shows on the card and the last five appear in the hover history"

# --- live work: classification and the wants-captain boundary -------------
task_json() {  # <id> <repo> <state> <detail> <extra-json>
  jq -n --arg id "$1" --arg repo "$2" --arg state "$3" --arg detail "$4" --argjson extra "$5" \
    '{
       id: $id, kind: "ship", project: "/p", backend: "tmux", remote: null,
       current_state: {state: $state, source: "run-step", detail: $detail},
       conn: {held: false, age_seconds: null},
       endpoint: {target: null, exists: true},
       pr: {url: null},
       hints: {pending_decision: false, blocked_event: false, open_decisions: []},
       backlog: {repo: $repo, title: null, hold_kind: null, hold_reason: null,
                 blocked_reason: null, captain_actionable: false}
     } * $extra'
}

FLEET_W="$TMP_ROOT/fleet-waiting.json"
jq -n --argjson tasks "$(jq -n \
  --argjson failed "$(task_json t-failed proj failed 'run failed' '{}')" \
  --argjson blocked "$(task_json t-blocked proj blocked 'stopped' '{}')" \
  --argjson askuser "$(task_json t-askuser proj parked 'parked at review: 2 finding(s) (ask-user: authority decision)' '{}')" \
  --argjson hold "$(task_json t-hold proj paused 'idling' '{"backlog":{"hold_kind":"captain","hold_reason":"Try the new landing screen and say what you think."}}')" \
  --argjson keyed "$(task_json t-keyed proj working 'harness busy' '{"hints":{"open_decisions":["which-auth-provider"]}}')" \
  --argjson review "$(task_json t-review proj 'done' 'checks green: PR ready for review' '{"pr":{"url":"https://example.invalid/pr/1"}}')" \
  --argjson gate "$(task_json t-gate proj parked 'parked at document: 1 finding(s)' '{}')" \
  --argjson external "$(task_json t-external proj paused 'waiting for the nightly export' '{}')" \
  --argjson working "$(task_json t-working proj working 'validating (fixing)' '{}')" \
  --argjson conn "$(task_json t-conn proj working 'harness busy' '{"conn":{"held":true,"age_seconds":12}}')" \
  --argjson unclear "$(task_json t-unclear proj unknown '' '{}')" \
  '[$failed,$blocked,$askuser,$hold,$keyed,$review,$gate,$external,$working,$conn,$unclear]')" \
  '{schema: "fm-fleet-snapshot.v1", generated: "2026-01-01T00:00:00Z", tasks: $tasks}' \
  > "$FLEET_W"

generate --fleet-json "$FLEET_W"

expect_wants() {  # <id> <label>
  row "$1" | grep -q 'class="row wants"' \
    || fail "$1 should be marked as waiting on the captain: $(row "$1")"
  row "$1" | grep -qF "$2" \
    || fail "$1 should read '$2': $(row "$1")"
}
expect_wants t-failed  'Failed'
expect_wants t-blocked 'Blocked - needs you'
expect_wants t-askuser 'Needs your decision'
expect_wants t-hold    'Needs your decision'
expect_wants t-keyed   'Needs your decision'
expect_wants t-review  'Ready for your review'
pass "failures, blockers, captain decisions, and a finished PR all read as waiting on the captain"

expect_calm() {  # <id> <label>
  row "$1" | grep -q 'class="row wants"' \
    && fail "$1 must not claim the captain: $(row "$1")"
  row "$1" | grep -qF "$2" || fail "$1 should read '$2': $(row "$1")"
}
expect_calm t-gate     'In its own review'
expect_calm t-external 'Waiting on something outside'
expect_calm t-working  'Nothing owed'
expect_calm t-unclear  'Unclear - worth a look'
pass "a run at its own gate, a declared external wait, ordinary work, and an unreadable state never claim the captain"

row t-conn | grep -q 'class="row conn"' \
  || fail "a task the captain is driving should get its own treatment: $(row t-conn)"
row t-conn | grep -q 'class="row wants"' \
  && fail "a task the captain is driving must not claim to be waiting on him: $(row t-conn)"
row t-conn | grep -qF 'You are working in this terminal' \
  || fail "a conn row should say so in plain words: $(row t-conn)"
pass "a task the captain has the conn on never reads as stuck and never claims to want him"

# Plain words, never a pipeline label leaked onto the page.
row t-askuser | grep -qF 'Stopped for a decision it cannot make itself' \
  || fail "an ask-user gate should be described in the captain's words: $(row t-askuser)"
grep -qE 'fix_review|ask-user|run-step|parked at' "$PAGE" \
  && fail "the page must not leak internal state vocabulary: $(grep -oE 'fix_review|ask-user|run-step|parked at[^<]*' "$PAGE" | head -3)"
pass "rows speak in the captain's nouns rather than leaking pipeline labels"

# Whatever wants him sits at the top.
FIRST=$(awk '/class="row/ { print; exit }' "$PAGE")
printf '%s' "$FIRST" | grep -q 'class="row wants"' \
  || fail "the first live row should be one that wants the captain: $FIRST"
LAST_WANTS=$(grep -n 'class="row wants"' "$PAGE" | tail -1 | cut -d: -f1)
FIRST_CALM=$(grep -n 'class="row">' "$PAGE" | head -1 | cut -d: -f1)
[ "$LAST_WANTS" -lt "$FIRST_CALM" ] \
  || fail "every row that wants the captain must sort above every calm row"
pass "live work is ordered so whatever wants the captain is at the top"

# A captain hold reason is a sentence written for him, so it beats any composed label.
row t-hold | grep -qF 'Try the new landing screen and say what you think.' \
  || fail "a captain hold reason should be shown as written: $(row t-hold)"
pass "a captain hold reason reaches the page as the sentence it was written as"

# --- degradation: the project half must still build -----------------------
generate --fleet-json "$TMP_ROOT/not-here.json"
grep -q 'Could not read the work running now' "$PAGE" \
  || fail "an unusable fleet read should say so on the page"
card 1 | grep -q '>alpha<' \
  || fail "an unusable fleet read must not cost the captain his project board: $(card 1)"
pass "an unusable fleet read reports itself and still leaves every project card standing"

printf 'not json at all\n' > "$TMP_ROOT/garbage.json"
generate --fleet-json "$TMP_ROOT/garbage.json"
grep -q 'Could not read the work running now' "$PAGE" \
  || fail "an unparseable fleet read should say so on the page"
pass "an unparseable fleet read degrades to a stated reason rather than a broken page"

# An empty registry is not an error.
mv "$FM_HOME/data/projects.md" "$TMP_ROOT/projects.md.bak"
generate --fleet-json "$EMPTY_FLEET"
grep -q 'No projects registered' "$PAGE" || fail "an absent registry should say so"
grep -q 'No work running' "$PAGE" || fail "an empty fleet should say so"
mv "$TMP_ROOT/projects.md.bak" "$FM_HOME/data/projects.md"
pass "an absent registry and an empty fleet each state themselves rather than failing"

# --- terminal presence and the jump command, against a real tmux ----------
if ! command -v tmux >/dev/null 2>&1; then
  echo "skip: tmux not found - terminal presence assertions skipped"
  echo "ALL TESTS PASSED"
  exit 0
fi

REAL_TMUX=$(command -v tmux)
SOCKET="fm-dashboard-$$"
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-shim.XXXXXX")
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
# generator's own bare `tmux` reads never touch the host's real sessions.
cat > "$SHIM_DIR/tmux" <<TMUXSH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
TMUXSH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

tmux new-session -d -s crew -n other 2>/dev/null \
  || { echo "skip: cannot start a private tmux server"; echo "ALL TESTS PASSED"; exit 0; }
# A window with a live shell in it. The shell is what makes the endpoint
# readable; whether it counts as an agent is bin/backends/tmux.sh's business.
tmux new-window -t crew -n fm-present
# Deliberately NOT created: crew:fm-vanished.

FLEET_T="$TMP_ROOT/fleet-terminals.json"
jq -n --argjson tasks "$(jq -n \
  --argjson present "$(task_json t-present proj working 'harness busy' \
    '{"endpoint":{"target":"crew:fm-present","exists":true}}')" \
  --argjson vanished "$(task_json t-vanished proj working 'harness busy' \
    '{"endpoint":{"target":"crew:fm-vanished","exists":true}}')" \
  --argjson remote "$(task_json t-remote proj working 'harness busy' \
    '{"remote":"builder.invalid","endpoint":{"target":"crew:fm-remote","exists":true}}')" \
  '[$present, $vanished, $remote]')" \
  '{schema: "fm-fleet-snapshot.v1", generated: "2026-01-01T00:00:00Z", tasks: $tasks}' \
  > "$FLEET_T"

generate --fleet-json "$FLEET_T"

# The window that exists gets a copyable command naming its own recorded
# session - never a hardcoded session name.
row t-present | grep -q 'this terminal no longer exists' \
  && fail "a window that exists must not read as gone: $(row t-present)"
row t-present | grep -qF 'crew:fm-present' \
  || fail "the terminal command must target the recorded endpoint: $(row t-present)"
row t-present | grep -qF 'switch-client' \
  || fail "the terminal command must also work from inside tmux: $(row t-present)"
pass "a window that exists reads as reachable and gets a jump command built from its own recorded session"

# The critical assertion. `endpoint.exists` in the fixture says true for BOTH
# rows, exactly as the canonical snapshot's cheap read reports it, because
# `tmux display-message -t <missing window>` silently answers for the current
# window instead of failing. The page must still tell these two apart.
row t-vanished | grep -qF 'this terminal no longer exists' \
  || fail "a window that no longer exists must read as gone even though the cheap endpoint read claims it exists: $(row t-vanished)"
row t-vanished | grep -qF 'crew:fm-vanished' \
  && fail "a terminal known to be gone must not offer a jump command: $(row t-vanished)"
pass "a vanished window reads as gone with no jump command, despite the cheap endpoint read reporting it exists"

row t-remote | grep -qF 'this work runs on another machine' \
  || fail "a remote endpoint should say where the work is: $(row t-remote)"
row t-remote | grep -qF 'crew:fm-remote' \
  && fail "a remote endpoint is not a local terminal to walk into: $(row t-remote)"
pass "a remote endpoint reports as remote and is offered no local jump command"

echo "ALL TESTS PASSED"
