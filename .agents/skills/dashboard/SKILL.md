---
name: dashboard
description: >-
  Run the fleet check (bearings) and then build and serve a visual board on a local
  port showing the work running right now beside every registered project's git
  health.
  Use when the captain invokes /dashboard or asks for a visual fleet/project status
  board, a dashboard of registered projects, which task terminals are open or which
  one is waiting on him, or "what needs attention across my projects".
user-invocable: true
metadata:
  internal: true
---

# dashboard

`/dashboard` is for launch: a quick bearings check plus one visual board with two
halves - the work running right now, and every registered project's git health -
so the captain can see what needs attention in one glance.
The live half exists because he works across several projects at once and drives
each task in its own terminal: it tells him which terminals exist, which one is
waiting on him, and how to reach it, so jumping between terminals does not become
hunting for them.
It is operationally read-only apart from the ordinary bearings side effects and
the dashboard's own generated files under `$FM_HOME/.dashboard/`; it never
fetches, pulls, commits, or otherwise mutates a project checkout, and never
steers, tears down, or merges a task.

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

3. **Gather the work running right now.**
   Run `bin/fm-dashboard-live-snapshot.sh > <live>.json`.
   Its header owns the exact `fm-dashboard-live.v1` output contract: one row per
   live task carrying the captain's name for its project, what it is doing from
   real current state, what it is waiting on, and how to reach its terminal,
   pre-sorted so whatever wants him is first.
   It is a view-specific projection over `bin/fm-fleet-snapshot.sh --json`, the
   canonical fleet reader, and parses no fleet state of its own.
   Because step 1's bearings check already read the fleet, pass that capture back
   in with `--fleet-json <file>` when you still have it rather than paying for a
   second full fleet read.
   A fleet read that cannot complete returns `available: false` with a reason
   instead of failing, so the project half of the board still builds.

4. **Build and serve the dashboard.**
   Run `bin/fm-dashboard-serve.sh build <tmp>.json --live <live>.json`.
   It injects the snapshot into the shipped template
   (`assets/dashboard-template.html`) at the stable path
   `$FM_HOME/.dashboard/index.html`, and serves that directory with a plain
   local static HTTP server bound to `127.0.0.1` - not `lavish-axi` - because
   this is a read-only, regenerate-on-each-run status page with no captain
   feedback loop for a session to poll.
   A server already running for this home is reused (rebuilt content is picked
   up on the browser's next request, no restart needed); otherwise a fresh one
   is started on the first free port at or after 4590.
   Its output gives the served URL.

5. **Report both to the captain.**
   Send the bearings four-section chat digest, then the dashboard URL from step
   4, in the same reply.
   Do not describe the dashboard's internal file paths, the server process, or
   the port-selection mechanics; just the URL and what it shows (the work running
   now and which of it is waiting on him, plus project health at a glance -
   clean/uncommitted, branch, last commit).

## Design intent

The dashboard is deliberately plain "internal tool" styling per the captain's
own instruction, not the warm nautical chrome used for captain-facing
surfaces like the bearings board: a status grid, restrained color reserved for
the clean/uncommitted and off-default-branch signals, monospace where it helps
scanning.
Projects are sorted worst-first (unavailable, then uncommitted, then off-default
branch, then clean) so what needs attention surfaces without scrolling.
A project with a commit in the last 7 days additionally renders its whole card
with a light-blue background regardless of its sort position, so work
currently in progress draws the eye even when it is not otherwise flagged.
Do not restyle it toward the nautical/warm-paper design system without an
explicit captain request to do so.

It stays ONE page at one command and one served location.
The captain's complaint that produced the live half was being lost between
places, so an extra surface makes it worse; restructure the page if it needs to
hold more, but do not split it.

## Live work

The live half is one row per running task, ranked so whatever wants him is at
the top: a failure first, then a blocker, a decision he owes, and work finished
and waiting to be approved.
Only those four wear the loud "waiting on you" treatment, because a badge that
also fires on ambiguity stops meaning anything.
Below them sit a run at its own review gate, a declared external wait, a task he
personally has the conn on, and ordinary work with nothing owed.
`bin/fm-dashboard-live-snapshot.sh`'s header owns the exact ranking and the
signals behind each classification.

Rows speak in the captain's nouns per `AGENTS.md` section 9 - "stopped for a
decision it cannot make itself", never "parked at fix_review".
The gatherer does that translation so the wording has one owner.

When the captain is working in a task's terminal, that row reads "you have the
conn" in the same blue the project half uses for his own recent work: never
loud, never stuck, and never claiming to want him.
That state is owned by the captain-has-the-conn work and reaches this board
through `bin/fm-crew-state.sh` and the canonical fleet snapshot; the board only
recognizes it and gives it a place.

### Reaching a terminal

Each row carries the exact command for its own task terminal, click-to-copy, and
the presence of that terminal read through the recovery-grade endpoint contract
rather than the cheap presence check - a board that offers a way in has to be
right about whether the terminal is still there.
A terminal known to be gone says so and offers no command, because handing him a
jump that is known to fail is worse than telling him the terminal is gone.
`docs/verification/runtime-backends.md` ("Window-targeted reads and the
/dashboard jump command") records why the command takes the shape it does.

### Honest about age

The page is generated when the command runs; there is no live feed behind it.
Live work goes stale in a way git health does not, so the live section states its
own age, keeps recomputing it while the tab stays open, and past ten minutes
turns red and says plainly not to walk into a terminal on the strength of it.
Never present this section as current state without its age: the failure being
guarded against is the captain trusting a stale row and walking into the wrong
terminal.
If he wants current state, the answer is to re-run `/dashboard`, not to make the
page poll - polling would turn a read-only observation surface into something
that repeatedly drives fleet reads on its own.

## When something looks unavailable

A project the snapshot marks `available: false` (its resolved clone path
does not exist, or is not a git checkout) renders as a distinct muted card
with the reason, sorted to the front alongside uncommitted projects - it is a
signal that registry state needs attention, not silently dropped.
This is expected for a stale or not-yet-cloned registry entry; do not treat it
as a script failure.
