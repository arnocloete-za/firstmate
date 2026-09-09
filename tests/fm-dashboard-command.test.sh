#!/usr/bin/env bash
# tests/fm-dashboard-command.test.sh - the captain's `dashboard` command
# (bin/fm-dashboard-open.sh) and how it gets onto his PATH
# (bin/fm-install-dashboard-command.sh).
#
# The board itself is pinned by tests/fm-dashboard.test.sh; nothing here
# re-asserts what the page says. What is asserted here is the half the captain
# lost a morning to: whether the command can tell that a refresh loop is
# actually running.
#
# The first version of the command answered that by pattern-matching the process
# list, and a CREWMATE matched it - a crewmate's launch brief quotes this whole
# command - so it reported a loop that did not exist and left him reading a
# board nothing was refreshing. Every liveness case below therefore runs with a
# DECOY process alive whose command line contains that pattern, and each one
# first proves the decoy would satisfy a pattern match before asserting the
# command's own verdict. Without that divergence the cases would pass vacuously.
#
# Everything is asserted through the two commands' own output, exit status, and
# observable effect on the world - the loop that does or does not get started,
# the link that does or does not get installed - never over their source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OPEN="$ROOT/bin/fm-dashboard-open.sh"
INSTALL="$ROOT/bin/fm-install-dashboard-command.sh"
TMP_ROOT=$(fm_test_tmproot fm-dashboard-command)

# Decoys are started inside a command substitution, so their pids cannot come
# back through a shell array - they are recorded in a file the real shell reads,
# the same reason tests/lib.sh registers its temp roots that way.
DECOY_PIDS="$TMP_ROOT/decoy-pids"
cleanup_decoys() {
  local pid
  [ -f "$DECOY_PIDS" ] || return 0
  while read -r pid; do
    [ -n "$pid" ] || continue
    kill "$pid" 2> /dev/null || true
  done < "$DECOY_PIDS"
}
stop_all_loops() {
  local record pid
  for record in "$TMP_ROOT"/*/home/.dashboard/*.watch.pid; do
    [ -e "$record" ] || continue
    pid=$(cut -f1 "$record")
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    kill "$pid" 2> /dev/null || true
  done
}
trap 'stop_all_loops; cleanup_decoys; fm_test_cleanup' EXIT
trap 'stop_all_loops; cleanup_decoys; fm_test_cleanup; exit 130' INT
trap 'stop_all_loops; cleanup_decoys; fm_test_cleanup; exit 143' TERM

# --- fixtures --------------------------------------------------------------
#
# A world is one throwaway firstmate home plus a throwaway code root whose
# bin/fm-dashboard.mjs is a stub standing in for the real generator. The stub
# reproduces exactly the generator's contract that this command depends on: it
# prints `dashboard:` and `open:` lines, honors --open, and under --watch runs
# until it is stopped. It also records every watch it starts, which is how these
# cases count loops without searching the process table themselves.
WORLD=
HOME_DIR=
GEN=
STARTS=
OPENS=
make_world() { # <name>
  local name=$1
  WORLD="$TMP_ROOT/$name"
  HOME_DIR="$WORLD/home"
  GEN="$WORLD/root/bin/fm-dashboard.mjs"
  STARTS="$HOME_DIR/.dashboard/watch-starts.log"
  OPENS="$HOME_DIR/.dashboard/opens.log"
  mkdir -p "$WORLD/root/bin" "$HOME_DIR/.dashboard"
  cat > "$GEN" << 'STUB'
#!/usr/bin/env bash
set -u
group=work
watch=0
open=0
interval=
while [ $# -gt 0 ]; do
  case "$1" in
    --group) shift; group=$1 ;;
    --interval) shift; interval=$1 ;;
    --watch) watch=1 ;;
    --open) open=1 ;;
  esac
  shift
done
dir="$FM_HOME/.dashboard"
mkdir -p "$dir"
page="$dir/$group.html"
if [ "$watch" -eq 1 ]; then
  if [ -n "${STUB_REFUSE_WATCH:-}" ]; then
    printf 'fm-dashboard: the interval must be at least 5 seconds\n' >&2
    exit 1
  fi
  printf '%s %s\n' "$group" "$interval" >> "$dir/watch-starts.log"
fi
printf 'generated %s\n' "$(date +%s%N)" > "$page"
printf 'dashboard: %s\n' "$page"
printf 'open: file://%s\n' "$page"
[ "$open" -eq 1 ] && printf '%s\n' "$group" >> "$dir/opens.log"
if [ "$watch" -eq 1 ]; then
  while :; do sleep 1; done
fi
STUB
  chmod +x "$GEN"
}

dash() { # <args...>
  FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$HOME_DIR" "$OPEN" "$@"
}

record_of() { # <board>
  printf '%s\n' "$HOME_DIR/.dashboard/$1.watch.pid"
}
recorded_pid() { # <board>
  cut -f1 "$(record_of "$1")"
}
loops_started() {
  [ -s "$STARTS" ] || {
    printf '0\n'
    return
  }
  awk 'END { print NR }' "$STARTS"
}

# A process whose command line contains everything a pattern match would look
# for, and which is not a refresh loop. The whole pattern sits inside ONE
# argument, exactly as it does in a crewmate's launch brief.
start_decoy() { # -> prints the pid
  local pid
  cat > "$WORLD/decoy.sh" << 'DECOY'
#!/usr/bin/env bash
while :; do sleep 1; done
DECOY
  chmod +x "$WORLD/decoy.sh"
  # stdout and stderr detached: a background process holding this function's
  # own output pipe would make the command substitution that calls it wait.
  "$WORLD/decoy.sh" "run $GEN --group work --watch --interval 30, then dashboard --stop" \
    > /dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$DECOY_PIDS"
  printf '%s\n' "$pid"
}

# A real refresh loop for this board that the command did not start: what the
# captain gets by running the generator himself, or what an older launcher left
# behind. Started WITHOUT --group on purpose, because that is the generator's
# own default board and the real one found on his machine looked exactly so.
start_loose_loop() { # <extra-args...> -> prints the pid
  local pid
  FM_HOME="$HOME_DIR" "$GEN" --watch "$@" > /dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >> "$DECOY_PIDS"
  # Wait for it to be a real running loop before anything reads for it.
  local tries=0
  while [ ! -s "$STARTS" ] && [ "$tries" -lt 50 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  printf '%s\n' "$pid"
}

# The check the broken version made: search every process's command line for
# the pattern. Asserting this MATCHES the decoy is what keeps each liveness case
# from passing for the wrong reason.
pattern_match_finds() { # <pid>
  local pattern="$GEN --group work --watch"
  # Grepping ps output is the defect under test, deliberately reproduced here.
  # shellcheck disable=SC2009
  ps -A -o pid= -o args= 2> /dev/null \
    | grep -F -- "$pattern" \
    | awk '{ print $1 }' \
    | grep -qx -- "$1"
}

# --- cases -----------------------------------------------------------------

test_a_loop_this_command_did_not_start_is_reported_not_joined() {
  local loose out
  make_world competing
  loose=$(start_loose_loop)

  out=$(dash --status)
  assert_contains "$out" "did not start it (pid $loose)" "--status must name the loop it cannot manage"
  assert_contains "$out" "kill $loose" "--status must leave the ending of it to him"

  out=$(dash)
  assert_contains "$out" "did not start it (pid $loose)" "a run must report the loop already refreshing this board"
  assert_contains "$out" "nothing new was started" "a run must not add a second loop to the same page"
  assert_absent "$(record_of work)" "no record should be written for a loop this command did not start"
  [ "$(loops_started)" = 1 ] || fail "the command started a competing loop: $(loops_started) in all"
  kill -0 "$loose" 2> /dev/null || fail "the command signalled a loop it did not start"

  kill "$loose" 2> /dev/null
  while kill -0 "$loose" 2> /dev/null; do sleep 0.1; done
  out=$(dash)
  assert_contains "$out" "refreshing every 30s" "once his own loop is gone the command must start a managed one"
  pass "dashboard: a refresh loop it did not start is reported and handed back to him, never joined"
}

test_a_process_that_quotes_the_command_is_not_reported_as_competing() {
  local decoy out
  make_world competing-decoy
  decoy=$(start_decoy)
  pattern_match_finds "$decoy" \
    || fail "the decoy does not match the pattern, so this case would prove nothing"

  out=$(dash --status || true)
  assert_not_contains "$out" "did not start it" "a process that only quotes this command is not a refresh loop"
  assert_contains "$out" "nothing is refreshing the work board" "the verdict must still be that nothing refreshes"

  out=$(dash)
  assert_contains "$out" "refreshing every 30s" "the command must start a loop, not stand off for a decoy"
  assert_not_contains "$out" "did not start it" "the decoy must not be reported as a competing loop"
  pass "dashboard: the competing-loop scan reads argv words, so a command line that only quotes this is not one"
}

test_a_loop_writing_another_page_is_not_competing() {
  local other out
  make_world competing-elsewhere
  other=$(start_loose_loop --out "$WORLD/elsewhere.html")
  out=$(dash)
  assert_not_contains "$out" "did not start it" "a loop writing another page is not competing for this board"
  assert_contains "$out" "refreshing every 30s" "the command must still start this board's own loop"
  kill -0 "$other" 2> /dev/null || fail "the other loop was signalled"
  pass "dashboard: a loop writing some other page is not treated as this board's refresh"
}

test_a_loop_for_the_other_board_is_not_competing() {
  local personal out
  make_world competing-other-board
  personal=$(start_loose_loop --group personal)
  out=$(dash)
  assert_not_contains "$out" "did not start it" "the personal board's loop must not count against the work board"
  assert_contains "$out" "refreshing every 30s" "the work board must get its own loop"
  out=$(dash personal --status || true)
  assert_contains "$out" "did not start it (pid $personal)" "the personal board must report its own loose loop"
  pass "dashboard: a loose loop counts only against the board it is actually refreshing"
}

test_stop_says_what_it_could_not_stop() {
  local loose out
  make_world competing-stop
  loose=$(start_loose_loop)
  out=$(dash --stop)
  assert_contains "$out" "nothing was refreshing" "--stop must report on the loop it owns first"
  assert_contains "$out" "did not start it (pid $loose)" "--stop must say what is still running that it cannot stop"
  kill -0 "$loose" 2> /dev/null || fail "--stop signalled a loop this command did not start"
  pass "dashboard: --stop reports the loop it cannot stop rather than leaving him to wonder"
}

test_help_documents_the_whole_command() {
  local out
  make_world help
  out=$(dash --help)
  assert_contains "$out" "dashboard                     the work board" "help must document the work board"
  assert_contains "$out" "dashboard personal" "help must document the personal board"
  assert_contains "$out" "dashboard --stop" "help must document how to stop the refresh"
  assert_contains "$out" "dashboard --status" "help must document the status read"
  assert_contains "$out" "dashboard --interval" "help must document the interval override"
  pass "dashboard: --help prints the whole command surface"
}

test_one_run_opens_the_board_and_leaves_it_refreshing() {
  local out pid
  make_world one-run
  out=$(dash)
  assert_contains "$out" "dashboard: $HOME_DIR/.dashboard/work.html" "the run must hand over the page"
  assert_contains "$out" "open: file://" "the run must hand over the link"
  assert_contains "$out" "refreshing every 30s" "the run must report the loop it started"
  assert_contains "$out" "dashboard --stop" "the run must say how to stop the refresh"
  assert_grep work "$OPENS" "the board must be handed to the desktop opener"
  [ "$(loops_started)" = 1 ] || fail "expected exactly one refresh loop, got $(loops_started)"
  assert_grep 'work 30' "$STARTS" "the interval must be the pinned 30 seconds"

  pid=$(recorded_pid work)
  dash --status > /dev/null || fail "--status did not see the loop the same command just started"
  kill -0 "$pid" 2> /dev/null || fail "the recorded refresh loop is not running"
  pass "dashboard: one run generates the board, opens it, and leaves one refresh loop running"
}

test_running_it_again_reuses_the_loop() {
  local first out second
  make_world reuse
  dash > /dev/null
  first=$(recorded_pid work)

  out=$(dash)
  second=$(recorded_pid work)
  assert_contains "$out" "already refreshing itself (pid $first)" "a second run must report the loop it reused"
  [ "$second" = "$first" ] || fail "a second run replaced the loop ($first -> $second)"
  [ "$(loops_started)" = 1 ] || fail "a second run started another loop: $(loops_started) in all"
  [ "$(awk 'END { print NR }' "$OPENS")" = 2 ] \
    || fail "a second run must still open the board for him"
  pass "dashboard: running it again reuses the loop already refreshing that board"
}

test_a_process_that_merely_quotes_the_command_is_not_a_loop() {
  local decoy out pid
  make_world decoy-no-record
  decoy=$(start_decoy)
  pattern_match_finds "$decoy" \
    || fail "the decoy does not match the pattern, so this case would prove nothing"

  dash --status > /dev/null && fail "--status reported a refresh loop that does not exist"

  out=$(dash)
  assert_contains "$out" "refreshing every 30s" "the command must start a real loop, not adopt the decoy"
  pid=$(recorded_pid work)
  [ "$pid" != "$decoy" ] || fail "the command recorded the decoy as its refresh loop"
  [ "$(loops_started)" = 1 ] || fail "expected one real refresh loop, got $(loops_started)"
  kill -0 "$decoy" 2> /dev/null || fail "the decoy was signalled"
  pass "dashboard: a process that only quotes this command is never mistaken for a refresh loop"
}

test_a_decoy_named_by_an_older_record_is_not_a_loop() {
  local decoy out
  make_world decoy-in-record
  decoy=$(start_decoy)
  pattern_match_finds "$decoy" \
    || fail "the decoy does not match the pattern, so this case would prove nothing"
  # The bare-pid form an older launcher wrote, naming the decoy.
  printf '%s\n' "$decoy" > "$(record_of work)"

  dash --status > /dev/null \
    && fail "--status trusted an older record naming a process that is not a loop"

  out=$(dash --stop)
  assert_contains "$out" "nothing was refreshing the work board" "--stop must not claim to have stopped a stranger"
  kill -0 "$decoy" 2> /dev/null || fail "--stop signalled a process this command never started"
  pass "dashboard: a record naming a process that only quotes this command is not trusted, and never signalled"
}

test_a_record_that_is_a_link_is_not_followed() {
  local out
  make_world linked-record
  # --stop signals whatever the record names, so a record replaced by a link
  # must read as no loop rather than be followed to another file's contents.
  ln -s /etc/hostname "$(record_of work)"
  dash --status > /dev/null && fail "--status followed a record that is a symlink"
  out=$(dash --stop)
  assert_contains "$out" "nothing was refreshing the work board" "--stop must not follow a linked record"
  pass "dashboard: a refresh record replaced by a link reads as no loop"
}

test_a_recycled_pid_is_not_a_loop() {
  local out
  make_world recycled
  # A live pid - this test's own shell - carrying the identity of some other,
  # long-gone process, which is what a recycled pid looks like.
  printf '%s\tlinux-starttime=1 cmdline-hex=00\n' "$$" > "$(record_of work)"

  dash --status > /dev/null \
    && fail "--status trusted a record whose process identity no longer matches"
  out=$(dash --stop)
  assert_contains "$out" "nothing was refreshing the work board" "--stop must not act on a recycled pid"
  kill -0 "$$" 2> /dev/null || fail "--stop signalled the recycled pid"
  pass "dashboard: a recycled pid fails the identity check instead of being stopped"
}

test_a_loop_from_an_older_launcher_is_adopted_not_duplicated() {
  local pid out record
  make_world adopt
  dash > /dev/null
  pid=$(recorded_pid work)
  record=$(record_of work)
  # Exactly what an older launcher left behind: the pid of a real loop, with no
  # identity beside it.
  printf '%s\n' "$pid" > "$record"

  out=$(dash --status)
  assert_contains "$out" "refreshing itself (pid $pid)" "a real loop from an older record must be adopted"
  assert_grep "$(printf '%s\t' "$pid")" "$record" "adoption must record the identity it confirmed"

  out=$(dash)
  assert_contains "$out" "already refreshing itself (pid $pid)" "the adopted loop must be reused"
  [ "$(loops_started)" = 1 ] || fail "the adopted loop was duplicated: $(loops_started) started in all"
  pass "dashboard: a real loop recorded by an older launcher is adopted rather than duplicated"
}

test_the_interval_is_pinned_and_overridable() {
  local out
  make_world interval
  out=$(dash --interval 7)
  assert_contains "$out" "refreshing every 7s" "--interval must reach the loop"
  assert_grep 'work 7' "$STARTS" "the loop must run at the interval asked for"
  dash --stop > /dev/null

  out=$(FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$HOME_DIR" DASHBOARD_INTERVAL=11 "$OPEN")
  assert_contains "$out" "refreshing every 11s" "DASHBOARD_INTERVAL must reach the loop"
  dash --stop > /dev/null

  out=$(FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$HOME_DIR" DASHBOARD_INTERVAL=11 "$OPEN" --interval 13)
  assert_contains "$out" "refreshing every 13s" "--interval must win over DASHBOARD_INTERVAL"
  pass "dashboard: the interval defaults to a pinned 30 and both overrides reach the loop"
}

test_the_two_boards_are_independent() {
  local work_pid personal_pid out
  make_world boards
  dash > /dev/null
  dash personal > /dev/null
  work_pid=$(recorded_pid work)
  personal_pid=$(recorded_pid personal)
  [ "$work_pid" != "$personal_pid" ] || fail "both boards recorded the same refresh loop"
  assert_grep 'personal 30' "$STARTS" "the personal board must get its own loop"

  out=$(dash --stop)
  assert_contains "$out" "stopped refreshing the work board" "--stop must name the board it stopped"
  dash personal --status > /dev/null || fail "stopping the work board also stopped the personal board"
  out=$(dash personal --stop)
  assert_contains "$out" "stopped refreshing the personal board" "the personal board must stop on its own word"
  assert_contains "$(dash personal)" "dashboard personal --stop" "the hint must name the board he is on"
  pass "dashboard: each board keeps its own refresh loop, stopped on its own word"
}

test_stop_and_status_when_nothing_is_running() {
  local out rc
  make_world idle
  out=$(dash --stop)
  assert_contains "$out" "nothing was refreshing the work board" "--stop must say plainly that nothing ran"
  rc=0
  dash --status > /dev/null || rc=$?
  expect_code 1 "$rc" "--status on an idle board"
  # A record left by a loop that is long gone must not survive as a claim.
  printf '999999999\tlinux-starttime=1 cmdline-hex=00\n' > "$(record_of work)"
  dash --stop > /dev/null
  assert_absent "$(record_of work)" "a stale record must be cleared rather than left to be believed"
  pass "dashboard: an idle board reports itself idle and leaves no record behind"
}

test_a_loop_that_will_not_start_is_reported_not_pretended() {
  local out rc
  make_world refuse
  rc=0
  out=$(FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$HOME_DIR" STUB_REFUSE_WATCH=1 "$OPEN" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a refresh loop that never started was reported as success"
  assert_contains "$out" "the refresh loop stopped as soon as it started" "the failure must be stated plainly"
  assert_contains "$out" "at least 5 seconds" "the generator's own refusal must be surfaced"
  assert_absent "$(record_of work)" "a loop that never started must leave no record"
  pass "dashboard: a refresh loop that will not start is reported, with what the board itself said"
}

test_usage_errors_are_loud() {
  local rc
  make_world usage
  rc=0
  dash --nonsense > /dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown argument"
  rc=0
  dash --interval soon > /dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an interval that is not a number"
  assert_absent "$(record_of work)" "a rejected argument must not start anything"
  pass "dashboard: an unknown argument and a non-numeric interval both refuse before anything starts"
}

test_it_works_through_the_symlink_it_is_installed_as() {
  local dir out
  make_world symlinked
  dir="$WORLD/bin"
  mkdir -p "$dir/first"
  # A chain, not a single link: an installed command may sit behind a symlinked
  # directory as well as a symlinked name.
  ln -s "$OPEN" "$dir/first/dashboard"
  ln -s "$dir/first/dashboard" "$dir/dashboard"

  out=$("$dir/dashboard" --help) || fail "the command could not run through a symlink chain"
  assert_contains "$out" "dashboard personal" "help must survive being reached through a link"

  out=$(FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$HOME_DIR" "$dir/dashboard")
  assert_contains "$out" "refreshing every 30s" "the command must work in full through a symlink chain"
  pass "dashboard: it resolves its own repository through the symlink chain it is installed as"
}

# --- how it reaches his PATH -----------------------------------------------

install_in() { # <dir> <args...>
  local dir=$1
  shift
  PATH="$dir:$PATH" "$INSTALL" --dir "$dir" "$@"
}

test_install_puts_the_command_on_path() {
  local dir out rc link
  make_world install
  dir="$WORLD/pathdir"
  rc=0
  out=$(install_in "$dir" --check 2>&1) || rc=$?
  expect_code 5 "$rc" "--check before anything is installed"
  assert_contains "$out" "not installed" "--check must say plainly that nothing is installed"

  rc=0
  out=$(install_in "$dir" 2>&1) || rc=$?
  expect_code 0 "$rc" "installing into a directory that is on PATH"
  assert_contains "$out" "runs this home's board" "a finished install must say so"
  link="$dir/dashboard"
  [ -L "$link" ] || fail "the install must be a link, never a copy"
  [ "$(cd "$(dirname "$link")" && readlink "$(basename "$link")")" = "$OPEN" ] \
    || fail "the link must point at this repository's own command"
  install_in "$dir" --check > /dev/null || fail "--check did not recognize its own install"

  rc=0
  out=$(install_in "$dir" 2>&1) || rc=$?
  expect_code 0 "$rc" "re-installing over its own link"
  pass "dashboard command: installing links this home's command into a directory on PATH"
}

test_install_reports_a_directory_that_is_not_on_path() {
  local dir out rc
  make_world install-offpath
  dir="$WORLD/offpath"
  mkdir -p "$dir"
  rc=0
  out=$("$INSTALL" --dir "$dir" 2>&1) || rc=$?
  expect_code 3 "$rc" "installing into a directory that is not on PATH"
  assert_contains "$out" "is not on your PATH" "an unusable install must not be reported as done"
  assert_contains "$out" "export PATH=\"$dir:\$PATH\"" "it must give him the exact line to add"
  [ -L "$dir/dashboard" ] || fail "the link should still have been installed"
  pass "dashboard command: a directory that is not on PATH is reported, with the line that fixes it"
}

test_install_creates_a_missing_directory() {
  local dir
  make_world install-mkdir
  dir="$WORLD/nowhere/bin"
  "$INSTALL" --dir "$dir" > /dev/null 2>&1
  [ -L "$dir/dashboard" ] || fail "the install must create a directory that does not exist yet"
  pass "dashboard command: a missing install directory is created rather than refused"
}

test_install_refuses_to_replace_what_it_did_not_install() {
  local dir out rc his
  make_world install-refuse
  dir="$WORLD/pathdir"
  mkdir -p "$dir"
  his="$dir/dashboard"
  printf '#!/bin/sh\necho his own script\n' > "$his"
  chmod +x "$his"

  rc=0
  out=$(install_in "$dir" 2>&1) || rc=$?
  expect_code 4 "$rc" "installing over a file it did not install"
  assert_contains "$out" "the one you are using right now" "the refusal must say what it found"
  assert_contains "$out" "--force" "the refusal must name the command that replaces it"
  assert_grep 'his own script' "$his" "the refusal must leave his own file exactly as it was"

  rc=0
  out=$(install_in "$dir" --force 2>&1) || rc=$?
  expect_code 0 "$rc" "replacing it with --force"
  [ -L "$his" ] || fail "--force must replace the file with this home's link"
  pass "dashboard command: it never replaces his own command without being told to"
}

test_install_refuses_another_homes_command() {
  local dir out rc other
  make_world install-other-home
  dir="$WORLD/pathdir"
  other="$WORLD/other-home/bin/fm-dashboard-open.sh"
  mkdir -p "$dir" "$(dirname "$other")"
  printf '#!/bin/sh\n' > "$other"
  chmod +x "$other"
  ln -s "$other" "$dir/dashboard"

  rc=0
  out=$(install_in "$dir" 2>&1) || rc=$?
  expect_code 4 "$rc" "installing over another home's link"
  assert_contains "$out" "another firstmate home's board command" "the refusal must name what it found"
  [ "$(cd "$dir" && readlink dashboard)" = "$other" ] || fail "the other home's link must be left alone"

  rc=0
  out=$(install_in "$dir" --check 2>&1) || rc=$?
  expect_code 4 "$rc" "--check over another home's link"
  assert_contains "$out" "not this home's board command" "--check must report whose command is installed"
  pass "dashboard command: another home's dashboard is reported, never silently taken over"
}

test_install_reports_a_link_that_leads_nowhere() {
  local dir out rc
  make_world install-broken
  dir="$WORLD/pathdir"
  mkdir -p "$dir"
  ln -s "$WORLD/gone/fm-dashboard-open.sh" "$dir/dashboard"
  rc=0
  out=$(install_in "$dir" --check 2>&1) || rc=$?
  expect_code 4 "$rc" "--check over a link that leads nowhere"
  assert_contains "$out" "no longer leads anywhere" "a dangling link must be reported as such"
  rc=0
  out=$(install_in "$dir" --force 2>&1) || rc=$?
  expect_code 0 "$rc" "--force over a link that leads nowhere"
  pass "dashboard command: a link that leads nowhere is reported and replaceable"
}

test_help_documents_the_whole_command
test_one_run_opens_the_board_and_leaves_it_refreshing
test_running_it_again_reuses_the_loop
test_a_process_that_merely_quotes_the_command_is_not_a_loop
test_a_decoy_named_by_an_older_record_is_not_a_loop
test_a_record_that_is_a_link_is_not_followed
test_a_recycled_pid_is_not_a_loop
test_a_loop_from_an_older_launcher_is_adopted_not_duplicated
test_the_interval_is_pinned_and_overridable
test_the_two_boards_are_independent
test_stop_and_status_when_nothing_is_running
test_a_loop_that_will_not_start_is_reported_not_pretended
test_usage_errors_are_loud
test_it_works_through_the_symlink_it_is_installed_as
test_install_puts_the_command_on_path
test_install_reports_a_directory_that_is_not_on_path
test_install_creates_a_missing_directory
test_install_refuses_to_replace_what_it_did_not_install
test_install_refuses_another_homes_command
test_install_reports_a_link_that_leads_nowhere
test_a_loop_this_command_did_not_start_is_reported_not_joined
test_a_process_that_quotes_the_command_is_not_reported_as_competing
test_a_loop_writing_another_page_is_not_competing
test_a_loop_for_the_other_board_is_not_competing
test_stop_says_what_it_could_not_stop
