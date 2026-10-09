#!/bin/bash
# project-map SessionStart hook (INTERFACES-3.2 section 5.0 / 5.1). Mechanical only: no model call.
# Prints nothing and exits 0 when there is no map. Always exits 0.
export PYTHONDONTWRITEBYTECODE=1
PLUGIN="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
[ -n "$PLUGIN" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

IN=$(head -c 65536)
CWD=$(printf '%s' "$IN" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"
[ -d "$CWD" ] || exit 0
CWD=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
HOME_R=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)

# 5.0 ROOT: git toplevel of cwd, else cwd; toplevel == HOME -> cwd; cwd == HOME -> no ROOT.
[ -n "$HOME_R" ] && [ "$CWD" = "$HOME_R" ] && exit 0
TOP=$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_git;print(pm_git.toplevel(sys.argv[2]) or "")' "$PLUGIN/scripts" "$CWD" 2>/dev/null | head -n 1)
ROOT="$CWD"
if [ -n "$TOP" ] && [ -d "$TOP" ]; then
  TOP=$(cd "$TOP" 2>/dev/null && pwd -P)
  if [ -n "$TOP" ] && [ "$TOP" != "$HOME_R" ]; then ROOT="$TOP"; fi
fi

PM="$ROOT/.project-map"
[ -L "$PM/current" ] || [ -f "$PM/state.json" ] || exit 0

# facts first: it may re-render mechanically and switch `current`
VLINE=$(python3 "$PLUGIN/scripts/project-map-facts.py" "$ROOT" --budget 10 --no-stage 2>/dev/null | head -n 1)

# then pin `current` ONCE and read that generation's files only (INTERFACES 1.4)
GENNAME=""
if [ -L "$PM/current" ]; then
  GEN=""; i=0
  while [ -z "$GEN" ] && [ $i -lt 5 ]; do   # macOS: EINVAL while embed swaps the symlink
    GEN=$(readlink "$PM/current" 2>/dev/null)
    [ -n "$GEN" ] || { i=$((i+1)); sleep 0.05; }
  done
  [ -n "$GEN" ] || GEN="current"
  case "$GEN" in /*) GENDIR="$GEN" ;; *) GENDIR="$PM/$GEN" ;; esac
  GENNAME=$(basename "$GENDIR"); GENNAME=${GENNAME#gen-}
  HAVE_CURRENT=1
elif [ -f "$PM/state.json" ]; then
  GENDIR="$PM"; HAVE_CURRENT=0
else
  GENDIR="$PM/current"; HAVE_CURRENT=1
fi
VLINE=$(printf '%s' "$VLINE" | LC_ALL=C tr -cd '\11\40-\176' | cut -c1-300)
VERDICT=${VLINE%% *}
WHY=""
case "$VLINE" in *" "*) WHY=${VLINE#* } ;; esac
WHY=${WHY% inv *}

emit() { # $1 = context text
  jq -n --arg c "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
}

read_brief() { # prints the brief (no trailing newline) or fails
  python3 - "$GENDIR/brief.txt" "$HAVE_CURRENT" "$GENNAME" <<'PY' 2>/dev/null
import sys
p, cur, gen = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
import time
b = None
for _ in range(5):
    try:
        b = open(p, "rb").read()
        break
    except OSError:
        time.sleep(0.05)
if b is None:
    sys.exit(1)
if not b.strip() or len(b) > 1000:
    sys.exit(1)
t = b.decode("utf-8")
last = [l for l in t.split("\n") if l.strip()][-1]
if cur and last != "generation " + gen:
    sys.exit(1)
sys.stdout.write(t.rstrip("\n"))
PY
}

case "$VERDICT" in
  NO_CHANGE|NEEDS_REFRESH|NEEDS_JUDGEMENT|NEEDS_FULL)
    # verify the pinned generation (sha256 + HMAC of its manifest) before trusting anything in it
    if [ "$HAVE_CURRENT" = 1 ] && ! python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_common;sys.exit(0 if pm_common.verify_generation(sys.argv[2]) else 1)' "$PLUGIN/scripts" "$GENDIR" >/dev/null 2>&1; then
      emit "project-map: map unverified; run /project-map"; exit 0
    fi
    BRIEF=$(read_brief)
    if [ $? -ne 0 ] || [ -z "$BRIEF" ]; then
      emit "project-map: brief unreadable; run /project-map"; exit 0
    fi
    case "$VERDICT" in
      NO_CHANGE|NEEDS_REFRESH)
        emit "$BRIEF"$'\n'"map: $ROOT/.project-map/index.html · /project-map re-judges" ;;
      NEEDS_FULL)
        case "$WHY" in
          migrate*) emit "$BRIEF"$'\n'"map needs migration to 3.2: run /project-map" ;;
          *)        emit "$BRIEF"$'\n'"map is behind: $WHY; run /project-map" ;;
        esac ;;
      *) emit "$BRIEF"$'\n'"map is behind: $WHY; run /project-map" ;;
    esac ;;
  REFRESH_FAILED|ERROR)
    emit "project-map: $VLINE; run /project-map" ;;
  *)
    [ -n "$VLINE" ] || VLINE="facts printed no verdict"
    emit "project-map: $VLINE; run /project-map" ;;
esac
exit 0
