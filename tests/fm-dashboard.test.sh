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

# card_in <page> <n>: print the nth project card's markup (1-based, page order).
card_in() {  # <page> <n>
  awk -v want="$2" '
    /^<div class="card[ "]/ { seen++ }
    seen == want { print }
    seen > want { exit }
  ' "$1"
}

# row_in <page> <task-id>: print the live row carrying that task id.
row_in() {  # <page> <id>
  awk -v id="$2" '
    /^<div class="row[ "]/ { block = $0; next }
    block != "" { block = block "\n" $0 }
    /^<\/div>$/ { if (block ~ ">" id "<") print block; block = "" }
  ' "$1"
}

# The shared fixture reads the one page every case but the board cases use.
card() { card_in "$PAGE" "$1"; }  # <n>
row() { row_in "$PAGE" "$1"; }    # <id>

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

# --- boards: which projects, and whose work, each one shows ---------------
# The captain keeps his work and his own personal projects on separate boards.
# What matters here is that the split is REGISTRY state and that its failure
# direction is safe: a project he has not marked, or has marked wrong, must land
# on the work board rather than off both, because a project he cannot see
# anywhere is worse than one on the wrong board.
#
# A separate home so these cases cannot disturb the shared fixture above.
BOARD_HOME="$TMP_ROOT/boards/home"
BOARD_REPOS="$TMP_ROOT/boards/repos"
mkdir -p "$BOARD_HOME/data"
for name in w-one w-two w-bad p-one p-two; do
  make_repo "$BOARD_REPOS/$name" main
done

cat > "$BOARD_HOME/data/projects.md" <<REG
# Projects

- w-one - no annotation at all (added 2026-01-01); clone kept in place at $BOARD_REPOS/w-one
- p-one [local-only +personal] - clone kept in place at $BOARD_REPOS/p-one (added 2026-01-01)
- w-two [no-mistakes] - clone kept in place at $BOARD_REPOS/w-two (added 2026-01-01)
- p-two [no-mistakes-prod-only +personal] - clone kept in place at $BOARD_REPOS/p-two (added 2026-01-01)
- w-bad [no-mistakes +persnoal] - a misspelled marker (added 2026-01-01); clone kept in place at $BOARD_REPOS/w-bad
REG

# One task per board, plus one whose project is registered on no board at all.
BOARD_FLEET="$TMP_ROOT/fleet-boards.json"
jq -n --argjson tasks "$(jq -n \
  --argjson work "$(task_json t-work w-one working 'harness busy' '{}')" \
  --argjson personal "$(task_json t-personal p-one working 'harness busy' '{}')" \
  --argjson ghost "$(task_json t-ghost not-registered working 'harness busy' '{}')" \
  '[$work, $personal, $ghost]')" \
  '{schema: "fm-fleet-snapshot.v1", generated: "2026-01-01T00:00:00Z", tasks: $tasks}' \
  > "$BOARD_FLEET"

WORK_PAGE="$TMP_ROOT/boards/work.html"
PERSONAL_PAGE="$TMP_ROOT/boards/personal.html"
board() {  # <group> <page> <extra-args...>
  local group=$1 page=$2
  shift 2
  FM_HOME="$BOARD_HOME" "$DASH" --group "$group" --out "$page" \
    --fleet-json "$BOARD_FLEET" "$@" > "$TMP_ROOT/board-out.txt" 2> "$TMP_ROOT/board-err.txt" \
    || fail "generating the $group board failed: $(cat "$TMP_ROOT/board-err.txt")"
}
board work "$WORK_PAGE"
board personal "$PERSONAL_PAGE"

# The captain asked for the marked projects to be gone from the work board, so
# absence from the whole page is the assertion - not merely absence of a card.
for marked in p-one p-two; do
  grep -qF ">$marked<" "$WORK_PAGE" \
    && fail "$marked is marked personal and must not appear on the work board"
done
for unmarked in w-one w-two w-bad; do
  grep -qF ">$unmarked<" "$PERSONAL_PAGE" \
    && fail "$unmarked is not marked personal and must not appear on the personal board"
done
card_in "$PERSONAL_PAGE" 1 | grep -q '>p-one<' \
  || fail "the personal board should show the first marked project: $(card_in "$PERSONAL_PAGE" 1)"
card_in "$PERSONAL_PAGE" 2 | grep -q '>p-two<' \
  || fail "the personal board should show the second marked project: $(card_in "$PERSONAL_PAGE" 2)"
card_in "$PERSONAL_PAGE" 3 | grep -q 'class="card' \
  && fail "the personal board must show ONLY the marked projects: $(card_in "$PERSONAL_PAGE" 3)"
pass "a registry marker moves a project between boards, and each board shows only its own projects"

# The safe failure direction: unmarked, unannotated, and misspelled all mean the
# work board, so nothing the captain has not deliberately moved can vanish.
card_in "$WORK_PAGE" 1 | grep -q '>w-one<' \
  || fail "a project with no annotation at all belongs on the work board: $(card_in "$WORK_PAGE" 1)"
card_in "$WORK_PAGE" 3 | grep -q '>w-bad<' \
  || fail "a misspelled marker must leave the project on the work board, not on none: $(card_in "$WORK_PAGE" 3)"
grep -qF '>w-bad<' "$PERSONAL_PAGE" \
  && fail "a misspelled marker must not put a project on the personal board"
pass "an unmarked, unannotated, or misspelled project lands on the work board, so nothing silently vanishes"

# Numbering is per board and in registry order within it, so a project's number
# is its position among the projects the captain sees beside it.
card_in "$WORK_PAGE" 1 | grep -q 'class="num">01<' \
  || fail "the work board should number its own first project 01: $(card_in "$WORK_PAGE" 1)"
card_in "$WORK_PAGE" 2 | grep -q '>w-two<' \
  || fail "the work board should skip the marked project and number registry order within itself: $(card_in "$WORK_PAGE" 2)"
card_in "$PERSONAL_PAGE" 1 | grep -q 'class="num">01<' \
  || fail "each board numbers from 01 independently: $(card_in "$PERSONAL_PAGE" 1)"
card_in "$PERSONAL_PAGE" 2 | grep -q 'class="num">02<' \
  || fail "the personal board should number its second project 02: $(card_in "$PERSONAL_PAGE" 2)"
pass "each board numbers its own projects from 01 in registry order within that board"

# The same guarantee the whole-fleet board has: a number is a spoken handle, so
# it must not move when a project's status changes.
printf 'churn\n' >> "$BOARD_REPOS/w-two/file.txt"
board work "$WORK_PAGE"
card_in "$WORK_PAGE" 2 | grep -q '>w-two<' \
  || fail "a project's number moved on its board when its status changed: $(card_in "$WORK_PAGE" 2)"
card_in "$WORK_PAGE" 2 | grep -q 'uncommitted' \
  || fail "w-two should now read uncommitted: $(card_in "$WORK_PAGE" 2)"
git -C "$BOARD_REPOS/w-two" checkout -q -- file.txt
board work "$WORK_PAGE"
pass "a per-board number holds still when the project's status changes"

# A task is on the board its project is on, and one whose project is registered
# nowhere stays on the work board for the same reason an unmarked project does.
row_in "$WORK_PAGE" t-work | grep -q 'class="row' \
  || fail "a task on a work project belongs on the work board"
row_in "$PERSONAL_PAGE" t-personal | grep -q 'class="row' \
  || fail "a task on a personal project belongs on the personal board"
row_in "$PERSONAL_PAGE" t-work | grep -q 'class="row' \
  && fail "a task on a work project must not appear on the personal board"
row_in "$WORK_PAGE" t-personal | grep -q 'class="row' \
  && fail "a task on a personal project must not appear on the work board"
row_in "$WORK_PAGE" t-ghost | grep -q 'class="row' \
  || fail "a task whose project is not registered must stay on the work board, not vanish"
row_in "$PERSONAL_PAGE" t-ghost | grep -q 'class="row' \
  && fail "an unregistered task belongs on one board only"
grep -q '<b>1</b> running' "$PERSONAL_PAGE" \
  || fail "the personal board should count only its own running work: $(grep -o '<b>[0-9]*</b> running' "$PERSONAL_PAGE")"
pass "live work follows its project's board, and work on an unregistered project stays on the work board"

# One generator, one template. The two boards are the same page with different
# projects on it, so their styling and script must be byte-identical - a fork
# would let them drift the first time only one was changed.
# styling: everything between the style tags, which spans many lines.
styling() {  # <page>
  awk '/<style>/ { on = 1 } on { print } /<\/style>/ { if (on) exit }' "$1"
}
title_of() {  # <page>
  sed -n 's/.*<title>\(.*\)<\/title>.*/\1/p' "$1"
}
[ "$(styling "$WORK_PAGE" | wc -l)" -gt 20 ] \
  || fail "the work board should carry its style block: $(styling "$WORK_PAGE" | head -3)"
[ "$(styling "$WORK_PAGE")" = "$(styling "$PERSONAL_PAGE")" ] \
  || fail "the two boards must render from one template - their styling has diverged"
[ "$(title_of "$WORK_PAGE")" = "Fleet dashboard" ] \
  || fail "the work board keeps its own name: $(title_of "$WORK_PAGE")"
[ "$(title_of "$PERSONAL_PAGE")" = "Personal dashboard" ] \
  || fail "the personal board should name itself so the captain knows which board he is on"
grep -qF 're-run /dashboard-personal to refresh' "$PERSONAL_PAGE" \
  || fail "each board should name the command that re-runs IT"
grep -qF 're-run /dashboard to refresh' "$WORK_PAGE" \
  || fail "the work board should still name /dashboard"
pass "both boards render from one template and differ only in their projects and their own name"

# Each board has its own default location, so generating one can never overwrite
# the other, and a watch on one cannot publish over the other's page.
for group in work personal; do
  FM_HOME="$BOARD_HOME" "$DASH" --group "$group" --fleet-json "$BOARD_FLEET" \
    > "$TMP_ROOT/board-default-$group.txt" 2>&1 \
    || fail "the $group board should generate at its own default path: $(cat "$TMP_ROOT/board-default-$group.txt")"
done
WORK_DEFAULT=$(sed -n 's/^dashboard: //p' "$TMP_ROOT/board-default-work.txt")
PERSONAL_DEFAULT=$(sed -n 's/^dashboard: //p' "$TMP_ROOT/board-default-personal.txt")
[ -n "$WORK_DEFAULT" ] && [ -n "$PERSONAL_DEFAULT" ] \
  || fail "each board should print the page it wrote"
[ "$WORK_DEFAULT" != "$PERSONAL_DEFAULT" ] \
  || fail "the boards share a default page path, so one would overwrite the other: $WORK_DEFAULT"
grep -qF '>p-one<' "$PERSONAL_DEFAULT" \
  || fail "the personal board's default page should hold the personal projects"
grep -qF '>p-one<' "$WORK_DEFAULT" \
  && fail "the work board's default page must not hold a personal project"
pass "each board writes its own default page, so generating one never overwrites the other"

# A board name that is not a board is refused rather than quietly rendered as
# some other board's projects under this one's name.
if FM_HOME="$BOARD_HOME" "$DASH" --group persnoal --out "$TMP_ROOT/boards/typo.html" \
    --fleet-json "$BOARD_FLEET" > "$TMP_ROOT/board-typo.txt" 2>&1; then
  fail "an unknown board name should be refused: $(cat "$TMP_ROOT/board-typo.txt")"
fi
assert_contains "$(cat "$TMP_ROOT/board-typo.txt")" "--group must be one of" \
  "an unknown board name should say which boards exist"
[ -f "$TMP_ROOT/boards/typo.html" ] \
  && fail "a refused board name must not leave a page behind"
pass "an unknown board name is refused by name rather than rendered as some other board"

# --- watch mode -----------------------------------------------------------
# The captain starts one command and the page stops going stale on him. What
# matters here is what that command PUBLISHES, because the page has no other
# way to learn anything: the board file only when the board changed, and one
# sidecar every pass carrying the evidence that the watch is still reading.
# Whether a browser then acts on those files is proved against a real browser
# and recorded in docs/verification/dashboard-watch.md.
STAMP="$PAGE.watch.js"

# Refusals first: they cost nothing and a cadence silently ignored is worse
# than one refused.
"$DASH" --out "$PAGE" --interval 10 > "$TMP_ROOT/out.txt" 2> "$TMP_ROOT/err.txt" \
  && fail "--interval without --watch should be refused, not ignored"
grep -q 'interval means nothing without --watch' "$TMP_ROOT/err.txt" \
  || fail "the refusal should say why: $(cat "$TMP_ROOT/err.txt")"
"$DASH" --out "$PAGE" --watch --interval 1 > /dev/null 2> "$TMP_ROOT/err.txt" \
  && fail "an interval under the floor should be refused"
"$DASH" --out "$PAGE" --watch --interval soon > /dev/null 2> "$TMP_ROOT/err.txt" \
  && fail "a non-numeric interval should be refused"
pass "a cadence that means nothing, or would hammer the fleet, is refused rather than quietly accepted"

# A page generated WITHOUT --watch is unchanged: no pickup, and nothing that
# would go looking for a sidecar.
generate --fleet-json "$EMPTY_FLEET"
grep -q 'fmDashboardStamp' "$PAGE" \
  && fail "a page written without --watch must carry no watch pickup at all"
pass "the plain command still writes a page with nothing watching it"

# Fixture repos of their own, committed at a fixed old date, so a commit's
# displayed age cannot tick over mid-test and make an unchanged fleet look
# changed.
WREPOS="$TMP_ROOT/watch-repos"
make_repo "$WREPOS/echo" main
GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
  git -C "$WREPOS/echo" commit -q --amend --no-edit --date='2020-01-01T00:00:00Z'
cat > "$FM_HOME/data/projects.md" <<REG
# Projects

- echo [no-mistakes] - clone kept in place at $WREPOS/echo (added 2026-01-01)
REG

# wait_until <seconds> <command...>: poll a condition so the test is as fast as
# the watch allows and still survives a loaded machine.
wait_until() {  # <seconds> <command...>
  local limit=$1 waited=0
  shift
  while [ "$waited" -lt "$limit" ]; do
    "$@" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}
stamp_field() {  # <name>
  sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$STAMP"
}
page_content_id() {
  sed -n 's/.*name="fm-dashboard-content" content="\([^"]*\)".*/\1/p' "$PAGE"
}
file_id() {  # <path>: inode, which a publish-by-rename always changes
  stat -c %i "$1" 2>/dev/null || stat -f %i "$1"
}
read_advanced() { [ -f "$STAMP" ] && [ "$(stamp_field readAt)" != "$1" ]; }

rm -f "$PAGE" "$STAMP"
WATCH_INTERVAL=5
"$DASH" --out "$PAGE" --watch --interval "$WATCH_INTERVAL" --fleet-json "$EMPTY_FLEET" \
  > "$TMP_ROOT/watch.log" 2>&1 &
WATCH_PID=$!
watch_stop() { kill -0 "$WATCH_PID" 2>/dev/null && kill -INT "$WATCH_PID" 2>/dev/null; }
trap 'watch_stop; fm_test_cleanup' EXIT

announced() { grep -q "^watching: " "$TMP_ROOT/watch.log"; }
wait_until 20 announced \
  || fail "the watch should say it is running and how to stop it: $(cat "$TMP_ROOT/watch.log")"
grep -q 'Ctrl-C' "$TMP_ROOT/watch.log" \
  || fail "stopping must be as obvious as starting: $(cat "$TMP_ROOT/watch.log")"
# The link is handed over only once there is a page behind it.
LINK=$(sed -n 's/^open: file:\/\///p' "$TMP_ROOT/watch.log")
[ -f "$LINK" ] || fail "the watch offered a link to a page that is not there: $LINK"
[ -f "$STAMP" ] || fail "a watch should publish its sidecar alongside the page"
grep -q 'fmDashboardStamp' "$PAGE" || fail "a watched page should carry the pickup that reads the sidecar"
[ "$(stamp_field content)" = "$(page_content_id)" ] \
  || fail "the sidecar must report the very page it was published beside"
pass "one command publishes the board, the sidecar beside it, and says how to stop"

# The sidecar's claim expires, so nothing can keep saying "watching" on the
# strength of a watch that used to be running.
DUE=$(stamp_field dueBy)
[ -n "$DUE" ] || fail "the sidecar must say when the next one is owed: $(cat "$STAMP")"
[ "$DUE" \> "$(stamp_field readAt)" ] \
  || fail "the next stamp must be owed after the read it follows: $(cat "$STAMP")"
grep -q 'dueBy' "$PAGE" || fail "the page must start with that expiry too, not with an open-ended claim"
pass "the watch publishes an expiry on its own liveness rather than an open-ended claim"

# An unchanged fleet: the sidecar keeps proving the watch is reading, and the
# page the captain is looking at is left exactly where it is.
PAGE_ID=$(file_id "$PAGE")
FIRST_READ=$(stamp_field readAt)
wait_until $((WATCH_INTERVAL * 4)) read_advanced "$FIRST_READ" \
  || fail "the sidecar must keep advancing, or the page cannot tell a live watch from a dead one"
[ "$(file_id "$PAGE")" = "$PAGE_ID" ] \
  || fail "an unchanged board must not be rewritten under the captain's scroll position"
pass "an unchanged fleet keeps proving the watch is alive without rewriting the page"

# A real change: the page is republished and the sidecar points at the new one.
printf 'more\n' >> "$WREPOS/echo/file.txt"
git -C "$WREPOS/echo" add file.txt
git -C "$WREPOS/echo" commit -q -m "the newest thing"
page_republished() { [ "$(file_id "$PAGE")" != "$PAGE_ID" ]; }
wait_until $((WATCH_INTERVAL * 4)) page_republished \
  || fail "a changed board must be republished: $(cat "$TMP_ROOT/watch.log")"
grep -q 'the newest thing' "$PAGE" || fail "the republished page should carry the change"
wait_until 10 test "$(stamp_field content)" = "$(page_content_id)" \
  || fail "the sidecar must catch up to the page it was published beside"
grep -q '^updated: ' "$TMP_ROOT/watch.log" \
  || fail "the captain should see that something changed: $(cat "$TMP_ROOT/watch.log")"
pass "a real change republishes the page and the sidecar names it"

# The watch page is still display only.
for forbidden in '<form' 'method="post"' 'fetch(' 'XMLHttpRequest' 'http://127.0.0.1' 'http://localhost'; do
  grep -qiF "$forbidden" "$PAGE" \
    && fail "a watched page must not carry '$forbidden' - it is still display only"
done
grep -qiE '>[^<]*(run|start|stop|steer|merge|refresh)[^<]*</button>' "$PAGE" \
  && fail "a watched page must offer no button that acts on anything"
pass "a watched page still has no form, no request back to any server, and no button that acts"

# Ctrl-C: stops cleanly, leaves no temporary file behind, and tells the page it
# is over instead of letting it go on claiming to be watched.
kill -INT "$WATCH_PID"
STOP_CODE=0
wait "$WATCH_PID" || STOP_CODE=$?
trap fm_test_cleanup EXIT
expect_code 0 "$STOP_CODE" "Ctrl-C should stop the watch cleanly"
grep -q '^stopped: ' "$TMP_ROOT/watch.log" \
  || fail "a stopped watch should say so: $(cat "$TMP_ROOT/watch.log")"
LEFTOVERS=$(find "$TMP_ROOT" -maxdepth 1 -name '*.tmp' -print)
[ -z "$LEFTOVERS" ] || fail "a stopped watch left staged files behind: $LEFTOVERS"
grep -q '"watching":false' "$STAMP" \
  || fail "the last word to the page must be that the watch is over: $(cat "$STAMP")"
[ "$(stamp_field content)" = "$(page_content_id)" ] \
  || fail "stopping must not invent a board that was never published: $(cat "$STAMP")"
pass "Ctrl-C stops the watch, leaves nothing staged, and tells the page the watch is over"

# Stopping mid-read is the ordinary case on a real fleet, where one pass is
# seconds of git and terminal reads. It must not wait the read out, must not
# leave the read behind, and must not publish a board assembled from reads that
# were killed - a project reported as missing because the captain pressed Ctrl-C
# would be worse than any stale page.
SLOWBIN=$(fm_fakebin "$TMP_ROOT/slow")
REAL_GIT=$(command -v git)
cat > "$SLOWBIN/git" <<SLOWGIT
#!/usr/bin/env bash
printf '%s\n' "\$\$" >> "$TMP_ROOT/slow-git.pids"
exec sleep 120
SLOWGIT
chmod +x "$SLOWBIN/git"
GOOD_PAGE_ID=$(file_id "$PAGE")
PATH="$SLOWBIN:$PATH" "$DASH" --out "$PAGE" --watch --interval "$WATCH_INTERVAL" \
  --fleet-json "$EMPTY_FLEET" > "$TMP_ROOT/slow.log" 2>&1 &
SLOW_PID=$!
trap 'kill -0 "$SLOW_PID" 2>/dev/null && kill -INT "$SLOW_PID" 2>/dev/null; fm_test_cleanup' EXIT
wait_until 20 test -s "$TMP_ROOT/slow-git.pids" \
  || fail "the watch should have started reading: $(cat "$TMP_ROOT/slow.log")"

STOP_STARTED=$(date +%s)
kill -INT "$SLOW_PID"
SLOW_CODE=0
wait "$SLOW_PID" || SLOW_CODE=$?
STOP_TOOK=$(( $(date +%s) - STOP_STARTED ))
trap fm_test_cleanup EXIT
expect_code 0 "$SLOW_CODE" "a watch stopped mid-read should still stop cleanly"
[ "$STOP_TOOK" -lt 30 ] \
  || fail "stopping waited out the read it should have killed (${STOP_TOOK}s)"
while read -r pid; do
  [ -n "$pid" ] || continue
  kill -0 "$pid" 2>/dev/null && fail "a read outlived the watch that started it: pid $pid"
done < "$TMP_ROOT/slow-git.pids"
[ "$(file_id "$PAGE")" = "$GOOD_PAGE_ID" ] \
  || fail "a watch stopped mid-read must publish nothing, not a board built from killed reads"
grep -q 'the newest thing' "$PAGE" \
  || fail "the last good board should still be what the captain has"
pass "a watch stopped mid-read kills its reads, publishes nothing, and leaves the last good board standing"

# The other half of the same rule: a stopping watch starts no further reads.
# Killing what is in flight is not enough on its own, because the code that was
# waiting on a killed read goes on to ask its next question - and that one would
# be a process nothing is left to stop.
make_repo "$WREPOS/detached" main
git -C "$WREPOS/detached" checkout -q --detach
cat > "$FM_HOME/data/projects.md" <<REG
# Projects

- detached [no-mistakes] - clone kept in place at $WREPOS/detached (added 2026-01-01)
REG
LATEBIN=$(fm_fakebin "$TMP_ROOT/late")
cat > "$LATEBIN/git" <<LATEGIT
#!/usr/bin/env bash
# Hang on the history read, so the stop lands with one read in flight, and
# record the read that only ever happens AFTER that one comes back.
seen_revparse=0 seen_short=0
for arg in "\$@"; do
  [ "\$arg" = rev-parse ] && seen_revparse=1
  [ "\$arg" = --short ] && seen_short=1
  if [ "\$arg" = log ]; then
    printf '%s\n' "\$\$" >> "$TMP_ROOT/late-hung.pids"
    exec sleep 120
  fi
done
if [ "\$seen_revparse" = 1 ] && [ "\$seen_short" = 1 ]; then
  printf 'started\n' >> "$TMP_ROOT/late-reads"
fi
exec $REAL_GIT "\$@"
LATEGIT
chmod +x "$LATEBIN/git"
PATH="$LATEBIN:$PATH" "$DASH" --out "$PAGE" --watch --interval "$WATCH_INTERVAL" \
  --fleet-json "$EMPTY_FLEET" > "$TMP_ROOT/late.log" 2>&1 &
LATE_PID=$!
trap 'kill -0 "$LATE_PID" 2>/dev/null && kill -INT "$LATE_PID" 2>/dev/null; fm_test_cleanup' EXIT
wait_until 20 test -s "$TMP_ROOT/late-hung.pids" \
  || fail "the watch should have reached the read that hangs: $(cat "$TMP_ROOT/late.log")"
[ ! -f "$TMP_ROOT/late-reads" ] \
  || fail "the later read fired before the stop, so this case proves nothing"
kill -INT "$LATE_PID"
LATE_CODE=0
wait "$LATE_PID" || LATE_CODE=$?
trap fm_test_cleanup EXIT
expect_code 0 "$LATE_CODE" "a watch stopped waiting on a read should still stop cleanly"
[ ! -f "$TMP_ROOT/late-reads" ] \
  || fail "a stopping watch started a new read that nothing was left to stop"
pass "a stopping watch starts no further reads, so nothing outlives it by being launched too late"

# Restore the registry the later sections read.
cat > "$FM_HOME/data/projects.md" <<REG
# Projects

- alpha [no-mistakes] - clone kept in place at $REPOS/alpha (added 2026-01-01)
- bravo [no-mistakes] - clone kept in place at $REPOS/bravo (added 2026-01-01)
- charlie [no-mistakes] - clone kept in place at $REPOS/charlie (added 2026-01-01)
- delta [local-only] - clone kept in place at $TMP_ROOT/nowhere (added 2026-01-01)
REG

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
