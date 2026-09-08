#!/usr/bin/env bash
# tests/fm-task-number.test.sh - behavior tests for the captain's project
# numbers (bin/fm-task-number-lib.sh).
#
# The point of the scheme is that the captain can hear a number, say a number,
# and know which piece of work it is, so what is asserted here is the properties
# that promise makes: numbers that hold still while statuses change, a reserved
# ship number that cannot collide and cannot renumber his board underneath him,
# a pool that reuses numbers without letting one mean two things in the same
# afternoon, and one terminal label derived from the same record so the board
# and the terminal can never disagree.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-number)

# shellcheck source=bin/fm-task-number-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-task-number-lib.sh"

# home <name>: a private data/ + state/ pair, so each case owns its registry.
home() {  # <name>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/data" "$dir/state"
  printf '%s\n' "$dir"
}

# registry <home> <line...>: write data/projects.md from registry lines.
registry() {  # <home> <line...>
  local dir=$1
  shift
  {
    printf '# Projects\n\n'
    printf '%s\n' "$@"
  } > "$dir/data/projects.md"
}

number_of() {  # <home> <project>
  fm_task_number_of_project "$1/data" "$2" 2>/dev/null || printf 'none'
}

# The board column of the one table every consumer reads; the work board is the
# fallback for a project the table does not list, the same direction an
# unreadable marker takes.
board_of() {  # <home> <project>
  local row
  row=$(fm_task_number_table "$1/data" 2>/dev/null \
    | awk -F'\t' -v n="$2" '$1 == n { print $2; exit }')
  printf '%s' "${row:-$FM_TASK_NUMBER_WORK_BOARD}"
}

# --- the scheme the captain was promised ----------------------------------
test_boards_number_from_their_own_bases() {
  local dir
  dir=$(home boards)
  registry "$dir" \
    '- alpha [no-mistakes] - first work project' \
    '- side-one [local-only +personal] - a personal project' \
    '- beta [no-mistakes] - second work project' \
    '- side-two [local-only +personal] - another personal project' \
    '- gamma - third work project, no annotation at all'

  [ "$(number_of "$dir" alpha)" = 1 ] || fail "the work board must start at 1: got $(number_of "$dir" alpha)"
  [ "$(number_of "$dir" beta)" = 2 ] || fail "work numbering must follow registry order within its own board: got $(number_of "$dir" beta)"
  [ "$(number_of "$dir" gamma)" = 3 ] || fail "an unannotated project belongs to the work run: got $(number_of "$dir" gamma)"
  [ "$(number_of "$dir" side-one)" = 50 ] || fail "the personal board must start at 50: got $(number_of "$dir" side-one)"
  [ "$(number_of "$dir" side-two)" = 51 ] || fail "personal numbering must follow registry order within its own board: got $(number_of "$dir" side-two)"
  [ "$(board_of "$dir" side-one)" = personal ] || fail "the +personal flag must select the personal board"
  [ "$(board_of "$dir" gamma)" = work ] || fail "an unannotated project must sit on the work board"
  pass "each board numbers its own projects in registry order from its own base"
}

test_an_unreadable_marker_still_numbers_a_project() {
  local dir
  dir=$(home marker)
  registry "$dir" \
    '- alpha [no-mistakes +personl] - the flag is misspelled' \
    '- beta [+yolo] - flags but no board marker' \
    '- gamma [no-mistakes] - work, and its description mentions [+personal] in prose'

  # Membership of any other board has to be STATED, so every unreadable marker
  # leaves the project numbered on the board he reads first rather than nowhere.
  [ "$(board_of "$dir" alpha)" = work ] || fail "a misspelled marker must not move a project off the work board"
  [ "$(board_of "$dir" gamma)" = work ] || fail "a bracket in the free-form description must not be read as a board marker"
  [ "$(number_of "$dir" alpha)" = 1 ] || fail "a misspelled marker must still leave a number: got $(number_of "$dir" alpha)"
  [ "$(number_of "$dir" beta)" = 2 ] || fail "a bracket with no board marker must stay in the work run"
  [ "$(number_of "$dir" gamma)" = 3 ] || fail "prose must not consume a board position"
  pass "an unreadable or absent board marker leaves a project numbered on the work board"
}

test_the_ship_holds_a_reserved_number_either_way() {
  local dir unregistered registered
  dir=$(home ship-unregistered)
  registry "$dir" \
    '- alpha [no-mistakes] - first work project' \
    '- beta [no-mistakes] - second work project'
  unregistered="$(number_of "$dir" alpha) $(number_of "$dir" beta) $(number_of "$dir" firstmate)"

  dir=$(home ship-registered)
  registry "$dir" \
    '- alpha [no-mistakes] - first work project' \
    '- firstmate [project-branch] - the fleet tooling itself' \
    '- beta [no-mistakes] - second work project'
  registered="$(number_of "$dir" alpha) $(number_of "$dir" beta) $(number_of "$dir" firstmate)"

  # Registering firstmate as a project changes how work on it RUNS; it must not
  # change a single number the captain has learned.
  [ "$unregistered" = "$registered" ] \
    || fail "registering firstmate changed the numbering: '$unregistered' became '$registered'"
  [ "$(number_of "$dir" firstmate)" = 0 ] || fail "the ship's reserved number must be 0"
  [ "$(number_of "$dir" beta)" = 2 ] \
    || fail "a registered firstmate must not consume a board position: beta got $(number_of "$dir" beta)"
  pass "firstmate holds its reserved number whether or not it is registered, and never shifts the board"

  # Reserved 0 is the one value that cannot collide with a board run or the
  # pool, which is the whole reason it was chosen.
  [ "$FM_TASK_NUMBER_FIRSTMATE" -lt "$FM_TASK_NUMBER_WORK_BASE" ] \
    || fail "the reserved ship number must sit below every board run"
  pass "the reserved ship number cannot collide with a board position or a pool number"
}

test_work_outside_the_registry_has_no_derived_number() {
  local dir
  dir=$(home unregistered)
  registry "$dir" '- alpha [no-mistakes] - the only registered project'
  [ "$(number_of "$dir" whatever)" = none ] \
    || fail "an unregistered project must derive no number: got $(number_of "$dir" whatever)"
  [ "$(board_of "$dir" whatever)" = work ] \
    || fail "an unregistered project's work still belongs on the work board"
  # It is numbered by ALLOCATION instead, from the pool, when work starts.
  [ "$(fm_task_number_allocate "$dir/data" "$dir/state" whatever)" = "$FM_TASK_NUMBER_POOL_BASE" ] \
    || fail "work on an unregistered project must take the pool's first number"
  [ "$(fm_task_number_allocate "$dir/data" "$dir/state" alpha)" = 1 ] \
    || fail "work on a registered project must take that project's own number, never a pool number"
  pass "work outside the registry is numbered from the pool, and registered work never is"
}

test_a_missing_registry_numbers_nothing_rather_than_guessing() {
  local dir
  dir=$(home no-registry)
  [ "$(number_of "$dir" alpha)" = none ] || fail "no registry must mean no derived number"
  [ "$(number_of "$dir" firstmate)" = 0 ] || fail "the ship's number does not depend on a registry"
  [ "$(fm_task_number_allocate "$dir/data" "$dir/state" alpha)" = "$FM_TASK_NUMBER_POOL_BASE" ] \
    || fail "with no registry, starting work still takes a pool number"
  pass "a missing registry numbers nothing by derivation and still numbers new work from the pool"
}

# --- the pool: reuse without letting one number mean two things -----------
test_the_pool_hands_out_the_lowest_free_number() {
  local dir base
  dir=$(home pool)
  base=$FM_TASK_NUMBER_POOL_BASE
  [ "$(fm_task_number_pool_lowest_free "$dir/state")" = "$base" ] \
    || fail "an empty pool must start at its base"

  fm_write_meta "$dir/state/one.meta" "number=$base" "project=/x/one"
  [ "$(fm_task_number_pool_lowest_free "$dir/state")" = "$((base + 1))" ] \
    || fail "a number a live task holds must not be handed out again"
  fm_write_meta "$dir/state/two.meta" "number=$((base + 1))" "project=/x/two"
  [ "$(fm_task_number_pool_lowest_free "$dir/state")" = "$((base + 2))" ] \
    || fail "the pool must skip every number in use"

  # A gap is filled before the pool climbs, which is what keeps the numbers he
  # says aloud short.
  rm -f "$dir/state/one.meta"
  [ "$(fm_task_number_pool_lowest_free "$dir/state")" = "$base" ] \
    || fail "a freed number below the high water mark must be reused, not skipped"
  pass "the pool always hands out its lowest free number, so the numbers stay small"
}

test_a_finished_pool_number_is_held_before_it_is_reused() {
  local dir base
  dir=$(home quarantine)
  base=$FM_TASK_NUMBER_POOL_BASE
  fm_write_meta "$dir/state/one.meta" "number=$base" "project=/x/one"
  rm -f "$dir/state/one.meta"
  fm_task_number_release "$dir/state" "$base"

  # The captain's complaint is a number he said a few messages ago. If it became
  # different work inside that window the number would actively mislead him, so
  # a released number waits rather than being reissued at once.
  [ "$(fm_task_number_pool_lowest_free "$dir/state")" = "$((base + 1))" ] \
    || fail "a just-released number must not be handed straight to the next piece of work"

  # And it does come back on its own, with no cleanup step to forget.
  [ "$(FM_TASK_NUMBER_QUARANTINE_SECS=0 fm_task_number_pool_lowest_free "$dir/state")" = "$base" ] \
    || fail "a released number must return to the pool once its hold window has passed"
  pass "a finished pool number is held briefly, then returns on its own"
}

test_only_pool_numbers_are_released() {
  local dir
  dir=$(home release-scope)
  fm_task_number_release "$dir/state" 7
  fm_task_number_release "$dir/state" 50
  fm_task_number_release "$dir/state" 0
  fm_task_number_release "$dir/state" ''
  fm_task_number_release "$dir/state" not-a-number
  assert_absent "$dir/state/number-quarantine" \
    "a number the registry derives is not the pool's to release"
  pass "releasing a derived number, or no number at all, changes nothing"
}

test_the_held_list_does_not_grow_without_bound() {
  local dir base n
  dir=$(home prune)
  base=$FM_TASK_NUMBER_POOL_BASE
  n=0
  while [ "$n" -lt 5 ]; do
    printf '%s 1\n' "$((base + n))" >> "$dir/state/number-quarantine"
    n=$((n + 1))
  done
  fm_task_number_release "$dir/state" "$base"
  [ "$(wc -l < "$dir/state/number-quarantine")" -eq 1 ] \
    || fail "long-expired holds must be pruned rather than accumulating: $(cat "$dir/state/number-quarantine")"
  pass "expired holds are pruned when a number is released"
}

# --- one label, derived from one record -----------------------------------
test_the_terminal_label_leads_with_the_number() {
  local dir
  dir=$(home label)
  fm_write_meta "$dir/state/seven.meta" "number=7" "project=/x/alpha"
  fm_write_meta "$dir/state/ship.meta" "number=0" "project=/x/firstmate"
  fm_write_meta "$dir/state/pool.meta" "number=100" "project=/x/other"
  fm_write_meta "$dir/state/legacy.meta" "project=/x/alpha"

  [ "$(fm_task_label "$dir/state" seven)" = fm-07-seven ] \
    || fail "a numbered task's terminal must lead with its number: got $(fm_task_label "$dir/state" seven)"
  [ "$(fm_task_label "$dir/state" ship)" = fm-00-ship ] \
    || fail "the ship's reserved number must appear in its terminal name too"
  [ "$(fm_task_label "$dir/state" pool)" = fm-100-pool ] \
    || fail "a pool number keeps its own width: got $(fm_task_label "$dir/state" pool)"
  # Every task record written before numbering existed must still validate, so
  # an unnumbered task keeps the historical label exactly.
  [ "$(fm_task_label "$dir/state" legacy)" = fm-legacy ] \
    || fail "a task with no recorded number must keep the historical label"
  [ "$(fm_task_label "$dir/state" missing)" = fm-missing ] \
    || fail "a task with no record at all must resolve to the historical label"
  pass "one owner derives the terminal label, and an unnumbered task keeps the historical one"
}

test_an_ambiguous_recorded_number_is_no_number() {
  local dir
  dir=$(home ambiguous)
  fm_write_meta "$dir/state/two.meta" "number=7" "number=8" "project=/x/alpha"
  # Two numbers would make the label ambiguous, and a guessed label is what
  # would send a cleanup at the wrong terminal.
  fm_task_number_recorded "$dir/state" two >/dev/null 2>&1 \
    && fail "an ambiguous number record must not resolve to a number"
  [ "$(fm_task_label "$dir/state" two)" = fm-two ] \
    || fail "an ambiguous number record must not compose a numbered label"
  pass "an ambiguous recorded number reads as no number rather than a guess"
}

test_a_recorded_number_survives_a_rearranged_registry() {
  local dir
  dir=$(home recorded)
  registry "$dir" \
    '- alpha [no-mistakes] - first' \
    '- beta [no-mistakes] - second'
  fm_write_meta "$dir/state/work.meta" "number=2" "project=$dir/beta"
  [ "$(fm_task_number_of_task "$dir/data" "$dir/state" work)" = 2 ] \
    || fail "a task's own record must answer for its number"

  registry "$dir" \
    '- beta [no-mistakes] - the captain moved this one first' \
    '- alpha [no-mistakes] - and this one second'
  [ "$(fm_task_number_of_task "$dir/data" "$dir/state" work)" = 2 ] \
    || fail "a recorded number must not move under a rearranged registry"
  [ "$(fm_task_label "$dir/state" work)" = fm-02-work ] \
    || fail "the terminal that exists must keep the name it was created with"
  pass "a recorded number, and the terminal named after it, survive a rearranged registry"
}

test_an_unrecorded_task_falls_back_to_its_project() {
  local dir
  dir=$(home derived)
  registry "$dir" \
    '- alpha [no-mistakes] - first' \
    '- side [local-only +personal] - personal'
  fm_write_meta "$dir/state/on-alpha.meta" "project=$dir/projects/alpha"
  fm_write_meta "$dir/state/on-side.meta" "project=/anywhere/side"
  fm_write_meta "$dir/state/on-ship.meta" "project=/anywhere/firstmate"
  fm_write_meta "$dir/state/nowhere.meta" "project=/anywhere/unregistered"

  [ "$(fm_task_number_of_task "$dir/data" "$dir/state" on-alpha)" = 1 ] \
    || fail "a task with no recorded number must take its project's number"
  [ "$(fm_task_number_of_task "$dir/data" "$dir/state" on-side)" = 50 ] \
    || fail "a personal project's task must take its personal number"
  [ "$(fm_task_number_of_task "$dir/data" "$dir/state" on-ship)" = 0 ] \
    || fail "work on firstmate itself must take the reserved number"
  fm_task_number_of_task "$dir/data" "$dir/state" nowhere >/dev/null 2>&1 \
    && fail "an unrecorded task on an unregistered project must not invent a number"
  pass "an unrecorded task takes its project's number, and never an invented one"
}

test_the_table_states_board_number_and_spelling_once() {
  local dir table
  dir=$(home table)
  registry "$dir" \
    '- alpha [no-mistakes] - first' \
    '- side [local-only +personal] - personal' \
    '- firstmate [project-branch] - the ship'
  table=$(fm_task_number_table "$dir/data")
  # Every consumer reads board membership, the number, and the way it is written
  # from this one table, so a project card and a live row cannot disagree.
  assert_contains "$table" "alpha	work	1	01" "the table must state alpha's board, number, and spelling"
  assert_contains "$table" "side	personal	50	50" "the table must state side's board, number, and spelling"
  assert_contains "$table" "firstmate	work	0	00" "the table must state the ship's reserved number and spelling"
  [ "$(fm_task_number_display 7)" = 07 ] || fail "a single-digit number is written with two digits"
  [ "$(fm_task_number_display 100)" = 100 ] || fail "a three-digit number keeps its own width"
  pass "one table states each project's board, number, and spelling for every consumer"
}

test_boards_refuse_to_outgrow_their_bands() {
  local dir i lines table
  dir=$(home overflow)
  lines=""
  i=1
  while [ "$i" -le "$FM_TASK_NUMBER_PERSONAL_BASE" ]; do
    lines="$lines- p$i [no-mistakes] - work project $i"$'\n'
    i=$((i + 1))
  done
  printf '# Projects\n\n%s' "$lines" > "$dir/data/projects.md"
  table=$(fm_task_number_table "$dir/data" 2>/dev/null)
  # A number shown twice would be worse than no number, so the overflowing
  # project shows none and the table says so on stderr.
  assert_contains "$table" "p49	work	49	49" "the last project inside the band must still be numbered"
  assert_contains "$table" "p50	work		" "a project past its band must carry no number"
  [ "$(number_of "$dir" p50)" = none ] || fail "an overflowing project must derive no number"
  assert_contains "$(fm_task_number_table "$dir/data" 2>&1 >/dev/null)" "outgrown its number band" \
    "an overflowing board must say so rather than reusing a number"
  pass "a board that outgrows its band leaves a project unnumbered instead of duplicating a number"
}

test_boards_number_from_their_own_bases
test_an_unreadable_marker_still_numbers_a_project
test_the_ship_holds_a_reserved_number_either_way
test_work_outside_the_registry_has_no_derived_number
test_a_missing_registry_numbers_nothing_rather_than_guessing
test_the_pool_hands_out_the_lowest_free_number
test_a_finished_pool_number_is_held_before_it_is_reused
test_only_pool_numbers_are_released
test_the_held_list_does_not_grow_without_bound
test_the_terminal_label_leads_with_the_number
test_an_ambiguous_recorded_number_is_no_number
test_a_recorded_number_survives_a_rearranged_registry
test_an_unrecorded_task_falls_back_to_its_project
test_the_table_states_board_number_and_spelling_once
test_boards_refuse_to_outgrow_their_bands
