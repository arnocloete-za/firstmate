#!/usr/bin/env node
// fm-dashboard.mjs - generate the /dashboard board as one static HTML file.
//
// The dashboard is a read-only display surface: it shows every registered
// project's git health beside the work running right now, and it does nothing
// else. There is no server, no endpoint, no button, and no path from the page
// back to the fleet - re-running this command IS the refresh, and --watch is
// only this command re-running itself until stopped. Node because
// firstmate already requires it (bin/fm-bootstrap.sh's COMMON_TOOLS), it needs
// no jq/python subprocess per field, and it runs every git read concurrently.
//
// Usage:
//   fm-dashboard.mjs [--fleet-json <file>] [--out <path>] [--open]
//                    [--watch [--interval <seconds>]]
//     --fleet-json <file>  project this already-captured `fm-fleet-snapshot.sh
//                          --json` output instead of running it again. The
//                          fleet read dominates this command's wall clock, so
//                          pass a capture back in when you already have one.
//                          Under --watch it is re-read every cycle.
//     --out <path>         write the page here instead of
//                          $FM_HOME/.dashboard/index.html
//     --open               also hand the page to the desktop opener
//     --watch              keep the page current until stopped (see below)
//     --interval <seconds> seconds BETWEEN watch cycles; default 30, floor 5,
//                          and rejected without --watch rather than ignored
//     -h, --help           usage
//
// Prints the written path and its file:// URL on stdout.
//
// Watch mode
// ----------
// --watch re-reads the fleet every interval until the captain stops it, and
// still adds no server, no endpoint, and no path from the page back to the
// fleet. The page's only new job is to notice that this command rewrote it.
//
// The wait runs BETWEEN cycles, so cycles can never overlap or pile up however
// slow a read is. Ctrl-C (SIGINT, SIGTERM, or SIGHUP) stops the loop, kills the
// reads it started, starts no more, removes any staged temporary file, and
// exits: no orphan process, no lock, and never a half-written page, because
// every publish is a staged write plus a rename. A pass interrupted mid-read
// publishes nothing at all, so a stop can never leave the board reporting things
// as missing that were only unread.
//
// A cycle rewrites the page only when the board's own content changed. The
// comparison is a hash over the rendered page with every per-run stamp
// neutralized, carried in the page as <meta name="fm-dashboard-content">, so an
// unchanged fleet leaves the file - and the captain's scroll position - alone.
//
// How the open page notices, and why it cannot lie about its age: each cycle
// also publishes one tiny sibling script, <page>.watch.js, carrying that content
// hash, the instant of the read, and whether the watch is still running. The
// page re-loads that one file every few seconds and reloads itself only when the
// hash it carries differs from its own - never on a timer, and never backwards,
// because a stamp older than the page it is offered to is ignored. Scroll
// position rides across the reload in window.name, which needs no storage
// permission a file:// page may not have.
// The sidecar is therefore also the ONLY evidence the page has that the watch is
// alive, and that evidence expires. Every stamp says when the next one is owed,
// measured against what that pass actually cost, and "watching" is only ever
// shown before that moment - so a watch that is killed, or a sidecar that never
// loads at all, lapses to "the watch has stopped" on its own. The read instant
// likewise only moves forward and only from a stamp, so the age keeps climbing
// and, past ten minutes, still says plainly not to trust the page, exactly as it
// does with no watch at all. A clean stop publishes one last stamp saying it is
// over, so the page reports it within seconds rather than waiting out that
// expiry.
//
// Read-only: every git call is status/log/for-each-ref/symbolic-ref, and the
// fleet read is bin/fm-fleet-snapshot.sh, the canonical structured fleet reader
// ("Human views must render this output instead of parsing state files again").
// This command never fetches, pulls, commits, steers, tears down, or merges.
//
// Project ordering is REGISTRY ORDER, and the number on each card is that
// project's registry position. The captain reads these numbers aloud, so a
// number must not move when a project's status changes - that is why the board
// does not sort worst-first, and why attention shows as color instead.
//
// Default-branch resolution and terminal presence are not decided here: both
// shell out to their owners, fm_default_branch() in bin/fm-tangle-lib.sh and
// fm_backend_agent_state() in bin/fm-backend.sh.
//
// Path resolution: data/projects.md has no structured path field (its format is
// owned by bin/fm-project-mode.sh's header). A project registered under the
// default layout lives at $FM_HOME/projects/<name>; for one registered outside
// it, this script reads the literal phrase "clone kept in place at <PATH>" from
// the registry description. That phrase is this script's own read-only reading
// convention, written by hand by a captain who keeps a clone out of layout.
//
// FM_ROOT_OVERRIDE / FM_HOME / FM_DATA_OVERRIDE follow the same override
// contract as the rest of bin/ (tests only).

import { execFile } from 'node:child_process';
import { mkdir, readFile, writeFile, rename, unlink } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { basename, dirname, join, resolve } from 'node:path';

// Every read this command starts is tracked, so a watch that is stopped takes
// its own children down with it rather than leaving them behind - and once it is
// stopping it starts no new ones, so an interrupted pass unwinds instead of
// replacing the reads that were just killed.
const children = new Set();
let stopping = false;
function run(command, args, options) {
  if (stopping) return Promise.reject(new Error('the watch is stopping'));
  return new Promise((settle, reject) => {
    const child = execFile(command, args, options, (error, stdout, stderr) => {
      children.delete(child);
      if (error) reject(error);
      else settle({ stdout, stderr });
    });
    children.add(child);
  });
}

const BIN = dirname(fileURLToPath(import.meta.url));
const FM_ROOT = process.env.FM_ROOT_OVERRIDE || resolve(BIN, '..');
const FM_HOME = process.env.FM_HOME || FM_ROOT;
const DATA = process.env.FM_DATA_OVERRIDE || join(FM_HOME, 'data');
const REGISTRY = join(DATA, 'projects.md');

function usage() {
  const src = process.argv[1];
  return readFile(src, 'utf8').then((text) => {
    const out = [];
    for (const line of text.split('\n').slice(1)) {
      if (!line.startsWith('//')) break;
      out.push(line.replace(/^\/\/ ?/, ''));
    }
    return out.join('\n');
  });
}

function die(msg) {
  process.stderr.write(`fm-dashboard: ${msg}\n`);
  process.exit(1);
}

// --- arguments -------------------------------------------------------------
// The floor exists so no typo can turn the watch into a spin; the default is
// well clear of what one cycle costs on a real fleet, where the fleet read
// alone is seconds of work.
const DEFAULT_INTERVAL = 30;
const MIN_INTERVAL = 5;

const opts = {
  fleetJson: null, out: null, open: false, watch: false, interval: DEFAULT_INTERVAL,
};
let intervalGiven = false;
for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === '--fleet-json' || arg === '--out') {
    const value = process.argv[i + 1];
    if (value === undefined) die(`${arg} requires a value`);
    if (arg === '--fleet-json') opts.fleetJson = value;
    else opts.out = value;
    i += 1;
  } else if (arg === '--interval') {
    const value = process.argv[i + 1];
    if (value === undefined) die('--interval requires a value');
    if (!/^[0-9]+$/.test(value) || Number(value) < MIN_INTERVAL) {
      die(`--interval must be a whole number of seconds, ${MIN_INTERVAL} or more`);
    }
    opts.interval = Number(value);
    intervalGiven = true;
    i += 1;
  } else if (arg === '--watch') {
    opts.watch = true;
  } else if (arg === '--open') {
    opts.open = true;
  } else if (arg === '-h' || arg === '--help') {
    process.stdout.write(`${await usage()}\n`);
    process.exit(0);
  } else {
    process.stderr.write(`${await usage()}\n`);
    process.exit(2);
  }
}
// An interval with no watch behind it does nothing, so say so rather than
// letting the captain believe he set a cadence.
if (intervalGiven && !opts.watch) die('--interval means nothing without --watch');

// The page and, under --watch, the one sibling file it reads to notice a
// change. The sidecar is named after the page so two boards written to
// different paths can never read each other's stamp.
const out = opts.out ? resolve(opts.out) : join(FM_HOME, '.dashboard', 'index.html');
const stampPath = `${out}.watch.js`;
const stampName = basename(stampPath);

// --- small helpers ---------------------------------------------------------
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
));

// A value inlined into a <script> block: JSON with '<' escaped, so no filename
// or stamp can end the script element early.
const js = (value) => JSON.stringify(value).replace(/</g, '\\u003c');

// classes/lines: drop the empty entries, so no element carries a dangling class
// attribute and no optional block leaves a blank line in the page.
const classes = (...names) => names.filter(Boolean).join(' ');
const lines = (...parts) => parts.filter(Boolean).join('\n    ');

async function git(cwd, args) {
  const { stdout } = await run('git', ['-C', cwd, ...args], { maxBuffer: 1 << 22 });
  return stdout;
}

// Every git read is allowed to fail on its own without taking the board down.
const gitOrNull = (cwd, args) => git(cwd, args).then((out) => out, () => null);

// bashFn <lib> <fn> <arg...>: call one existing bash helper as its own owner
// rather than reimplementing its rule here. Arguments are passed positionally,
// never interpolated into the shell text.
async function bashFn(lib, fn, ...args) {
  const script = `. "$1"; shift; ${fn} "$@"`;
  const { stdout } = await run('bash', ['-c', script, '_', join(BIN, lib), ...args]);
  return stdout.trim();
}
const bashFnOrEmpty = (lib, fn, ...args) => bashFn(lib, fn, ...args).then((v) => v, () => '');

// The captain reads this page, so the generation stamp is his own local clock.
function localStamp(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} `
    + `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function ago(iso) {
  if (!iso) return '';
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return '';
  const mins = Math.round((Date.now() - then) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}

const withinDays = (iso, days) => {
  const then = Date.parse(iso || '');
  return !Number.isNaN(then) && (Date.now() - then) < days * 86400000;
};

// --- 1. the registry -------------------------------------------------------
async function readRegistry() {
  let text;
  try {
    text = await readFile(REGISTRY, 'utf8');
  } catch {
    return [];
  }
  const projects = [];
  for (const line of text.split('\n')) {
    if (!line.startsWith('- ')) continue;
    const name = line.slice(2).trim().split(/\s+/)[0];
    if (!name) continue;
    const embedded = /clone kept in place at ([^ ;)]+)/.exec(line);
    projects.push({ name, path: embedded ? embedded[1] : join(FM_HOME, 'projects', name) });
  }
  return projects;
}

// --- 2. per-project git health (all projects concurrently) -----------------
async function projectHealth({ name, path }) {
  const base = { name, path };
  if (!existsSync(path) || !(await gitOrNull(path, ['rev-parse', '--is-inside-work-tree']))) {
    return { ...base, available: false, reason: 'no git checkout at this path' };
  }
  const [status, head, defaultBranch, log] = await Promise.all([
    gitOrNull(path, ['status', '--porcelain']),
    gitOrNull(path, ['symbolic-ref', '--quiet', '--short', 'HEAD']),
    bashFnOrEmpty('fm-tangle-lib.sh', 'fm_default_branch', path),
    gitOrNull(path, ['log', '-n', '5', '--format=%h%x1f%ad%x1f%an%x1f%s', '--date=iso-strict']),
  ]);
  const short = head ? null : await gitOrNull(path, ['rev-parse', '--short', 'HEAD']);
  const branch = head ? head.trim() : `detached@${(short || 'unknown').trim()}`;
  const commits = (log || '').split('\n').filter(Boolean).map((row) => {
    const [hash, date, author, ...rest] = row.split('\x1f');
    return { hash, date, author, subject: rest.join('\x1f') };
  });
  return {
    ...base,
    available: true,
    clean: (status || '').trim() === '',
    branch,
    defaultBranch: defaultBranch || null,
    onDefault: defaultBranch ? branch === defaultBranch : null,
    commits,
  };
}

// --- 3. the work running right now -----------------------------------------
// A view-specific projection over the canonical fleet snapshot: it renames,
// classifies, and translates fields that reader already decided, and derives no
// current state, backlog role, or captain actionability of its own.
const RANKS = {
  failed: 0, blocked: 1, decision: 2, review: 3, unclear: 4, gate: 5, external: 6, conn: 7, none: 8,
};
const LABELS = {
  failed: 'Failed',
  blocked: 'Blocked - needs you',
  decision: 'Needs your decision',
  review: 'Ready for your review',
  unclear: 'Unclear - worth a look',
  gate: 'In its own review',
  external: 'Waiting on something outside',
  conn: 'You have the conn',
  none: 'Nothing owed',
};
const PRESENCE_NOTES = {
  live: 'a worker is in this terminal',
  idle: 'the terminal is open but no worker is in it',
  gone: 'this terminal no longer exists',
  unclear: 'cannot tell what is in this terminal',
  remote: 'this work runs on another machine',
  unknown: 'terminal state unknown',
};

function activityOf(task) {
  const state = task.current_state?.state || 'unknown';
  const detail = task.current_state?.detail || '';
  if (task.conn?.held) return 'You are working in this terminal';
  if (state === 'working') {
    if (/^ci running/.test(detail)) return 'Running its checks';
    if (/validating \(fixing\)/.test(detail)) return 'Fixing what its review found';
    if (/validating|^run active/.test(detail)) return 'Checking its own work';
    if (/harness busy/.test(detail)) return 'Working';
    return detail || 'Working';
  }
  if (state === 'parked') {
    return /ask-user/.test(detail)
      ? 'Stopped for a decision it cannot make itself'
      : 'Stopped at a review point in its own checks';
  }
  if (state === 'paused') return 'Idling on a wait it expects to clear';
  if (state === 'blocked') return 'Stopped and needs help';
  if (state === 'failed') return 'Its work failed';
  if (state === 'done') {
    if (/merged|closed/.test(detail)) return 'Finished and landed';
    if (/checks green|ready for review/.test(detail)) return 'Finished, checks passed';
    return 'Finished';
  }
  return 'Could not read what it is doing';
}

function waitingKindOf(task) {
  const state = task.current_state?.state || 'unknown';
  const decisions = task.hints?.open_decisions || [];
  const owesDecision = decisions.length > 0
    || task.hints?.pending_decision === true
    || task.backlog?.captain_actionable === true
    || task.backlog?.hold_kind === 'captain'
    || (state === 'parked' && /ask-user/.test(task.current_state?.detail || ''));
  if (task.conn?.held) return 'conn';
  if (state === 'failed') return 'failed';
  if (state === 'blocked' || task.hints?.blocked_event === true) return 'blocked';
  if (owesDecision) return 'decision';
  if (state === 'done') return 'review';
  if (state === 'parked') return 'gate';
  if (state === 'paused') return 'external';
  if (state === 'working') return 'none';
  return 'unclear';
}

// The captain-facing reason he is wanted. A captain hold reason is a sentence
// firstmate already wrote FOR him, so it beats any label composed here; raw
// current-state detail is evidence, never captain-facing prose.
function waitingNoteOf(task) {
  const decisions = task.hints?.open_decisions || [];
  if (task.backlog?.hold_reason) return task.backlog.hold_reason;
  if (task.backlog?.blocked_reason) return task.backlog.blocked_reason;
  if (decisions.length > 0) return decisions.map(String).join('; ');
  if (task.current_state?.state === 'parked' && /ask-user/.test(task.current_state?.detail || '')) {
    return 'Its own review raised a call it is not allowed to make.';
  }
  if (task.backlog?.captain_actionable === true) return 'This work is held for you.';
  return '';
}

// Presence comes from fm_backend_agent_state, the recovery-grade endpoint
// contract, not the snapshot's cheap endpoint.exists: a board that offers a way
// into a terminal has to be right about whether that terminal is still there.
async function presenceOf(task) {
  if (task.remote !== null && task.remote !== undefined) return 'remote';
  const target = task.endpoint?.target;
  if (!target) return 'unknown';
  const verdict = await bashFnOrEmpty('fm-backend.sh', 'fm_backend_agent_state', task.backend || '', target);
  return { alive: 'live', dead: 'idle', missing: 'gone', ambiguous: 'unclear' }[verdict] || 'unknown';
}

// `attach` then `switch-client` covers both places the captain can be standing,
// and both fail loudly on a window that is gone, so a presence read that goes
// stale by seconds can never silently send him nowhere. A terminal already known
// to be gone gets no command at all - a jump known to fail is worse than saying
// the terminal is gone. See docs/verification/runtime-backends.md.
function jumpCommand(task, presence) {
  if (task.backend !== 'tmux') return null;
  const target = task.endpoint?.target;
  if (!target || ['remote', 'unknown', 'gone'].includes(presence)) return null;
  return `tmux attach -t '${target}' 2>/dev/null || tmux switch-client -t '${target}'`;
}

async function liveWork() {
  let raw;
  try {
    raw = opts.fleetJson
      ? await readFile(opts.fleetJson, 'utf8')
      : (await run(join(BIN, 'fm-fleet-snapshot.sh'), ['--json'],
        { maxBuffer: 1 << 26, env: { ...process.env, FM_HOME } })).stdout;
  } catch {
    return { available: false, reason: 'the fleet read did not complete', tasks: [] };
  }
  let fleet;
  try {
    fleet = JSON.parse(raw);
  } catch {
    return { available: false, reason: 'the fleet read did not return a readable snapshot', tasks: [] };
  }
  if (!Array.isArray(fleet?.tasks)) {
    return { available: false, reason: 'the fleet read did not return a readable snapshot', tasks: [] };
  }
  const tasks = await Promise.all(fleet.tasks.map(async (task) => {
    const kind = waitingKindOf(task);
    const presence = await presenceOf(task);
    return {
      id: task.id,
      project: task.backlog?.repo || task.project?.split('/').filter(Boolean).pop() || 'unregistered',
      title: task.backlog?.title || null,
      activity: activityOf(task),
      waiting: {
        kind,
        label: LABELS[kind],
        note: waitingNoteOf(task),
        wantsCaptain: RANKS[kind] <= 3,
      },
      terminal: {
        presence,
        presenceNote: PRESENCE_NOTES[presence],
        command: jumpCommand(task, presence),
      },
      prUrl: task.pr?.url || null,
      rank: RANKS[kind],
    };
  }));
  tasks.sort((a, b) => a.rank - b.rank || a.id.localeCompare(b.id));
  return { available: true, observedAt: fleet.generated || null, tasks };
}

// --- 4. the page -----------------------------------------------------------
const STYLE = `
:root {
  color-scheme: light;
  --bg-page: #f9f9f7; --bg-surface: #fcfcfb; --bg-raised: #fff;
  --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #898781;
  --border: rgba(11,11,11,.10); --border-strong: #c3c2b7;
  --good: #0ca30c; --critical: #d03b3b; --critical-soft: #fbe8e8;
  --warning: #a8710a; --warning-soft: #fbeed2; --info: #2f6fb5; --info-soft: #e2f0ff;
  --font-sans: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  --font-mono: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    color-scheme: dark;
    --bg-page: #0d0d0d; --bg-surface: #1a1a19; --bg-raised: #212120;
    --text-primary: #fff; --text-secondary: #c3c2b7; --text-muted: #898781;
    --border: rgba(255,255,255,.10); --border-strong: #383835;
    --critical: #e66767; --critical-soft: #3a1414;
    --warning: #d9a441; --warning-soft: #362a10; --info: #6fa8e0; --info-soft: #16283d;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg-page); color: var(--text-primary);
  font-family: var(--font-sans); font-size: 14px; line-height: 1.45;
}
main { max-width: 1200px; margin: 0 auto; padding: 24px 20px 48px; }
header.page-head {
  display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between;
  gap: 8px 24px; padding-bottom: 16px; border-bottom: 1px solid var(--border-strong); margin-bottom: 20px;
}
h1 { font-size: 1.15rem; font-weight: 700; margin: 0; }
h2 { font-size: .95rem; font-weight: 700; margin: 0 0 10px; }
.section { margin-bottom: 28px; }
.meta, .summary { font-family: var(--font-mono); font-size: .8rem; color: var(--text-muted); }
.summary { margin-bottom: 10px; }
.summary b { color: var(--text-primary); font-variant-numeric: tabular-nums; }
.stale { color: var(--critical); font-weight: 700; }

/* Live work: one row per running task. */
.row {
  display: grid; grid-template-columns: 1fr auto; gap: 4px 16px; align-items: start;
  background: var(--bg-surface); border: 1px solid var(--border);
  border-left: 4px solid var(--border-strong); border-radius: 6px;
  padding: 10px 14px; margin-bottom: 8px;
}
.row.wants { border-left-color: var(--critical); background: var(--critical-soft); }
.row.conn { border-left-color: var(--info); background: var(--info-soft); }
.row-project { font-weight: 700; }
.row-id { font-family: var(--font-mono); font-size: .78rem; color: var(--text-muted); }
.row-activity { color: var(--text-secondary); }
.row-note { color: var(--text-secondary); font-size: .88rem; }
.row-right { text-align: right; display: grid; gap: 4px; justify-items: end; }
.badge {
  font-size: .72rem; font-weight: 700; text-transform: uppercase; letter-spacing: .04em;
  padding: 2px 7px; border-radius: 3px; border: 1px solid var(--border-strong); color: var(--text-secondary);
  white-space: nowrap;
}
.badge.wants { background: var(--critical); border-color: var(--critical); color: #fff; }
.badge.conn { background: var(--info); border-color: var(--info); color: #fff; }
.presence { font-size: .76rem; color: var(--text-muted); }
button.copy {
  font-family: var(--font-mono); font-size: .74rem; cursor: pointer;
  background: var(--bg-raised); color: var(--text-secondary);
  border: 1px solid var(--border-strong); border-radius: 3px; padding: 2px 7px;
}
button.copy:hover { color: var(--text-primary); }
a { color: var(--info); }

/* Projects: fixed-size numbered cards in registry order - the number is the
   captain's handle for the project, so nothing about the grid may move it. */
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 12px; }
.card {
  position: relative; height: 132px; overflow: visible;
  background: var(--bg-surface); border: 1px solid var(--border);
  border-left: 4px solid var(--good); border-radius: 6px; padding: 10px 12px;
}
.card.uncommitted { border-left-color: var(--critical); }
.card.off-default { border-left-color: var(--warning); }
.card.unavailable { border-left-color: var(--text-muted); opacity: .72; }
.card-head { display: grid; grid-template-columns: auto 1fr; gap: 8px; align-items: baseline; }
.num {
  font-family: var(--font-mono); font-size: .95rem; font-weight: 700;
  color: var(--text-muted); font-variant-numeric: tabular-nums;
}
.proj-name { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chips { display: flex; flex-wrap: wrap; gap: 4px; margin: 6px 0; }
.chip {
  font-family: var(--font-mono); font-size: .72rem; padding: 1px 6px; border-radius: 3px;
  border: 1px solid var(--border-strong); color: var(--text-secondary); background: var(--bg-raised);
}
.chip.clean { color: var(--good); }
.chip.uncommitted { color: var(--critical); background: var(--critical-soft); border-color: var(--critical); }
.chip.off-default { color: var(--warning); background: var(--warning-soft); border-color: var(--warning); }
.commit { font-size: .82rem; color: var(--text-secondary); }
.commit .when { font-family: var(--font-mono); }
.commit.recent .when { color: var(--text-primary); font-weight: 700; }
.commit .subject { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.reason { font-size: .82rem; color: var(--text-muted); }

/* The last five commits appear on hover, in an overlay - the card itself never
   changes size, so the grid cannot reflow under the cursor. */
.history {
  display: none; position: absolute; left: -1px; right: -1px; top: 100%; z-index: 5;
  background: var(--bg-raised); border: 1px solid var(--border-strong); border-radius: 6px;
  padding: 8px 12px; box-shadow: 0 6px 18px rgba(0,0,0,.18);
}
.card:hover .history, .card:focus-within .history { display: block; }
.history li { font-size: .78rem; color: var(--text-secondary); margin-bottom: 3px; }
.history ol { margin: 0; padding-left: 0; list-style: none; }
.history .hash { font-family: var(--font-mono); color: var(--text-muted); }
.empty { color: var(--text-muted); font-style: italic; }
`;

// The page is generated when the command runs; there is no feed behind it. Live
// work ages far faster than git health, so the live section states its own age,
// keeps recomputing it, and past ten minutes says plainly not to trust it.
//
// readAt only ever moves forward, and only a watch stamp moves it, so nothing
// here can make an old page look young.
const SCRIPT = `
const el = document.getElementById('live-age');
let readAt = el ? Date.parse(el.dataset.at) : NaN;
let watched = false;
let dueBy = 0;
const setReadAt = (iso) => { const t = Date.parse(iso); if (t > readAt) readAt = t; };
const tick = () => {
  if (!el || Number.isNaN(readAt)) return;
  const age = Date.now() - readAt;
  const mins = Math.floor(age / 60000);
  let text = mins < 1 ? 'read just now' : 'read ' + mins + 'm ago';
  if (watched) {
    text += Date.now() <= dueBy ? ' \\u00b7 watching' : ' \\u00b7 the watch has stopped';
  }
  const stale = mins >= 10;
  if (stale) text += ' - too old to walk into a terminal on; re-run /dashboard';
  el.classList.toggle('stale', stale);
  el.textContent = text;
};
tick();
setInterval(tick, 30000);
for (const button of document.querySelectorAll('button.copy')) {
  button.addEventListener('click', () => {
    navigator.clipboard.writeText(button.dataset.command).then(() => {
      button.textContent = 'copied';
      setTimeout(() => { button.textContent = 'copy terminal command'; }, 1500);
    });
  });
}
`;

// Added only to a page a watch wrote. It reads one sibling file the same watch
// rewrites and reloads the page only when that file reports different content -
// never on a timer, and never from a stamp older than this page, so a leftover
// stamp can never start a reload loop.
//
// "Watching" is a claim with an expiry the watch itself sets and every stamp
// renews. A watch that is killed renews nothing, so the claim lapses on its own;
// a sidecar that never loads at all lapses the same way. Nothing here can keep
// saying watching because a watch used to be running.
const STAMP_POLL_MS = 5000;
const watchScript = ({ renderedAt, contentHash, dueBy }) => `
watched = true;
dueBy = Date.parse(${js(dueBy)});
(() => {
  const SRC = ${js(stampName)};
  const MINE = ${js(contentHash)};
  const RENDERED = Date.parse(${js(renderedAt)});
  const KEY = 'fm-dashboard-scroll:';
  // window.name survives a reload in the same tab and needs no storage
  // permission, which a file:// page does not reliably have.
  try {
    if (typeof window.name === 'string' && window.name.indexOf(KEY) === 0) {
      const y = Number(window.name.slice(KEY.length));
      window.name = '';
      if (Number.isFinite(y)) {
        if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
        window.scrollTo(0, y);
      }
    }
  } catch (error) { /* a tab that will not hold a note still shows the board */ }
  window.fmDashboardStamp = (stamp) => {
    if (!stamp || typeof stamp.readAt !== 'string') return;
    const alive = stamp.watching !== false;
    dueBy = alive ? Math.max(dueBy, Date.parse(stamp.dueBy)) : 0;
    setReadAt(stamp.readAt);
    tick();
    if (!alive || stamp.content === MINE) return;
    if (!(Date.parse(stamp.readAt) > RENDERED)) return;
    try { window.name = KEY + String(window.scrollY); } catch (error) { /* keep the reload */ }
    location.reload();
  };
  const poll = () => {
    const tag = document.createElement('script');
    tag.src = SRC + '?t=' + Date.now();
    tag.onload = tag.onerror = () => tag.remove();
    document.head.appendChild(tag);
  };
  setInterval(() => { poll(); tick(); }, ${STAMP_POLL_MS});
  poll();
})();
`;

// The sidecar itself: one call, guarded so a page with no watch pickup in it
// cannot be broken by a stamp left over from an earlier run.
const stampFile = (stamp) => `if (window.fmDashboardStamp) window.fmDashboardStamp(${js(stamp)});\n`;

function renderLive(live, observedAt) {
  if (!live.available) {
    return `<div class="empty">Could not read the work running now: ${esc(live.reason)}</div>`;
  }
  if (live.tasks.length === 0) return '<div class="empty">No work running.</div>';
  const wants = live.tasks.filter((t) => t.waiting.wantsCaptain).length;
  const summary = `<div class="summary"><b>${live.tasks.length}</b> running`
    + (wants ? ` · <b>${wants}</b> waiting on you` : '')
    + ` · <span id="live-age" data-at="${esc(observedAt)}"></span></div>`;
  const rows = live.tasks.map((task) => {
    const flag = task.waiting.kind === 'conn' ? 'conn' : (task.waiting.wantsCaptain ? 'wants' : '');
    return `<div class="${classes('row', flag)}">
  <div>
    ${lines(
    `<div><span class="row-project">${esc(task.project)}</span> <span class="row-id">${esc(task.id)}</span></div>`,
    `<div class="row-activity">${esc(task.activity)}</div>`,
    task.waiting.note && `<div class="row-note">${esc(task.waiting.note)}</div>`,
    task.prUrl && `<div class="row-note"><a href="${esc(task.prUrl)}">${esc(task.prUrl)}</a></div>`,
  )}
  </div>
  <div class="row-right">
    ${lines(
    `<span class="${classes('badge', flag)}">${esc(task.waiting.label)}</span>`,
    `<span class="presence">${esc(task.terminal.presenceNote)}</span>`,
    task.terminal.command
      && `<button class="copy" data-command="${esc(task.terminal.command)}">copy terminal command</button>`,
  )}
  </div>
</div>`;
  }).join('\n');
  return `${summary}\n${rows}`;
}

function renderProjects(projects) {
  if (projects.length === 0) return '<div class="empty">No projects registered.</div>';
  const uncommitted = projects.filter((p) => p.available && !p.clean).length;
  const offDefault = projects.filter((p) => p.available && p.onDefault === false).length;
  const unavailable = projects.filter((p) => !p.available).length;
  const summary = `<div class="summary"><b>${projects.length}</b> projects`
    + ` · <b>${uncommitted}</b> uncommitted · <b>${offDefault}</b> off default branch`
    + (unavailable ? ` · <b>${unavailable}</b> unavailable` : '') + '</div>';
  const cards = projects.map((project, index) => {
    const num = String(index + 1).padStart(2, '0');
    if (!project.available) {
      return `<div class="card unavailable">
  <div class="card-head"><span class="num">${num}</span><span class="proj-name">${esc(project.name)}</span></div>
  <div class="reason">${esc(project.reason)}</div>
  <div class="reason">${esc(project.path)}</div>
</div>`;
    }
    const flag = !project.clean ? 'uncommitted' : (project.onDefault === false ? 'off-default' : '');
    const last = project.commits[0];
    const chips = [
      project.clean
        ? '<span class="chip clean">clean</span>'
        : '<span class="chip uncommitted">uncommitted</span>',
      `<span class="${classes('chip', project.onDefault === false && 'off-default')}">${esc(project.branch)}</span>`,
    ].join('');
    const commit = last
      ? `<div class="${classes('commit', withinDays(last.date, 7) && 'recent')}">
    <span class="when">${esc(ago(last.date))}</span> · ${esc(last.author)}
    <span class="subject">${esc(last.subject)}</span>
  </div>`
      : '<div class="reason">no commits</div>';
    const history = project.commits.length > 1
      ? `<div class="history"><ol>${project.commits.map((c) => (
        `<li><span class="hash">${esc(c.hash)} ${esc(ago(c.date))}</span> ${esc(c.subject)}</li>`
      )).join('')}</ol></div>`
      : '';
    return `<div class="${classes('card', flag)}" tabindex="0">
  <div class="card-head"><span class="num">${num}</span><span class="proj-name">${esc(project.name)}</span></div>
  <div class="chips">${chips}</div>
  ${lines(commit, history)}
</div>`;
  }).join('\n');
  return `${summary}\n<div class="grid">\n${cards}\n</div>`;
}

function page({ projects, live, generatedAt, observedAt, renderedAt, contentHash, dueBy }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="fm-dashboard-content" content="${esc(contentHash)}" />
<title>Fleet Dashboard</title>
<style>${STYLE}</style>
</head>
<body>
<main>
<header class="page-head">
  <h1>Fleet dashboard</h1>
  <span class="meta">generated ${esc(generatedAt)} · re-run /dashboard to refresh</span>
</header>
<section class="section">
  <h2>Live work</h2>
  ${renderLive(live, observedAt)}
</section>
<section class="section">
  <h2>Projects</h2>
  ${renderProjects(projects)}
</section>
</main>
<script>${SCRIPT}${opts.watch ? watchScript({ renderedAt, contentHash, dueBy }) : ''}</script>
</body>
</html>
`;
}

// --- 5. generate -----------------------------------------------------------
// Every file this command publishes carries fleet state - PR links, what each
// task is waiting on - so it stays private to the captain, staged under its own
// name and published by rename so a half-written file is never what the browser
// picks up.
const staged = new Set();
async function publish(path, text) {
  const tmp = `${path}.${process.pid}.tmp`;
  staged.add(tmp);
  try {
    await writeFile(tmp, text, { mode: 0o600 });
    await rename(tmp, path);
  } finally {
    staged.delete(tmp);
    await unlink(tmp).catch(() => {});
  }
}

const CONTENT_META = /<meta name="fm-dashboard-content" content="([^"]*)"/;
let lastStamp = null;

// One pass: read everything, publish the page only if the board changed, and
// under --watch publish the stamp every time, because the stamp is what proves
// to the open page that this command is still reading.
async function cycle() {
  const started = Date.now();
  const registry = await readRegistry();
  // The fleet read dominates the wall clock, so it runs alongside every
  // project's git reads rather than after them.
  const [projects, live] = await Promise.all([
    Promise.all(registry.map(projectHealth)),
    liveWork(),
  ]);
  // Reads killed by a stop would render a board full of things that are only
  // missing because the watch was interrupted, so an interrupted pass publishes
  // nothing and the last good page stands.
  if (stopping) return false;
  const now = new Date();
  const readAt = now.toISOString();
  // When the next stamp is owed, measured against what this pass actually
  // cost rather than a guess, so the page's "watching" claim expires on this
  // watch's real cadence however slow the fleet is to read.
  const dueBy = new Date(
    now.getTime() + opts.interval * 1000 + Math.max((Date.now() - started) * 2, 5000),
  ).toISOString();
  const render = (stamps) => page({ projects, live, ...stamps });
  const contentHash = createHash('sha1')
    .update(render({
      generatedAt: '-', observedAt: '-', renderedAt: '-', contentHash: '-', dueBy: '-',
    }))
    .digest('hex')
    .slice(0, 16);

  await mkdir(dirname(out), { recursive: true, mode: 0o700 });
  const existing = await readFile(out, 'utf8').catch(() => null);
  const changed = CONTENT_META.exec(existing || '')?.[1] !== contentHash;
  if (changed) {
    await publish(out, render({
      generatedAt: localStamp(now),
      observedAt: live.observedAt || readAt,
      renderedAt: readAt,
      contentHash,
      dueBy,
    }));
  }
  lastStamp = { content: contentHash, readAt, dueBy };
  if (opts.watch) await publish(stampPath, stampFile({ ...lastStamp, watching: true }));
  return changed;
}

const url = pathToFileURL(out).href;
async function openPage() {
  const opener = process.platform === 'darwin' ? 'open' : 'xdg-open';
  await run(opener, [url]).catch(() => {});
}

if (!opts.watch) {
  try {
    await cycle();
  } catch (error) {
    die(`cannot write the dashboard: ${error.message}`);
  }
  process.stdout.write(`dashboard: ${out}\n`);
  process.stdout.write(`open: ${url}\n`);
  if (opts.open) await openPage();
} else {
  // --- 6. watch ------------------------------------------------------------
  const SIGNALS = ['SIGINT', 'SIGTERM', 'SIGHUP'];
  let wake = () => {};
  const sleep = (ms) => new Promise((done) => {
    const timer = setTimeout(done, ms);
    wake = () => { clearTimeout(timer); done(); };
  });

  // Stopping never races a publish: a cycle awaits its own write, so killing
  // the reads it started can only cut the reading short, never the writing.
  function requestStop() {
    if (stopping) process.exit(130);
    stopping = true;
    for (const child of children) child.kill('SIGTERM');
    wake();
  }
  for (const signal of SIGNALS) process.on(signal, requestStop);

  // The link is only handed over once a pass has actually published the page,
  // so it never points at a file that is not there yet.
  let announced = false;
  while (!stopping) {
    let changed = false;
    let passed = true;
    try {
      changed = await cycle();
    } catch (error) {
      // A pass that fails is this pass only; the page stands as last written
      // and keeps aging honestly until one succeeds.
      passed = false;
      if (!stopping) process.stderr.write(`fm-dashboard: this pass did not finish: ${error.message}\n`);
    }
    if (stopping) break;
    if (!announced && passed) {
      announced = true;
      process.stdout.write(`dashboard: ${out}\n`);
      process.stdout.write(`open: ${url}\n`);
      process.stdout.write(
        `watching: re-reading the fleet every ${opts.interval}s - press Ctrl-C to stop\n`,
      );
      if (opts.open) await openPage();
    } else if (changed) {
      process.stdout.write(`updated: ${localStamp(new Date())}\n`);
    }
    await sleep(opts.interval * 1000);
  }

  for (const signal of SIGNALS) process.removeListener(signal, requestStop);
  for (const tmp of staged) await unlink(tmp).catch(() => {});
  // Tell the open page the watch is over, so it says so within seconds instead
  // of waiting for the last stamp's expiry to pass.
  if (lastStamp) {
    await publish(stampPath, stampFile({ ...lastStamp, watching: false })).catch(() => {});
  }
  process.stdout.write('stopped: the page stays as last written and shows its age climbing\n');
}
