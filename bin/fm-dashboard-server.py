#!/usr/bin/env python3
"""fm-dashboard-server.py - local HTTP server for the /dashboard board.

Usage: fm-dashboard-server.py <port> <directory>

Serves <directory> as plain static files (like `python3 -m http.server`) for
every GET/HEAD request - the ordinary read-only dashboard page and its
assets. Bound to 127.0.0.1 only by its caller (bin/fm-dashboard-serve.sh),
and threaded, so one stalled or idle connection cannot wedge the board.

The one addition: a POST to /run with a JSON body {"name": "<project name>"}
launches that project's registered run script in a local tmux session named
exactly "dashboard", in a window named after the project with its working
directory set to the project's own path. When that session does not exist yet,
it is created detached already carrying that first window, so a Run never
leaves a stray bare-shell window behind. If a window with the project's name
is still live (an earlier run still going, or one the captain is watching),
Run never kills or replaces it - real work in a tmux window is never destroyed
from here - it just selects that window by its tmux window id so it comes to
focus, and creates nothing new.

A successful POST /run says which of its two outcomes happened:
{"ok": true, "action": "launched"} when it started the run script, and
{"ok": true, "action": "focused"} when the project's run was already going and
it only brought that window to focus. The two are never collapsed - "Started"
for a click that started nothing would be a lie.

"Live" is decided per pane, not by name: under `remain-on-exit` tmux keeps a
finished run's window around with a dead pane, and a dead pane is not a run.
Matching on the name alone would focus that corpse and answer "started"
forever while the script never ran again. So a window whose panes are all dead
counts as no live run and Run starts a fresh one - without touching the dead
window, whose scrollback is the finished run's output. tmux lets two windows
share a name, so that output survives beside the new run.

Because the server is threaded, launches are serialized under one lock: the
look-for-an-existing-window and create-it steps are a single check-then-act on
shared tmux state, so two clicks arriving together can neither both miss the
same window and duplicate it nor collide creating the session.

Every tmux target here is either this session's own scope ("=dashboard:") or
a tmux-assigned window id ("@N"), never an interpolated "session:window"
string, because a window name containing "." or ":" parses as a pane/window
suffix rather than as the name.

Both halves of "=dashboard:" earn their place. Without the "=", tmux
prefix-matches session names and the target can land in an unrelated session
like "dashboard-notes". Without the trailing ":", tmux resolves a -t argument
as a window target first and only falls back to reading it as a session name,
so a window named "dashboard" anywhere it searches wins that race - and then
list-panes reports that foreign session's panes and new-window tries to reuse
that window's index ("index in use"). The colon forces the
"<session>:<current window>" parse, which keeps the exact-session match while
never matching a window name.

POST /run is closed to other pages the captain has open, though not to local
non-browser clients, which send neither header and are served: it requires an
"application/json" content type, which a cross-origin page cannot set without
a preflight this server answers 501 to, and it rejects any request whose
Sec-Fetch-Site or Origin does name a different origin, which is what catches a
same-origin-looking DNS rebind. So no cross-origin page can reach it, and
curl on the captain's own machine still can.

The request body carries only a project name, never a path or command. The
name is resolved against the fm-dashboard-snapshot.v1 payload embedded in
<directory>/index.html - the same trusted data bin/fm-dashboard-snapshot.sh
already read from data/projects.md - and a name that is not a known
registered project, or one that is not runnable right now, is rejected with
400 rather than launched from the wrong working directory or reported as
started when there was nothing to run. _run_script_error is the single owner
of "is this run script runnable": absent, not absolute, not a file, and not
executable are all rejected there, because tmux resolves a relative command
against the project directory it is given while this server would resolve it
against its own cwd, and tmux exits 0 either way.

Neither value that reaches tmux is client-supplied text: the project name is
passed as a tmux window name, a single argv element tmux never re-parses, and
the run script is a path the snapshot registered. The run script is still
shell text, though - tmux hands a one-argument shell-command to "/bin/sh -c" -
so _launch quotes it once for that shell. Unquoted, a valid path carrying a
shell metacharacter ("/home/x/proj/run(1).sh") passes every check above and is
then rejected by sh with a syntax error that tmux reports as success: the
window closes and Run says "Started" with nothing running.
"""
import http.server
import json
import os
import re
import shlex
import subprocess
import sys
import threading

DATA_SLOT_RE = re.compile(
    r'<script id="dashboard-data" type="application/json">\s*(.*?)\s*</script>',
    re.S,
)
SESSION = "dashboard"
SESSION_TARGET = "=" + SESSION + ":"
LAUNCH_LOCK = threading.Lock()
# A tmux client blocks forever on a socket whose server is alive but wedged
# (SIGSTOPed or thrashing): connect() succeeds and the read never returns.
# Every tmux call below runs while LAUNCH_LOCK is held, so an unbounded one
# would strand the lock and leave every later Run stuck on "..." for good.
TMUX_TIMEOUT = 10


class Handler(http.server.SimpleHTTPRequestHandler):
    allowed_origins = ()

    def do_POST(self):
        if self.path != "/run":
            self.send_error(404)
            return

        cross_site = self._cross_site_reason()
        if cross_site is not None:
            self._respond_json(403, {"error": cross_site})
            return

        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length) if length else b""
            payload = json.loads(body)
            name = payload["name"]
            if not isinstance(name, str) or not name:
                raise ValueError("name must be a non-empty string")
        except Exception as exc:  # noqa: BLE001 - reported to the client, not raised
            self._respond_json(400, {"error": "bad request: %s" % exc})
            return

        project = self._find_project(name)
        if project is None:
            self._respond_json(400, {"error": "unknown project: %s" % name})
            return

        run_script = project.get("run_script")
        run_script_error = self._run_script_error(name, run_script)
        if run_script_error is not None:
            self._respond_json(400, {"error": run_script_error})
            return

        path = project.get("path")
        if not path:
            self._respond_json(400, {"error": "project has no registered path: %s" % name})
            return
        if not os.path.isdir(path):
            self._respond_json(400, {"error": "project path is not a directory: %s" % path})
            return

        try:
            action = self._launch(name, path, run_script)
        except Exception as exc:  # noqa: BLE001 - reported to the client, not raised
            self._respond_json(500, {"error": "launch failed: %s" % exc})
            return
        self._respond_json(200, {"ok": True, "action": action})

    def _run_script_error(self, name, run_script):
        if not run_script:
            return "project has no registered run script: %s" % name
        if not os.path.isabs(run_script):
            return "project run script is not an absolute path: %s" % run_script
        if not os.path.isfile(run_script) or not os.access(run_script, os.X_OK):
            return "project run script is not an executable file: %s" % run_script
        return None

    def _cross_site_reason(self):
        content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if content_type != "application/json":
            return "expected a JSON content type, got: %s" % (content_type or "none")
        fetch_site = self.headers.get("Sec-Fetch-Site")
        if fetch_site is not None and fetch_site != "same-origin":
            return "cross-site request refused"
        origin = self.headers.get("Origin")
        if origin is not None and origin not in self.allowed_origins:
            return "cross-origin request refused"
        return None

    def _find_project(self, name):
        try:
            with open(self.translate_path("/index.html"), "r", encoding="utf-8") as f:
                html = f.read()
        except OSError:
            return None
        match = DATA_SLOT_RE.search(html)
        if not match:
            return None
        try:
            data = json.loads(match.group(1))
        except ValueError:
            return None
        for project in data.get("projects", []):
            if project.get("name") == name:
                return project
        return None

    def _launch(self, name, path, run_script):
        command = shlex.quote(run_script)
        with LAUNCH_LOCK:
            # One call answers both questions: it exits non-zero for a
            # missing session or a missing tmux server, and -s reports every
            # pane in the session with the window it belongs to, so a
            # window's panes can be checked for life rather than trusting
            # its name.
            existing = subprocess.run(
                ["tmux", "list-panes", "-s", "-t", SESSION_TARGET,
                 "-F", "#{window_id}\t#{window_name}\t#{pane_dead}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                text=True,
                timeout=TMUX_TIMEOUT,
            )
            if existing.returncode != 0:
                subprocess.run(
                    ["tmux", "new-session", "-d", "-s", SESSION,
                     "-n", name, "-c", path, command],
                    check=True,
                    timeout=TMUX_TIMEOUT,
                )
                return "launched"
            # tmux allows more than one window with the same name in a
            # session - it does not reuse or refuse on a name collision, it
            # just adds another. Run must never kill or replace a window: it
            # may be real, currently-running work the captain is watching.
            # So when this project's run is still live, just select it
            # (bring it to focus) and create nothing new. Any pane still
            # alive counts as live - something is still running in there.
            live_window = None
            for line in existing.stdout.splitlines():
                fields = line.split("\t")
                if len(fields) != 3:
                    continue
                window_id, window_name, pane_dead = fields
                if window_name == name and pane_dead != "1":
                    live_window = window_id
                    break
            if live_window is not None:
                subprocess.run(
                    ["tmux", "select-window", "-t", live_window],
                    check=True,
                    timeout=TMUX_TIMEOUT,
                )
                return "focused"
            subprocess.run(
                ["tmux", "new-window", "-t", SESSION_TARGET, "-n", name, "-c", path, command],
                check=True,
                timeout=TMUX_TIMEOUT,
            )
            return "launched"

    def _respond_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # noqa: A002 - matches base class signature
        pass


def main():
    port = int(sys.argv[1])
    directory = sys.argv[2]

    class BoundHandler(Handler):
        allowed_origins = (
            "http://127.0.0.1:%d" % port,
            "http://localhost:%d" % port,
        )

        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

    with http.server.ThreadingHTTPServer(("127.0.0.1", port), BoundHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
