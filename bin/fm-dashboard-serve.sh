#!/usr/bin/env bash
# fm-dashboard-serve.sh - build and serve the /dashboard project-status board.
#
# The dashboard is a read-only, regenerate-on-each-run status page: no captain
# feedback loop, so it is served with a plain local static HTTP server
# (python3 -m http.server) rather than a lavish-axi session - there is nothing
# for a Lavish session's answer-binding machinery to do here.
#
# Usage:
#   fm-dashboard-serve.sh build <data.json>
#   fm-dashboard-serve.sh path
#   fm-dashboard-serve.sh stop
#
# build      Validate <data.json> against the fm-dashboard-snapshot.v1 schema
#            (from bin/fm-dashboard-snapshot.sh) and inject it into a fresh
#            copy of the shipped template
#            (.agents/skills/dashboard/assets/dashboard-template.html) at the
#            stable path $FM_HOME/.dashboard/index.html. Reuses an already-live
#            server for this home when one is running (its content is served
#            straight off disk, so the rebuilt file is picked up on the
#            browser's next request/reload with no restart needed); otherwise
#            binds a fresh python3 static server to 127.0.0.1 on the first
#            free port at or after FM_DASHBOARD_PORT_BASE (default 4590,
#            scanning up to 50 ports) and records its pid/port for reuse.
#            Prints:
#              dashboard: <path>
#              served: http://127.0.0.1:<port>/
# path       Print the stable dashboard directory for this home.
# stop       Stop this home's dashboard server, if one is running.
#
# The server is bound to 127.0.0.1 only, never a wider interface, and this
# script never fetches, pulls, or otherwise mutates any project checkout -
# bin/fm-dashboard-snapshot.sh already gathered every git fact read-only.
#
# FM_DASHBOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

TEMPLATE="${FM_DASHBOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/dashboard/assets/dashboard-template.html}"
PLACEHOLDER='__FM_DASHBOARD_DATA__'
DASHBOARD_SCHEMA=fm-dashboard-snapshot.v1
PORT_BASE="${FM_DASHBOARD_PORT_BASE:-4590}"
PORT_TRIES=50

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-dashboard-serve: %s\n' "$*" >&2
  exit 1
}

dashboard_dir() { printf '%s/.dashboard\n' "$FM_HOME"; }
dashboard_path() { printf '%s/index.html\n' "$(dashboard_dir)"; }
state_file() { printf '%s/state/.dashboard-server\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$DASHBOARD_SCHEMA" '
    .schema == $schema and (.projects | type == "array")
  ' "$1" >/dev/null 2>&1
}

port_free() {  # <port>
  python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
    s.close()
except OSError:
    sys.exit(1)
' "$1"
}

find_free_port() {  # <base>
  local base=$1 port=$1 tries=0
  while [ "$tries" -lt "$PORT_TRIES" ]; do
    if port_free "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
    tries=$((tries + 1))
  done
  fail "no free port found in [$base, $((base + PORT_TRIES - 1))]"
}

# running_dashboard_pid <pid> <port>: true if <pid> is alive and looks like
# the http.server we launched for <port> (best-effort cmdline check; Linux
# /proc only, since a stale/foreign pid on that number is otherwise harmless -
# it just costs one extra port scan).
running_dashboard_pid() {
  local pid=$1 port=$2 cmdline
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmdline" in
      *http.server*"$port"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

read_state() {  # prints "pid port" or nothing
  local f pid="" port=""
  f=$(state_file)
  [ -f "$f" ] || return 0
  # shellcheck disable=SC1090
  . "$f" 2>/dev/null || return 0
  [ -n "$pid" ] && [ -n "$port" ] || return 0
  printf '%s %s\n' "$pid" "$port"
}

write_state() {  # <pid> <port>
  local f dir
  f=$(state_file)
  dir=$(dirname "$f")
  mkdir -p "$dir"
  printf 'pid=%s\nport=%s\n' "$1" "$2" > "$f"
}

start_server() {  # <dir> -> prints port
  local dir=$1 port worker_pid monitor_was_on=0 waited=0 existing pid eport
  existing=$(read_state || true)
  if [ -n "$existing" ]; then
    pid=${existing% *}
    eport=${existing#* }
    if running_dashboard_pid "$pid" "$eport"; then
      printf '%s\n' "$eport"
      return 0
    fi
  fi

  port=$(find_free_port "$PORT_BASE")
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" \
    >/dev/null 2>&1 </dev/null &
  worker_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  while [ "$waited" -lt 20 ]; do
    if ! kill -0 "$worker_pid" 2>/dev/null; then
      fail "dashboard server exited immediately; is port $port already in use by something else?"
    fi
    if ! port_free "$port" 2>/dev/null; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  write_state "$worker_pid" "$port"
  printf '%s\n' "$port"
}

command_build() {
  local data=${1-} board dir json tmp port extracted
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required"
  [ -f "$data" ] || fail "dashboard data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "dashboard data is not valid JSON: $data"
  validate_payload "$data" || fail "dashboard data does not satisfy $DASHBOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "dashboard template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "dashboard template does not carry exactly one data slot: $TEMPLATE"

  json=$(jq -c . "$data") || fail "cannot compact the dashboard data"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  dir=$(dashboard_dir)
  board=$(dashboard_path)
  (umask 077; mkdir -p "$dir") || fail "cannot create $dir"
  tmp=$(umask 077; mktemp "$dir/.index.XXXXXX") || fail "cannot stage the dashboard"
  if ! DASHBOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{DASHBOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the dashboard data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the dashboard data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a page that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="dashboard-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$DASHBOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built dashboard does not carry a readable $DASHBOARD_SCHEMA payload"
  fi
  if ! { chmod 0644 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the dashboard"
  fi
  printf 'dashboard: %s\n' "$board"

  port=$(start_server "$dir")
  printf 'served: http://127.0.0.1:%s/\n' "$port"
}

command_stop() {
  local existing pid port
  existing=$(read_state || true)
  [ -n "$existing" ] || { printf 'not running\n'; return 0; }
  pid=${existing% *}
  port=${existing#* }
  if running_dashboard_pid "$pid" "$port"; then
    kill "$pid" 2>/dev/null || true
    printf 'stopped: pid %s\n' "$pid"
  else
    printf 'not running\n'
  fi
  rm -f -- "$(state_file)"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) dashboard_dir ;;
  stop) command_stop ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
