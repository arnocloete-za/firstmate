#!/usr/bin/env bash
# Behavior tests for delivery mode project-branch: the workspace model where a
# crewmate works in the project's OWN registered directory, on a batch branch the
# captain owns, instead of in a disposable isolated copy
# (docs/architecture.md "The shared-directory model").
#
# Every other mode can rely on isolation for its safety: the worker's copy is
# disposable, so a reset or a teardown costs nothing. This mode deliberately gives
# that up, so each guarantee the isolation used to provide has to exist here as a
# refusal instead. These tests exercise those refusals through the real
# bin/fm-spawn.sh, bin/fm-brief.sh, and bin/fm-teardown.sh:
#
#   1. a project that is not on its OWN default branch is occupied, full stop -
#      the dispatch blocks, names the branch holding it, and creates nothing,
#      without trying to distinguish a worker holding it from the captain
#   2. that default branch is the project's own, never an assumed "master"
#   3. work never happens on the default branch, and dirty-on-default blocks too
#   4. nothing is stashed, reset, or discarded to make room
#   5. a batch branch is never derived from a task id
#   6. the branch is announced before any code changes
#   7. the worker stops at "ready for a pull request" and cannot open one itself
#   8. cleanup leaves the captain's directory, branch, and commits alone
#
# Every spawn case here stops before any endpoint exists: the dispatch guards run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases meant to get past them, so no window is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-branch)

# A home plus a real project clone with a real origin, so the branch resolution
# under test reads a genuine default branch rather than a stub. Echoes
# "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<default-branch>]
  local name=$1 default=${2:-main} home projects fakebin origin proj
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  origin="$TMP_ROOT/$name/origin.git"
  proj="$projects/proj"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects" "$fakebin"
  # A tmux that refuses, so a spawn that clears every dispatch guard still creates
  # nothing. FM_PB_TMUX_OK=1 swaps in a silently succeeding one for the teardown
  # cases, which have to get past the endpoint kill to reach the workspace logic.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${FM_PB_TMUX_OK:-0}" = 1 ] && exit 0
exit 1
SH
  # treehouse must never be asked to return anything in this model; if it is, the
  # test should see it rather than have it silently succeed.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
echo "treehouse called with: $*" >&2
exit 0
SH
  # No PR is associated with any branch, keeping the landed-work reads hermetic.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
esac
exit 1
SH
  # No process holds anything open. The cwd scan is a separate successful empty
  # query, and a plain not-found exit for everything else.
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/gh-axi" "$fakebin/lsof"
  touch "$home/state/.last-watcher-beat"

  # A real origin with a real symbolic HEAD, so the default branch under test is
  # resolved the way it is in a registered project rather than guessed.
  git init --quiet --bare --initial-branch="$default" "$origin"
  git init --quiet --initial-branch="$default" "$proj"
  git -C "$proj" config user.email crew@example.com
  git -C "$proj" config user.name crew
  printf 'v1\n' > "$proj/VERSION"
  git -C "$proj" add VERSION
  git -C "$proj" commit --quiet -m "initial"
  git -C "$proj" remote add origin "$origin"
  git -C "$proj" push --quiet -u origin "$default"
  git -C "$proj" remote set-head origin "$default"

  printf '%s\n' "$home|$proj|$fakebin"
}

# A filled brief recording the delivery contract line the spawn checks itself
# against. Mode and branch are written exactly as fm-dod-lib.sh renders them.
write_brief() {  # <home> <id> <mode> [<branch>]
  local home=$1 id=$2 mode=$3 branch=${4:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise the project-branch workspace.\n\n## Firstmate spec\nVerify the shared-directory refusals.\n\n# Definition of done\n'
    if [ -n "$branch" ]; then
      printf 'Delivery contract: mode=%s branch=%s\n' "$mode" "$branch"
    else
      printf 'Delivery contract: mode=%s\n' "$mode"
    fi
  } > "$home/data/$id/brief.md"
}

# Task metadata standing in for a task firstmate has not torn down yet. Presence
# is what makes a directory occupied, so this is exactly the state a second
# dispatch has to refuse against.
record_task() {  # <home> <id> <worktree> <project> [<extra-line>...]
  local home=$1 id=$2 wt=$3 proj=$4
  shift 4
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$proj"
    printf 'harness=claude\nkind=ship\nmode=project-branch\nyolo=off\nbackend=tmux\n'
    printf 'spawn_gen=project-branch-test-%s\n' "$id"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$home/state/$id.meta"
}

# A scaffolded brief still carries {TASK}/{FIRSTMATE_SPEC}, which the spawn refuses
# before any delivery check. Fill them the way firstmate does so a test that is
# about a later refusal actually reaches it.
fill_brief_subsections() {  # <file>
  local file=$1 content
  content=$(cat "$file")
  content=${content//'{TASK}'/Exercise the project-branch workspace.}
  content=${content//'{FIRSTMATE_SPEC}'/Verify the shared-directory refusals.}
  printf '%s\n' "$content" > "$file"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_brief() {  # <home> <brief-args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    "$BRIEF" "$@" 2>&1
}

run_teardown() {  # <home> <fakebin> <teardown-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEARDOWN_NO_GUARD=1 FM_PB_TMUX_OK=1 PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

# The captain's own ruling on concurrency: "one piece of work at a time per project
# is fine". That makes the refusal the feature, so it has to name the task holding
# the directory (firstmate has to ask him about a specific piece of work), and it
# must not queue, steal, or disturb that task's state.
test_second_dispatch_into_an_occupied_directory_refuses() {
  local rec home proj fakebin out status before_head before_status
  rec=$(make_home occupied)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  git -C "$proj" checkout --quiet -b batch/autumn
  printf 'first worker in progress\n' > "$proj/first.txt"

  record_task "$home" holder-a1 "$proj" "$proj" workspace=project branch=batch/autumn
  before_head=$(git -C "$proj" rev-parse HEAD)
  before_status=$(git -C "$proj" status --porcelain)

  write_brief "$home" second-a2 project-branch batch/autumn
  out=$(run_spawn "$home" "$fakebin" second-a2 "$proj" claude \
    --mode project-branch --branch batch/autumn --yolo off)
  status=$?

  [ "$status" -ne 0 ] || fail "a second dispatch into an occupied project directory should exit non-zero"
  assert_contains "$out" "already held by holder-a1" \
    "the refusal did not name the task holding the directory"
  assert_absent "$home/state/second-a2.meta" \
    "the refused second dispatch wrote task metadata"
  assert_present "$home/state/holder-a1.meta" \
    "the refused second dispatch removed the holding task's record"
  [ "$(git -C "$proj" rev-parse HEAD)" = "$before_head" ] \
    || fail "the refused second dispatch moved the project directory's HEAD"
  [ "$(git -C "$proj" status --porcelain)" = "$before_status" ] \
    || fail "the refused second dispatch disturbed the first worker's uncommitted changes"
  [ -f "$proj/first.txt" ] || fail "the refused second dispatch removed the first worker's file"
  pass "fm-spawn: a second project-branch dispatch refuses, names the holder, and steals nothing"
}

# The captain's loop is branch, finish, merge to the default branch, branch again.
# So a project only becomes dispatchable again once it is back on its default
# branch: releasing the task record alone is not enough, because the branch is the
# authoritative signal.
test_a_project_back_on_its_default_branch_dispatches_again() {
  local rec home proj fakebin out status
  rec=$(make_home released)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  git -C "$proj" checkout --quiet -b batch/spring
  record_task "$home" holder-b1 "$proj" "$proj" workspace=project branch=batch/spring

  write_brief "$home" second-b2 project-branch batch/spring
  out=$(run_spawn "$home" "$fakebin" second-b2 "$proj" claude \
    --mode project-branch --branch batch/spring --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the occupied case should still refuse before the project is released"
  assert_contains "$out" "OCCUPIED" "occupancy refusal was not reported as occupancy"

  # Retiring the task record alone leaves the project on the batch branch, which
  # is still occupied as far as the gate is concerned.
  rm -f "$home/state/holder-b1.meta"
  out=$(run_spawn "$home" "$fakebin" second-b2 "$proj" claude \
    --mode project-branch --branch batch/spring --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a project still on a batch branch should stay blocked after the record is gone"
  assert_contains "$out" "OCCUPIED" \
    "a project left on its batch branch was not reported as occupied"

  # Back on the default branch, as it is after he merges: dispatch proceeds past
  # the occupancy gate (the fake tmux stops it later, so nothing is created).
  git -C "$proj" checkout --quiet main
  out=$(run_spawn "$home" "$fakebin" second-b2 "$proj" claude \
    --mode project-branch --branch batch/spring --yolo off)
  assert_not_contains "$out" "OCCUPIED" \
    "a project back on its default branch was still reported as occupied"
  pass "fm-spawn: a project blocks until it is back on its own default branch"
}

# The heart of the captain's ruling: the gate is the project's git state, with no
# attempt to tell a busy worker from a busy captain. With NO task record at all -
# the case firstmate's own bookkeeping would miss - a project sitting on a branch
# must still block, and must name that branch so he is told what holds it.
test_off_default_blocks_with_no_task_record_at_all() {
  local rec home proj fakebin out status head_before
  rec=$(make_home captains_own)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  # The captain's own branch and his own uncommitted work on it. No task record
  # exists, so only the git-state gate can catch this.
  git -C "$proj" checkout --quiet -b my/experiment
  printf 'captain thinking out loud\n' > "$proj/notes.txt"
  head_before=$(git -C "$proj" rev-parse HEAD)

  write_brief "$home" newwork-k1 project-branch batch/unrelated
  out=$(run_spawn "$home" "$fakebin" newwork-k1 "$proj" claude \
    --mode project-branch --branch batch/unrelated --yolo off)
  status=$?

  [ "$status" -ne 0 ] || fail "a project on the captain's own branch should block the dispatch"
  assert_contains "$out" "OCCUPIED" "the block was not reported as occupancy"
  assert_contains "$out" "my/experiment" "the block did not name the branch holding the project"
  assert_contains "$out" "Nothing was created or changed" \
    "the block did not state that nothing was created"
  assert_absent "$home/state/newwork-k1.meta" "the blocked dispatch wrote task metadata"
  [ "$(git -C "$proj" rev-parse --abbrev-ref HEAD)" = "my/experiment" ] \
    || fail "the blocked dispatch moved the captain off his own branch"
  [ "$(git -C "$proj" rev-parse HEAD)" = "$head_before" ] \
    || fail "the blocked dispatch moved the captain's HEAD"
  [ -f "$proj/notes.txt" ] || fail "the blocked dispatch removed the captain's uncommitted file"
  git -C "$proj" rev-parse --verify --quiet refs/heads/batch/unrelated >/dev/null \
    && fail "the blocked dispatch created the batch branch anyway"
  pass "fm-spawn: a project off its default branch blocks even with no task record, naming the branch"
}

# The default branch is the project's OWN. A project whose default is develop is
# dispatchable while it sits on develop, and a project sitting on master while its
# default is develop must block - the exact case an assumed "master" would get
# backwards.
test_the_default_branch_is_the_projects_own() {
  local rec home proj fakebin out status
  rec=$(make_home nonmaster develop)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  [ "$(git -C "$proj" rev-parse --abbrev-ref HEAD)" = "develop" ] \
    || fail "fixture did not put the project on its develop default branch"

  # On its own default branch: the occupancy gate lets this through.
  write_brief "$home" nonmaster-l1 project-branch batch/from-develop
  out=$(run_spawn "$home" "$fakebin" nonmaster-l1 "$proj" claude \
    --mode project-branch --branch batch/from-develop --yolo off)
  assert_not_contains "$out" "OCCUPIED" \
    "a project on its own develop default branch was reported as occupied"

  # develop is this project's default branch, so naming it as the batch branch is
  # refused exactly as naming main would be elsewhere.
  write_brief "$home" nonmaster-l2 project-branch develop
  out=$(run_spawn "$home" "$fakebin" nonmaster-l2 "$proj" claude \
    --mode project-branch --branch develop --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "naming develop, this project's default branch, should exit non-zero"
  assert_contains "$out" "work never happens on the default branch" \
    "the project's own default branch was not refused as such"

  # A master branch is NOT this project's default, so sitting on it is occupancy.
  git -C "$proj" checkout --quiet -b master
  out=$(run_spawn "$home" "$fakebin" nonmaster-l1 "$proj" claude \
    --mode project-branch --branch batch/from-develop --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a develop-default project sitting on master should block"
  assert_contains "$out" "OCCUPIED" "master was treated as a default branch rather than occupancy"
  assert_contains "$out" "develop" "the block did not name the project's real default branch"
  pass "fm-spawn: occupancy is judged against the project's own default branch, not an assumed master"
}

# Work never happens on the default branch, and the batch branch is always named
# explicitly. Two shapes have to refuse: the default branch named AS the batch
# branch, and no batch branch named at all.
test_the_default_branch_is_refused() {
  local rec home proj fakebin out status
  rec=$(make_home default_branch)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" onmain-c1 project-branch main
  out=$(run_spawn "$home" "$fakebin" onmain-c1 "$proj" claude \
    --mode project-branch --branch main --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "naming the default branch as the batch branch should exit non-zero"
  assert_contains "$out" "work never happens on the default branch" \
    "naming the default branch was not refused as such"
  assert_absent "$home/state/onmain-c1.meta" "the refused default-branch spawn wrote task metadata"

  # No batch branch named at all: deriving one - from the task id or from whatever
  # the directory happens to be on - is exactly what this mode must not do.
  write_brief "$home" nobranch-c2 project-branch
  out=$(run_spawn "$home" "$fakebin" nobranch-c2 "$proj" claude \
    --mode project-branch --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a project-branch spawn with no --branch should exit non-zero"
  assert_contains "$out" "requires --branch" "the missing batch branch was not refused"
  assert_absent "$home/state/nobranch-c2.meta" "the refused branchless spawn wrote task metadata"
  pass "fm-spawn: the default branch is refused, and the batch branch is never implicit"
}

# Uncommitted changes on the DEFAULT branch are a deliberate refusal, separate
# from occupancy: `checkout -b` would carry them onto the batch branch and into
# the PR the captain later reviews, and stashing them aside is what this model may
# never do. So it blocks, says so as its own condition, and leaves them alone.
test_dirty_on_the_default_branch_blocks_and_keeps_the_changes() {
  local rec home proj fakebin out status
  rec=$(make_home dirty_default)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  printf 'captain mid-edit\n' > "$proj/VERSION"
  printf 'scratch\n' > "$proj/untracked.txt"

  write_brief "$home" dirty-d1 project-branch batch/fresh
  out=$(run_spawn "$home" "$fakebin" dirty-d1 "$proj" claude \
    --mode project-branch --branch batch/fresh --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a dirty default branch should refuse rather than carry changes across"
  assert_contains "$out" "uncommitted changes" "the dirty-tree refusal did not name the changes"
  assert_contains "$out" "Nothing here stashes, resets, or discards" \
    "the dirty-tree refusal did not state that nothing is discarded"
  [ "$(cat "$proj/VERSION")" = "captain mid-edit" ] \
    || fail "the refused spawn discarded the captain's uncommitted change"
  [ -f "$proj/untracked.txt" ] || fail "the refused spawn removed the captain's untracked file"
  git -C "$proj" rev-parse --verify --quiet refs/heads/batch/fresh >/dev/null \
    && fail "the refused spawn created the batch branch anyway"
  assert_absent "$home/state/dirty-d1.meta" "the refused dirty-tree spawn wrote task metadata"

  # Clean again: the same dispatch proceeds past the gate, proving the refusal was
  # the dirty tree and not the branch name.
  git -C "$proj" checkout --quiet -- VERSION
  rm -f "$proj/untracked.txt"
  out=$(run_spawn "$home" "$fakebin" dirty-d1 "$proj" claude \
    --mode project-branch --branch batch/fresh --yolo off)
  assert_not_contains "$out" "uncommitted changes" \
    "a clean default branch was still refused for uncommitted changes"
  pass "fm-spawn: uncommitted work on the default branch blocks and is never stashed or discarded"
}

# A batch branch belongs to a batch of work, not to one task, so the tools must
# never accept a task id as a stand-in for it: the brief requires it explicitly,
# and a brief and spawn that disagree refuse rather than launching a worker onto a
# branch its own instructions do not name.
test_the_batch_branch_is_never_derived_from_the_task_id() {
  local rec home proj fakebin out status brief_body
  rec=$(make_home batch_branch)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  out=$(run_brief "$home" project-branch-e1 proj --mode project-branch)
  status=$?
  [ "$status" -ne 0 ] || fail "a project-branch brief with no --branch should exit non-zero"
  assert_contains "$out" "requires --branch" "the brief did not refuse a missing batch branch"

  out=$(run_brief "$home" project-branch-e1 proj --mode project-branch --branch batch/winter)
  status=$?
  [ "$status" -eq 0 ] || fail "a complete project-branch brief should scaffold: $out"
  brief_body=$(cat "$home/data/project-branch-e1/brief.md")
  assert_contains "$brief_body" "Delivery contract: mode=project-branch branch=batch/winter" \
    "the scaffolded brief did not record the batch branch machine-readably"
  assert_not_contains "$brief_body" "fm/project-branch-e1" \
    "the project-branch brief still told the worker to use a task-id branch"

  # The brief tells the worker which branch it may touch, so dispatching a
  # different one would hand it instructions for a branch it is not on.
  fill_brief_subsections "$home/data/project-branch-e1/brief.md"
  out=$(run_spawn "$home" "$fakebin" project-branch-e1 "$proj" claude \
    --mode project-branch --branch batch/other --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn batch-branch mismatch should exit non-zero"
  assert_contains "$out" "branch mismatch for project-branch-e1" \
    "the branch mismatch refusal did not name the task"
  assert_absent "$home/state/project-branch-e1.meta" \
    "the refused mismatched spawn wrote task metadata"
  pass "fm-brief/fm-spawn: the batch branch is explicit and never derived from the task id"
}

# --branch is meaningless without the shared-directory model, so accepting it
# elsewhere would silently imply a workspace the task does not get.
test_branch_is_refused_for_isolated_modes() {
  local rec home proj fakebin out status
  rec=$(make_home isolated)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" isolated-f1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" isolated-f1 "$proj" claude \
    --mode no-mistakes --branch batch/nope --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "--branch on an isolated mode should exit non-zero"
  assert_contains "$out" "applies only to --mode project-branch" \
    "--branch was not refused for an isolated mode"

  out=$(run_brief "$home" isolated-f1 proj --mode direct-PR --branch batch/nope)
  status=$?
  [ "$status" -ne 0 ] || fail "--branch on an isolated-mode brief should exit non-zero"
  assert_contains "$out" "applies only to --mode project-branch" \
    "the brief did not refuse --branch for an isolated mode"
  pass "fm-spawn/fm-brief: --branch is refused for every isolated mode"
}

# The generated brief is the worker's whole contract, so the two-stage captain
# gate and the never-destroy rules have to be IN it: a worker that opens the PR
# before his word, or clears his files to make room, is the failure this mode
# exists to prevent.
test_the_generated_brief_carries_the_shared_directory_contract() {
  local rec home proj fakebin body status
  rec=$(make_home brief_contract)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  run_brief "$home" contract-g1 proj --mode project-branch --branch batch/summer >/dev/null
  status=$?
  [ "$status" -eq 0 ] || fail "scaffolding the project-branch brief failed"
  body=$(cat "$home/data/contract-g1/brief.md")

  assert_contains "$body" "not a disposable one" \
    "the brief did not tell the worker the directory is the captain's own"
  assert_contains "$body" "git rev-parse --abbrev-ref HEAD" \
    "the brief did not make the worker verify its branch"
  assert_contains "$body" "Never destroy the captain's work" \
    "the brief omitted the never-destroy contract that replaces the isolation"
  assert_contains "$body" "stop-and-report" \
    "the brief did not make foreign uncommitted changes a stop-and-report"
  assert_contains "$body" "Detect this project's own versioning mechanism" \
    "the brief let the worker assume a versioning scheme"
  assert_contains "$body" "needs-decision: version bump mechanism unclear" \
    "the brief had no escalation for an undetectable version scheme"
  assert_contains "$body" "never merge" \
    "the brief did not reserve the merge for the captain"

  # The isolated assertion would be actively wrong here: this worker IS in the
  # project's own directory, so a brief telling it to stop unless it is elsewhere
  # would stop every such task.
  assert_not_contains "$body" "disposable task worktree" \
    "the project-branch brief kept the isolated-copy assertion"
  pass "fm-brief: the project-branch brief carries the two-stage gate and never-destroy contract"
}

# The captain has to be told, by name, that his project branched: it is how he
# knows the project is occupied and by what. So the announcement is a required
# first status line rather than advice, and the brief names the exact line.
test_the_brief_requires_announcing_the_branch_first() {
  local rec home proj fakebin body
  rec=$(make_home announce)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  run_brief "$home" announce-m1 proj --mode project-branch --branch batch/announced >/dev/null \
    || fail "scaffolding the project-branch brief failed"
  body=$(cat "$home/data/announce-m1/brief.md")

  assert_contains "$body" "working: branched batch/announced" \
    "the brief did not give the worker the exact branch announcement line"
  assert_contains "$body" "FIRST status line" \
    "the brief did not make the announcement the worker's first status line"
  assert_contains "$body" "before you change any code" \
    "the brief let the worker change code before announcing the branch"

  pass "fm-brief: the branch is announced by name before any code changes"
}

# Ruling: "the crewmate must always tell me when it's done and it is ready For a
# pull request, but it should not go ahead". A green pipeline is not authority to
# open a PR, so the brief must skip the pipeline's own push/PR/CI steps, must say
# the skip is not the worker's to drop, and its ready line must name the branch.
test_the_brief_stops_before_the_pull_request() {
  local rec home proj fakebin body
  rec=$(make_home stop_before_pr)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  run_brief "$home" stop-n1 proj --mode project-branch --branch batch/held >/dev/null \
    || fail "scaffolding the project-branch brief failed"
  body=$(cat "$home/data/stop-n1/brief.md")

  # The pipeline still runs and still has to pass - it just cannot reach a PR.
  assert_contains "$body" "--skip push,pr,ci" \
    "the brief did not skip the pipeline's own push, PR, and CI steps"
  assert_contains "$body" "is REQUIRED and is not yours to drop" \
    "the brief let the worker drop the skip that holds the PR back"
  assert_contains "$body" "A passing pipeline is not authority to create a PR here" \
    "the brief treated a green pipeline as authority to open a PR"
  assert_contains "$body" "Never open the pull request yourself, and never push" \
    "the brief did not forbid opening the PR and pushing"

  # Finishing silently is the other half of the ruling: the ready line has to name
  # the branch, because the reminder is the point.
  assert_contains "$body" "done: ready for a pull request on branch batch/held" \
    "the brief's ready signal did not name the branch"

  # And the PR run exists, but only behind the captain's relayed word.
  assert_contains "$body" "only if firstmate relays the captain's word to open the PR" \
    "the brief had no captain-gated stage for opening the PR"
  assert_contains "$body" "Do nothing in this stage unless that instruction actually arrives" \
    "the brief did not hold the PR stage until the instruction arrives"
  pass "fm-brief: work ends at ready-for-a-pull-request and cannot open one itself"
}

# Cleanup is where the isolated model destroys things: it hard-resets and returns
# the copy. Here there is nothing to return and nothing to reset, so a completed
# task's directory, branch, and commits must survive teardown untouched.
test_teardown_leaves_the_captains_directory_intact() {
  local rec home proj fakebin out head_before
  rec=$(make_home teardown_intact)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  git -C "$proj" checkout --quiet -b batch/landed
  printf 'v2\n' > "$proj/VERSION"
  git -C "$proj" commit --quiet -am "worker's committed batch work"
  head_before=$(git -C "$proj" rev-parse HEAD)

  record_task "$home" done-h1 "$proj" "$proj" workspace=project branch=batch/landed
  printf 'done: ready on branch batch/landed\n' > "$home/state/done-h1.status"

  out=$(run_teardown "$home" "$fakebin" done-h1)

  # Prove the cleanup actually ran to completion rather than stopping early for an
  # unrelated reason, which would make every assertion below vacuously true.
  assert_absent "$home/state/done-h1.meta" \
    "teardown did not complete - the task record survived: $out"
  assert_not_contains "$out" "treehouse called with" \
    "teardown tried to return a pool slot for a directory it never allocated"
  assert_not_contains "$out" "REFUSED" "teardown refused a clean project-branch cleanup: $out"

  [ -d "$proj" ] || fail "teardown removed the captain's project directory: $out"
  [ "$(git -C "$proj" rev-parse --abbrev-ref HEAD)" = "batch/landed" ] \
    || fail "teardown moved the project directory off its batch branch: $out"
  [ "$(git -C "$proj" rev-parse HEAD)" = "$head_before" ] \
    || fail "teardown changed the batch branch's HEAD: $out"
  [ "$(cat "$proj/VERSION")" = "v2" ] \
    || fail "teardown reverted the committed batch work: $out"
  git -C "$proj" rev-parse --verify --quiet refs/heads/batch/landed >/dev/null \
    || fail "teardown deleted the captain's batch branch: $out"
  pass "fm-teardown: a project-branch cleanup leaves the directory, branch, and commits intact"
}

# Uncommitted changes are the one gate that does apply here: they mean either an
# interrupted edit or the captain working in that directory right now, so cleanup
# refuses instead of killing the worker under them - and still discards nothing
# when it is forced to release the task anyway.
test_teardown_refuses_uncommitted_changes_and_never_discards_them() {
  local rec home proj fakebin out status
  rec=$(make_home teardown_dirty)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  git -C "$proj" checkout --quiet -b batch/dirty
  printf 'captain is editing this right now\n' > "$proj/VERSION"

  record_task "$home" dirty-i1 "$proj" "$proj" workspace=project branch=batch/dirty

  out=$(run_teardown "$home" "$fakebin" dirty-i1)
  status=$?
  [ "$status" -ne 0 ] || fail "teardown should refuse a project directory with uncommitted changes"
  assert_contains "$out" "REFUSED" "the dirty-directory teardown did not refuse"
  assert_contains "$out" "uncommitted changes" "the refusal did not name the uncommitted changes"
  [ "$(cat "$proj/VERSION")" = "captain is editing this right now" ] \
    || fail "the refused teardown discarded the uncommitted change"
  assert_present "$home/state/dirty-i1.meta" "the refused teardown removed the task record"

  # --force releases the task; it must still not reach into the directory.
  out=$(run_teardown "$home" "$fakebin" dirty-i1 --force)
  [ "$(cat "$proj/VERSION")" = "captain is editing this right now" ] \
    || fail "a forced teardown discarded the captain's uncommitted change: $out"
  [ -d "$proj" ] || fail "a forced teardown removed the captain's project directory: $out"
  [ "$(git -C "$proj" rev-parse --abbrev-ref HEAD)" = "batch/dirty" ] \
    || fail "a forced teardown moved the directory off its branch: $out"
  pass "fm-teardown: uncommitted changes refuse cleanup, and even --force discards nothing"
}

# The Orca runtime's whole model is a worktree it allocates and owns, which is the
# one thing this mode does without, so the combination has to be refused rather
# than resolved into one of the two.
test_orca_is_refused_for_the_project_workspace() {
  local rec home proj fakebin out status
  rec=$(make_home orca)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  git -C "$proj" checkout --quiet -b batch/orca
  write_brief "$home" orca-j1 project-branch batch/orca
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=orca PATH="$fakebin:$PATH" \
    "$SPAWN" orca-j1 "$proj" claude --backend orca \
      --mode project-branch --branch batch/orca --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "backend=orca with mode=project-branch should exit non-zero"
  assert_contains "$out" "orca" "the refusal did not name the runtime"
  assert_absent "$home/state/orca-j1.meta" "the refused orca spawn wrote task metadata"
  pass "fm-spawn: the orca runtime is refused for the project workspace"
}

test_second_dispatch_into_an_occupied_directory_refuses
test_a_project_back_on_its_default_branch_dispatches_again
test_off_default_blocks_with_no_task_record_at_all
test_the_default_branch_is_the_projects_own
test_the_default_branch_is_refused
test_dirty_on_the_default_branch_blocks_and_keeps_the_changes
test_the_batch_branch_is_never_derived_from_the_task_id
test_branch_is_refused_for_isolated_modes
test_the_generated_brief_carries_the_shared_directory_contract
test_the_brief_requires_announcing_the_branch_first
test_the_brief_stops_before_the_pull_request
test_teardown_leaves_the_captains_directory_intact
test_teardown_refuses_uncommitted_changes_and_never_discards_them
test_orca_is_refused_for_the_project_workspace
echo "# all fm-project-branch tests passed"
