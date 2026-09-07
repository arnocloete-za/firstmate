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
already exists (an earlier run still going, or one the captain is watching),
Run never kills or replaces it - real work in a tmux window is never destroyed
from here - it just selects that window by its tmux window id so it comes to
focus, and creates nothing new.

Because the server is threaded, launches are serialized under one lock: the
look-for-an-existing-window and create-it steps are a single check-then-act on
shared tmux state, so two clicks arriving together can neither both miss the
same window and duplicate it nor collide creating the session.

Every tmux target here is either an exact session name ("=dashboard") or a
tmux-assigned window id ("@N"), never an interpolated "session:window" string:
tmux prefix-matches bare session names, so a bare "dashboard" target can land
in an unrelated session like "dashboard-notes", and a window name containing
"." or ":" parses as a pane/window suffix rather than as the name.

POST /run only answers same-origin requests from the served page itself. It
requires a JSON content type and rejects any request whose Sec-Fetch-Site or
Origin says it came from somewhere else, so another page the captain has open
cannot use the loopback port to launch a run script behind their back.

The request body carries only a project name, never a path or command. The
name is resolved against the fm-dashboard-snapshot.v1 payload embedded in
<directory>/index.html - the same trusted data bin/fm-dashboard-snapshot.sh
already read from data/projects.md - and a name that is not a known
registered project with a run_script, whose path is not a directory right
now, or whose run script is not an executable file right now, is rejected with
400 rather than launched from the wrong working directory or reported as
started when there was nothing to run. This is the only place a
client-supplied value reaches a subprocess call, and it is always passed as a
tmux window name (a single argv element, never shell text).
"""
import http.server
import json
import os
import re
import subprocess
import sys
import threading

DATA_SLOT_RE = re.compile(
    r'<script id="dashboard-data" type="application/json">\s*(.*?)\s*</script>',
    re.S,
)
SESSION = "dashboard"
SESSION_TARGET = "=" + SESSION
LAUNCH_LOCK = threading.Lock()


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
        path = project.get("path")
        if not run_script or not path:
            self._respond_json(400, {"error": "project has no registered run script: %s" % name})
            return
        if not os.path.isdir(path):
            self._respond_json(400, {"error": "project path is not a directory: %s" % path})
            return
        if not os.path.isfile(run_script) or not os.access(run_script, os.X_OK):
            self._respond_json(
                400,
                {"error": "project run script is not an executable file: %s" % run_script},
            )
            return

        try:
            self._launch(name, path, run_script)
        except Exception as exc:  # noqa: BLE001 - reported to the client, not raised
            self._respond_json(500, {"error": "launch failed: %s" % exc})
            return
        self._respond_json(200, {"ok": True})

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
        with LAUNCH_LOCK:
            # list-windows also answers "does the session exist at all" - it
            # exits non-zero for a missing session or a missing tmux server.
            existing = subprocess.run(
                ["tmux", "list-windows", "-t", SESSION_TARGET, "-F", "#{window_id}\t#{window_name}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                text=True,
            )
            if existing.returncode != 0:
                subprocess.run(
                    ["tmux", "new-session", "-d", "-s", SESSION,
                     "-n", name, "-c", path, run_script],
                    check=True,
                )
                return
            # tmux allows more than one window with the same name in a
            # session - it does not reuse or refuse on a name collision, it
            # just adds another. Run must never kill or replace a window: it
            # may be real, currently-running work the captain is watching.
            # If one with this project's name already exists, just select it
            # (bring it to focus) and create nothing new.
            for line in existing.stdout.splitlines():
                window_id, _, window_name = line.partition("\t")
                if window_name == name:
                    subprocess.run(["tmux", "select-window", "-t", window_id], check=True)
                    return
            subprocess.run(
                ["tmux", "new-window", "-t", SESSION_TARGET, "-n", name, "-c", path, run_script],
                check=True,
            )

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
