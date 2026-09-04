#!/usr/bin/env python3
"""fm-dashboard-server.py - local HTTP server for the /dashboard board.

Usage: fm-dashboard-server.py <port> <directory>

Serves <directory> as plain static files (like `python3 -m http.server`) for
every GET/HEAD request - the ordinary read-only dashboard page and its
assets. Bound to 127.0.0.1 only by its caller (bin/fm-dashboard-serve.sh).

The one addition: a POST to /run with a JSON body {"name": "<project name>"}
launches that project's registered run script in a local tmux session named
"dashboard" (created detached if it does not already exist), in a new window
named after the project with its working directory set to the project's own
path. If a window with that name already exists (an earlier run still going,
or one the captain is watching), Run never kills or replaces it - real work
in a tmux window is never destroyed from here - it just selects that window
so it comes to focus, and creates nothing new.

The request body carries only a project name, never a path or command. The
name is resolved against the fm-dashboard-snapshot.v1 payload embedded in
<directory>/index.html - the same trusted data bin/fm-dashboard-snapshot.sh
already read from data/projects.md - and a name that is not a known
registered project with a run_script is rejected with 400. This is the only
place a client-supplied value reaches a subprocess call, and it is always
passed as a tmux window name (a single argv element, never shell text).
"""
import http.server
import json
import re
import socketserver
import subprocess
import sys

DATA_SLOT_RE = re.compile(
    r'<script id="dashboard-data" type="application/json">\s*(.*?)\s*</script>',
    re.S,
)


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/run":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        try:
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

        try:
            self._launch(name, path, run_script)
        except Exception as exc:  # noqa: BLE001 - reported to the client, not raised
            self._respond_json(500, {"error": "launch failed: %s" % exc})
            return
        self._respond_json(200, {"ok": True})

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
        has_session = subprocess.run(
            ["tmux", "has-session", "-t", "dashboard"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if has_session.returncode != 0:
            subprocess.run(["tmux", "new-session", "-d", "-s", "dashboard"], check=True)
        else:
            # tmux allows more than one window with the same name in a
            # session - it does not reuse or refuse on a name collision, it
            # just adds another. Run must never kill or replace a window: it
            # may be real, currently-running work the captain is watching.
            # If one with this project's name already exists, just select it
            # (bring it to focus) and create nothing new.
            existing = subprocess.run(
                ["tmux", "list-windows", "-t", "dashboard", "-F", "#{window_name}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                text=True,
            )
            if name in existing.stdout.splitlines():
                subprocess.run(
                    ["tmux", "select-window", "-t", "dashboard:%s" % name],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
                return
        subprocess.run(
            ["tmux", "new-window", "-t", "dashboard", "-n", name, "-c", path, run_script],
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
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

    with socketserver.TCPServer(("127.0.0.1", port), BoundHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
