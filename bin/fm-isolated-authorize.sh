#!/usr/bin/env bash
# Record - or withdraw - the captain's say-so that ONE piece of ship work may run
# in a disposable copy of one of his OWN registered projects.
#
# Ship work on a registered project runs in that project's directory, on a branch
# the captain can see. bin/fm-project-branch-lib.sh owns that rule and the
# refusals that enforce it; this script writes the only thing that lifts it.
#
# It is a separate, deliberate act rather than a flag on the dispatch because a
# flag is exactly the walk-around the rule exists to close: it would live in
# whichever agent chose it, and firstmate inferring that the captain "would have
# wanted" a disposable copy is the failure this whole path was built to prevent.
# So the say-so has to be on disk, has to name the piece of work and the project
# it covers, and has to carry his own words for the next session to read.
#
# The grant covers ONE task and ONE project. It is not standing authority, does
# not carry to another task, and disappears with the task at cleanup.
#
# Usage: fm-isolated-authorize.sh grant <task-id> <project-name> --captain "<his words>"
#        fm-isolated-authorize.sh revoke <task-id>
#        fm-isolated-authorize.sh show <task-id>
#
# grant writes state/<task-id>.isolated-authorized and refuses to overwrite a
# grant that already names a different project, so a record cannot be quietly
# widened; revoke that one first if the captain really moved the work.
# show prints the record, or exits 1 when there is none.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-project-branch-lib.sh
. "$SCRIPT_DIR/fm-project-branch-lib.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: fm-isolated-authorize.sh grant <task-id> <project-name> --captain "<his words>"
       fm-isolated-authorize.sh revoke <task-id>
       fm-isolated-authorize.sh show <task-id>

Records the captain's own say-so that ONE piece of ship work may run in a
disposable copy of one of his registered projects. Read this file's header for
why it is a separate act rather than a flag on the dispatch.
USAGE
  exit 1
}

ACTION=${1:-}
[ -n "$ACTION" ] || usage
shift || true

case "$ACTION" in
  grant|revoke|show) ;;
  *) usage ;;
esac

ID=${1:-}
[ -n "$ID" ] || usage
case "$ID" in
  */* | .. | . | -*) echo "error: '$ID' is not a usable task id" >&2; exit 1 ;;
esac
shift

RECORD=$(fm_project_branch_isolation_record "$STATE" "$ID")

if [ "$ACTION" = show ]; then
  [ "$#" -eq 0 ] || usage
  if [ ! -f "$RECORD" ] || [ -L "$RECORD" ]; then
    echo "no recorded say-so for $ID; ship work on a registered project runs in the captain's own copy" >&2
    exit 1
  fi
  cat "$RECORD"
  exit 0
fi

if [ "$ACTION" = revoke ]; then
  [ "$#" -eq 0 ] || usage
  rm -f -- "$RECORD"
  echo "revoked: $ID has no recorded say-so to run in a throwaway copy"
  exit 0
fi

PROJECT=${1:-}
[ -n "$PROJECT" ] || usage
shift
case "$PROJECT" in
  */* | -*) echo "error: '$PROJECT' is not a project name; pass the name the captain registered, not a path" >&2; exit 1 ;;
esac

CAPTAIN=
CAPTAIN_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --captain)
      shift
      [ "$#" -gt 0 ] || usage
      CAPTAIN=$1
      CAPTAIN_SET=1
      shift
      ;;
    *) usage ;;
  esac
done

# His words are the whole point of the record: without them the next session
# cannot tell an authorization apart from an assumption.
if [ "$CAPTAIN_SET" -eq 0 ] || [ -z "$(printf '%s' "$CAPTAIN" | tr -d '[:space:]')" ]; then
  echo "error: --captain \"<his words>\" is required; a grant with nothing he said is an assumption, not authority" >&2
  exit 1
fi
# One record, one line per field, so a multi-line quote cannot forge a field.
CAPTAIN=$(printf '%s' "$CAPTAIN" | tr '\n\r\t' '   ')

"$FM_ROOT/bin/fm-project-mode.sh" --registered "$PROJECT" >/dev/null 2>&1 || {
  echo "warning: $PROJECT is not in the project registry, so no grant was needed; recording it anyway in case it is registered later" >&2
}

[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }

EXISTING=$(fm_project_branch_isolation_authorized_project "$STATE" "$ID")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$PROJECT" ]; then
  echo "error: $ID already has the captain's say-so for $EXISTING; revoke that before recording one for $PROJECT" >&2
  exit 1
fi

TMP="$STATE/.$ID.isolated-authorized.${BASHPID:-$$}"
{
  printf 'task=%s\n' "$ID"
  printf 'project=%s\n' "$PROJECT"
  printf 'granted=%s\n' "$(date +%s)"
  printf 'captain=%s\n' "$CAPTAIN"
} > "$TMP" || { rm -f -- "$TMP"; echo "error: could not write the captain's say-so for $ID" >&2; exit 1; }
mv "$TMP" "$RECORD" || { rm -f -- "$TMP"; echo "error: could not publish the captain's say-so for $ID" >&2; exit 1; }

echo "recorded: $ID may run in a throwaway copy of $PROJECT, on the captain's own words"
