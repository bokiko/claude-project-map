#!/bin/bash
# project-map UserPromptSubmit hook (INTERFACES-3.2 section 5.2). No model call.
# Silent unless the plugin's template/embed changed under a mapped project. Always exits 0.
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
[ -n "$HOME_R" ] && [ "$CWD" = "$HOME_R" ] && exit 0

# Cheapest check first: walk up to find a map is not needed; ROOT rule per 5.0 (git timeout 1 s here
# so the whole hook fits its 5 s timeout together with the 3.5 s embed deadline).
TOP=$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_git;print(pm_git.toplevel(sys.argv[2],timeout=1.0) or "")' "$PLUGIN/scripts" "$CWD" 2>/dev/null | head -n 1)
ROOT="$CWD"
if [ -n "$TOP" ] && [ -d "$TOP" ]; then
  TOP=$(cd "$TOP" 2>/dev/null && pwd -P)
  if [ -n "$TOP" ] && [ "$TOP" != "$HOME_R" ]; then ROOT="$TOP"; fi
fi

PM="$ROOT/.project-map"
[ -L "$PM/current" ] || exit 0

T="$PLUGIN/scripts/project-map-template.html"
E="$PLUGIN/scripts/project-map-embed.py"
[ -f "$T" ] && [ -f "$E" ] || exit 0
TH=$(shasum -a 256 "$T" 2>/dev/null | cut -d' ' -f1)
EH=$(shasum -a 256 "$E" 2>/dev/null | cut -d' ' -f1)
[ -n "$TH" ] && [ -n "$EH" ] || exit 0

CACHE="$PM/cache.json"
# Prints: "<ack template> <ack embed> <seconds since last attempt or -1>"
STATE=$(python3 - "$CACHE" <<'PY' 2>/dev/null
import sys, json, time, datetime
try:
    d = json.load(open(sys.argv[1]))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
a = d.get("ack_hashes")
if not isinstance(a, dict): a = {}
t = str(a.get("template") or "-"); e = str(a.get("embed") or "-")
ago = -1
v = d.get("ack_attempt_at")
try:
    if isinstance(v, (int, float)): ts = float(v)
    else: ts = datetime.datetime.strptime(str(v)[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
    ago = max(0, int(time.time() - ts))
except Exception:
    pass
print(t, e, ago)
PY
)
set -- $STATE
ACK_T="${1:--}"; ACK_E="${2:--}"; AGO="${3:--1}"
[ "$ACK_T" = "$TH" ] && [ "$ACK_E" = "$EH" ] && exit 0
# once per 10 minutes after an unacknowledged attempt
if [ "$AGO" -ge 0 ] 2>/dev/null && [ "$AGO" -lt 600 ]; then exit 0; fi

OUT=$(bash "$PLUGIN/scripts/project-map-embed.sh" "$ROOT" --mechanical --deadline 3.5 2>&1)
LINE=$(printf '%s\n' "$OUT" | grep -E '^(PM_EMBED_|SUPERSEDED)' | tail -n 1)
[ -n "$LINE" ] || LINE=$(printf '%s\n' "$OUT" | grep -v '^$' | tail -n 1)
LINE=$(printf '%s' "$LINE" | LC_ALL=C tr -cd '\11\40-\176' | cut -c1-300)

# read-modify-write cache.json through a temp file + rename; $1 = ok|fail
update_cache() {
  python3 - "$CACHE" "$1" "$TH" "$EH" <<'PY' 2>/dev/null
import sys, os, json, time
p, mode, th, eh = sys.argv[1:5]
try:
    d = json.load(open(p))
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
if mode == "ok":
    d["ack_hashes"] = {"template": th, "embed": eh}
    d.pop("ack_attempt_at", None)
else:
    d["ack_attempt_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
tmp = "%s.tmp.%d" % (p, os.getpid())
try:
    with open(tmp, "w") as f:
        json.dump(d, f, sort_keys=True, allow_nan=False)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, p)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
PY
}

emit() {
  jq -n --arg c "$1" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
}

case "$LINE" in
  PM_EMBED_OK*)
    update_cache ok
    emit "project-map: map re-rendered after a plugin update" ;;
  *)
    update_cache fail
    [ -n "$LINE" ] || LINE="PM_EMBED_ERROR no output"
    emit "project-map: $LINE" ;;
esac
exit 0
