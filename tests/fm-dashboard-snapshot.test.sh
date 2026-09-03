#!/usr/bin/env bash
# tests/fm-dashboard-snapshot.test.sh - behavior tests for the /dashboard git
# status projection.
#
# Covers path resolution (default projects/<name> layout vs the embedded
# "clone kept in place at <PATH>" registry phrase), clean/dirty detection,
# last-commit fields, the bounded commit list, default-branch resolution via
# both origin/HEAD and the local main/master fallback, the on_default flag,
# and the unavailable-project path for a registry entry whose clone is
# missing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-dashboard-snapshot.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-dashboard-snapshot)
FM_ROOT_OVERRIDE="$TMP_ROOT/home"
mkdir -p "$FM_ROOT_OVERRIDE/data" "$FM_ROOT_OVERRIDE/projects"
export FM_ROOT_OVERRIDE

make_repo() {  # <dir> <branch>
  mkdir -p "$1"
  git init -q -b "$2" "$1"
}

commit_file() {  # <dir> <file> <content> <subject> <author>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  GIT_AUTHOR_NAME="$5" GIT_AUTHOR_EMAIL="$5@example.invalid" \
    GIT_COMMITTER_NAME="$5" GIT_COMMITTER_EMAIL="$5@example.invalid" \
    git -C "$1" commit -qm "$4"
}

# --- fixture: default-layout project, clean, on its default branch ---------
DEFAULT_LAYOUT="$FM_ROOT_OVERRIDE/projects/proj-default"
make_repo "$DEFAULT_LAYOUT" main
commit_file "$DEFAULT_LAYOUT" README.md "hello" "initial" alice
commit_file "$DEFAULT_LAYOUT" README.md "hello again" "second" alice

# --- fixture: dirty project (uncommitted change after the last commit) -----
DIRTY="$FM_ROOT_OVERRIDE/projects/proj-dirty"
make_repo "$DIRTY" main
commit_file "$DIRTY" README.md "hello" "initial" bob
echo "uncommitted" >> "$DIRTY/README.md"

# --- fixture: off-default-branch project ------------------------------------
OFF_DEFAULT="$FM_ROOT_OVERRIDE/projects/proj-off-default"
make_repo "$OFF_DEFAULT" main
commit_file "$OFF_DEFAULT" README.md "hello" "initial" carol
git -C "$OFF_DEFAULT" checkout -qb wip

# --- fixture: outside-layout project, path embedded in the description -----
OUTSIDE="$TMP_ROOT/elsewhere/proj-outside"
make_repo "$OUTSIDE" master
commit_file "$OUTSIDE" README.md "hello" "initial" dave

# --- fixture: default-branch resolution via origin/HEAD (no fetch needed) --
ORIGIN_HEAD="$FM_ROOT_OVERRIDE/projects/proj-origin-head"
make_repo "$ORIGIN_HEAD" trunk
commit_file "$ORIGIN_HEAD" README.md "hello" "initial" erin
git -C "$ORIGIN_HEAD" update-ref refs/remotes/origin/trunk HEAD
git -C "$ORIGIN_HEAD" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

# --- fixture: many commits, to exercise the bound -----------
MANY="$FM_ROOT_OVERRIDE/projects/proj-many-commits"
make_repo "$MANY" main
for i in $(seq 1 12); do
  commit_file "$MANY" README.md "rev $i" "commit $i" frank
done

cat > "$FM_ROOT_OVERRIDE/data/projects.md" <<EOF
# Projects

- proj-default - default layout project (added 2026-01-01)
- proj-dirty - dirty project (added 2026-01-01)
- proj-off-default - off default branch project (added 2026-01-01)
- proj-outside [no-mistakes] - outside layout; clone kept in place at $OUTSIDE (added 2026-01-01)
- proj-origin-head - resolves default branch via origin/HEAD (added 2026-01-01)
- proj-many-commits - has more commits than the bound (added 2026-01-01)
- proj-ghost - never cloned (added 2026-01-01)
EOF

OUT=$("$SNAPSHOT")
echo "$OUT" | jq -e '.schema == "fm-dashboard-snapshot.v1"' >/dev/null \
  || fail "wrong schema tag: $OUT"
echo "$OUT" | jq -e '.projects | length == 7' >/dev/null \
  || fail "expected 7 projects, got: $(echo "$OUT" | jq '.projects | length')"
pass "snapshot carries the fm-dashboard-snapshot.v1 schema and every registered project"

proj() {  # <name> -> that project's JSON object
  echo "$OUT" | jq -c --arg n "$1" '.projects[] | select(.name == $n)'
}

proj proj-default | jq -e '.available == true and .clean == true' >/dev/null \
  || fail "proj-default should be available and clean: $(proj proj-default)"
proj proj-default | jq -e --arg p "$DEFAULT_LAYOUT" '.path == $p' >/dev/null \
  || fail "proj-default did not resolve to the default projects/<name> layout: $(proj proj-default)"
proj proj-default | jq -e '.branch == "main" and .default_branch == "main" and .on_default == true' >/dev/null \
  || fail "proj-default should read as on its default branch: $(proj proj-default)"
proj proj-default | jq -e '.last_commit.author == "alice" and (.last_commit.subject == "second")' >/dev/null \
  || fail "proj-default last_commit fields wrong: $(proj proj-default)"
pass "default projects/<name> layout, clean status, and last-commit fields resolve correctly"

proj proj-dirty | jq -e '.available == true and .clean == false' >/dev/null \
  || fail "proj-dirty should be dirty: $(proj proj-dirty)"
pass "an uncommitted change is detected as dirty"

proj proj-off-default | jq -e '.branch == "wip" and .default_branch == "main" and .on_default == false' >/dev/null \
  || fail "proj-off-default should read as off its default branch: $(proj proj-off-default)"
pass "a checked-out feature branch is reported as off the default branch"

proj proj-outside | jq -e --arg p "$OUTSIDE" '.path == $p and .available == true' >/dev/null \
  || fail "proj-outside did not resolve the embedded clone path: $(proj proj-outside)"
pass "the embedded 'clone kept in place at <PATH>' phrase resolves the project path"

proj proj-origin-head | jq -e '.branch == "trunk" and .default_branch == "trunk" and .on_default == true' >/dev/null \
  || fail "proj-origin-head should resolve its default branch via origin/HEAD: $(proj proj-origin-head)"
pass "default-branch resolution prefers origin/HEAD over the local main/master fallback"

proj proj-ghost | jq -e '.available == false' >/dev/null \
  || fail "proj-ghost (never cloned) should be unavailable: $(proj proj-ghost)"
proj proj-ghost | jq -e '.reason | length > 0' >/dev/null \
  || fail "proj-ghost should carry a reason: $(proj proj-ghost)"
pass "a registered project with no clone on disk is reported unavailable with a reason"

proj proj-many-commits | jq -e '.commits | length == 8' >/dev/null \
  || fail "default commit bound should be 8: $(proj proj-many-commits | jq '.commits | length')"
pass "the default commit-history bound is 8"

OUT5=$("$SNAPSHOT" --commits 5)
echo "$OUT5" | jq -e --arg n proj-many-commits \
  '(.projects[] | select(.name == $n) | .commits | length) == 5' >/dev/null \
  || fail "--commits 5 should bound the commit list to 5"
pass "--commits overrides the default bound within range"

OUT20=$("$SNAPSHOT" --commits 20)
echo "$OUT20" | jq -e --arg n proj-many-commits \
  '(.projects[] | select(.name == $n) | .commits | length) == 10' >/dev/null \
  || fail "--commits 20 should clamp to 10"
pass "--commits is clamped to the documented 5-10 range"

echo "ALL TESTS PASSED"
