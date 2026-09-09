#!/usr/bin/env bash
# fm-install-dashboard-command.sh - put this home's `dashboard` command on PATH.
#
# Usage:
#   fm-install-dashboard-command.sh            install it, then check it
#   fm-install-dashboard-command.sh --check    report only; change nothing
#   fm-install-dashboard-command.sh --force    also replace a `dashboard` this
#                                              home did not install
#   fm-install-dashboard-command.sh --dir <d>  install into <d> instead of the
#                                              default directory
#
# What it installs is a SYMLINK to bin/fm-dashboard-open.sh in this repository,
# never a copy. A copy would keep working while silently diverging from the
# command this home actually ships, so every self-update would leave the captain
# running an older `dashboard` with no sign of it; a symlink cannot go stale.
#
# Default directory: $XDG_BIN_HOME if set, else ~/.local/bin - the per-user
# directory the platform already expects, so nothing outside the captain's own
# home is touched and no privileged step is needed. The directory is created
# when it does not exist. Being ON PATH is the one thing this script cannot do
# for him: PATH comes from his shell's own startup files, which are his to edit,
# so a directory that is not on PATH is reported with the exact line to add and
# the install is reported as NOT yet usable rather than as done.
#
# It refuses to replace anything it did not install - a hand-written script, or
# a symlink into a different firstmate home - because that file may be what the
# captain is using right now, and because a second home silently taking over
# `dashboard` would point the command at the wrong board. --force is how he
# chooses to replace it, and the refusal names that command.
#
# Exit status:
#   0  installed (or already installed) and usable from a new shell
#   1  could not install
#   3  installed, but its directory is not on PATH, so `dashboard` will not
#      resolve until that is fixed
#   4  something else owns that name; --force is how to replace it
#   5  --check only: nothing is installed there
set -uo pipefail

SELF=${BASH_SOURCE[0]}
BIN=$(CDPATH='' cd -- "$(dirname -- "$SELF")" && pwd -P) || exit 1
ROOT=$(CDPATH='' cd -- "$BIN/.." && pwd -P) || exit 1
TARGET="$ROOT/bin/fm-dashboard-open.sh"
SCRIPT="$BIN/fm-install-dashboard-command.sh"
NAME=dashboard

CHECK=0
FORCE=0
DIR=${XDG_BIN_HOME:-$HOME/.local/bin}

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
  printf 'fm-install-dashboard-command.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '4,12p' "$SCRIPT" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    --dir)
      shift
      DIR=${1:-}
      [ -n "$DIR" ] || die "--dir needs a directory"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift
done

[ -x "$TARGET" ] || die "$TARGET is missing or not executable"
LINK="$DIR/$NAME"

# Resolve a symlink chain to its final path without readlink -f, which older
# macOS does not have.
resolve_link() { # <path>
  local path=$1 hops=0 link
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    link=$(readlink -- "$path") || return 1
    case "$link" in
      /*) path=$link ;;
      *) path=$(dirname -- "$path")/$link ;;
    esac
  done
  printf '%s\n' "$path"
}

# Is <dir> a PATH entry? Compared as resolved directories, so ~/.local/bin
# matches an entry written as $HOME/.local/bin or through a symlinked home.
dir_on_path() { # <dir>
  local want=$1 entry resolved
  local -a entries=()
  want=$(CDPATH='' cd -- "$want" 2>/dev/null && pwd -P) || return 1
  IFS=: read -r -a entries <<< "${PATH:-}"
  for entry in ${entries[@]+"${entries[@]}"}; do
    [ -n "$entry" ] || continue
    resolved=$(CDPATH='' cd -- "$entry" 2>/dev/null && pwd -P) || continue
    [ "$resolved" = "$want" ] && return 0
  done
  return 1
}

path_advice() {
  say "$NAME is installed at $LINK, but $DIR is not on your PATH, so typing $NAME will not find it yet."
  say "Add this line to your shell's startup file (~/.bashrc, ~/.zshrc), then open a new terminal:"
  say ""
  say "  export PATH=\"$DIR:\$PATH\""
}

# What currently occupies the name: ours, another home's, a plain file, or free.
existing_state() {
  local resolved
  if [ -L "$LINK" ]; then
    resolved=$(resolve_link "$LINK") || {
      printf 'broken-link\n'
      return
    }
    if [ ! -e "$resolved" ]; then
      printf 'broken-link\n'
      return
    fi
    if [ "$resolved" = "$TARGET" ]; then
      printf 'ours\n'
    else
      printf 'other-link\t%s\n' "$resolved"
    fi
    return
  fi
  if [ -e "$LINK" ]; then
    printf 'file\n'
    return
  fi
  printf 'absent\n'
}

IFS=$'\t' read -r STATE DETAIL <<< "$(existing_state)"
DETAIL=${DETAIL:-}

if [ "$CHECK" -eq 1 ]; then
  case "$STATE" in
    ours)
      if dir_on_path "$DIR"; then
        say "$NAME is installed at $LINK and runs this home's board."
        exit 0
      fi
      path_advice
      exit 3
      ;;
    other-link)
      warn "$LINK is a link to $DETAIL, which is not this home's board command."
      exit 4
      ;;
    broken-link)
      warn "$LINK is a link that no longer leads anywhere; $NAME will fail until it is replaced."
      exit 4
      ;;
    file)
      warn "$LINK is a file this home did not install."
      exit 4
      ;;
    *)
      say "$NAME is not installed in $DIR."
      exit 5
      ;;
  esac
fi

case "$STATE" in
  ours) : ;;
  absent) : ;;
  *)
    if [ "$FORCE" -ne 1 ]; then
      case "$STATE" in
        other-link) warn "$LINK already points at $DETAIL, another firstmate home's board command." ;;
        broken-link) warn "$LINK is already a link that leads nowhere." ;;
        file) warn "$LINK is already a file - very likely the one you are using right now." ;;
      esac
      warn "Left exactly as it is. Replace it with this home's command by running:"
      warn "  $SCRIPT --force"
      exit 4
    fi
    ;;
esac

mkdir -p "$DIR" || die "cannot create $DIR"
# Stage the link and rename it over the name, so the command is never missing
# for a moment mid-install and a failure leaves the old one standing.
STAGE="$LINK.installing.$$"
rm -f "$STAGE"
ln -s "$TARGET" "$STAGE" || die "cannot create a link in $DIR"
mv -f "$STAGE" "$LINK" || {
  rm -f "$STAGE"
  die "cannot install $LINK"
}

RESOLVED=$(resolve_link "$LINK") || die "installed $LINK but cannot resolve it"
[ "$RESOLVED" = "$TARGET" ] || die "installed $LINK but it resolves to $RESOLVED"

if dir_on_path "$DIR"; then
  say "$NAME is installed at $LINK and runs this home's board."
  say "Open a new terminal, or run it now as $LINK."
  exit 0
fi
path_advice
exit 3
