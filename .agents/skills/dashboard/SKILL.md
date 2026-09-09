---
name: dashboard
description: >-
  Generate one local HTML page showing the work running right now beside the git
  health of the projects on the captain's work board.
  Use when the captain invokes /dashboard or asks for a visual fleet/project
  status board, a dashboard of his projects, which task terminals are open or
  which one is waiting on him, or "what needs attention across my projects".
  For his personal projects, use /dashboard-personal instead.
user-invocable: true
metadata:
  internal: true
---

# dashboard

`/dashboard` shows the captain state and does nothing else.
One command generates one static page: the work running right now, and the git
health of the projects on his work board.

Its companion is [`/dashboard-personal`](../dashboard-personal/SKILL.md), the
same page for the personal projects he keeps off this one.
Both are thin callers of one generator with a different board selected, so keep
any change here a change to that generator rather than to one board.

It is display only.
The page has no server, no endpoint, and no button; nothing on it can start,
stop, steer, or change anything, and re-running the command is the refresh.
Every read is read-only, and the only files written are the page itself and, in
watch mode, the one sibling file it reads, both under `$FM_HOME/.dashboard/`.

## What it does

1. **Generate the page.**
   Run `bin/fm-dashboard.mjs`.
   Its header owns the exact arguments, the board table, the output path, and
   the read-only contract.
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

The page reloads itself only when the board actually changed, and it keeps
where he was reading when it does - how far down the board, and the project
overlay he had open - so it can be left open.
The clock alone is never a change: a commit's age is recomputed in his tab, not
by rewriting the page under him.
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

Each board stays ONE page at one command and one location.
The captain's complaint that produced the live half was being lost between
places, so a board that spills into extra surfaces makes it worse; restructure
a board if it needs to hold more, but do not split it.

There are exactly two boards because the captain's work and his own personal
projects are separate parts of his life that he reads at separate times - not
because a board ran out of room.
So that rule is not a licence to add a third for some other cut of the same
projects: a cut he has to recombine in his head is the lostness the one-page
rule exists to prevent.
Which board a project is on is registry state (below), and only he moves one.

The two boards are one page's worth of code: `--group` selects the board, and
the generator's board table is where a board is defined.
Never fork the generator or the template for a board - two copies drift the
first time only one is changed, and "the same page for my personal projects" is
what he actually asked for.

Projects are numbered in **registry order within their own board**, and that
number is the captain's handle for the project - he reads it aloud to name one.
So a board never sorts worst-first: a number that moved when a project's status
changed would be worse than no number at all.
Attention shows as color instead.

The board does not decide those numbers.
`bin/fm-task-number-lib.sh` is their single owner and its header owns the
scheme, including which board a project is on; this page reads its table and
takes a live row's number from the fleet snapshot, which resolves it through
that same owner.
That is why a card and a row can never disagree about what #7 is, and why the
number a task's own terminal is named after is the same number again.

Every project card is a fixed size, and clicking one opens that project's own
overlay above the board, so the grid never reflows and nothing resizes a card.

The overlay holds everything the card holds plus the three things only it
shows: the project's last five commits, its latest version tag, and its latest
release note.
It replaced the hover reveal the cards used to carry rather than joining it,
because two ways to read the same five commits is the lostness the one-page rule
exists to prevent.

An open overlay survives a refresh, so a watch running behind it cannot take
the panel away mid-sentence.

That overlay reaches nothing.
Every word in it is baked into the page when the command runs, read from the
local checkout exactly like the cards, so a release note this clone does not
carry reads as absent rather than being looked up - a request per project would
wreck the watch and break the read-only promise.
The generator's header owns which sources a release note comes from and why a
tag's own annotation is not one of them.

The two version facts are shown independently because they genuinely disagree:
a project's newest release note and its newest local tag are separate records,
and forcing them to agree would have to hide one.
A `fm-task/*` tag is never shown as a version - that is firstmate's own
bookkeeping, and presenting one as the captain's release would mislead him.

## Live work

Each row leads with the captain's number for that work, in the same reading the
project cards use, so he can say it back without reading a name.
One row per running task, ranked so whatever wants the captain is at the top: a
failure first, then a blocker, a decision he owes, and work finished and waiting
to be approved.
Only those four wear the loud "waiting on you" treatment, because a badge that
also fires on ambiguity stops meaning anything.
Below them sit a run at its own review gate, a declared external wait, a task he
personally has the conn on, and ordinary work with nothing owed.

A task appears on the board its project is on, so a board shows the work on the
projects it shows and nothing else.
A task whose project is not registered at all stays on the work board rather
than disappearing from every board.

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

Those two are deliberately not the same: a command he ran himself always
rewrites the page, and a watch cycle rewrites it only when the board changed.
The generator's header owns that asymmetry and the reason for it.

## Which projects are on this board

A project is on the work board unless its `data/projects.md` entry marks it onto
another one, so this board is also the fallback: an unmarked project shows up
here.
`+personal` in a project's annotation bracket moves it to
`/dashboard-personal`; `bin/fm-project-mode.sh`'s header owns that line's
format and `bin/fm-task-number-lib.sh` reads the marker, because a board and
its numbers are one decision.

Moving a project between boards is that one-line registry edit and it is the
captain's call - never reassign a project's board on your own.
Because unmarked means work, a marker that is missing or misspelled leaves a
project visible here rather than on no board at all: if he reports a project
missing from both boards, suspect its registry line before the page.

## When something looks unavailable

A project whose resolved clone path does not exist, or is not a git checkout,
renders as a muted card with the reason - it is a signal that registry state
needs attention, not silently dropped.
This is expected for a stale or not-yet-cloned registry entry; do not treat it
as a failure.
