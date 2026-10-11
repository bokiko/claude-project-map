#!/bin/bash
# Tests for the two session hooks (project-map-session.sh, project-map-prompt.sh), INTERFACES-3.2 sections 5.0-5.2.
# Runs them against STUB facts/embed/pm_git, so the suite does not depend on the real scripts.
#   HOOKS_SCRATCH=<dir>  scratch dir (default: a fresh mktemp -d)
#   HOOKS_DIR=<dir>      directory holding project-map-session.sh and project-map-prompt.sh (default: ../scripts)
# Works under bash 3.2 and 5. Prints "total N pass N fail N".
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCR=${HOOKS_SCRATCH:-$(mktemp -d)}
mkdir -p "$SCR" || exit 1
SCR=$(cd "$SCR" && pwd -P)
HOOKS_DIR=${HOOKS_DIR:-$HERE/scripts}
SESSION="$HOOKS_DIR/project-map-session.sh"
PROMPT="$HOOKS_DIR/project-map-prompt.sh"
[ -f "$SESSION" ] && [ -f "$PROMPT" ] || { echo "hook scripts not found in $HOOKS_DIR"; exit 1; }

PLG="$SCR/plugin"; HOME_T="$SCR/home"; LOG="$SCR/stub.log"
rm -rf "$PLG" "$HOME_T" "$SCR/roots"
mkdir -p "$PLG/scripts" "$HOME_T" "$SCR/roots"

# ---- stubs -------------------------------------------------------------------------------------
cat > "$PLG/scripts/project-map-facts.py" <<'PY'
import os, sys
open(os.environ["STUB_LOG"], "a").write("facts " + " ".join(sys.argv[1:]) + "\n")
sw = os.environ.get("STUB_SWAP")
if sw:  # simulate a mechanical re-render switching `current` while facts runs
    g = os.path.join(sw, "gen-000002-bbbbbbbb"); os.makedirs(g, exist_ok=True)
    open(os.path.join(g, "brief.txt"), "w").write("new · ~/n · phase 1/1 A · ok\nassessment now · 1 commits since\ngeneration 000002-bbbbbbbb\n")
    os.symlink("gen-000002-bbbbbbbb", os.path.join(sw, "current.tmp")); os.replace(os.path.join(sw, "current.tmp"), os.path.join(sw, "current"))
v = os.environ.get("STUB_VERDICT", "")
if v:
    print(v)
sys.exit(int(os.environ.get("STUB_RC", "0")))
PY
cat > "$PLG/scripts/project-map-embed.sh" <<'SH'
#!/bin/bash
echo "embed $*" >> "$STUB_LOG"
[ -n "$STUB_SLEEP" ] && sleep "$STUB_SLEEP"
[ -n "$STUB_EMBED_OUT" ] && printf '%b\n' "$STUB_EMBED_OUT"
exit "${STUB_EMBED_RC:-0}"
SH
cat > "$PLG/scripts/pm_git.py" <<'PY'
import os
def toplevel(path, timeout=3.0):
    p = os.path.realpath(path)
    while True:
        if os.path.exists(os.path.join(p, ".git")):
            return p
        q = os.path.dirname(p)
        if q == p:
            return None
        p = q
PY
cat > "$PLG/scripts/pm_common.py" <<'PY'
import os
def verify_generation(d):
    return os.path.isdir(d) and not os.path.exists(os.path.join(d, "UNVERIFIED"))
PY
echo "<html>template v1</html>" > "$PLG/scripts/project-map-template.html"
echo "# embed v1" > "$PLG/scripts/project-map-embed.py"
cp "$SESSION" "$PLG/scripts/"; cp "$PROMPT" "$PLG/scripts/"

# ---- harness -----------------------------------------------------------------------------------
TOTAL=0; PASS=0; FAIL=0
ok()   { TOTAL=$((TOTAL+1)); if [ "$2" = 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
eq()   { TOTAL=$((TOTAL+1)); if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fi; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

MAXMS=0
# run_hook <session|prompt> <cwd> ; stdout -> OUT, status -> RC, wall ms -> MS
run_hook() {
  local script json t0 t1
  if [ "$1" = session ]; then script="$PLG/scripts/project-map-session.sh"; else script="$PLG/scripts/project-map-prompt.sh"; fi
  json=$(jq -nc --arg c "$2" --arg e "$([ "$1" = session ] && echo SessionStart || echo UserPromptSubmit)" '{session_id:"s1",cwd:$c,hook_event_name:$e}')
  t0=$(now_ms)
  OUT=$(printf '%s' "$json" | env -i PATH="$PATH" HOME="$HOME_T" CLAUDE_PLUGIN_ROOT="$PLG" STUB_LOG="$LOG" \
        STUB_VERDICT="$STUB_VERDICT" STUB_RC="$STUB_RC" STUB_EMBED_OUT="$STUB_EMBED_OUT" STUB_EMBED_RC="$STUB_EMBED_RC" STUB_SLEEP="$STUB_SLEEP" STUB_SWAP="$STUB_SWAP" \
        "$BASH" "$script" 2>/dev/null)
  RC=$?
  t1=$(now_ms); MS=$((t1-t0)); [ "$MS" -gt "$MAXMS" ] && MAXMS=$MS
  CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
}
reset_stub() { STUB_VERDICT=""; STUB_RC=0; STUB_EMBED_OUT=""; STUB_EMBED_RC=0; STUB_SLEEP=""; STUB_SWAP=""; : > "$LOG"; }
calls() { grep -c "^$1" "$LOG"; }

BRIEF='demo · ~/demo · phase 1/3 Setup · ok
assessment 2026-10-08T10:00 · current
All good, nothing needs you.
generation 000001-aaaaaaaa'
mkmap() { # <dir>: 3.2 layout with a valid brief
  mkdir -p "$1/.project-map/gen-000001-aaaaaaaa"
  printf '%s\n' "$BRIEF" > "$1/.project-map/gen-000001-aaaaaaaa/brief.txt"
  ln -s gen-000001-aaaaaaaa "$1/.project-map/current"
  ln -s current/brief.txt "$1/.project-map/brief.txt"
}
newroot() { mkdir -p "$SCR/roots/$1"; (cd "$SCR/roots/$1" && pwd -P); }

# ===== SessionStart ===============================================================================
R=$(newroot s1); mkmap "$R"
EXTRA_OK=$'\n'"map: $R/.project-map/index.html · /project-map re-judges"

reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"
run_hook session "$R"
eq "S NO_CHANGE exit 0" 0 "$RC"
eq "S NO_CHANGE context" "$BRIEF$EXTRA_OK" "$CTX"
eq "S NO_CHANGE event name" SessionStart "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.hookEventName)"
eq "S facts called with ROOT --budget 10 --no-stage" "facts $R --budget 10 --no-stage" "$(head -n 1 "$LOG")"
ok "S NO_CHANGE fast with stubs (<1s)" $([ "$MS" -lt 1000 ] && echo 1 || echo 0)

reset_stub; STUB_VERDICT="NEEDS_REFRESH coverage partial 1/3"
run_hook session "$R"
eq "S NEEDS_REFRESH context" "$BRIEF$EXTRA_OK" "$CTX"

reset_stub; STUB_VERDICT="NEEDS_JUDGEMENT git key moved inv inv-1a2b3c4d"
run_hook session "$R"
eq "S NEEDS_JUDGEMENT context" "$BRIEF"$'\n'"map is behind: git key moved; run /project-map" "$CTX"

reset_stub; STUB_VERDICT="NEEDS_FULL invalid state inv inv-1a2b3c4d"
run_hook session "$R"
eq "S NEEDS_FULL context" "$BRIEF"$'\n'"map is behind: invalid state; run /project-map" "$CTX"

reset_stub; STUB_VERDICT="NEEDS_FULL migrate inv inv-1a2b3c4d"
run_hook session "$R"
eq "S NEEDS_FULL migrate context" "$BRIEF"$'\n'"map needs migration to 3.2: run /project-map" "$CTX"

reset_stub; STUB_VERDICT="REFRESH_FAILED render failed: disk full" STUB_RC=3
run_hook session "$R"
eq "S REFRESH_FAILED context" "project-map: REFRESH_FAILED render failed: disk full; run /project-map" "$CTX"
eq "S REFRESH_FAILED exit 0" 0 "$RC"

reset_stub; STUB_VERDICT="ERROR git collection failure" STUB_RC=2
run_hook session "$R"
eq "S ERROR context" "project-map: ERROR git collection failure; run /project-map" "$CTX"
eq "S ERROR exit 0" 0 "$RC"

# H-deferred (13.4): facts ran out of its budget and did not refresh: the brief on disk is not presented as refreshed
reset_stub; STUB_VERDICT="NEEDS_REFRESH facts incomplete (deferred: budget)"
run_hook session "$R"
eq "H-deferred: NEEDS_REFRESH (deferred: budget) -> the not-refreshed line, no brief" "project-map: facts not refreshed (budget); run /project-map" "$CTX"
eq "H-deferred: ... exit 0" 0 "$RC"
reset_stub; STUB_VERDICT="NEEDS_REFRESH plugin files changed (deferred: budget)"
run_hook session "$R"
eq "H-deferred: any refresh reason carrying the token gets the same line" "project-map: facts not refreshed (budget); run /project-map" "$CTX"
reset_stub; STUB_VERDICT="NEEDS_FULL first map (deferred: budget)"
run_hook session "$R"
eq "H-deferred: NEEDS_FULL (deferred: budget) too" "project-map: facts not refreshed (budget); run /project-map" "$CTX"
reset_stub; STUB_VERDICT="NEEDS_REFRESH coverage partial 1/3 (deferred: budget)"
run_hook session "$R"
eq "H-deferred: ... also after the reason (a partial coverage refresh that was deferred)" "project-map: facts not refreshed (budget); run /project-map" "$CTX"
reset_stub; STUB_VERDICT="NEEDS_REFRESH coverage partial 1/3"
run_hook session "$R"
eq "H-deferred: without the token the brief is injected as before" "$BRIEF$EXTRA_OK" "$CTX"

reset_stub; STUB_VERDICT=""
run_hook session "$R"
eq "S empty verdict context" "project-map: facts printed no verdict; run /project-map" "$CTX"

reset_stub; STUB_VERDICT="SOMETHING_NEW odd"
run_hook session "$R"
eq "S unknown verdict context" "project-map: SOMETHING_NEW odd; run /project-map" "$CTX"

# brief unreadable: missing, empty, oversized, no generation trailer
R2=$(newroot s2); mkmap "$R2"; rm "$R2/.project-map/gen-000001-aaaaaaaa/brief.txt"
reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"
run_hook session "$R2"
eq "S brief missing" "project-map: brief unreadable; run /project-map" "$CTX"
: > "$R2/.project-map/gen-000001-aaaaaaaa/brief.txt"
run_hook session "$R2"
eq "S brief empty" "project-map: brief unreadable; run /project-map" "$CTX"
python3 -c 'print("x"*1200)' > "$R2/.project-map/gen-000001-aaaaaaaa/brief.txt"
run_hook session "$R2"
eq "S brief oversized" "project-map: brief unreadable; run /project-map" "$CTX"
printf 'name · ~/x · phase 1/1 A · ok\nno trailer here\n' > "$R2/.project-map/gen-000001-aaaaaaaa/brief.txt"
run_hook session "$R2"
eq "S brief without generation trailer" "project-map: brief unreadable; run /project-map" "$CTX"
printf '\377\376 bad utf8\ngeneration 000001-aaaaaaaa\n' > "$R2/.project-map/gen-000001-aaaaaaaa/brief.txt"
run_hook session "$R2"
eq "S brief invalid utf-8" "project-map: brief unreadable; run /project-map" "$CTX"
reset_stub; STUB_VERDICT="ERROR git collection failure"
run_hook session "$R2"
eq "S ERROR needs no brief" "project-map: ERROR git collection failure; run /project-map" "$CTX"

# generation trailer must match the pinned generation exactly (no prefix match)
printf 'n · ~/x · phase 1/1 A · ok\ngeneration 000001-aaaaaaaa-extra\n' > "$R2/.project-map/gen-000001-aaaaaaaa/brief.txt"
reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"; run_hook session "$R2"
eq "S trailer longer than generation" "project-map: brief unreadable; run /project-map" "$CTX"
printf 'n · ~/x · phase 1/1 A · ok\ngeneration 000009-ffffffff\n' > "$R2/.project-map/gen-000001-aaaaaaaa/brief.txt"
run_hook session "$R2"
eq "S trailer of another generation" "project-map: brief unreadable; run /project-map" "$CTX"

# facts re-renders (switches current) -> the NEW brief is injected, not the pre-facts one
R7=$(newroot s7); mkmap "$R7"
reset_stub; STUB_VERDICT="NEEDS_REFRESH usage moved"; STUB_SWAP="$R7/.project-map"
run_hook session "$R7"
eq "S brief read after facts re-render" $'new · ~/n · phase 1/1 A · ok\nassessment now · 1 commits since\ngeneration 000002-bbbbbbbb\nmap: '"$R7"'/.project-map/index.html · /project-map re-judges' "$CTX"

# an unverified generation: nothing from the brief is injected
R8=$(newroot s8); mkmap "$R8"; : > "$R8/.project-map/gen-000001-aaaaaaaa/UNVERIFIED"
reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"; run_hook session "$R8"
eq "S unverified generation (NO_CHANGE)" "project-map: map unverified; run /project-map" "$CTX"
STUB_VERDICT="NEEDS_JUDGEMENT git key moved inv inv-1a2b3c4d"; run_hook session "$R8"
eq "S unverified generation (NEEDS_JUDGEMENT)" "project-map: map unverified; run /project-map" "$CTX"
STUB_VERDICT="ERROR git collection failure"; run_hook session "$R8"
eq "S ERROR verdict does not depend on verification" "project-map: ERROR git collection failure; run /project-map" "$CTX"

# brief with JSON-hostile characters is escaped by jq
R3=$(newroot s3); mkmap "$R3"
printf 'q"uote \\ back · ~/x · phase 1/1 A · ok\ntab\there "x"\ngeneration 000001-aaaaaaaa\n' > "$R3/.project-map/gen-000001-aaaaaaaa/brief.txt"
reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"
run_hook session "$R3"
ok "S hostile brief gives valid JSON" $(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)
case "$CTX" in
  'q"uote \ back'*) HOSTILE=1 ;;
  *) HOSTILE=0 ;;
esac
ok "S hostile brief round-trips" "$HOSTILE"

# unmapped: silence, facts never called
R4=$(newroot s4)
reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"
run_hook session "$R4"
eq "S unmapped: no output" "" "$OUT"
eq "S unmapped: exit 0" 0 "$RC"
eq "S unmapped: facts not called" 0 "$(calls facts)"
run_hook session "$SCR/does-not-exist"
eq "S missing cwd: no output" "" "$OUT"; eq "S missing cwd: exit 0" 0 "$RC"

# $HOME: silent even when it holds a map
mkmap "$HOME_T"
reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"
run_hook session "$HOME_T"
eq "S cwd == HOME: no output" "" "$OUT"
eq "S cwd == HOME: facts not called" 0 "$(calls facts)"
rm -rf "$HOME_T/.project-map"

# git toplevel is HOME -> use cwd; git toplevel below HOME -> use it
mkdir -p "$HOME_T/.git" "$HOME_T/sub"; SUB=$(cd "$HOME_T/sub" && pwd -P); mkmap "$SUB"
reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"
run_hook session "$SUB"
eq "S toplevel == HOME falls back to cwd" "$BRIEF"$'\n'"map: $SUB/.project-map/index.html · /project-map re-judges" "$CTX"
rm -rf "$HOME_T/.git" "$HOME_T/sub"

R5=$(newroot s5); mkdir -p "$R5/.git" "$R5/deep/er"; mkmap "$R5"
reset_stub; STUB_VERDICT="NO_CHANGE key unchanged"
run_hook session "$R5/deep/er"
eq "S subdirectory resolves to git toplevel" "$BRIEF"$'\n'"map: $R5/.project-map/index.html · /project-map re-judges" "$CTX"
eq "S facts called with the toplevel" "facts $R5 --budget 10 --no-stage" "$(head -n 1 "$LOG")"

# legacy 3.x map (state.json, no current)
R6=$(newroot s6); mkdir -p "$R6/.project-map"
printf 'old · ~/old · 40%% · watch\nOld headline\n' > "$R6/.project-map/brief.txt"; echo '{}' > "$R6/.project-map/state.json"
reset_stub; STUB_VERDICT="NEEDS_FULL migrate inv inv-0a0a0a0a"
run_hook session "$R6"
eq "S legacy map: migration line" $'old · ~/old · 40% · watch\nOld headline\nmap needs migration to 3.2: run /project-map' "$CTX"
eq "S legacy map: facts called" "facts $R6 --budget 10 --no-stage" "$(head -n 1 "$LOG")"

# ===== UserPromptSubmit ===========================================================================
P=$(newroot p1); mkmap "$P"
TH=$(sha "$PLG/scripts/project-map-template.html"); EH=$(sha "$PLG/scripts/project-map-embed.py")
cache_get() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));v=d
for k in sys.argv[2:]:
    v=v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)' "$P/.project-map/cache.json" "$@"; }

reset_stub; STUB_EMBED_OUT="PM_EMBED_OK gen 000002-bbbbbbbb 41234"
echo '{"watch_cache":{"/x":{"size":1}},"coverage_cursor":7}' > "$P/.project-map/cache.json"
run_hook prompt "$P"
eq "P first prompt: exit 0" 0 "$RC"
eq "P first prompt: message" "project-map: map re-rendered after a plugin update" "$CTX"
eq "P first prompt: event name" UserPromptSubmit "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.hookEventName)"
eq "P embed argv" "embed $P --mechanical --deadline 3.5" "$(head -n 1 "$LOG")"
eq "P acked template hash" "$TH" "$(cache_get ack_hashes template)"
eq "P acked embed hash" "$EH" "$(cache_get ack_hashes embed)"
eq "P other cache keys preserved" "7" "$(cache_get coverage_cursor)"
eq "P watch_cache preserved" "1" "$(cache_get watch_cache /x size)"
eq "P facts never called" 0 "$(calls facts)"
ok "P no leftover tmp files" $([ -z "$(ls "$P/.project-map" | grep 'cache.json.tmp')" ] && echo 1 || echo 0)
ok "P fast with stubs (<1s)" $([ "$MS" -lt 1000 ] && echo 1 || echo 0)

: > "$LOG"
run_hook prompt "$P"
eq "P second prompt silent" "" "$OUT"
eq "P second prompt: no embed" 0 "$(calls embed)"

# plugin changes -> one re-render, then silent again
echo "<html>template v2</html>" > "$PLG/scripts/project-map-template.html"
TH2=$(sha "$PLG/scripts/project-map-template.html")
run_hook prompt "$P"
eq "P template changed: re-render message" "project-map: map re-rendered after a plugin update" "$CTX"
eq "P template changed: new hash acked" "$TH2" "$(cache_get ack_hashes template)"
: > "$LOG"; run_hook prompt "$P"
eq "P after ack: silent" "" "$OUT"
echo "# embed v2" > "$PLG/scripts/project-map-embed.py"
run_hook prompt "$P"
eq "P embed.py changed: re-render" "project-map: map re-rendered after a plugin update" "$CTX"

# failure: reported, not acknowledged, retried at most once per 10 minutes
echo "<html>template v3</html>" > "$PLG/scripts/project-map-template.html"
TH3=$(sha "$PLG/scripts/project-map-template.html")
reset_stub; STUB_EMBED_OUT="PM_EMBED_ERROR deadline" STUB_EMBED_RC=1
run_hook prompt "$P"
eq "P failure: message" "project-map: PM_EMBED_ERROR deadline" "$CTX"
eq "P failure: exit 0" 0 "$RC"
ok "P failure: hash NOT acknowledged" $([ "$(cache_get ack_hashes template)" != "$TH3" ] && echo 1 || echo 0)
ok "P failure: attempt time recorded" $([ -n "$(cache_get ack_attempt_at)" ] && echo 1 || echo 0)
eq "P failure: watch_cache preserved" "1" "$(cache_get watch_cache /x size)"
: > "$LOG"
run_hook prompt "$P"
eq "P retry within 10 min: silent" "" "$OUT"
eq "P retry within 10 min: no embed" 0 "$(calls embed)"
set_attempt_age() { python3 - "$P/.project-map/cache.json" "$1" <<'PY'
import sys, json, time
p = sys.argv[1]; d = json.load(open(p))
d["ack_attempt_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[2])))
json.dump(d, open(p, "w"))
PY
}
set_attempt_age 300
: > "$LOG"; run_hook prompt "$P"
eq "P retry after 5 min: still silent" "" "$OUT"
eq "P retry after 5 min: no embed" 0 "$(calls embed)"
set_attempt_age 660
STUB_EMBED_OUT="PM_EMBED_OK gen 000009-cccccccc 100" STUB_EMBED_RC=0
run_hook prompt "$P"
eq "P retry after 10 min: embed runs" 1 "$(calls embed)"
eq "P retry after 10 min: message" "project-map: map re-rendered after a plugin update" "$CTX"
eq "P retry success: hash acked" "$TH3" "$(cache_get ack_hashes template)"
eq "P retry success: attempt time cleared" "" "$(cache_get ack_attempt_at)"

# SUPERSEDED and noisy output
echo "<html>template v4</html>" > "$PLG/scripts/project-map-template.html"
reset_stub; STUB_EMBED_OUT="warning: noise\nSUPERSEDED base 000005-aa current 000006-bb\n" STUB_EMBED_RC=4
run_hook prompt "$P"
eq "P SUPERSEDED line passed through" "project-map: SUPERSEDED base 000005-aa current 000006-bb" "$CTX"
ok "P SUPERSEDED not acknowledged" $([ "$(cache_get ack_hashes template)" != "$(sha "$PLG/scripts/project-map-template.html")" ] && echo 1 || echo 0)
python3 - "$P/.project-map/cache.json" <<'PY'
import sys, json
p = sys.argv[1]; d = json.load(open(p)); d.pop("ack_attempt_at", None); json.dump(d, open(p, "w"))
PY
reset_stub; STUB_EMBED_OUT="" STUB_EMBED_RC=1
run_hook prompt "$P"
eq "P embed with no output" "project-map: PM_EMBED_ERROR no output" "$CTX"

# slow embed beyond the hook budget is the embed's own deadline; here a stub that sleeps is still bounded by us finishing
# corrupt cache.json is replaced by a valid one
python3 - "$P/.project-map/cache.json" <<'PY'
import sys; open(sys.argv[1], "w").write("{not json")
PY
reset_stub; STUB_EMBED_OUT="PM_EMBED_OK gen 000010-dddddddd 100"
run_hook prompt "$P"
ok "P corrupt cache.json: valid after" $(jq -e . "$P/.project-map/cache.json" >/dev/null 2>&1 && echo 1 || echo 0)
eq "P corrupt cache.json: acked" "$(sha "$PLG/scripts/project-map-template.html")" "$(cache_get ack_hashes template)"

# no map / legacy map / HOME / unmapped: silent, embed never called
Q=$(newroot p2)
reset_stub; STUB_EMBED_OUT="PM_EMBED_OK gen 1 1"
run_hook prompt "$Q"
eq "P unmapped: silent" "" "$OUT"; eq "P unmapped: exit 0" 0 "$RC"
eq "P unmapped: no embed" 0 "$(calls embed)"
Q2=$(newroot p3); mkdir -p "$Q2/.project-map"; echo '{}' > "$Q2/.project-map/state.json"
run_hook prompt "$Q2"
eq "P legacy-only map: silent" "" "$OUT"; eq "P legacy-only map: no embed" 0 "$(calls embed)"
mkmap "$HOME_T"
run_hook prompt "$HOME_T"
eq "P cwd == HOME: silent" "" "$OUT"; eq "P cwd == HOME: no embed" 0 "$(calls embed)"
rm -rf "$HOME_T/.project-map"
mkdir -p "$HOME_T/.git" "$HOME_T/sub2"; SUB2=$(cd "$HOME_T/sub2" && pwd -P); mkmap "$SUB2"
run_hook prompt "$SUB2"
eq "P toplevel == HOME falls back to cwd" "embed $SUB2 --mechanical --deadline 3.5" "$(head -n 1 "$LOG")"
rm -rf "$HOME_T/.git" "$HOME_T/sub2"
Q3=$(newroot p4); mkdir -p "$Q3/.git" "$Q3/a/b"; mkmap "$Q3"; : > "$LOG"
run_hook prompt "$Q3/a/b"
eq "P subdirectory resolves to git toplevel" "embed $Q3 --mechanical --deadline 3.5" "$(head -n 1 "$LOG")"


# ===== Real scripts: H-session, H-prompt, H-prompt-deadline ======================================
RP="$SCR/real-plugin"; rm -rf "$RP"; mkdir -p "$RP/scripts"
cp "$HERE"/scripts/*.py "$HERE"/scripts/*.sh "$HERE"/scripts/project-map-template.html "$RP/scripts/" 2>/dev/null
cp "$SESSION" "$PROMPT" "$RP/scripts/"
HAVE_VERIFY=0
python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_common;pm_common.verify_generation' "$RP/scripts" >/dev/null 2>&1 && HAVE_VERIFY=1
REAL_ENV=""
run_real() { # session|prompt <cwd>; extra env words in $REAL_ENV
  local script json t0 t1
  if [ "$1" = session ]; then script="$RP/scripts/project-map-session.sh"; else script="$RP/scripts/project-map-prompt.sh"; fi
  json=$(jq -nc --arg c "$2" '{session_id:"s1",cwd:$c}')
  t0=$(now_ms)
  OUT=$(printf '%s' "$json" | env -i PATH="$PATH" HOME="$HOME_T" CLAUDE_PLUGIN_ROOT="$RP" PM_USAGE_SKIP=1 PYTHONDONTWRITEBYTECODE=1 $REAL_ENV "$BASH" "$script" 2>/dev/null)
  RC=$?; t1=$(now_ms); MS=$((t1-t0))
  CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
}
renv() { env -i PATH="$PATH" HOME="$HOME_T" PM_USAGE_SKIP=1 PYTHONDONTWRITEBYTECODE=1 "$@"; }
RR="$SCR/roots/real"; mkdir -p "$RR"; RR=$(cd "$RR" && pwd -P); RPM="$RR/.project-map"
(cd "$RR" && git init -q -b main && echo readme > README.md && seq 1 300 > PLAN.md && seq 1 200 > REVIEW-LOG.md && mkdir -p docs thoughts/ledgers && echo d > docs/a.md && \
 printf '## Goal\n- goal line\n## Next action\n1. step\n## Blockers\n- b1\n' > thoughts/ledgers/demo-engine.md && git add -A && \
 git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm init)
VL=$(renv python3 "$RP/scripts/project-map-facts.py" "$RR"); INVN="inv-${VL##* }"
python3 "$HERE/tests/pm_testlib.py" jud "$RPM" "$INVN" full >/dev/null 2>&1
EO=$(renv bash "$RP/scripts/project-map-embed.sh" "$RR" "$INVN")
case "$EO" in
  "PM_EMBED_OK gen "*) MAPPED=1 ;;
  *) MAPPED=0; echo "NOTE: could not map the scratch project: $VL | $EO" ;;
esac
ok "real: scratch project mapped through facts + embed" "$MAPPED"
cur_gen() { readlink "$RPM/current"; }
sha_t() { shasum -a 256 "$RP/scripts/project-map-template.html" | cut -d' ' -f1; }
if [ "$MAPPED" = 1 ] && [ "$HAVE_VERIFY" = 1 ]; then
  # H-session: brief injected, no model call, no staging dir
  NINV=$(ls "$RPM" | grep -c '^inv-')
  run_real session "$RR"
  BR=$(sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$RPM/current/brief.txt")
  eq "H-session: real brief + map line" "$BR"$'\n'"map: $RR/.project-map/index.html · /project-map re-judges" "$CTX"
  eq "H-session: exit 0" 0 "$RC"
  ok "H-session: well under the 20 s hook timeout (${MS} ms)" $([ "$MS" -lt 10000 ] && echo 1 || echo 0)
  echo more >> "$RR/PLAN.md"; (cd "$RR" && git add -A && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm more)
  run_real session "$RR"
  case "$CTX" in *"map is behind: "*"; run /project-map") B=1 ;; *) B=0 ;; esac
  ok "H-session: moved repo -> 'map is behind' line" "$B"
  eq "H-session: no staging dir created by the hook" "$NINV" "$(ls "$RPM" | grep -c '^inv-')"
  # H-since: after a judged update the brief the hook injects carries line 7 (what changed since the previous assessment)
  VL=$(renv python3 "$RP/scripts/project-map-facts.py" "$RR"); INVN="inv-${VL##* }"
  python3 "$HERE/tests/pm_testlib.py" jud "$RPM" "$INVN" update >/dev/null 2>&1
  EO=$(renv bash "$RP/scripts/project-map-embed.sh" "$RR" "$INVN")
  case "$EO" in "PM_EMBED_OK gen "*) B=1 ;; *) B=0; echo "NOTE: update not published: $VL | $EO" ;; esac
  ok "H-since: a judged update publishes" "$B"
  run_real session "$RR"
  eq "H-since: the SessionStart context carries line 7: since <assessment minute>: 1 commits · 0 uncommitted · 0 changes" "1" "$(printf '%s\n' "$CTX" | grep -cE '^since 20[0-9-]+T[0-9:]{5}: 1 commits · [0-9]+ uncommitted · 0 changes$')"
  eq "H-since: ... and line 2 names both times" "1" "$(printf '%s\n' "$CTX" | grep -cE '^as of 20[0-9-]+T[0-9:]{5} · assessed 20[0-9-]+T[0-9:]{5} · (current|behind: )')"
  eq "H-since: ... the injected brief ends with the generation trailer and the map line" "map: $RR/.project-map/index.html · /project-map re-judges" "$(printf '%s\n' "$CTX" | tail -n 1)"
else
  echo "SKIP: H-session (needs the scratch map and pm_common.verify_generation; mapped=$MAPPED verify=$HAVE_VERIFY)"
fi
if [ "$MAPPED" = 1 ]; then
  # H-prompt: embed acknowledges at publish, so a fresh map is silent; a template change re-renders once
  G0=$(cur_gen); REAL_ENV=""
  run_real prompt "$RR"
  eq "H-prompt: fresh publish -> prompt hook silent" "" "$OUT"
  eq "H-prompt: fresh publish -> no generation added" "$G0" "$(cur_gen)"
  eq "H-prompt: template hash acknowledged by embed" "$(sha_t)" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["ack_hashes"]["template"])' "$RPM/cache.json")"
  echo "<!-- plugin restyled -->" >> "$RP/scripts/project-map-template.html"
  run_real prompt "$RR"
  eq "H-prompt: template change -> one re-render line" "project-map: map re-rendered after a plugin update" "$CTX"
  ok "H-prompt: page picked up the new template" $(grep -q 'plugin restyled' "$RPM/index.html" && echo 1 || echo 0)
  ok "H-prompt: re-render published a new generation" $([ "$(cur_gen)" != "$G0" ] && echo 1 || echo 0)
  G1=$(cur_gen); run_real prompt "$RR"
  eq "H-prompt: second prompt silent" "" "$OUT"
  eq "H-prompt: second prompt publishes nothing" "$G1" "$(cur_gen)"
  ok "H-prompt: fast enough for its 5 s timeout (${MS} ms)" $([ "$MS" -lt 5000 ] && echo 1 || echo 0)
  # H-prompt-deadline: a render slower than the 3.5 s deadline fails cleanly and is NOT acknowledged
  echo "<!-- restyled again -->" >> "$RP/scripts/project-map-template.html"
  G2=$(cur_gen); REAL_ENV="PM_EMBED_RENDER_DELAY=3.8"
  run_real prompt "$RR"
  eq "H-prompt-deadline: message" "project-map: PM_EMBED_ERROR deadline" "$CTX"
  eq "H-prompt-deadline: nothing replaced" "$G2" "$(cur_gen)"
  ok "H-prompt-deadline: hashes not acknowledged" $([ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["ack_hashes"]["template"])' "$RPM/cache.json")" != "$(sha_t)" ] && echo 1 || echo 0)
  ok "H-prompt-deadline: returned before the 5 s hook timeout (${MS} ms)" $([ "$MS" -lt 5000 ] && echo 1 || echo 0)
  REAL_ENV=""; run_real prompt "$RR"
  eq "H-prompt-deadline: retry inside 10 min is silent" "" "$OUT"
  # H-focus (14.3): the prompt hook's refresh NEVER applies owner answers. A pending F-set that exactly confirms the focus the last
  # assessment served stays pending after it; only facts' own "focus confirmed" path (embed --apply-answers) consumes it.
  python3 - "$RPM/cache.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d.pop("ack_attempt_at", None); json.dump(d, open(p, "w"))
PY
  python3 - "$RPM/state.json" >> "$RPM/answers.jsonl" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))["intent"]["target"]
print(json.dumps({"id": "F-set", "answer": t["outcome"], "note": t["done_when"], "at": "2026-10-11T10:00:00+03:00", "by": "owner"}))
PY
  ANS0=$(cat "$RPM/answers.jsonl"); G3=$(cur_gen)
  STATE_BEFORE=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["answers"]["applied"], d["intent"]["accepted"], d["judged_key"]["answers_count"])' "$RPM/state.json")
  REAL_ENV=""; run_real prompt "$RR"
  eq "H-focus: the prompt hook re-rendered the map (it published a generation)" "project-map: map re-rendered after a plugin update" "$CTX"
  ok "H-focus: ... a new generation was added" $([ "$(cur_gen)" != "$G3" ] && echo 1 || echo 0)
  eq "H-focus: ... the confirming F-set is still pending: applied, accepted and the judged key are as before" "$STATE_BEFORE" "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["answers"]["applied"], d["intent"]["accepted"], d["judged_key"]["answers_count"])' "$RPM/state.json")"
  eq "H-focus: ... answers.jsonl was not touched" "$ANS0" "$(cat "$RPM/answers.jsonl")"
  ok "H-focus: ... the map says it is behind (the line is a pending answer)" $([ "$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("stale") or {}).get("why",""))' "$RPM/state.json")" = "1 pending answers" ] && echo 1 || echo 0)
  VL=$(renv python3 "$RP/scripts/project-map-facts.py" "$RR" --no-stage)
  eq "H-focus: facts (not the hook) applies the plain confirmation without a model" "NEEDS_REFRESH focus confirmed" "$VL"
  ok "H-focus: ... applied 1 and the focus is accepted" $([ "$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["answers"]["applied"], d["intent"]["accepted"]["line"])' "$RPM/state.json")" = "1 1" ] && echo 1 || echo 0)
else
  echo "SKIP: H-prompt, H-prompt-deadline (scratch map not built)"
fi

# ===== S-preflight: the expected sentences are the ones SKILL.md specifies ========================
SKILL="$HERE/skills/project-map/SKILL.md"
for sentence in \
  "project-map needs a project folder, not your home directory." \
  "project-map only maps project folders inside your home folder (not hidden folders or ~/Library)." \
  "project-map cannot map a path containing spaces or brackets; move or rename the folder." \
  "project-map needs python3 3.9 or newer." \
  "project-map needs jq installed." \
  "project-map needs git installed."; do
  ok "S-preflight sentence in SKILL.md: $sentence" $(grep -qF "\"$sentence\"" "$SKILL" && echo 1 || echo 0)
done
# the script-side facts of those checks
mkdir -p "$SCR/roots/sp ace" "$SCR/roots/br[ack]"
o=$(renv python3 "$RP/scripts/project-map-facts.py" "$HOME_T"); r=$?
eq "S-preflight: facts refuses \$HOME" "2:ERROR unsupported location (\$HOME)" "$r:$o"
o=$(renv python3 "$RP/scripts/project-map-facts.py" "$SCR/roots/sp ace"); r=$?
eq "S-preflight: facts refuses a space" "2:ERROR unsupported location (space or bracket in path)" "$r:$o"
o=$(renv python3 "$RP/scripts/project-map-facts.py" "$SCR/roots/br[ack]"); r=$?
eq "S-preflight: facts refuses a bracket" "2:ERROR unsupported location (space or bracket in path)" "$r:$o"
# jq missing: both hooks stay silent and exit 0 (the skill's own check says the sentence above)
mkdir -p "$SCR/emptybin"
for h in session prompt; do
  o=$(printf '{"cwd":"%s"}' "$RR" | env -i PATH="$SCR/emptybin" HOME="$HOME_T" CLAUDE_PLUGIN_ROOT="$RP" "$BASH" "$RP/scripts/project-map-$h.sh" 2>&1); r=$?
  eq "S-preflight: no jq -> $h hook silent, exit 0" "0:" "$r:$o"
done

# garbage stdin never breaks the hooks
for h in session prompt; do
  if [ $h = session ]; then s="$PLG/scripts/project-map-session.sh"; else s="$PLG/scripts/project-map-prompt.sh"; fi
  o=$(printf 'not json at all' | env -i PATH="$PATH" HOME="$HOME_T" CLAUDE_PLUGIN_ROOT="$PLG" STUB_LOG="$LOG" "$BASH" "$s" 2>/dev/null); r=$?
  eq "garbage stdin ($h): exit 0" 0 "$r"
done

ok "slowest hook run under 1 s with stubs (max ${MAXMS} ms)" $([ "$MAXMS" -lt 1000 ] && echo 1 || echo 0)

# hooks.json: subagent lifecycle events call the guard with the exact args
HJ="$HERE/hooks/hooks.json"
if [ -f "$HJ" ] && command -v jq >/dev/null 2>&1; then
  for pair in "SubagentStart:start" "SubagentStop:stop"; do
    ev=${pair%%:*}; arg=${pair##*:}
    eq "hooks.json $ev args" "[\"--subagent\",\"$arg\"]" "$(jq -c ".hooks.$ev[0].hooks[0].args" "$HJ")"
    eq "hooks.json $ev timeout" 10 "$(jq -r ".hooks.$ev[0].hooks[0].timeout" "$HJ")"
    eq "hooks.json $ev command" '${CLAUDE_PLUGIN_ROOT}/scripts/project-map-guard.sh' "$(jq -r ".hooks.$ev[0].hooks[0].command" "$HJ")"
    eq "hooks.json $ev type" command "$(jq -r ".hooks.$ev[0].hooks[0].type" "$HJ")"
    eq "hooks.json $ev has one entry" 1 "$(jq -r ".hooks.$ev | length" "$HJ")"
  done
else
  ok "hooks.json present and jq available" 0
fi

echo "total $TOTAL pass $PASS fail $FAIL"
[ "$FAIL" = 0 ]
