---
name: dashboard-personal
description: >-
  Generate the captain's personal board: the same read-only page as /dashboard,
  showing only the projects he keeps on the personal board.
  Use when the captain invokes /dashboard-personal or asks for the board, page,
  or status of his personal or side projects as distinct from his work.
user-invocable: true
metadata:
  internal: true
---

# dashboard-personal

`/dashboard-personal` is the personal half of `/dashboard`, not a second board
with a life of its own.
Run the same generator with the personal board selected:

```
bin/fm-dashboard.mjs --group personal
```

Then give the captain the `open:` line it prints, exactly as `/dashboard` does.
His own shell command for this board is `dashboard personal`, which the
[`dashboard` skill](../dashboard/SKILL.md) owns along with everything else about
keeping a board current.

Everything else is that skill's: read the internal
[`dashboard` skill](../dashboard/SKILL.md) for what the page shows, the watch,
the design intent, and how unavailable projects render.
It applies here unchanged, because this is the same generator, the same
template, and the same page written to its own path.
`bin/fm-dashboard.mjs`'s header owns the arguments, the board table, and the
read-only contract.

## Why this is a separate command and not a separate board

The captain's personal projects and his work are separate parts of his life and
he reads them at separate times, so each board is a page he can hold whole.
That is the ONLY reason there are two.
They are one page's worth of code: `--group` picks which projects a board takes,
and the board table in the generator's header is where a board is defined.
Never fork the generator or the template to change one board - a forked page
means every later change has to be made twice, and the two drift the first time
it is made once.

## Which projects are on this board

Board membership is registry state, not a list in this skill or in the
generator: a project is on this board when its `data/projects.md` entry carries
`+personal` in its annotation bracket, beside the registered delivery posture.
Moving a project between boards is that one-line edit, and it is the captain's
call - never reassign a project's board on your own.

An unmarked project is a work project, so a marker that is missing or misspelled
leaves a project on `/dashboard` where he can still see it.
That direction is deliberate: if he reports a project missing from BOTH boards,
suspect the marker on its registry line rather than the page.
