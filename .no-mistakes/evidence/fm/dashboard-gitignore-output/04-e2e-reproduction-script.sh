#!/usr/bin/env bash
# End-to-end reproduction of the reported bug and its fix, using the real
# /dashboard and /updatefirstmate scripts against real git checkouts.
#   BEFORE = firstmate home at 01bfb80 (the commit that shipped /dashboard)
#   AFTER  = firstmate home at a8d974c (this change)
set -u
PLAY=/tmp/fm-dash-e2e-t
rm -rf "$PLAY"; mkdir -p "$PLAY"
SRC=/home/arno/.no-mistakes/worktrees/cbd2dd3ced60/01M1XFHWCP5CVFQ80KMD42ZDM1
git clone -q --bare "$SRC" "$PLAY/origin.git"
git -C "$PLAY/origin.git" branch -f main a8d974c
git -C "$PLAY/origin.git" symbolic-ref HEAD refs/heads/main
for n in before after; do
  git clone -q "$PLAY/origin.git" "$PLAY/$n"
  git -C "$PLAY/$n" remote set-head origin main >/dev/null 2>&1
  git -C "$PLAY/$n" config user.name Captain
  git -C "$PLAY/$n" config user.email captain@example.invalid
  mkdir -p "$PLAY/$n/data" "$PLAY/$n/state" "$PLAY/$n/projects"
  touch "$PLAY/$n/state/.last-watcher-beat"
  printf '# Projects\n\n- firstmate - this home itself; clone kept in place at %s/%s (added 2026-09-07)\n' "$PLAY" "$n" > "$PLAY/$n/data/projects.md"
done
git -C "$PLAY/before" checkout -q -B main 01bfb80

run_dashboard() {  # <home> <port>
  FM_DASHBOARD_PORT_BASE=$2 "$1/bin/fm-dashboard-snapshot.sh" > "$PLAY/snap.json"
  FM_DASHBOARD_PORT_BASE=$2 "$1/bin/fm-dashboard-serve.sh" build "$PLAY/snap.json" | sed 's/^/    /'
  printf '    board says the firstmate repo is: %s\n' \
    "$(jq -r '.projects[0] | if .clean then "CLEAN" else "UNCOMMITTED" end' "$PLAY/snap.json")"
}

hdr() { printf '\n=== %s\n' "$*"; }

hdr "BEFORE (home at 01bfb80) - captain runs /dashboard twice"
run_dashboard "$PLAY/before" 4810 >/dev/null; run_dashboard "$PLAY/before" 4810
printf '  $ git status --short\n'; git -C "$PLAY/before" status --short | sed 's/^/    /'
printf '  $ bin/fm-update.sh   (the /updatefirstmate mechanics)\n'
"$PLAY/before/bin/fm-update.sh" 2>&1 | sed 's/^/    /'
printf '    HEAD stays at %s - the home is stranded\n' "$(git -C "$PLAY/before" rev-parse --short HEAD)"
FM_HOME="$PLAY/before" "$PLAY/before/bin/fm-dashboard-serve.sh" stop >/dev/null 2>&1

hdr "AFTER (home at a8d974c) - captain runs /dashboard twice"
run_dashboard "$PLAY/after" 4820 >/dev/null; run_dashboard "$PLAY/after" 4820
printf '  $ git status --short\n'; git -C "$PLAY/after" status --short | sed 's/^/    /'
printf '    (no output above: the generated board is not uncommitted work)\n'
printf '  $ git check-ignore -v .dashboard/index.html\n'
git -C "$PLAY/after" check-ignore -v .dashboard/index.html | sed 's/^/    /'
FM_HOME="$PLAY/after" "$PLAY/after/bin/fm-dashboard-serve.sh" stop >/dev/null 2>&1

# --- the sync guard, on a home that generated the board before the ignore rule
P="$PLAY/after"
git -C "$P" worktree add -q --detach "$PLAY/sm1" 01bfb80
{ echo 'window=main:fm-sm1'; echo 'kind=secondmate'; echo "home=$PLAY/sm1"; } > "$P/state/sm1.meta"
sm_reset() {  # <untracked-mode>
  git -C "$PLAY/sm1" reset -q --hard 01bfb80
  git -C "$PLAY/sm1" config status.showUntrackedFiles "$1"
  rm -rf "$PLAY/sm1/UNLANDED.md"
  printf 'sm1\n' > "$PLAY/sm1/.fm-secondmate-home"
  mkdir -p "$PLAY/sm1/.dashboard"; printf '<html>board</html>\n' > "$PLAY/sm1/.dashboard/index.html"
}
guard() {  # <lib-home> <label>
  printf '  %s: %s\n' "$2" \
    "$(FM_ROOT_OVERRIDE="$P" FM_HOME="$P" "$1/bin/fm-update.sh" 2>&1 | grep 'secondmate sm1')"
  printf '     home HEAD now: %s\n' "$(git -C "$PLAY/sm1" rev-parse --short HEAD)"
}

hdr "SYNC GUARD - a home carrying a board it generated before the ignore rule"
for mode in normal all; do
  printf '  host status.showUntrackedFiles=%s -> porcelain reads "%s"\n' "$mode" \
    "$(sm_reset "$mode"; git -C "$PLAY/sm1" status --porcelain | head -1)"
  sm_reset "$mode"; guard "$PLAY/before" "pre-fix guard "
  sm_reset "$mode"; guard "$PLAY/after"  "this change  "
done

hdr "STILL PROTECTED - genuine uncommitted work next to the board"
sm_reset all; printf 'uncommitted local edit\n' >> "$PLAY/sm1/AGENTS.md"
guard "$PLAY/after" "this change  "
printf '     local edit preserved: %s\n' "$(grep -c 'uncommitted local edit' "$PLAY/sm1/AGENTS.md")"

hdr "BONUS - host status.showUntrackedFiles=no no longer hides operator work"
sm_reset no; rm -rf "$PLAY/sm1/.dashboard"; printf 'notes\n' > "$PLAY/sm1/UNLANDED.md"
printf '  plain porcelain hides it: [%s]\n' "$(git -C "$PLAY/sm1" status --porcelain)"
guard "$PLAY/before" "pre-fix guard "
sm_reset no; rm -rf "$PLAY/sm1/.dashboard"; printf 'notes\n' > "$PLAY/sm1/UNLANDED.md"
guard "$PLAY/after"  "this change  "
echo
