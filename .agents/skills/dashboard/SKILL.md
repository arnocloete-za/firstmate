---
name: dashboard
description: >-
  Run the fleet check (bearings) and then build and serve a visual project-status
  dashboard on a local port.
  Use when the captain invokes /dashboard or asks for a visual fleet/project status
  board, a dashboard of registered projects, or "what needs attention across my
  projects".
user-invocable: true
metadata:
  internal: true
---

# dashboard

`/dashboard` is for launch: a quick bearings check plus a visual board of every
registered project's git health, so the captain can see what needs attention in
one glance.
It is operationally read-only toward every project checkout, apart from the
ordinary bearings side effects and the dashboard's own generated files under
`$FM_HOME/.dashboard/`; it never fetches, pulls, commits, or otherwise mutates
a checkout.
The one exception is launching: clicking a project card's "Run" control, when
that project has a registered run script, starts that script in a local tmux
session named `dashboard` (created if it does not already exist), in a window
named after the project.
Clicking Run again while that run is still going never kills, replaces, or
duplicates its window - it may be real work in progress - so Run only brings
it to focus, creates nothing new, and the button says "Focused" rather than
claiming a launch it did not make.
A window a finished run left behind (tmux `remain-on-exit`) is not a running
run: Run starts a fresh run in a new window and leaves that finished window
and its output alone - see step 3.

## What it does

1. **Run bearings exactly as plain `/bearings` does.**
   Load the `bearings` skill and follow its plain `/bearings` invocation - steps
   1 through 3 of its "What it does" - to gather the snapshot via
   `bin/fm-bearings-snapshot.sh` and compose the four-section chat digest.
   Do not fork or duplicate that fleet-state reader, and do not add file or
   lavish mode unless the captain separately asks for `/bearings file` or
   `/bearings lavish`.

2. **Gather every registered project's git status.**
   Run `bin/fm-dashboard-snapshot.sh > <tmp>.json`.
   Its header owns the exact `fm-dashboard-snapshot.v1` output contract: per
   registered project, working-tree cleanliness, the last commit's date and
   author, the last 5-10 commits, and the current branch versus that repo's own
   default branch.
   Every check it runs is read-only.
   That header also owns the optional `run script at <path>` registry-description
   phrase that gives a project the run script step 3's Run control launches, so
   read it before telling the captain how to add one.

3. **Build and serve the dashboard.**
   Run `bin/fm-dashboard-serve.sh build <tmp>.json`.
   It injects the snapshot into the shipped template
   (`assets/dashboard-template.html`) at the stable path
   `$FM_HOME/.dashboard/index.html`, and serves that directory with a small
   local HTTP server (`bin/fm-dashboard-server.py`, stdlib-only) bound to
   `127.0.0.1` - not `lavish-axi` - because this is a regenerate-on-each-run
   status page with no captain feedback loop for a session to poll.
   That server is a plain static file server for every ordinary request, plus
   one `POST /run` endpoint that launches a registered project's own run
   script in a local `dashboard` tmux session; `bin/fm-dashboard-server.py`'s
   own header owns that endpoint's exact contract and trust boundary.
   A server already running for this home is reused (rebuilt content is picked
   up on the browser's next request, no restart needed); otherwise a fresh one
   is started on the first free port at or after 4590.
   Its output gives the served URL.

4. **Report both to the captain.**
   Send the bearings four-section chat digest, then the dashboard URL from step
   3, in the same reply.
   Do not describe the dashboard's internal file paths, the server process, or
   the port-selection mechanics; just the URL and what it shows (project health
   at a glance - clean/uncommitted, branch, last commit).

## Design intent

The dashboard is deliberately plain "internal tool" styling per the captain's
own instruction, not the warm nautical chrome used for captain-facing
surfaces like the bearings board: a status grid, restrained color reserved for
the clean/uncommitted and off-default-branch signals, monospace where it helps
scanning.
Projects are sorted worst-first (unavailable, then uncommitted, then off-default
branch, then clean) so what needs attention surfaces without scrolling.
A project with a commit in the last 7 days additionally renders its whole card
with a tinted background regardless of its sort position - light blue when that
commit is the captain's own identity, warm amber when it is someone else's - so
work currently in progress draws the eye even when it is not otherwise
flagged.
Each card also shows a small badge with its 1-based position in the grid as
actually drawn (after the worst-first sort), so the captain can say
"project 3" by voice when a project's name doesn't recognize well; that
number is display order, not registry order, so it can shift between builds
if a project's status moves it in the sort.
A project's "Run" control, when it has a registered run script, is a small,
plain, distinct button next to the card's head - it never overloads that head's
own click, which for an available project still just opens or closes the
commits panel.
Do not restyle it toward the nautical/warm-paper design system without an
explicit captain request to do so.

## When something looks unavailable

A project the snapshot marks `available: false` (its resolved clone path
does not exist, or is not a git checkout) renders as a distinct muted card
with the reason, sorted to the front alongside uncommitted projects - it is a
signal that registry state needs attention, not silently dropped.
This is expected for a stale or not-yet-cloned registry entry; do not treat it
as a script failure.
If such an entry also registered a run script, its Run control can only report
"Failed" with the reason, because the server refuses to launch from a path that
is not there.
