#!/bin/bash
# pm-git.sh ROOT <sub> [flags]: agent-facing read-only git (INTERFACES-3.2 section 7.2).
# Allowed: status | log [-n N<=60] | rev-parse | branch | ls-files [relpath] | tag
# Anything else: stderr "pm-git: not allowed", exit 2. The real work and the final
# validation happen in pm_git.py (hardened core). bash 3.2 compatible.

deny() { echo "pm-git: not allowed" >&2; exit 2; }

[ $# -ge 2 ] || deny
ROOT=$1
SUB=$2
shift 2

case "$ROOT" in /*) ;; *) deny ;; esac
case "$ROOT" in *[[:space:]]*) deny ;; esac
[ -d "$ROOT" ] || deny

case "$SUB" in
  status|rev-parse|branch|tag)
    [ $# -eq 0 ] || deny ;;
  log)
    if [ $# -ne 0 ]; then
      [ $# -eq 2 ] && [ "$1" = "-n" ] || deny
      case "$2" in ''|*[!0-9]*|????*) deny ;; esac
      [ "$2" -ge 1 ] && [ "$2" -le 60 ] || deny
    fi ;;
  ls-files)
    [ $# -le 1 ] || deny ;;
  *) deny ;;
esac

# Resolve this script's real directory (file and directory symlinks).
SRC=$0
while [ -L "$SRC" ]; do
  LINK=$(readlink "$SRC")
  case "$LINK" in /*) SRC=$LINK ;; *) SRC=$(dirname "$SRC")/$LINK ;; esac
done
DIR=$(cd "$(dirname "$SRC")" && pwd -P) || deny

exec python3 -I "$DIR/pm_git.py" --agent "$ROOT" "$SUB" "$@"
