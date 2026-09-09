# `/dashboard` watch-mode browser verification

Audience: maintainer verification.

This record supports the active guarantee that a `bin/fm-dashboard.mjs --watch` page picks up new content on its own, and stops claiming to be current when the watch stops.
`bin/fm-dashboard.mjs`'s header owns the watch contract; the internal [`dashboard` skill](../../.agents/skills/dashboard/SKILL.md) owns when to offer it.

The page-side half is browser behavior, so a stub proves nothing about it: whether a `file://` page may load a sibling script, whether a cache-busting query defeats the file cache, whether a reload restores a scroll position, and whether a `<dialog>` reopened during a fresh load is really modal are all decided by the browser, not by this repository.
`tests/fm-dashboard.test.sh` is the portable regression and pins everything the command publishes - change-only republication, the sidecar and its expiry, the stop path, and that a stopped watch leaves nothing staged.
The checks below are the ones only a browser can answer.

Verified on 2026-09-07 with Google Chrome 151.0.7922.169 on Linux, driven through `chrome-devtools-axi`.
The page under test was published by `--watch --interval 5` over a fourteen-project registry and one running task, opened as a `file://` URL, with the viewport at 1100x700 so the board actually scrolled.

`chrome-devtools-axi` itself needs Node 20.11 or newer (it uses `import.meta.dirname`).
Under this machine's default Node 18 every subcommand fails with `The "paths[0]" argument must be of type string. Received undefined`, which is a tooling floor rather than a browser result.

## A `file://` page loads its sibling stamp, and a query does not defeat it

```
$ chrome-devtools-axi eval "({ stampFn: typeof window.fmDashboardStamp, age: document.getElementById('live-age').textContent })"
result: "{\"stampFn\":\"function\",\"age\":\"read just now · watching\"}"
```

`watching` is rendered only from a stamp that arrived, so this output is also proof that the injected script element - the sidecar's own name with a cache-busting query appended - was fetched from disk and executed.

## An unchanged board does not reload the page

A probe was planted on the window and the page left alone for three watch intervals with no change to the fleet.
A reload would have discarded it.

```
$ chrome-devtools-axi eval "() => { window.scrollTo(0, 900); window.__probe = 'alive'; return { y: window.scrollY, probe: window.__probe }; }"
result: "{\"y\":387,\"probe\":\"alive\"}"
# ... 16s, nothing changed ...
$ chrome-devtools-axi eval "({ probe: window.__probe || 'GONE', y: window.scrollY, age: document.getElementById('live-age').textContent })"
result: "{\"probe\":\"alive\",\"y\":387,\"age\":\"read just now · watching\"}"
```

The age stayed current while the page was not reloaded, which is the pairing that matters: the stamp kept arriving, the page kept believing it, and nothing was disturbed.

## A changed board reloads the page and keeps the scroll position

With the page still at the maximum scroll offset from the check above, one commit was made in a registered project.

```
$ git -C <fixture>/proj7 commit -q --allow-empty -m "XRAY the newest commit"
# ... 12s ...
$ chrome-devtools-axi eval "({ probe: window.__probe || 'GONE', y: window.scrollY, hasNew: document.body.innerHTML.indexOf('XRAY the newest commit') !== -1 })"
result: "{\"probe\":\"GONE\",\"y\":387,\"hasNew\":true}"
```

The probe is gone, so the page really did reload; the new commit is on it; and the scroll offset came back exactly.

## A watch that is killed cannot leave the page claiming to be current

The watch was killed with `SIGKILL`, so it published no closing stamp and the page had only the expiry its last stamp carried.
That interval was 5 seconds over a sub-second pass, so the next stamp was owed 10 seconds after the read, and the page polls every 5.

```
$ kill -9 <watch pid>
$ chrome-devtools-axi eval "document.getElementById('live-age').textContent"   # t+6s
result: "\"read just now · watching\""
$ chrome-devtools-axi eval "document.getElementById('live-age').textContent"   # t+10s
result: "\"read just now · the watch has stopped\""
$ chrome-devtools-axi eval "document.getElementById('live-age').textContent"   # t+14s
result: "\"read just now · the watch has stopped\""
```

A clean `SIGINT` stop is reported faster, because the watch publishes a closing stamp rather than leaving the page to wait the expiry out.

```
$ chrome-devtools-axi eval "document.getElementById('live-age').textContent"   # watch running
result: "\"read just now · watching\""
$ kill -INT <watch pid>
$ chrome-devtools-axi eval "document.getElementById('live-age').textContent"   # 7s later
result: "\"read just now · the watch has stopped\""
```

The pre-existing staleness warning is unchanged on a watched page, and still fires off the read instant rather than off anything the watch left behind:

```
$ chrome-devtools-axi eval "() => { readAt = Date.now() - 11*60000; tick(); const el = document.getElementById('live-age'); return { text: el.textContent, stale: el.classList.contains('stale') }; }"
result: "{\"text\":\"read 11m ago · the watch has stopped - too old to walk into a terminal on; re-run /dashboard\",\"stale\":true}"
```

## An overlay the captain had open survives the reload

Verified on 2026-09-09 with Google Chrome 151.0.7922.169 on Linux, driven through `chrome-devtools-axi`, against a three-project registry published by `--watch --interval 5`.
The board is meant to be left open, so a reload that closed the panel he was reading would make the watch worse than no watch.
A project card was clicked, then a commit was made in a DIFFERENT project so the board genuinely changed underneath the open overlay.

```
$ chrome-devtools-axi click @g19:1_14           # the spock card
$ git -C <fixture>/morpheus commit -aqm "a brand new commit while the captain reads spock"
# ... 13s, one republication ...
$ chrome-devtools-axi eval "() => { const d = document.querySelector('dialog.detail[open]'); return { openProject: d ? d.dataset.project : null, newCommitOnBoard: document.body.innerHTML.includes('a brand new commit'), scrollY: window.scrollY }; }"
result: "{\"openProject\":\"spock\",\"newCommitOnBoard\":true,\"scrollY\":0}"
```

The new commit is on the page, so it really did reload, and spock's overlay is open on the page that replaced it.
The overlay is reopened by project NAME, so a board that gained or lost a project cannot reopen the wrong one.

## The clock alone does not reload the page, and the tab keeps its own ages honest

A relative age and the recent-commit highlight are the only things on this page the clock decides, and both are recomputed in the tab out of the absolute instant the markup carries.
That is what lets the command leave the clock out of the hash that decides the board changed - which it must, because a board of ten projects would otherwise be rewritten, and the captain's overlay thrown away, most cycles.

With the watch still running and the fleet unchanged, the page file was left alone across an age rollover while the tab was read:

```
$ grep -o 'class="ago" data-at="[^"]*">[^<]*' <fixture>/board.html | head -2
class="ago" data-at="2026-09-09T11:10:59+02:00">1m ago
class="ago" data-at="2026-09-09T11:10:59+02:00">1m ago
$ chrome-devtools-axi eval "() => { const s=[...document.querySelectorAll('span.ago')].map(n=>n.textContent); const d=document.querySelector('dialog.detail[open]'); return {painted:[...new Set(s)], stillOpen: d?d.dataset.project:null}; }"
result: "{\"painted\":[\"3m ago\",\"2m ago\"],\"stillOpen\":\"spock\"}"
```

The file on disk still says `1m ago` and its inode never changed, so nothing rewrote it; the tab is showing `2m ago` and `3m ago`; and the overlay from the previous check is still open through all of it.

## Refreshing this record

Re-run the checks above against a current Chrome after any change to the page-side pickup, to the sidecar's fields, to what the page carries across a reload, or to how an age is rendered.
The command half needs no browser and is covered by `bash tests/fm-dashboard.test.sh`.
