---
name: dashboard
description: >-
  Generate one local HTML page showing the work running right now beside every
  registered project's git health.
  Use when the captain invokes /dashboard or asks for a visual fleet/project
  status board, a dashboard of registered projects, which task terminals are
  open or which one is waiting on him, or "what needs attention across my
  projects".
user-invocable: true
metadata:
  internal: true
---

# dashboard

`/dashboard` shows the captain state and does nothing else.
One command generates one static page: the work running right now, and every
registered project's git health.

It is display only.
The page has no server, no endpoint, and no button; nothing on it can start,
stop, steer, or change anything, and re-running the command is the refresh.
Every read is read-only, and the only files written are the page itself and, in
watch mode, the one sibling file it reads, both under `$FM_HOME/.dashboard/`.

## What it does

1. **Generate the page.**
   Run `bin/fm-dashboard.mjs`.
   Its header owns the exact arguments, output path, and read-only contract.
   It reads this home's registered projects and the canonical fleet snapshot
   concurrently, so the whole command costs about what the fleet read alone
   costs.
   When you already hold a `bin/fm-fleet-snapshot.sh --json` capture from this
   turn, pass it with `--fleet-json <file>` and the page generates in a
   fraction of a second.

2. **Give the captain the link.**
   Send the `open:` line it prints.
   Do not describe the file path, the generator, or how it gathered anything -
   just the link and what it shows.

`/dashboard` does not run `/bearings`.
The chat digest is that command's job; this one is the page.

## Keeping the page current

`bin/fm-dashboard.mjs --watch` re-reads the fleet on an interval until the
captain stops it, so the page he already has open updates itself.
Its header owns the interval, the default, and the whole watch contract.

Offer it when he says the board goes stale on him, asks how to refresh it, or is
about to sit with it while work is running.
Give him the command to run in his own terminal, with the link, and tell him
Ctrl-C is how it stops - the watch is his process, not one firstmate holds.
Never start a watch for him from firstmate's own session: it would die with the
turn, and a watch nobody can see or stop is worse than no watch.
One watch per page is enough; a second one adds reads and changes nothing.

The page reloads itself only when the board actually changed, and it keeps his
scroll position when it does, so it can be left open.
If the watch stops, the page says so and then ages exactly as an unwatched page
does: the live section keeps counting up and past ten minutes says plainly not
to trust it.
A Ctrl-C is reported within seconds because the watch says goodbye on its way
out; a watch that is killed outright is reported once the interval it promised
passes without another read.
Nothing on the page can claim to be current because a watch used to be running,
which is the whole reason it is safe to leave open.

## Design intent

Deliberately plain "internal tool" styling per the captain's own instruction,
not the warm nautical chrome used for captain-facing surfaces like the bearings
board.
Do not restyle it toward that design system without an explicit captain request.

It stays ONE page at one command and one location.
The captain's complaint that produced the live half was being lost between
places, so an extra surface makes it worse; restructure the page if it needs to
hold more, but do not split it.

Projects are numbered in **registry order**, and that number is the captain's
handle for the project - he reads it aloud to name one.
So the board never sorts worst-first: a number that moved when a project's
status changed would be worse than no number at all.
Attention shows as color instead.

Every project card is a fixed size, and the last five commits appear on hover in
an overlay, so the grid cannot reflow and hovering cannot resize a card.

## Live work

One row per running task, ranked so whatever wants the captain is at the top: a
failure first, then a blocker, a decision he owes, and work finished and waiting
to be approved.
Only those four wear the loud "waiting on you" treatment, because a badge that
also fires on ambiguity stops meaning anything.
Below them sit a run at its own review gate, a declared external wait, a task he
personally has the conn on, and ordinary work with nothing owed.

Rows speak in the captain's nouns per `AGENTS.md` section 9 - "stopped for a
decision it cannot make itself", never "parked at fix_review".
The generator does that translation over `bin/fm-fleet-snapshot.sh --json`, the
canonical fleet reader, and derives no current state, backlog role, or captain
actionability of its own.

Each row carries the exact command for its own task terminal, click-to-copy.
That is display - it puts text on his clipboard and nothing more.
Terminal presence is read through the recovery-grade endpoint contract, because a
board that offers a way in has to be right about whether the terminal is still
there; a terminal known to be gone says so and offers no command.
`docs/verification/runtime-backends.md` ("Window-targeted reads and the
/dashboard jump command") records why the command takes the shape it does.

The page is generated when the command runs; there is no live feed behind it.
Live work goes stale in a way git health does not, so the live section states its
own age, keeps recomputing it while the tab stays open, and past ten minutes says
plainly not to walk into a terminal on the strength of it.
If he wants current state, the answer is to re-run `/dashboard`, or to leave a
watch running (above) so the re-running happens for him.

## When something looks unavailable

A project whose resolved clone path does not exist, or is not a git checkout,
renders as a muted card with the reason - it is a signal that registry state
needs attention, not silently dropped.
This is expected for a stale or not-yet-cloned registry entry; do not treat it
as a failure.
