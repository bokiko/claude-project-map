#!/bin/bash
# Tests for project-map-usage.py (3.3.0 incremental scan): totals identical to a full rescan after appends, new files, deleted
# files and rewritten files; the cache is used (bytes read); a budgeted run hands back the previous totals as partial and
# resumes. Synthetic HOME only: never reads or writes the real ~/.claude or ~/.codex. Bash 3.2 compatible.
# HOOKS_DIR points the suite at another scripts directory.
SRC="${HOOKS_DIR:-$(cd "$(dirname "$0")/../scripts" && pwd)}"
T=$(mktemp -d "${TMPDIR:-/tmp}/pm-usage.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1 HOME="$T/home"
unset PM_USAGE_SKIP PM_USAGE_SLOW PM_USAGE_CACHE_CAP
CP="$HOME/.claude/projects/-proj"; XP="$HOME/.codex/sessions/2026/10/01"
mkdir -p "$CP" "$XP"
ROOT="$T/proj"; mkdir -p "$ROOT/.project-map"; ROOT=$(cd "$ROOT" && pwd -P)
U="$SRC/project-map-usage.py"
# 3.3.0: the cache lives in the plugin's PRIVATE directory (never in ROOT), named by the hash of the real root path
PD="$HOME/.claude/agent-memory/project-map/usage"
RH=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$ROOT")
CF="$PD/$RH-cache.json"; LF="$PD/$RH-last.json"
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 :: $2"; }
t_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2' want '$3'"; fi; }
t_true() { if eval "$2"; then ok "$1"; else bad "$1" "false: $2"; fi; }

cat > "$T/fx.py" <<'PY'
import datetime as dt, json, os, sys

def line(o):
    return json.dumps(o, separators=(",", ":")) + "\n"

def ts(i):
    return (dt.datetime(2026, 10, 1, 10, 0, 0, tzinfo=dt.timezone.utc) + dt.timedelta(seconds=i)).isoformat().replace("+00:00", "Z")

def asst(mid, cwd, i, inp=10):
    d = {"type": "assistant", "message": {"id": mid, "model": "claude-sonnet-x",
         "usage": {"input_tokens": inp, "output_tokens": 1, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 5}},
         "timestamp": ts(i)}
    if cwd:
        d["cwd"] = cwd
    return d

def app(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as fh:
        fh.write(text)

def norm(d):
    d = json.loads(json.dumps(d))
    for k in ("generated_at", "scan", "partial", "as_of"):
        d.pop(k, None)
    s = d.get("snapshot_for_state")
    if s:
        s.pop("at", None); s.pop("partial", None)
    return d

c = sys.argv[1]; a = sys.argv[2:]
if c == "claude":      # FILE ROOT START N [CWD|-] [INP]
    f, root, st, n = a[0], a[1], int(a[2]), int(a[3])
    cwd = root if len(a) < 5 else (None if a[4] == "-" else a[4])
    inp = int(a[5]) if len(a) > 5 else 10
    app(f, "".join(line(asst("m%d" % (st + i), cwd, st + i, inp)) for i in range(n)))
elif c == "tiny":      # FILE ROOT ID: one in-root record worth 11 tokens (5 in + 1 out + 5 cache read)
    d = asst("t" + a[2], a[1], int(a[2]), 5)
    d["message"]["usage"]["cache_read_input_tokens"] = 5; d["message"]["usage"]["cache_creation_input_tokens"] = 0
    app(a[0], line(d))
elif c == "dup":       # FILE ROOT ID  (same message id again with other usage: the last record wins)
    app(a[0], line(asst(a[2], a[1], 99999, 999)))
elif c == "title":
    app(a[0], line({"type": "ai-title", "aiTitle": a[1]}))
elif c == "user":      # FILE TEXT
    app(a[0], line({"type": "user", "message": {"content": a[1]}}))
elif c == "mention":   # FILE ROOT N: lines that name the root path but carry no cwd
    app(a[0], "".join(line({"type": "user", "message": {"content": "look at %s/file%d" % (a[1], i)}}) for i in range(int(a[2]))))
elif c == "raw":       # FILE TEXT (no newline added)
    app(a[0], a[1])
elif c == "asstraw":   # ROOT ID: one assistant record as text WITHOUT newline
    sys.stdout.write(line(asst(a[1], a[0], 5000)).rstrip("\n"))
elif c == "codex-new": # FILE ROOT
    app(a[0], line({"type": "session_meta", "payload": {"id": "sess-" + os.path.basename(a[0])[:6], "cwd": a[1]}}) +
        line({"type": "turn_context", "payload": {"model": "gpt-x", "turn_id": "turn-aaaa-1"}}))
elif c == "codex":     # FILE START N: cumulative counters grow with the event index (START=0 again is a counter reset)
    st, n = int(a[1]), int(a[2])
    out = ""
    for i in range(st, st + n):
        k = i + 1
        out += line({"type": "event_msg", "timestamp": ts(i), "payload": {"type": "token_count", "info": {"total_token_usage":
                    {"input_tokens": k * 100, "cached_input_tokens": k * 40, "cache_write_input_tokens": 0, "output_tokens": k * 10}}}})
    app(a[0], out)
elif c == "codexuser": # FILE TEXT: a Codex user message (conversation content)
    app(a[0], line({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": a[1]}]}}))
elif c == "edit":      # FILE LINE OLD NEW: same-width edit of one line in the middle of the file, in place
    L = open(a[0], "rb").read().split(b"\n")
    assert a[2].encode() in L[int(a[1])] and len(a[2]) == len(a[3])
    L[int(a[1])] = L[int(a[1])].replace(a[2].encode(), a[3].encode())
    open(a[0], "wb").write(b"\n".join(L))
elif c == "capcalc":   # CACHEFILE: a cap that fits every entry without its parse state plus a third of the parse state
    d = json.load(open(a[0])); full = len(json.dumps(d, separators=(",", ":")))
    for e in d["files"].values():
        e["st"] = None
    slim = len(json.dumps(d, separators=(",", ":")))
    print(slim + (full - slim) // 3)
elif c == "slimcap":   # CACHEFILE PERCENT: that share of the cache size with every parse state dropped (forces whole-file eviction)
    d = json.load(open(a[0]))
    for e in d["files"].values():
        e["st"] = None
    print(len(json.dumps(d, separators=(",", ":"))) * int(a[1]) // 100)
elif c == "prog":      # CACHEFILE: complete live entries + folded records (the work that survived), and the folded count
    d = json.load(open(a[0])); f = d.get("folded") or {}
    print("%d %d" % (sum(1 for e in d["files"].values() if not e["u"]) + len(f), len(f)))
elif c == "done":      # CACHEFILE: entries that are complete / total
    d = json.load(open(a[0])); print("%d/%d" % (sum(1 for e in d["files"].values() if not e["u"]), len(d["files"])))
elif c == "meta":      # FILE JSON
    open(a[0], "w").write(a[1])
elif c == "rewrite":   # FILE ROOT START N [INP]: replace the file with fresh content
    open(a[0], "w").close()
    os.system("python3 %s claude %s %s %s %s %s %s" % (sys.argv[0], a[0], a[1], a[2], a[3], a[1], a[4] if len(a) > 4 else 10))
elif c == "swap":      # FILE LINE OLD NEW: rename-over: the edited copy replaces the file (new inode), same size, original mtime_ns restored
    st = os.stat(a[0]); L = open(a[0], "rb").read().split(b"\n")
    assert a[2].encode() in L[int(a[1])] and len(a[2]) == len(a[3])
    L[int(a[1])] = L[int(a[1])].replace(a[2].encode(), a[3].encode())
    tmp = a[0] + ".swap"; open(tmp, "wb").write(b"\n".join(L)); os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns)); os.replace(tmp, a[0])
elif c == "inplace":   # FILE LINE OLD NEW: same-size edit IN PLACE (same inode), then the original atime_ns/mtime_ns restored (ctime cannot be)
    st = os.stat(a[0]); L = open(a[0], "rb").read().split(b"\n")
    assert a[2].encode() in L[int(a[1])] and len(a[2]) == len(a[3])
    L[int(a[1])] = L[int(a[1])].replace(a[2].encode(), a[3].encode())
    with open(a[0], "r+b") as fh:
        fh.write(b"\n".join(L))
    os.utime(a[0], ns=(st.st_atime_ns, st.st_mtime_ns))
elif c == "cpm":       # SRC DST: copy the content and the mtime_ns (a distinct file with equal size and equal mtime)
    st = os.stat(a[0]); open(a[1], "wb").write(open(a[0], "rb").read()); os.utime(a[1], ns=(st.st_atime_ns, st.st_mtime_ns))
elif c == "same":      # A B
    x, y = norm(json.load(open(a[0]))), norm(json.load(open(a[1])))
    print("same" if x == y else "DIFFERENT: " + ", ".join(k for k in x if x[k] != y.get(k)))
elif c == "get":       # FILE EXPR
    d = json.load(open(a[0])); print(eval(a[1]))
PY
fx() { python3 "$T/fx.py" "$@"; }
get() { fx get "$1" "$2"; }
uu()   { python3 "$U" "$ROOT" --max-jobs 100 "$@"; }
run()  { uu "$@" > "$T/run.json"; }                # with the cache
full() { uu --cache none "$@" > "$T/full.json"; }  # the reference: a full rescan
sc()   { get "$T/run.json" "d['scan']['$1']"; }
same() { full "${@:2}"; t_eq "$1" "$(fx same "$T/run.json" "$T/full.json")" same; }   # call after run
clean() { rm -rf "$CP" "$XP" "$PD"; mkdir -p "$CP" "$XP"; }
# the module itself, for the cases that need a function and not the CLI
cat > "$T/pmu.py" <<'PY'
import importlib.util, sys
def load(path):
    spec = importlib.util.spec_from_file_location("pmu", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
PY
pyu() { PYTHONPATH="$T" python3 -c "$1" "$U" "${@:2}"; }

# ---------------------------------------------------------------- fixture: 3 sessions + a subagent + a codex rollout
S1="$CP/s1.jsonl"; S2="$CP/s2.jsonl"; S3="$CP/s3.jsonl"
fx claude "$S1" "$ROOT" 0 3000; fx title "$S1" "first session"
fx claude "$S2" "$ROOT" 0 50 "$ROOT/sub"
fx claude "$S3" "$T/elsewhere" 0 40
SUB="$CP/s1/subagents/agent-1.jsonl"; fx claude "$SUB" "$ROOT" 0 6 - ; fx meta "$CP/s1/subagents/agent-1.meta.json" '{"description":"explore","agentType":"Explore"}'
fx user "$SUB" "x"  # a user record without the root marker
X1="$XP/rollout-2026-10-01T10-00-00-aaaaaaaa.jsonl"; fx codex-new "$X1" "$ROOT"; fx codex "$X1" 0 20

# ---------------------------------------------------------------- CLI shape and the first run
run
t_eq "U-cli: schema" "$(get "$T/run.json" 'd["schema"]')" project-map-usage-1
t_eq "U-cli: partial is false" "$(get "$T/run.json" 'd["partial"]')" False
t_eq "U-cli: all documented top-level keys are present" "$(get "$T/run.json" 'sorted(set(["root","since","generated_at","sources","totals","per_model","per_job_count","per_job","snapshot_for_state"]) - set(d))')" "[]"
t_eq "U-known: claude tokens = (3000 + 50 + 6 attributed messages) x 116" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "$(( (3000+50+6)*116 ))"
t_eq "U-known: codex tokens = the last cumulative counters (20 x 100 input + 20 x 10 output)" "$(get "$T/run.json" 'd["totals"]["codex"]["total"]')" "$((20*100 + 20*10))"
t_eq "U-known: the session in another cwd is not attributed" "$(get "$T/run.json" 'd["sources"]["claude"]["jobs_attributed"]')" 3
t_eq "U-known: a subagent label is generic (its meta description is conversation content), named after its session" "$(get "$T/run.json" '[j["label"] for j in d["per_job"] if j["kind"]=="subagent"][0]')" "Claude session s1"
t_eq "U-cold: first run is cold and reads every file" "$(sc cache)/$(sc full)" "cold/5"
same "U-cold: equals the full rescan"
t_true "U330-1 cache: <sha256 of the real root>-cache.json is in the private directory, mode 0600" '[ -f "$CF" ] && [ "$(mode_of "$CF")" = 600 ]'
t_true "U330-1 cache: ... and <sha256>-last.json, mode 0600" '[ -f "$LF" ] && [ "$(mode_of "$LF")" = 600 ]'
t_eq "U330-1 cache: the private directory is mode 0700" "$(mode_of "$PD")" 700
t_eq "U330-1 cache: nothing at all is written under ROOT (no usage-* file)" "$(ls -A "$ROOT/.project-map" | wc -l | tr -d ' ')" 0
t_true "U-cache: no temp file is left behind" '[ -z "$(ls -A "$PD" | grep "\.tmp$")" ]'
t_eq "U-full: a --cache none run writes nothing" "$(full; ls -A "$PD" | wc -l | tr -d ' ')" 2

# ---------------------------------------------------------------- warm run: nothing read
run; t_eq "U-warm: second run skips every file" "$(sc skipped)/$(sc bytes_read)/$(sc cache)" "5/0/warm"
same "U-warm: equals the full rescan"
BYTES=$(wc -c < "$S1")

# ---------------------------------------------------------------- appends
fx claude "$S1" "$ROOT" 3000 5
run
t_eq "U-append: one file read incrementally, the rest skipped" "$(sc incremental)/$(sc full)/$(sc skipped)" "1/0/4"
t_true "U330-2 append: the old prefix is read once to verify it and the new bytes twice ($(sc bytes_read) of $BYTES)" '[ "$(sc bytes_read)" -ge "$BYTES" ] && [ "$(sc bytes_read)" -lt $((BYTES + 60000)) ]'
same "U-append: equals the full rescan"
fx dup "$S1" "$ROOT" m10    # an old message id seen again in a later append: the last record wins
run; same "U-append-dup: a repeated message id (last wins) equals the full rescan"
fx claude "$S2" "$ROOT" 50 10 "$ROOT/sub"; fx claude "$S2" "$ROOT" 60 10 "$T/elsewhere"; fx claude "$S2" "$ROOT" 70 10 "$ROOT"
run; same "U-append-cwd: records after a cd out of the root and back (cwd filter state carried over) equal the full rescan"
t_eq "U-append-cwd: and only the in-root records count" "$(get "$T/run.json" '[j["msgs"] for j in d["per_job"] if j["label"].startswith("Claude session s2")][0]')" 70
fx title "$S1" "renamed"; fx claude "$S1" "$ROOT" 3005 1
run; same "U-append-title: a later ai-title is picked up"
t_eq "U-append-title: label" "$(get "$T/run.json" '[j["label"] for j in d["per_job"] if j["msgs"]==3006][0]')" renamed
fx codex "$X1" 20 15
run; same "U-append-codex: codex counters continue across appends"
t_eq "U-append-codex: incremental" "$(sc incremental)" 1
fx codex "$X1" 0 5    # counter reset (cumulative total drops)
run; same "U-append-codex-reset: a counter reset equals the full rescan"

# ---------------------------------------------------------------- new and deleted files
S4="$CP/s4.jsonl"; fx claude "$S4" "$ROOT" 0 12
run; t_eq "U-new: only the new file is read in full" "$(sc full)/$(sc incremental)" "1/0"
same "U-new: equals the full rescan"
rm "$S4"
run; same "U-deleted: equals the full rescan"
t_true "U-deleted: its cache entry is gone" '! grep -q "s4.jsonl" "$CF"'
rm "$SUB" "$CP/s1/subagents/agent-1.meta.json"
run; same "U-deleted: a deleted subagent drops out"

# ---------------------------------------------------------------- rewritten and truncated files
fx rewrite "$S2" "$ROOT" 0 20 20          # shorter than before
run; t_eq "U-truncate: a shrunk file is re-read from 0" "$(sc full)" 1
same "U-truncate: equals the full rescan"
fx rewrite "$S2" "$ROOT" 0 20 99          # same length, other content (the first KB differs)
run; t_eq "U-rewrite: a same-size rewrite is detected (prefix hash) and re-read" "$(sc full)" 1
same "U-rewrite: equals the full rescan"
fx rewrite "$S2" "$ROOT" 0 300 7          # longer, but the old prefix is gone
run; t_eq "U-rewrite-grow: a longer file whose prefix changed is re-read" "$(sc full)" 1
same "U-rewrite-grow: equals the full rescan"

# ---------------------------------------------------------------- a last line without newline is read tentatively, never committed
S5="$CP/s5.jsonl"; fx claude "$S5" "$ROOT" 0 10
run
fx raw "$S5" "$(fx asstraw "$ROOT" tailmsg)"       # complete JSON, no newline yet: a full scan counts it
run; same "U-tail: an unterminated but complete last record is counted like a full scan"
t_eq "U-tail: and counted" "$(get "$T/run.json" '[j["msgs"] for j in d["per_job"] if j["label"].startswith("Claude session s5")][0]')" 11
fx raw "$S5" $'\n'
fx claude "$S5" "$ROOT" 10 2
run; same "U-tail: after the newline arrives and more is appended"
t_eq "U-tail: no double count" "$(get "$T/run.json" '[j["msgs"] for j in d["per_job"] if j["label"].startswith("Claude session s5")][0]')" 13
fx raw "$S5" '{"type":"assistant","message":{"id":"half'
run; same "U-tail-partial: a half-written record is ignored"
t_eq "U-tail-partial: ignored" "$(get "$T/run.json" '[j["msgs"] for j in d["per_job"] if j["label"].startswith("Claude session s5")][0]')" 13

rm "$S5"; run; same "U-tail: the file with the dangling tail is deleted"

# ---------------------------------------------------------------- attribution changes while a file grows
S6="$CP/s6.jsonl"; fx claude "$S6" "$ROOT" 0 5 -        # no cwd, no mentions: not attributed
run; t_eq "U-attr: unattributed file contributes nothing" "$(get "$T/run.json" 'len([j for j in d["per_job"] if j["label"].startswith("Claude session s6")])')" 0
fx mention "$S6" "$ROOT" 30                              # 30 mentions: attributed by mentions, approximate
run; same "U-attr: becomes attributed by mentions (approximate)"
t_eq "U-attr: approximate" "$(get "$T/run.json" 'd["totals"]["approximate"]')" True
fx claude "$S6" "$ROOT" 5 3 "$T/elsewhere"               # names a cwd elsewhere: mentions are void
run; same "U-attr: a cwd elsewhere voids the mentions attribution"
fx claude "$S6" "$ROOT" 8 4 "$ROOT"                      # now a cwd hit: records filtered by cwd
run; same "U-attr: becomes a cwd hit (filtered by cwd)"
t_eq "U-attr: only the in-root records count" "$(get "$T/run.json" '[j["msgs"] for j in d["per_job"] if j["label"].startswith("Claude session s6")][0]')" 4

# ---------------------------------------------------------------- subagent inheritance
P2="$CP/p2.jsonl"; fx claude "$P2" "$ROOT" 0 3
A2="$CP/p2/subagents/agent-9.jsonl"; fx user "$A2" "do it"; fx claude "$A2" "$ROOT" 100 4 -
run; same "U-sub: a subagent without cwd inherits its parent's cwd hit"
t_eq "U-sub: attribution is inherited" "$(get "$T/run.json" '[j["attribution"] for j in d["per_job"] if j["kind"]=="subagent"][0]')" inherited
P3="$CP/p3.jsonl"; fx claude "$P3" "$T/elsewhere" 0 3
A3="$CP/p3/subagents/agent-1.jsonl"; fx user "$A3" "ROOT: $ROOT please"; fx claude "$A3" "$ROOT" 200 4 -
run; same "U-sub: a first user message with ROOT: <root> inherits"
A4="$CP/p3/subagents/agent-2.jsonl"; fx user "$A4" "nothing"; fx claude "$A4" "$ROOT" 300 4 -
run; same "U-sub: no marker, parent elsewhere: not attributed"
fx claude "$P3" "$ROOT" 10 3                              # the parent becomes a cwd hit later: agent-2 now inherits
run; same "U-sub: a parent that becomes a cwd hit later flips its subagent"

# ---------------------------------------------------------------- the since filter is part of the cache key
run --since 2026-10-01T10:00:30Z; t_eq "U-since: a different --since does not reuse the cache" "$(sc cache)" cold
same "U-since: equals the full rescan with the same --since" --since 2026-10-01T10:00:30Z
run --since 2026-10-01T10:00:30Z; t_eq "U-since: and is warm on the repeat" "$(sc cache)/$(sc bytes_read)" "warm/0"

# ---------------------------------------------------------------- damaged and foreign caches never change the answer
run
printf '{"key":{"x"' > "$CF"
run; same "U-damaged: a truncated cache file is ignored"
python3 - "$CF" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for e in d["files"].values():
    e.pop("fl", None)
json.dump(d, open(p, "w"))
PY
fx claude "$S1" "$ROOT" 4000 1
run; same "U-damaged: entries that do not fit the code are re-read"
python3 - "$CF" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["key"]["root"] = "/somewhere/else"; json.dump(d, open(p, "w"))
PY
run; t_eq "U-foreign: a cache written for another root is not used" "$(sc cache)" cold
same "U-foreign: equals the full rescan"

# ---------------------------------------------------------------- U330-4: a real size cap; completed results go first, unfinished state never
clean
for i in 1 2 3 4 5 6 7 8; do fx claude "$CP/b$i.jsonl" "$ROOT" 0 30; done
export PM_USAGE_CHUNK=2048       # several chunks per file, so a budgeted run stops in the middle of one
run; CAPV=$(fx capcalc "$CF")     # a cap that holds every entry without its parse state, not with it
t_true "U330-4 cap: the calibration cap ($CAPV) is below the uncapped cache ($(wc -c < "$CF") bytes)" '[ "$CAPV" -lt "$(wc -c < "$CF")" ]'
rm -rf "$PD"
export PM_USAGE_SLOW=0.03
n=0; PART=True; LASTDONE=0; MONO=1; CAPOK=1; MAXST=0
while [ "$PART" = True ] && [ "$n" -lt 100 ]; do
  n=$((n+1)); PM_USAGE_CACHE_CAP=$CAPV uu --budget 0.35 > "$T/run.json"; PART=$(get "$T/run.json" 'd["partial"]')
  DONE=$(fx done "$CF" | cut -d/ -f1)
  [ "$DONE" -lt "$LASTDONE" ] && MONO=0
  LASTDONE=$DONE
  [ "$(wc -c < "$CF")" -gt "$CAPV" ] && CAPOK=0
done
unset PM_USAGE_SLOW
t_true "U330-4 cap: repeated budgeted runs under a tiny cap finish ($n runs, never starved by eviction)" '[ "$PART" = False ] && [ "$n" -gt 2 ]'
t_eq "U330-4 cap: the number of completed files never went down" "$MONO" 1
t_eq "U330-4 cap: the cache file never exceeded the cap" "$CAPOK" 1
same "U330-4 cap: and the finished result equals the full rescan"
t_eq "U330-4 cap: all 8 entries are complete in the cache at the end" "$(fx done "$CF")" "8/8"
t_true "U330-4 cap: completed files lost their parse state to fit" '[ "$(get "$CF" "sum(1 for e in d[\"files\"].values() if e.get(\"st\") is None)")" -ge 1 ]'
fx claude "$CP/b1.jsonl" "$ROOT" 30 3
run; same "U330-4 cap: a file whose parse state was evicted and then grows is re-read correctly"
t_eq "U330-4 cap: ... parsed again from byte 0, only that one" "$(sc reparsed)" 1
unset PM_USAGE_CHUNK
# eviction order, on the function itself: parse state of completed files, then completed files, never an unfinished one
t_eq "U330-4 evict: completed parse state goes first; the unfinished entry keeps its state" "$(pyu '
import sys, json, os, tempfile
from pmu import load
m = load(sys.argv[1])
def ent(u, n): return {"sz": 1, "mt": 1, "off": 1, "ph": None, "fl": [0, 0, 0, None], "sn": n, "u": u, "po": 1, "pk": "all", "st": {"seen": {"k%d" % i: [1] * 6 for i in range(40)}}, "md": "cwd", "jb": [], "cnt": 0, "apx": 0, "ok": 1 - u}
def run(cap_of):
    files = {"/a": ent(0, 1), "/b": ent(1, 2), "/c": ent(0, 3)}
    full = len(json.dumps(files, separators=(",", ":")))
    p = os.path.join(tempfile.mkdtemp(), "c.json")
    ok, ev = m.save_cache(p, {"k": 1}, files, 5, cap_of(full, len(json.dumps(ent(1, 2), separators=(",", ":")))))
    return ok, ev, files["/b"]["st"] is not None if "/b" in files else None, sorted(files), (os.path.getsize(p) if os.path.exists(p) else -1)
a = run(lambda full, one: int(full * 0.5))
b = run(lambda full, one: one + 100)
c = run(lambda full, one: one // 2)
print(a[0], a[1], a[2], a[3], "|", b[0], b[1], b[2], b[3], "|", c[0], c[1], c[2], c[3], c[4])
')" "True 0 True ['/a', '/b', '/c'] | True 2 True ['/b'] | False 2 True ['/b'] -1"
# a cap that cannot be met: the answer is still complete and correct, the cache is reported partial and not written
clean; fx claude "$CP/b1.jsonl" "$ROOT" 0 30
PM_USAGE_CACHE_CAP=100 uu > "$T/run.json"
t_eq "U330-4 cap: an unmeetable cap -> complete answer, cache_partial, no cache file" "$(get "$T/run.json" 'd["partial"]')/$(sc cache_partial)/$([ -e "$CF" ] && echo written || echo none)" "False/True/none"
same "U330-4 cap: ... and the answer equals the full rescan"

# ---------------------------------------------------------------- U330-2: a middle edit is found (fixed expected totals, not a comparison with the shared parser)
clean
M1="$CP/mid.jsonl"; fx claude "$M1" "$ROOT" 0 100
run; t_eq "U330-2 base: 100 messages x 116" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 11600
fx edit "$M1" 50 '"input_tokens":10,' '"input_tokens":90,'
run; t_eq "U330-2 middle edit (same size, new mtime): 11600 + 80, re-read from byte 0" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(sc full)" "11680/1"
run; t_eq "U330-2 middle edit: and the warm run after it keeps the right number" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(sc skipped)" "11680/1"
fx edit "$M1" 20 '"input_tokens":10,' '"input_tokens":50,'; fx claude "$M1" "$ROOT" 100 1
run; t_eq "U330-2 middle edit + one appended record: 11680 + 40 + 116, the grown file's whole prefix is verified" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(sc full)" "11836/1"
same "U330-2: equals the full rescan"
touch "$M1"
run; t_eq "U330-2 touch only (new mtime, same bytes): re-read, same total" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(sc full)" "11836/1"
fx claude "$M1" "$ROOT" 101 2
run; t_eq "U330-2 a plain append is still incremental (prefix verified, no full re-read)" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(sc incremental)/$(sc full)" "12068/1/0"

# ---------------------------------------------------------------- U330-3: a file rewritten while it is read is never cached
G="$T/gate"
gate_run() { # SWAP-COMMAND: runs the scan, waits until it has read its first chunk, runs the command, lets it go
  rm -rf "$G"; mkdir -p "$G"
  PM_USAGE_GATE="$G" uu > "$T/race.json" &
  gpid=$!; gn=0
  while [ ! -e "$G/reached" ] && [ "$gn" -lt 500 ]; do sleep 0.02; gn=$((gn+1)); done
  eval "$1"
  : > "$G/go"; wait "$gpid"
}
X9="$XP/rollout-2026-10-01T10-00-00-cccccccc.jsonl"
fx codex-new "$T/swap.jsonl" "$T/elsewhere"; fx codex "$T/swap.jsonl" 0 3
clean; fx codex-new "$X9" "$ROOT"; fx codex "$X9" 0 1
run; cp "$T/run.json" "$T/before.json"
t_eq "U330-3 base: codex attributed by cwd, 1 event = 110" "$(get "$T/run.json" 'd["totals"]["codex"]["total"]')" 110
fx codex "$X9" 1 1                                           # a changed file, so the next run reads it
gate_run 'cp "$T/swap.jsonl" "$X9"'                          # rewritten in place (other cwd, other size) after the chunk was read
t_eq "U330-3 in-place rewrite during the read: partial, the previous totals handed back" "$(get "$T/race.json" 'd["partial"]')/$(get "$T/race.json" 'd["snapshot_for_state"]["totals"]')/$(get "$T/race.json" 'd["scan"]["unstable"]')" "True/$(get "$T/before.json" 'd["snapshot_for_state"]["totals"]')/1"
run; same "U330-3 in-place rewrite: the next run equals the full rescan (the mixed snapshot was never cached)"
t_eq "U330-3 in-place rewrite: ... and attributes nothing (the file is now in another cwd)" "$(get "$T/run.json" 'd["totals"]["codex"]["total"]')" 0
run; t_eq "U330-3 in-place rewrite: ... and stays so on the warm run" "$(get "$T/run.json" 'd["totals"]["codex"]["total"]')/$(sc cache)" "0/warm"
clean; fx codex-new "$X9" "$ROOT"; fx codex "$X9" 0 1; run; fx codex "$X9" 1 1
gate_run 'cp "$T/swap.jsonl" "$T/swap.new" && mv "$T/swap.new" "$X9"'   # replaced by another file (new inode)
t_eq "U330-3 replacement by another file: partial" "$(get "$T/race.json" 'd["partial"]')" True
run; same "U330-3 replacement: the next run equals the full rescan"
t_eq "U330-3 replacement: ... 0 tokens" "$(get "$T/run.json" 'd["totals"]["codex"]["total"]')" 0
clean; fx codex-new "$X9" "$ROOT"; fx codex "$X9" 0 1; run; fx codex "$X9" 1 2
gate_run 'fx codex "$X9" 3 1'                                # a live session: only appended meanwhile
t_eq "U330-3 append during the read (a live session): complete, the 3 events read at the start" "$(get "$T/race.json" 'd["partial"]')/$(get "$T/race.json" 'd["totals"]["codex"]["total"]')" "False/330"
run; same "U330-3 append: the next run picks up the append and equals the full rescan"
t_eq "U330-3 append: 4 events = 440" "$(get "$T/run.json" 'd["totals"]["codex"]["total"]')" 440

# ---------------------------------------------------------------- U330-5: the atomic writer
t_eq "U330-5 atomic: a planted symlink at the old predictable temp name is not followed; a planted 0644 temp file is not reused" "$(pyu '
import sys, os, stat, tempfile
from pmu import load
m = load(sys.argv[1])
d = tempfile.mkdtemp(); victim = os.path.join(d, "victim.txt"); open(victim, "w").write("precious")
os.getpid = lambda: 4242                       # the old writer named its temp file .<name>.tmp.<pid>
dest = os.path.join(d, "cache.json")
os.symlink(victim, os.path.join(d, ".cache.json.tmp.4242"))
r1 = m.write_atomic(dest, "BODY1")
v1 = open(victim).read()
os.unlink(os.path.join(d, ".cache.json.tmp.4242")) if os.path.islink(os.path.join(d, ".cache.json.tmp.4242")) else None
planted = os.path.join(d, ".cache.json.tmp.4242"); open(planted, "w").write("old"); os.chmod(planted, 0o644)
r2 = m.write_atomic(dest, "BODY2")
mode = stat.S_IMODE(os.stat(dest).st_mode)
os.unlink(dest); os.symlink(victim, dest)       # the destination itself is a symlink: replaced, not followed
r3 = m.write_atomic(dest, "BODY3")
print(r1, v1, r2, oct(mode), r3, open(victim).read(), os.path.islink(dest), open(dest).read(), open(planted).read(), sorted(n for n in os.listdir(d) if n.startswith(".cache.json.tmp.")))
')" "True precious True 0o600 True precious False BODY3 old ['.cache.json.tmp.4242']"
t_true "U330-5 atomic: the temp name is random (two writes use two names) and never left behind" '[ -z "$(ls -A "$PD" | grep "\.tmp$")" ]'

# ---------------------------------------------------------------- U330-6: the budget bounds the whole run
clean; fx claude "$CP/one.jsonl" "$ROOT" 0 1; rm -rf "$HOME/.codex"   # no Codex folder: its enumeration check cannot be what sees the overrun
# budget 1.0 -> the scan deadline is 0.8 s; each chunk read is followed by a 0.45 s pause (flags pass, then parse pass), so the
# only check that can see the overrun is the one after the last chunk (the check before the parse chunk runs at ~0.46 s)
PM_USAGE_SLOW=0.45 uu --budget 1.0 > "$T/run.json"
t_eq "U330-6 budget: a one-record scan whose last chunk overruns the budget is partial (no tick follows the last chunk)" "$(get "$T/run.json" 'd["partial"]')" True
rm -rf "$PD"
PM_USAGE_SLOW=0.45 uu --budget 1.0 > "$T/run.json"
t_eq "U330-6 budget: ... also with no previous result (snapshot null)" "$(get "$T/run.json" 'd["partial"]')/$(get "$T/run.json" 'd["snapshot_for_state"]')" "True/None"
run; t_eq "U330-6 budget: and an unbudgeted run completes" "$(get "$T/run.json" 'd["partial"]')/$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "False/116"
mkdir -p "$CP/deep"; i=0; while [ $i -lt 300 ]; do mkdir -p "$CP/deep/d$i"; i=$((i+1)); done
t_true "U330-6 budget: a budget already spent at the start (enumeration/load checked) -> partial" '[ "$(uu --budget 0.001 | python3 -c "import json,sys;print(json.load(sys.stdin)[\"partial\"])")" = True ]'
rm -rf "$CP/deep"

# ---------------------------------------------------------------- U330-R2-2: old-prefix verification resumes across budgeted runs
clean
export PM_USAGE_CHUNK=1024 PM_USAGE_BLOCK=1024          # 1 KB hash blocks: a 37 KB prefix is ~36 blocks
RG="$CP/grow.jsonl"; fx claude "$RG" "$ROOT" 0 150
run; t_eq "U330-R2-2 base: 150 messages x 116" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 17400
fx claude "$RG" "$ROOT" 150 1                           # one append: the whole old prefix must be verified before it is trusted
export PM_USAGE_SLOW=0.02                               # every block costs 20 ms, so one 0.3 s budget verifies only ~10 of ~36
R2OFF=$(get "$CF" "d['files']['$RG']['off']")
n=0; PART=True; MONO=1; PREVOFF=$R2OFF; PREVVP=-1; VPUP=1; FIRSTP=; PSNAP=1
while [ "$PART" = True ] && [ "$n" -lt 40 ]; do
  n=$((n+1)); uu --budget 0.3 > "$T/run.json"; PART=$(get "$T/run.json" 'd["partial"]')
  [ "$PART" = True ] && [ "$(get "$T/run.json" 'd["snapshot_for_state"]["totals"]["claude"]')" != 17400 ] && PSNAP=0
  OFF=$(get "$CF" "d['files']['$RG']['off']"); [ "$OFF" -lt "$PREVOFF" ] && MONO=0; PREVOFF=$OFF
  if [ "$PART" = True ]; then
    VP=$(get "$CF" "(d['files']['$RG'].get('vf') or {}).get('vp', 0)"); [ "$VP" -le "$PREVVP" ] && VPUP=0; PREVVP=$VP
  fi
done
unset PM_USAGE_SLOW
t_true "U330-R2-2 resume: verification that cannot finish in one budget needs several runs ($n) and converges" '[ "$n" -gt 2 ] && [ "$n" -lt 40 ] && [ "$PART" = False ]'
t_eq "U330-R2-2 resume: the converged total is exact (151 x 116)" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 17516
t_eq "U330-R2-2 resume: every partial run handed back the previous total, never a mixed one" "$PSNAP" 1
t_eq "U330-R2-2 resume: the committed offset never went down" "$MONO" 1
t_eq "U330-R2-2 resume: the verified position advanced on every partial run (no starvation)" "$VPUP" 1
t_eq "U330-R2-2 resume: and the offset ends at the file size" "$(get "$CF" "d['files']['$RG']['off']")" "$(wc -c < "$RG" | tr -d ' ')"
same "U330-R2-2 resume: equals the full rescan"
# rewrite detection survives the block scheme: an edit in the first block, in the middle, and in the unfinished last block
for ED in 3 70 150; do
  fx edit "$RG" "$ED" '"input_tokens":10,' '"input_tokens":30,'; fx claude "$RG" "$ROOT" 200 1
  run; same "U330-R2-2 rewrite: edit of line $ED + an append (prefix verified in blocks) equals the full rescan"
  t_eq "U330-R2-2 rewrite: ... line $ED was found and the file re-read" "$(sc full)" 1
done
# a verification interrupted by a budget, then the file is edited in the middle and grows again: the saved progress is not reused
RE="$CP/grow2.jsonl"; fx claude "$RE" "$ROOT" 0 150; run
fx claude "$RE" "$ROOT" 150 1
export PM_USAGE_SLOW=0.02; uu --budget 0.3 > "$T/run.json"; unset PM_USAGE_SLOW
t_eq "U330-R2-2 rewrite after a partial verification: the first run is partial" "$(get "$T/run.json" 'd["partial"]')" True
fx edit "$RE" 10 '"input_tokens":10,' '"input_tokens":70,'; fx claude "$RE" "$ROOT" 151 1
n=0; PART=True
while [ "$PART" = True ] && [ "$n" -lt 40 ]; do n=$((n+1)); PM_USAGE_SLOW=0.02 uu --budget 0.3 > "$T/run.json"; PART=$(get "$T/run.json" 'd["partial"]'); done
t_eq "U330-R2-2 rewrite after a partial verification: converges to the full rescan" "$PART" False
same "U330-R2-2 rewrite after a partial verification: the edit is in the total"
unset PM_USAGE_CHUNK PM_USAGE_BLOCK

# ---------------------------------------------------------------- U330-R2-3: whole-file eviction keeps the work done (folded bucket + scan cursor)
clean
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do fx tiny "$CP/f$i.jsonl" "$ROOT" $i; done
run; t_eq "U330-R2-3 base: 20 one-record files = 220" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 220
CAP3=$(fx slimcap "$CF" 60)                             # 60% of the cache without parse states: every entry cannot stay a live entry
t_true "U330-R2-3 cap: the calibrated cap ($CAP3) is below the size of the live entries without parse state" '[ "$CAP3" -lt "$(wc -c < "$CF")" ]'
rm -rf "$PD"
export PM_USAGE_SLOW=0.05
n=0; PART=True; PREV=0; MONO=1; MAXF=0; SAWCUR=0; PSNAP=1
while [ "$PART" = True ] && [ "$n" -lt 30 ]; do
  n=$((n+1)); PM_USAGE_CACHE_CAP=$CAP3 uu --budget 0.45 > "$T/run.json"; PART=$(get "$T/run.json" 'd["partial"]')
  set -- $(fx prog "$CF"); PROG=$1; [ "$2" -gt "$MAXF" ] && MAXF=$2
  [ "$PROG" -lt "$PREV" ] && MONO=0; PREV=$PROG
  [ "$PART" = True ] && [ "$(get "$CF" "str(d.get('cur'))")" != "{'c': None, 'x': None}" ] && SAWCUR=1
  [ "$PART" = True ] && [ "$n" = 1 ] && [ "$(get "$T/run.json" 'd["snapshot_for_state"]')" != None ] && PSNAP=0
done
unset PM_USAGE_SLOW
t_true "U330-R2-3 evict: a budget of ~3 files per run and a cap that forces whole-file eviction still completes ($n runs)" '[ "$PART" = False ] && [ "$n" -gt 2 ] && [ "$n" -le 20 ]'
t_eq "U330-R2-3 evict: the complete result is the exact total (20 x 11)" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 220
t_eq "U330-R2-3 evict: ... from 20 jobs" "$(get "$T/run.json" 'd["totals"]["claude"]["jobs"]')" 20
t_eq "U330-R2-3 evict: the work that survived each run (complete entries + folded) never went down" "$MONO" 1
t_true "U330-R2-3 evict: whole files really were evicted into the folded bucket (max $MAXF folded)" '[ "$MAXF" -gt 0 ]'
t_eq "U330-R2-3 evict: the first run had no previous result to hand back" "$PSNAP" 1
t_eq "U330-R2-3 cursor: a budgeted run leaves a scan cursor" "$SAWCUR" 1
t_eq "U330-R2-3 cursor: the complete run clears it" "$(get "$CF" "str(d.get('cur'))")" "{'c': None, 'x': None}"
t_true "U330-R2-3 evict: the cache stayed within the cap" '[ "$(wc -c < "$CF")" -le "$CAP3" ]'
same "U330-R2-3 evict: equals the full rescan"
# a folded file is reused only while unchanged: append, touch and delete are all noticed
FI=$(pyu '
import json, sys, os
from pmu import load
m = load(sys.argv[1]); d = json.load(open(sys.argv[2])); f = d["folded"]
print([i for i in range(1, 21) if m.pkey(os.path.join(sys.argv[3], "f%d.jsonl" % i)) in f][0])
' "$CF" "$CP")
PM_USAGE_CACHE_CAP=$CAP3 uu > "$T/run.json"; t_eq "U330-R2-3 folded: an unchanged folded file is skipped, the result stays exact" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 220
fx tiny "$CP/f$FI.jsonl" "$ROOT" 900
PM_USAGE_CACHE_CAP=$CAP3 uu > "$T/run.json"; t_eq "U330-R2-3 folded: an appended folded file is read again (231)" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 231
same "U330-R2-3 folded: equals the full rescan after the append"
FJ=$(pyu '
import json, sys, os
from pmu import load
m = load(sys.argv[1]); d = json.load(open(sys.argv[2])); f = d["folded"]
print([i for i in range(1, 21) if m.pkey(os.path.join(sys.argv[3], "f%d.jsonl" % i)) in f and i != int(sys.argv[4])][0])
' "$CF" "$CP" "$FI")
rm "$CP/f$FJ.jsonl"
PM_USAGE_CACHE_CAP=$CAP3 uu > "$T/run.json"; t_eq "U330-R2-3 folded: a deleted folded file drops out of the total (231 - 11)" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 220
same "U330-R2-3 folded: equals the full rescan after the delete"
t_true "U330-R2-3 folded: and its record is gone from the cache" '[ "$(get "$CF" "len(d[\"folded\"]) + len(d[\"files\"])")" = 19 ]'
# U330-R3-2: a folded record carries the file identity; rename-over with the same size and the mtime restored is another file
FK=$(pyu '
import json, sys, os
from pmu import load
m = load(sys.argv[1]); d = json.load(open(sys.argv[2])); f = d["folded"]
print([i for i in range(1, 21) if m.pkey(os.path.join(sys.argv[3], "f%d.jsonl" % i)) in f][0])
' "$CF" "$CP")
t_true "U330-R3-2 folded: setup: there is a folded file to replace (f$FK)" '[ -n "$FK" ]'
fx swap "$CP/f$FK.jsonl" 0 '"input_tokens":5,' '"input_tokens":9,'
PM_USAGE_CACHE_CAP=$CAP3 uu > "$T/run.json"
t_eq "U330-R3-2 folded: a folded file replaced by another inode (same size, mtime restored) is read again (220 + 4)" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(get "$T/run.json" 'd["partial"]')" "224/False"
same "U330-R3-2 folded: equals the full rescan"
# the scan cursor: the next budgeted run starts where the last one stopped, then reaches the files after it, then wraps around
t_eq "U330-R2-3 cursor: rotate() starts at the cursor, then the keys after it, then wraps" "$(pyu '
import sys
from pmu import load
m = load(sys.argv[1]); k = [(0, "a"), (0, "b"), (0, "c"), (1, "d")]
print(m.rotate(k, [0, "b"]), m.rotate(k, [0, "bb"]), m.rotate(k, None), m.rotate(k, [1, "z"]))
')" "[(0, 'b'), (0, 'c'), (1, 'd'), (0, 'a')] [(0, 'c'), (1, 'd'), (0, 'a'), (0, 'b')] [(0, 'a'), (0, 'b'), (0, 'c'), (1, 'd')] [(0, 'a'), (0, 'b'), (0, 'c'), (1, 'd')]"
clean
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do fx tiny "$CP/f$i.jsonl" "$ROOT" $i; done
export PM_USAGE_SLOW=0.05
uu --budget 0.45 > "$T/run.json"; t_eq "U330-R2-3 cursor: setup: the first budgeted run is partial" "$(get "$T/run.json" 'd["partial"]')" True
fx tiny "$CP/a0.jsonl" "$ROOT" 500           # sorts before every other file
uu --budget 0.45 > "$T/run.json"
unset PM_USAGE_SLOW
t_true "U330-R2-3 cursor: the second run resumed at the cursor and did not restart at the new first file" '! grep -q "a0.jsonl" "$CF"'
n=0; PART=True
while [ "$PART" = True ] && [ "$n" -lt 30 ]; do n=$((n+1)); PM_USAGE_SLOW=0.05 uu --budget 0.45 > "$T/run.json"; PART=$(get "$T/run.json" 'd["partial"]'); done
t_eq "U330-R2-3 cursor: later runs reach the wrapped-around file and finish with the exact total (21 x 11)" "$PART/$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "False/231"

# ---------------------------------------------------------------- U330-R3-1: settled files excluded from this project fold too (zero rows)
conv() { # NAME CAP: budgeted runs under CAP until a complete result; sets n PART MONO MAXF CAPOK
  local cap=$2 pg nf
  n=0; PART=True; PREV=0; MONO=1; MAXF=0; CAPOK=1
  export PM_USAGE_SLOW=0.05
  while [ "$PART" = True ] && [ "$n" -lt 30 ]; do
    n=$((n+1)); PM_USAGE_CACHE_CAP=$cap uu --budget 0.45 > "$T/run.json"; PART=$(get "$T/run.json" 'd["partial"]')
    pg=$(fx prog "$CF"); nf=${pg#* }; pg=${pg% *}
    [ "$nf" -gt "$MAXF" ] && MAXF=$nf
    [ "$pg" -lt "$PREV" ] && MONO=0; PREV=$pg
    [ "$(wc -c < "$CF")" -gt "$cap" ] && CAPOK=0
  done
  unset PM_USAGE_SLOW
}
clean
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do fx claude "$CP/g$i.jsonl" "$T/elsewhere" 0 1; done
run; t_eq "U330-R3-1 base: 20 transcripts of another project contribute nothing" "$(get "$T/run.json" 'd["sources"]["claude"]["jobs_attributed"]')/$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "0/0"
CAP5=$(fx slimcap "$CF" 60)
rm -rf "$PD"
conv foreign "$CAP5"
t_true "U330-R3-1 foreign: 20 excluded transcripts under a cap that forces whole-file eviction and a small budget converge ($n runs)" '[ "$PART" = False ] && [ "$n" -gt 2 ] && [ "$n" -le 15 ]'
t_true "U330-R3-1 foreign: excluded files really were folded (max $MAXF folded)" '[ "$MAXF" -gt 0 ]'
t_eq "U330-R3-1 foreign: the work that survived each run never went down" "$MONO" 1
t_eq "U330-R3-1 foreign: the cache stayed within the cap" "$CAPOK" 1
t_eq "U330-R3-1 foreign: nothing attributed" "$(get "$T/run.json" 'd["sources"]["claude"]["jobs_attributed"]')/$(get "$T/run.json" 'd["sources"]["claude"]["files_scanned"]')" "0/20"
same "U330-R3-1 foreign: equals the full rescan"
t_true "U330-R3-1 foreign: a folded excluded record has zero rows and no path" '[ "$(get "$CF" "len([r for r in d[\"folded\"].values() if r[\"j\"] == [] and r[\"d\"] is None])")" -ge 1 ]'
PM_USAGE_CACHE_CAP=$CAP5 uu > "$T/run.json"; t_eq "U330-R3-1 foreign: a warm run after the folds reads nothing it need not and stays complete" "$(get "$T/run.json" 'd["partial"]')/$(sc bytes_read)" "False/0"
# mixed: attributed and excluded files together
clean
for i in 1 2 3 4 5 6 7 8 9 10; do fx tiny "$CP/f$i.jsonl" "$ROOT" $i; fx claude "$CP/g$i.jsonl" "$T/elsewhere" 0 1; done
run; t_eq "U330-R3-1 mixed base: 10 attributed one-record files = 110" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 110
CAP6=$(fx slimcap "$CF" 60)
rm -rf "$PD"
conv mixed "$CAP6"
t_true "U330-R3-1 mixed: a mixed attributed/excluded set converges under the cap ($n runs, max $MAXF folded)" '[ "$PART" = False ] && [ "$n" -gt 2 ] && [ "$n" -le 15 ] && [ "$MAXF" -gt 0 ]'
t_eq "U330-R3-1 mixed: the exact total (10 x 11) from 10 jobs" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(get "$T/run.json" 'd["totals"]["claude"]["jobs"]')" "110/10"
t_eq "U330-R3-1 mixed: work never went down, cache within the cap" "$MONO/$CAPOK" "1/1"
same "U330-R3-1 mixed: equals the full rescan"

# ---------------------------------------------------------------- U330-R3-2: file identity is part of "unchanged" (live entries)
clean
IA="$CP/ident.jsonl"; fx claude "$IA" "$ROOT" 0 1
run; t_eq "U330-R3-2 base: one message = 116" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 116
run; t_eq "U330-R3-2 base: ... skipped on the warm run" "$(sc skipped)/$(sc bytes_read)" "1/0"
fx swap "$IA" 0 '"input_tokens":10,' '"input_tokens":90,'
t_eq "U330-R3-2 setup: the replacement has the same size and the same mtime_ns, another inode" "$(python3 - "$IA" "$T/run.json" "$CF" <<'PY'
import json, os, sys
s = os.stat(sys.argv[1]); e = json.load(open(sys.argv[3]))["files"][sys.argv[1]]
print(s.st_size == e["sz"], s.st_mtime_ns == e["mt"], [s.st_dev, s.st_ino, s.st_ctime_ns] != e["di"])
PY
)" "True True True"
run; t_eq "U330-R3-2 live: rename-over with the same size and the mtime restored is read again (116 + 80), not partial" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(get "$T/run.json" 'd["partial"]')/$(sc full)" "196/False/1"
same "U330-R3-2 live: equals the full rescan"
run; t_eq "U330-R3-2 live: and the warm run after it is skipped again" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(sc skipped)/$(sc bytes_read)" "196/1/0"
# an older cache layout (entries without an identity) is rebuilt, not trusted
python3 - "$CF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["key"]["schema"] = "project-map-usage-cache-3"
for e in d["files"].values(): e.pop("di", None)
json.dump(d, open(sys.argv[1], "w"))
PY
run; t_eq "U330-R3-2 schema: a cache of the previous layout is not used" "$(sc cache)/$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "cold/196"

# ---------------------------------------------------------------- U330-R4-1: ctime_ns is part of the identity (in-place rewrite, mtime restored)
clean
IB="$CP/inplace.jsonl"; fx claude "$IB" "$ROOT" 0 1
run; t_eq "U330-R4-1 base: one message = 116" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 116
run; t_eq "U330-R4-1 base: ... skipped on the warm run" "$(sc skipped)/$(sc bytes_read)" "1/0"
t_eq "U330-R4-1 identity: the cached identity and the verification snapshot both carry ctime_ns" "$(python3 - "$IB" "$CF" <<'PY'
import json, os, sys
s = os.stat(sys.argv[1]); e = json.load(open(sys.argv[2]))["files"][sys.argv[1]]
print(e["di"] == [s.st_dev, s.st_ino, s.st_ctime_ns], e["vf"]["sn"] == [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns])
PY
)" "True True"
INO=$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_ino)' "$IB")
fx inplace "$IB" 0 '"input_tokens":10,' '"input_tokens":90,'
t_eq "U330-R4-1 setup: same inode, same size, same mtime_ns as cached; only the ctime moved" "$(python3 - "$IB" "$CF" "$INO" <<'PY'
import json, os, sys
s = os.stat(sys.argv[1]); e = json.load(open(sys.argv[2]))["files"][sys.argv[1]]
print(s.st_ino == int(sys.argv[3]), s.st_size == e["sz"], s.st_mtime_ns == e["mt"], s.st_ctime_ns != e["di"][2])
PY
)" "True True True True"
run; t_eq "U330-R4-1 live: an in-place rewrite with the mtime restored is read again (116 -> 196), not partial" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(get "$T/run.json" 'd["partial"]')/$(sc full)" "196/False/1"
same "U330-R4-1 live: equals the full rescan"
run; t_eq "U330-R4-1 live: and the warm run after it is skipped again" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(sc skipped)/$(sc bytes_read)" "196/1/0"
t_eq "U330-R4-1 snapshot: ident() has five fields and moves with an in-place rewrite that restores the mtime" "$(pyu '
import os, sys
from pmu import load
m = load(sys.argv[1]); f = sys.argv[2]; a = m.ident(os.stat(f)); st = os.stat(f)
with open(f, "r+b") as fh:
    fh.write(b"{")
os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns))
b = m.ident(os.stat(f))
print(len(a), a[:4] == b[:4], a != b)
' "$IB")" "5 True True"
# a folded record carries ctime too: an in-place rewrite of a folded file is read again
clean
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do fx tiny "$CP/f$i.jsonl" "$ROOT" $i; done
run
CAP7=$(fx slimcap "$CF" 60); rm -rf "$PD"
PM_USAGE_CACHE_CAP=$CAP7 uu > "$T/run.json"; t_eq "U330-R4-1 folded: setup: 20 files, 220" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" 220
FL=$(pyu '
import json, sys, os
from pmu import load
m = load(sys.argv[1]); d = json.load(open(sys.argv[2])); f = d["folded"]
print([i for i in range(1, 21) if m.pkey(os.path.join(sys.argv[3], "f%d.jsonl" % i)) in f][0])
' "$CF" "$CP")
t_true "U330-R4-1 folded: setup: there is a folded file (f$FL) and the folded records carry a three-field identity" '[ -n "$FL" ] && [ "$(get "$CF" "sorted(set(len(r[\"i\"]) for r in d[\"folded\"].values()))")" = "[3]" ]'
fx inplace "$CP/f$FL.jsonl" 0 '"input_tokens":5,' '"input_tokens":9,'
PM_USAGE_CACHE_CAP=$CAP7 uu > "$T/run.json"
t_eq "U330-R4-1 folded: an in-place rewrite of a folded file with the mtime restored is read again (220 + 4)" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(get "$T/run.json" 'd["partial"]')" "224/False"
same "U330-R4-1 folded: equals the full rescan"
# a cache of the previous layout (identity without ctime) is rebuilt, not trusted
python3 - "$CF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["key"]["schema"] = "project-map-usage-cache-4"
json.dump(d, open(sys.argv[1], "w"))
PY
PM_USAGE_CACHE_CAP=$CAP7 uu > "$T/run.json"; t_eq "U330-R4-1 schema: a cache of the previous layout (cache-4) is not used" "$(sc cache)/$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "cold/224"

# ---------------------------------------------------------------- U330-R4-2: cache pressure is visible in the scan diagnostics
clean
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do fx tiny "$CP/f$i.jsonl" "$ROOT" $i; done
run; t_eq "U330-R4-2 default cap: no pressure" "$(sc cache_pressure)/$(sc evicted_records)" "False/0"
CAPA=$(fx slimcap "$CF" 60); CAPB=$(fx slimcap "$CF" 12)
rm -rf "$PD"; PM_USAGE_CACHE_CAP=$CAPA uu > "$T/run.json"
t_eq "U330-R4-2 adequate cap (compact records fit, entries were folded): cache_pressure false, evicted_records 0, cache not partial, exact" "$(sc cache_pressure)/$(sc evicted_records)/$(get "$T/run.json" "d['scan'].get('cache_partial', False)")/$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "False/0/False/220"
rm -rf "$PD"; PM_USAGE_CACHE_CAP=$CAPB uu > "$T/run.json"
t_true "U330-R4-2 too small a cap for the compact bucket ($CAPB bytes): cache_pressure true and a nonzero evicted_records ($(sc evicted_records))" '[ "$(sc cache_pressure)" = True ] && [ "$(sc evicted_records)" -gt 0 ]'
t_eq "U330-R4-2 ... the answer is still complete and exact" "$(get "$T/run.json" 'd["partial"]')/$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "False/220"
t_true "U330-R4-2 ... and the cache file stays within the cap" '[ ! -e "$CF" ] || [ "$(wc -c < "$CF")" -le "$CAPB" ]'
rm -rf "$PD"; uu --cache none > "$T/run.json"; t_eq "U330-R4-2 cache off: no pressure fields" "$(get "$T/run.json" "'cache_pressure' in d['scan']")" False

# ---------------------------------------------------------------- U330-R3-3: a folded-key collision never substitutes another file's rows
clean
CA="$CP/ca.jsonl"; CB="$CP/cb.jsonl"
fx tiny "$CA" "$ROOT" 1; fx cpm "$CA" "$CB"; fx edit "$CB" 0 '"input_tokens":5,' '"input_tokens":9,'; python3 - "$CA" "$CB" <<'PY'
import os, sys
st = os.stat(sys.argv[1]); os.utime(sys.argv[2], ns=(st.st_atime_ns, st.st_mtime_ns))
PY
run; t_eq "U330-R3-3 base: two files of equal size and mtime, 11 and 15 tokens" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')/$(python3 -c 'import os,sys;a,b=os.stat(sys.argv[1]),os.stat(sys.argv[2]);print(a.st_size==b.st_size and a.st_mtime_ns==b.st_mtime_ns)' "$CA" "$CB")" "26/True"
CAP7=$(fx slimcap "$CF" 60)
collide() { # EXTRA-ENV...: two runs under the cap with every path forced onto ONE folded key; prints the second run's total and the folded count
  rm -rf "$PD"
  PYTHONPATH="$T" python3 - "$U" "$ROOT" "$CAP7" "$CF" <<'PY'
import contextlib, io, json, os, sys
from pmu import load
m = load(sys.argv[1]); os.environ["PM_USAGE_CACHE_CAP"] = sys.argv[3]
m.pkey = lambda p: "x"                       # every path collides
tot = []
for _ in range(3):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        m.main(["x", sys.argv[2], "--max-jobs", "100"])
    o = json.loads(buf.getvalue())
    tot.append(o["totals"]["claude"]["total"])
print(tot, sorted(j["id"] for j in o["per_job"]), len(json.load(open(sys.argv[4]))["folded"]))
PY
}
t_eq "U330-R3-3 collision: with every path on one folded key, each run reports each file's own total (26, 26, 26)" "$(collide | cut -d']' -f1)]" "[26, 26, 26]"
# two hardlinks share size, mtime AND (device, inode): only the stored rest of the path digest tells their records apart
rm -f "$CB"; ln "$CA" "$CB"; run
CAP7=$(fx slimcap "$CF" 60)
t_eq "U330-R3-3 collision: hardlinked paths (identical size, mtime, inode) on one folded key keep their own job ids" "$(collide | sed 's/^\[[0-9, ]*\] //')" "['claude:ca', 'claude:cb'] 1"
t_eq "U330-R3-3 hook: PM_USAGE_PKEY_LEN=1 (16 possible keys) keeps both hardlinked files (11 + 11)" "$(rm -rf "$PD"; PM_USAGE_PKEY_LEN=1 PM_USAGE_CACHE_CAP=$CAP7 uu > "$T/run.json"; PM_USAGE_PKEY_LEN=1 PM_USAGE_CACHE_CAP=$CAP7 uu > "$T/run.json"; get "$T/run.json" 'd["totals"]["claude"]["total"]')" 22

# ---------------------------------------------------------------- U330-1: counters only, private location, legacy files swept
clean
D1="$CP/d1.jsonl"; fx claude "$D1" "$ROOT" 0 3; fx title "$D1" "Direct Title"
D3="$CP/d3.jsonl"; fx claude "$D3" "$ROOT" 0 2; fx claude "$D3" "$ROOT" 2 2 "$T/foreign-proj-q9"; fx title "$D3" "Title of d3"
MN="$CP/men.jsonl"; fx claude "$MN" "$ROOT" 0 2 -; fx mention "$MN" "$ROOT" 30; fx title "$MN" "MENTION-TITLE-q9"
SA="$CP/d1/subagents/agent-7.jsonl"; fx claude "$SA" "$ROOT" 10 2 -; fx meta "$CP/d1/subagents/agent-7.meta.json" '{"description":"META-DESC-q9","agentType":"Explore-q9"}'
fx claude "$CP/other-project-q9/z.jsonl" "$T/foreign-proj-q9" 0 4
XU="$XP/rollout-2026-10-01T10-00-00-dddddddd.jsonl"; fx codex-new "$XU" "$ROOT"; fx codexuser "$XU" "SECRET-EXCERPT-q9 please rotate the key"; fx codex "$XU" 0 3
mkdir -p "$ROOT/.project-map"; printf keep > "$ROOT/.project-map/keep.txt"
printf x > "$ROOT/.project-map/usage-cache.json"; printf x > "$ROOT/.project-map/usage-last.json"; printf x > "$ROOT/.project-map/.usage-cache.json.tmp.99"
run
t_eq "U330-1 legacy: a legacy usage-cache.json / usage-last.json / temp file in ROOT is deleted, other files stay" "$(ls -A "$ROOT/.project-map" | tr '\n' ' ')" "keep.txt "
t_true "U330-1 out: stdout carries no excerpt, no transcript path, no foreign cwd, no title of a non-direct session, no subagent description" '! grep -q -e "q9" -e "elsewhere" -e "\.claude/projects" -e "\.codex" "$T/run.json"'
t_eq "U330-1 out: a session that ran in the root keeps its ai-title" "$(get "$T/run.json" 'sorted(set(j["label"] for j in d["per_job"] if j["kind"]=="main" and j["attribution"]=="cwd"))')" "['Direct Title', 'Title of d3']"
t_eq "U330-1 out: a mention-attributed session is generic" "$(get "$T/run.json" '[j["label"] for j in d["per_job"] if j["attribution"]=="mentions"][0]')" "Claude session men"
t_eq "U330-1 out: an inherited subagent is generic (no description, no agent type)" "$(get "$T/run.json" '[(j["label"], j["kind"]) for j in d["per_job"] if j["kind"]=="subagent"][0]')" "('Claude session d1', 'subagent')"
t_true "U330-1 out: a Codex session is generic" '[ "$(get "$T/run.json" "[j[\"label\"] for j in d[\"per_job\"] if j[\"source\"]==\"codex\"][0][:14]")" = "Codex session " ]'
t_eq "U330-1 out: every per-job row has only the allowlisted keys" "$(get "$T/run.json" 'sorted(set(k for j in d["per_job"] for k in j))')" "['attribution', 'cache_read', 'cache_write', 'family', 'first_at', 'id', 'in', 'kind', 'label', 'last_at', 'model', 'msgs', 'out', 'source', 'total']"
t_eq "U330-1 out: approximate_files is a count, not a list of names" "$(get "$T/run.json" 'd["sources"]["claude"]["approximate_files"]')/$(get "$T/run.json" '"approximate_files_total" in d["sources"]["claude"]')" "1/False"
t_eq "U330-1 out: the snapshot the callers copy carries the label allowlist version" "$(get "$T/run.json" 'd["snapshot_for_state"]["allow"]')" 2
t_true "U330-1 private: neither file leaves a secret-looking cwd or Codex user text in the last result" '! grep -q -e "SECRET-EXCERPT" -e "foreign-proj" -e "META-DESC" "$LF"'
t_true "U330-1 private: the Codex user message is not even kept in the private cache" '! grep -q "SECRET-EXCERPT" "$CF"'
t_true "U330-1 private: the cache and last result are in the private directory only" '[ -f "$CF" ] && [ -f "$LF" ] && [ -z "$(ls -A "$ROOT/.project-map" | grep usage)" ]'

# ---------------------------------------------------------------- budget: partial result + resume
clean
for i in 1 2 3 4 5 6 7 8 9 10; do fx claude "$CP/b$i.jsonl" "$ROOT" 0 30; done
export PM_USAGE_SLOW=0.04
n=0; PART=1
while [ "$PART" = True ] || [ "$n" = 0 ]; do
  n=$((n+1)); run --budget 0.5; PART=$(get "$T/run.json" 'd["partial"]'); [ "$n" -gt 40 ] && break
done
unset PM_USAGE_SLOW
t_true "U-budget: a cold scan with a tiny budget needs several runs ($n) and then completes" '[ "$n" -gt 1 ] && [ "$PART" = False ]'
same "U-budget: the resumed result equals the full rescan"
uu > "$T/before.json"
for i in 1 2 3 4 5 6 7 8 9 10; do fx claude "$CP/b$i.jsonl" "$ROOT" 30 30; done
PM_USAGE_SLOW=0.04 uu --budget 0.3 > "$T/run.json"
t_eq "U-partial: out of budget -> partial true" "$(get "$T/run.json" 'd["partial"]')" True
t_eq "U-partial: ... snapshot marked partial" "$(get "$T/run.json" 'd["snapshot_for_state"]["partial"]')" True
t_eq "U-partial: ... with the PREVIOUS totals" "$(get "$T/run.json" 'd["snapshot_for_state"]["totals"]')" "$(get "$T/before.json" 'd["snapshot_for_state"]["totals"]')"
t_eq "U-partial: ... and the as-of time of the last complete scan" "$(get "$T/run.json" 'd["snapshot_for_state"]["at"]')" "$(get "$T/before.json" 'd["snapshot_for_state"]["at"]')"
t_eq "U-partial: ... and as_of names it too" "$(get "$T/run.json" 'd["as_of"]')" "$(get "$T/before.json" 'd["generated_at"]')"
n=0; PART=True
while [ "$PART" = True ] && [ "$n" -lt 40 ]; do n=$((n+1)); PM_USAGE_SLOW=0.04 uu --budget 0.5 > "$T/run.json"; PART=$(get "$T/run.json" 'd["partial"]'); done
t_eq "U-partial: later runs finish" "$PART" False
same "U-partial: and equal the full rescan"
t_true "U-partial: the new totals are larger than the old ones" '[ "$(get "$T/run.json" "d[\"totals\"][\"claude\"][\"total\"]")" -gt "$(get "$T/before.json" "d[\"totals\"][\"claude\"][\"total\"]")" ]'
# no previous complete result: partial with nothing to hand back
rm -rf "$PD"
PM_USAGE_SLOW=0.04 uu --budget 0.3 > "$T/run.json"
t_eq "U-partial-none: no previous result -> partial and snapshot null" "$(get "$T/run.json" 'd["partial"]')/$(get "$T/run.json" 'd["snapshot_for_state"]')" "True/None"
rc=0; uu --budget nope > /dev/null || rc=$?; t_eq "U-cli: a bad --budget is rejected (exit 2)" "$rc" 2
rc=0; uu --bogus > /dev/null || rc=$?; t_eq "U-cli: an unknown argument is rejected (exit 2)" "$rc" 2

# ---------------------------------------------------------------- the private directory is never a symlink
clean; fx claude "$CP/c1.jsonl" "$ROOT" 0 5
mkdir -p "$T/elsewhere-usage" "$(dirname "$PD")"; ln -s "$T/elsewhere-usage" "$PD"
run; t_eq "U330-1 private: a usage directory that is a symlink is refused (no cache, nothing written through it, the answer is right)" "$(sc cache)/$(ls -A "$T/elsewhere-usage" | wc -l | tr -d ' ')/$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "off/0/580"
rm -f "$PD"

# ---------------------------------------------------------------- no cache directory, no sources
clean; rm -rf "$ROOT/.project-map"
fx claude "$CP/c1.jsonl" "$ROOT" 0 5
run; t_eq "U-nocache: without a .project-map directory nothing is written under ROOT (the cache is private)" "$(sc cache)/$(ls -A "$ROOT" | wc -l | tr -d ' ')" "cold/0"
t_eq "U-nocache: the totals are still right" "$(get "$T/run.json" 'd["totals"]["claude"]["total"]')" "$((5*116))"
mkdir "$ROOT/.project-map"
rm -rf "$HOME/.claude" "$HOME/.codex"
run; t_eq "U-unavailable: missing source directories -> status unavailable, null totals" "$(get "$T/run.json" 'd["sources"]["claude"]["status"]+"/"+d["sources"]["codex"]["status"]+"/"+str(d["totals"]["all"])')" "unavailable/unavailable/None"

echo; echo "total $((pass+fail)) pass $pass fail $fail"; [ "$fail" = 0 ]
