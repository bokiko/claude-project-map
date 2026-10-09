#!/bin/bash
# Tests for project-map-facts.py + project-map-embed.sh (3.2: generations, staging, validation, coverage) in scratch repos.
# Never touches a real project. Bash 3.2 compatible. HOOKS_DIR points the suite at another scripts directory.
SRC="${HOOKS_DIR:-$(cd "$(dirname "$0")/../scripts" && pwd)}"
TD="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/pm-test.XXXXXX"); T=$(cd "$T" && pwd -P)
BGPIDS=""
cleanup() { for p in $BGPIDS; do kill -9 "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
export PM_USAGE_SKIP=1 PYTHONDONTWRITEBYTECODE=1 HOME="$T/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"; unset CLAUDE_PLUGIN_DATA PM_EMBED_CRASH_AT PM_FACTS_SLOW
HOOKS="$T/hooks"; mkdir "$HOOKS"; PM_SCRIPTS="$HOOKS"; export PM_SCRIPTS   # private copy so the template tests can edit it
cp "$SRC"/project-map-facts.py "$SRC"/project-map-embed.sh "$SRC"/project-map-embed.py "$SRC"/project-map-usage.py \
   "$SRC"/project-map-template.html "$SRC"/pm_*.py "$HOOKS"/
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1 :: $2"; }
t_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2' want '$3'"; fi; }
t_has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "'${2:0:240}' lacks '$3'";; esac; }
t_not() { case "$2" in *"$3"*) bad "$1" "'${2:0:240}' contains '$3'";; *) ok "$1";; esac; }
t_pre() { case "$2" in "$3"*) ok "$1";; *) bad "$1" "'${2:0:240}' does not start with '$3'";; esac; }
t_true() { if eval "$2"; then ok "$1"; else bad "$1" "false: $2"; fi; }
lib()   { python3 "$TD/pm_testlib.py" "$@"; }
facts() { python3 "$HOOKS/project-map-facts.py" "$R" "$@"; }
embed() { bash "$HOOKS/project-map-embed.sh" "$R" "$@"; }
jud()   { lib jud "$PM" "$@"; }
get()   { lib get "$1" "$2"; }
S()     { get "$PM/state.json" "$1"; }
cur()   { readlink "$PM/current"; }
gen()   { cur | sed 's/^gen-//'; }
ngens() { ls -d "$PM"/gen-* 2>/dev/null | wc -l | tr -d ' '; }
bump()  { echo "# t$RANDOM$RANDOM" >> "$R/PLAN.md"; }
settle(){ python3 -c "import os,sys;t=float(sys.argv[2]);os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
ndirs() { ls "$PM" | grep -c '^inv-' | tr -d ' '; }

mkrepo() { # NAME -> R PM: git repo with PLAN.md (300 lines), REVIEW-LOG.md (200), README, docs/, a ledger
  R="$T/$1"; mkdir -p "$R"; R=$(cd "$R" && pwd -P); PM="$R/.project-map"
  (cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false
   seq 1 300 > PLAN.md; seq 1 200 > REVIEW-LOG.md; echo readme > README.md; mkdir -p docs thoughts/ledgers; echo d > docs/a.md
   printf '## Goal\n- goal line\n## Next action\n1. step\n## Blockers\n- b1\n' > thoughts/ledgers/demo-engine.md
   git add -A && git commit -qm init)
}
begin() { # run facts, keep the verdict line and the staging name
  out=$(facts); rc=$?; INV=${out##* }; INVN="inv-$INV"; STAGE="$PM/$INVN"; export STAGE INVN
}
pub() { # CODE KIND -> publish the staging of the last facts run
  jud "$INVN" "${2:-update}" "$1"; eo=$(embed "$INVN"); erc=$?
}
mkproj() { mkrepo "$1"; begin; pub "${2:-}" full
  case "$eo" in "PM_EMBED_OK gen "*) return 0;; *) bad "mkproj $1" "$out | $eo"; return 1;; esac; }
upd() { bump; begin; pub "$1" update; }
rej() { # NAME CODE SUBSTRING [KIND]: embed must fail, publish nothing
  local c0 n0 o r; c0=$(cur); n0=$(ngens)
  jud "$INVN" "${4:-update}" "$2"; o=$(embed "$INVN"); r=$?
  if [ $r -eq 1 ] && case "$o" in *PM_EMBED_ERROR*"$3"*) true;; *) false;; esac && [ "$(cur)" = "$c0" ] && [ "$(ngens)" = "$n0" ]; then
    ok "reject: $1"; else bad "reject: $1" "rc=$r out=${o:0:300}"; fi
}
rejraw() { # NAME RAWTEXT SUBSTRING
  local c0 o r; c0=$(cur); jud "$INVN" update ""; printf '%s' "$2" > "$STAGE/judgement.out.json"; o=$(embed "$INVN"); r=$?
  if [ $r -eq 1 ] && case "$o" in *PM_EMBED_ERROR*"$3"*) true;; *) false;; esac && [ "$(cur)" = "$c0" ]; then ok "reject: $1"; else bad "reject: $1" "rc=$r out=${o:0:300}"; fi
}

# ======================================================================================================
# 0. argument handling and unsupported locations
# ======================================================================================================
mkrepo a0
out=$(python3 "$HOOKS/project-map-facts.py" 2>&1); rc=$?; t_eq "F-args no ROOT -> exit 2" "$rc" 2
out=$(python3 "$HOOKS/project-map-facts.py" relative/dir 2>&1); rc=$?; t_eq "F-args relative ROOT -> exit 2" "$rc" 2
out=$(facts --budget abc 2>&1); rc=$?; t_eq "F-args bad --budget -> exit 2" "$rc" 2
out=$(python3 "$HOOKS/project-map-facts.py" "$T/does-not-exist"); rc=$?; t_eq "F-error unreadable ROOT -> ERROR exit 2" "$rc:${out%% *}" "2:ERROR"
out=$(python3 "$HOOKS/project-map-facts.py" "$HOME"); rc=$?; t_eq "F-error ROOT = \$HOME -> ERROR exit 2" "$rc:${out%% *}" "2:ERROR"
mkdir -p "$T/with space"; out=$(python3 "$HOOKS/project-map-facts.py" "$T/with space"); rc=$?; t_eq "S-preflight space in path -> ERROR exit 2" "$rc:${out%% *}" "2:ERROR"
mkdir -p "$T/sl/real"; ln -s real "$T/sl/.project-map"; out=$(python3 "$HOOKS/project-map-facts.py" "$T/sl"); rc=$?; t_eq "F-error .project-map is a symlink -> ERROR" "$rc:${out%% *}" "2:ERROR"
out=$(python3 "$HOOKS/project-map-facts.py" --close-session "$R"); rc=$?; t_eq "F-close-session prints one line, exit 0" "$rc:${out%% *}" "0:CLOSE_SESSION"
out=$(python3 "$HOOKS/project-map-facts.py" --accept-answers "$R"); rc=$?; t_eq "F-accept-answers without a map -> ERROR exit 2" "$rc:${out%% *}" "2:ERROR"

# ======================================================================================================
# 1. bootstrap: first map, non-git, layout
# ======================================================================================================
mkdir -p "$T/ng/sub/.git" "$T/ng2"; echo hi > "$T/ng/README.md"; echo a > "$T/ng/f.txt"
R=$(cd "$T/ng" && pwd -P); PM="$R/.project-map"
out=$(facts); rc=$?; t_pre "F-bootstrap non-git: NEEDS_FULL first map inv <id>" "$out" "NEEDS_FULL first map inv "
idtok=${out##* }
t_true "F-bootstrap exit 0 and last token is the 8-hex id" "[ $rc = 0 ] && echo $idtok | grep -qE '^[0-9a-f]{8}\$'"
INV=${out##* }; STAGE="$PM/inv-$INV"
t_true "F-stage files: invocation snapshot pack plan judgement.in" "for f in invocation.json snapshot.json pack.json plan.json judgement.in.json; do [ -f $STAGE/\$f ] || exit 1; done"
t_eq "F-stage invocation.base is null for a first map" "$(get "$STAGE/invocation.json" 'd["base"]')" "None"
t_eq "F-stage invocation.root is the real root" "$(get "$STAGE/invocation.json" 'd["root"]')" "$R"
t_eq "F-stage invocation.id" "$(get "$STAGE/invocation.json" 'd["id"]')" "$INV"
t_eq "F-stage snapshot is stamped with the invocation name" "$(get "$STAGE/snapshot.json" 'd["generation"]')" "inv-$INV"
t_eq "F-stage pack is stamped with the invocation name" "$(get "$STAGE/pack.json" 'd["generation"]')" "inv-$INV"
t_eq "F-stage first-map judgement.in is empty" "$(get "$STAGE/judgement.in.json" 'len(d)')" 0
t_eq "F-snapshot non-git: vcs none, files >= 2" "$(get "$STAGE/snapshot.json" 'd["repos"][0]["vcs"]=="none" and d["repos"][0]["files"]>=2')" True
t_eq "F-snapshot default watch list is README" "$(get "$STAGE/snapshot.json" '[w["path"] for w in d["watch"]]')" "['README.md']"
t_eq "F-snapshot nested .git discovered as a repo entry" "$(get "$STAGE/snapshot.json" 'any(r["path"]=="sub" for r in d["repos"])')" True
t_eq "F-snapshot coverage complete 1/1" "$(get "$STAGE/snapshot.json" '(d["status"]["coverage"],d["status"]["covered"],d["status"]["total"])')" "('complete', 1, 1)"
t_true "F-bootstrap writes cache.json with the watch cache" "[ -f $PM/cache.json ] && grep -q watch_cache $PM/cache.json"
t_true "F-bootstrap never creates current or stable links" "[ ! -e $PM/current ] && [ ! -e $PM/state.json ]"
out=$(facts --json); t_true "F-json prints one JSON object with verdict, exit and snapshot" "echo \"\$out\" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d[\"verdict\"].startswith(\"NEEDS_FULL\") and d[\"exit\"]==0 and d[\"snapshot\"][\"schema\"]==\"project-map-snapshot-1\"'"
R=$(cd "$T/ng2" && pwd -P); PM="$R/.project-map"; out=$(facts); t_eq "F-ledger none -> ledger null, no error" "$(get "$PM/inv-${out##* }/snapshot.json" 'd["ledger"]')" None
mkdir -p "$T/home/thoughts/ledgers" "$T/led-3"; printf '## Goal\n- g\n' > "$T/home/thoughts/ledgers/CONTINUITY_CLAUDE-led.md"
R=$(cd "$T/led-3" && pwd -P); PM="$R/.project-map"; out=$(facts)
t_eq "F-ledger found via basename minus -digits under ~/thoughts" "$(get "$PM/inv-${out##* }/snapshot.json" 'd["ledger"]["goal"]')" "- g"
out=$(embed inv-deadbeef); t_pre "E-embed unknown staging -> PM_EMBED_ERROR" "$out" "PM_EMBED_ERROR"
out=$(embed ../../etc); t_pre "E-embed bad staging name -> PM_EMBED_ERROR" "$out" "PM_EMBED_ERROR"
out=$(bash "$HOOKS/project-map-embed.sh"); rc=$?; t_eq "E-embed no arguments -> exit 1" "$rc" 1
out=$(bash "$HOOKS/project-map-embed.sh" "$R" --mechanical); rc=$?; t_true "E-mech without a map -> PM_EMBED_ERROR exit 1" "[ $rc = 1 ] && case '$out' in PM_EMBED_ERROR*) true;; *) false;; esac"

# ======================================================================================================
# 2. first publish, layout, stamps, brief, gate
# ======================================================================================================
mkrepo p1; begin
t_pre "F-first map in a git repo: NEEDS_FULL first map inv" "$out" "NEEDS_FULL first map inv "
t_eq "F-stage snapshot repos[0] is git with a 40-hex-derived head" "$(get "$STAGE/snapshot.json" 'd["repos"][0]["vcs"]=="git" and len(d["repos"][0]["head"])==12 and d["repos"][0]["branch"]=="main"')" True
t_eq "F-stage snapshot commits: 1 commit listed" "$(get "$STAGE/snapshot.json" '(d["commits"]["count"],d["commits"]["listed"])')" "(1, 1)"
t_eq "F-stage snapshot ledger is the newest local ledger (absolute path)" "$(get "$STAGE/snapshot.json" 'd["ledger"]["path"].endswith("thoughts/ledgers/demo-engine.md") and d["ledger"]["path"].startswith("/")')" True
t_eq "F-stage snapshot ledger sections parsed (goal / next / blockers)" "$(get "$STAGE/snapshot.json" '(d["ledger"]["goal"],d["ledger"]["next"],d["ledger"]["blockers"])')" "('- goal line', '1. step', '- b1')"
t_eq "F-stage snapshot key has the 8 components" "$(get "$STAGE/snapshot.json" 'sorted(d["key"])')" "['answers_count', 'branches', 'expired_ids', 'heads', 'ledger_hash', 'schema', 'status_hash', 'watch_hashes']"
t_eq "F-stage snapshot answers baseline: applied 0, no pending" "$(get "$STAGE/snapshot.json" '(d["answers"]["applied"],len(d["answers"]["pending"]))')" "(0, 0)"
t_true "F-stage pack <= 8192 bytes" "[ \$(wc -c < $STAGE/pack.json) -le 8192 ]"
t_eq "F-stage pack drops the raw keys for digests" "$(get "$STAGE/pack.json" '"key" not in d and len(d["key_digest"])==12')" True
t_eq "F-stage pack carries trimmed counters (all zero here)" "$(get "$STAGE/pack.json" 'd["trimmed"]')" "{'items': 0, 'watch': 0, 'ledger': False, 'answers': 0, 'decisions': 0, 'usage': False}"
jud "$INVN" full ""; eo=$(embed "$INVN"); erc=$?
t_true "E-publish: PM_EMBED_OK gen <seq>-<id> <bytes>, exit 0" "[ $erc = 0 ] && echo '$eo' | grep -qE '^PM_EMBED_OK gen 000001-[0-9a-f]{8} [0-9]+\$'"
G=$(gen)
t_true "E-layout current -> gen-000001-<id8> (one symlink)" "[ -L $PM/current ] && [ \"\$(cur)\" = gen-$G ]"
t_true "E-layout stable links index mobile brief state -> current/<name>" "for n in index.html mobile.html brief.txt state.json; do [ \"\$(readlink $PM/\$n)\" = current/\$n ] || exit 1; done"
t_true "E-layout generation files exist" "for n in manifest.json state.json index.html mobile.html brief.txt snapshot.json pack.json plan.json judgement.json; do [ -f $PM/gen-$G/\$n ] || exit 1; done"
t_true "E-layout invocation/ is a copy of the staging dir (audit trail)" "[ -f $PM/gen-$G/invocation/judgement.out.json ] && [ -f $PM/gen-$G/invocation/plan.out.json ] && [ -f $PM/gen-$G/invocation/snapshot.json ]"
t_true "E-stage-retain: STAGE is still in place after a successful publish" "[ -f $STAGE/judgement.out.json ]"
t_eq "E-manifest generation and base" "$(get "$PM/current/manifest.json" '(d["generation"],d["base"])')" "('$G', None)"
t_eq "E-manifest lists every file with size+sha256 (manifest itself excluded)" "$(get "$PM/current/manifest.json" 'all(set(v)=={"size","sha256"} for v in d["files"].values()) and "manifest.json" not in d["files"] and "invocation/plan.out.json" in d["files"]')" True
t_eq "E-manifest complete: every listed file matches its size" "$(python3 -c "
import json,os,sys
d='$PM/gen-$G'; m=json.load(open(d+'/manifest.json'))
print(all(os.path.getsize(d+'/'+k)==v['size'] for k,v in m['files'].items()))")" True
for f in state snapshot pack plan judgement; do t_eq "E-stamp $f.json carries generation $G" "$(get "$PM/current/$f.json" 'd["generation"]')" "$G"; done
t_true "E-stamp index.html and mobile.html carry <meta name=pm-generation>" "grep -q 'name=\"pm-generation\" content=\"$G\"' $PM/current/index.html && grep -q 'name=\"pm-generation\" content=\"$G\"' $PM/current/mobile.html"
t_eq "E-stamp brief.txt last line is 'generation <seq>-<id>'" "$(tail -1 "$PM/brief.txt")" "generation $G"
t_eq "E-state schema is project-map-4" "$(S 'd["schema"]')" "project-map-4"
t_eq "E-state generation_files lists the files" "$(S '"index.html" in d["generation_files"] and "invocation/plan.out.json" in d["generation_files"]')" True
t_eq "E-state identity: name, folder, branch, head, generation" "$(S '(d["identity"]["name"],d["identity"]["branch"],len(d["identity"]["head"]),d["identity"]["generation"])')" "('demo-app', 'main', 7, '$G')"
t_eq "E-state identity.folder is the real root (no ~ outside HOME)" "$(S 'd["identity"]["folder"]')" "$R"
t_eq "E-state phases derived: P1 done, P2 current, P3 next" "$(S '[(p["id"],p["state"]) for p in d["phases"]]')" "[('P1', 'done'), ('P2', 'current'), ('P3', 'next')]"
t_eq "E-state phase done/total per phase" "$(S '[(p["done"],p["total"]) for p in d["phases"]]')" "[(1, 1), (0, 4), (0, 0)]"
t_eq "E-state focus: phase, done, total, next_step" "$(S '(d["focus"]["phase"],d["focus"]["done"],d["focus"]["total"],d["focus"]["next_step"]["actor"])')" "('P2', 0, 4, 'claude')"
t_eq "E-state coverage complete" "$(S 'd["coverage"]["coverage"]')" complete
t_eq "E-state judged_key holds the facts key; answers baseline recorded" "$(S '(sorted(d["judged_key"])==["answers_count","branches","expired_ids","heads","ledger_hash","schema","status_hash","watch_hashes"], d["answers"]["applied"])')" "(True, 0)"
t_eq "E-state history has one run, run.n 1" "$(S '(len(d["history"]),d["run"]["n"])')" "(1, 1)"
t_eq "E-state decisions: D-001 open (not ready), D-002 hard-rule open" "$(S '[(x["id"],x["status"],x["default"]) for x in d["decisions"]]')" "[('D-001', 'open', 'hold'), ('D-002', 'open', 'hold')]"
t_eq "E-state watch recorded from the first snapshot (README PLAN docs ledgers)" "$(S 'd["watch"]')" "['README.md', 'PLAN.md', 'docs', 'thoughts/ledgers']"
t_eq "E-state stale is null right after publishing" "$(S 'd["stale"]')" None
t_true "E-brief <= 1000 bytes" "[ \$(wc -c < $PM/brief.txt) -le 1000 ]"
t_true "E-brief line 1 folder: last two components after an ellipsis, no mid-component cut" "head -1 $PM/brief.txt | grep -qE ' · …/[^/ ]+/[^/ ]+ · phase'"
t_pre "E-brief line 1 starts with the project name" "$(head -1 "$PM/brief.txt")" "demo-app · "
t_true "E-brief line 1 ends with '· phase k/n <label> · <tone>'" "head -1 $PM/brief.txt | grep -q ' · phase 2/3 Full-model check passes · watch\$'"
t_pre "E-brief line 2 = assessment <minute> · current" "$(sed -n 2p "$PM/brief.txt")" "assessment 20"
t_has "E-brief line 2 ends with '· current'" "$(sed -n 2p "$PM/brief.txt")" "· current"
t_eq "E-brief line 3 is the headline" "$(sed -n 3p "$PM/brief.txt" | cut -c1-29)" "Full-model check failed twice"
t_has "E-brief names the next step" "$(cat "$PM/brief.txt")" "next: Finish the cycle-2 diagnosis report (claude)"
t_true "F-gate NO_CHANGE x2 after a publish" "[ \"\$(facts)\" = 'NO_CHANGE nothing moved' ] && [ \"\$(facts)\" = 'NO_CHANGE nothing moved' ]"
t_eq "F-gate exactly one stdout line" "$(facts | wc -l | tr -d ' ')" 1
t_true "E-publish leaves no tmp files or dirs" "! ls -A $PM | grep -q 'tmp'"
t_true "F-gate does not create a staging dir for NO_CHANGE" "[ \$(ndirs) = 1 ]"
t_true "E-lock-file: .lock is a regular file" "[ -f $PM/.lock ]"

# ======================================================================================================
# 3. which moves flip the key (F-*)
# ======================================================================================================
mkproj k1 || true
bump; out=$(facts); t_pre "F-key touching a watched file -> NEEDS_JUDGEMENT watch changed" "$out" "NEEDS_JUDGEMENT"
t_has "F-key watch change names the file" "$out" "watch changed: PLAN.md"
t_has "F-key working tree change reported" "$out" "working tree changed"
git -C "$R" checkout -q PLAN.md; t_eq "F-key reverting the edit returns to NO_CHANGE-or-refresh" "$(facts | cut -d' ' -f1 | grep -c -E '^(NO_CHANGE|NEEDS_REFRESH)$')" 1
facts >/dev/null
echo one > "$R/u.txt"; out=$(facts); t_has "F-key untracked file -> working tree changed" "$out" "working tree changed"
upd 'J["headline"]["text"]="dirty"'; t_pre "E-dirty file published" "$eo" "PM_EMBED_OK"
t_eq "F-key calm after the dirty file was judged" "$(facts)" "NO_CHANGE nothing moved"
echo "two two" > "$R/u.txt"; out=$(facts); t_has "F-key second edit of an already-dirty file is seen" "$out" "working tree changed"
git -C "$R" add -A; git -C "$R" commit -qm "more"; out=$(facts); t_has "F-key new commit -> N new commits" "$out" "1 new commits"
t_true "F-stale-refresh: the brief shows '1 commits since' after a verdict that spawns" "sed -n 2p $PM/brief.txt | grep -q '1 commits since'"
t_eq "F-stale-refresh: state.stale has judged_at, commits_since, why" "$(S '(d["stale"]["commits_since"], d["stale"]["why"].startswith("1 new commits"), "judged_at" in d["stale"])')" "(1, True, True)"
t_eq "F-stale-refresh: the page itself stays at the judged state (headline unchanged)" "$(S 'd["headline"]["text"]')" "dirty"
upd 'J["headline"]["text"]="after commit"'; t_pre "E-rejudge after a commit publishes" "$eo" "PM_EMBED_OK"
t_eq "E-rejudge clears the stale flag" "$(S 'd["stale"]')" None
t_eq "F-key calm after re-judging" "$(facts)" "NO_CHANGE nothing moved"
git -C "$R" checkout -q -b feat; out=$(facts); t_has "F-key branch switch -> branch changed" "$out" "branch changed"
git -C "$R" checkout -q main; settle "$R/PLAN.md" "$(date +%s)"
printf '## Goal\n- other\n' >> "$R/thoughts/ledgers/demo-engine.md"; out=$(facts); t_has "F-key ledger edit -> ledger changed" "$out" "ledger changed"
git -C "$R" checkout -q . 2>/dev/null; rm -f "$R/u.txt"
# ctime: same-size edit with the mtime restored, on an ignored (so git-invisible) watched file
mkproj c1 || true
printf 'docs/ign.md\n' > "$R/.gitignore"; echo abcd > "$R/docs/ign.md"; git -C "$R" add .gitignore; git -C "$R" commit -qm ign
upd 'J["headline"]["text"]="ign"'; t_eq "F-ctime baseline calm with an ignored watched file" "$(facts)" "NO_CHANGE nothing moved"
python3 - "$R/docs/ign.md" <<'PY'
import os, sys
p = sys.argv[1]; st = os.stat(p)
with open(p, "r+b") as fh:
    fh.write(b"abce")   # same size, in place
os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
PY
out=$(facts); t_has "F-ctime same-size edit with restored mtime flips the key" "$out" "watch changed: docs"
t_eq "F-untracked-watched: ignored files are hashed (docs hash moved, git status empty)" "$(git -C "$R" status --porcelain | grep -c ign.md)" 0

# F-log-n / F-log-at
mkrepo l1; for i in $(seq 1 59); do git -C "$R" commit -q --allow-empty -m "c$i"; done; git -C "$R" commit -q --allow-empty -m "fix: broken @@ router bound"
begin
t_eq "F-log-n 61 commits on a first map -> count <= 40" "$(get "$STAGE/snapshot.json" 'd["commits"]["count"]<=40 and d["commits"]["count"]>0')" True
t_eq "F-log-n exactly 40 listed" "$(get "$STAGE/snapshot.json" 'd["commits"]["listed"]')" 40
t_eq "F-log-at subject with '@@' stays intact" "$(get "$STAGE/snapshot.json" '[i["s"] for dd in d["commits"]["days"] for i in dd["items"] if "@@" in i["s"]]')" "['fix: broken @@ router bound']"
t_eq "F-log-at the same commit is flagged fail" "$(get "$STAGE/snapshot.json" '[i["f"] for dd in d["commits"]["days"] for i in dd["items"] if "@@" in i["s"]]')" "['fail']"
pub "" full; t_pre "E-publish after a long log" "$eo" "PM_EMBED_OK"
for i in 1 2 3; do git -C "$R" commit -q --allow-empty -m "n$i"; done; out=$(facts)
t_eq "F-log incremental: exact count since the judged head (3)" "$(get "$PM/inv-${out##* }/snapshot.json" 'd["commits"]["count"]')" 3
git -C "$R" reset -q --hard "HEAD~4"; git -C "$R" commit -q --allow-empty -m "after reset"; out=$(facts)
t_eq "F-log rewritten history (judged head no longer an ancestor) detected" "$(get "$PM/inv-${out##* }/snapshot.json" 'd["repos"][0]["rewritten"]')" True

# F-ledger-name: the basename match wins over mtime
mkdir -p "$T/ledtest"; R=$(cd "$T/ledtest" && pwd -P); PM="$R/.project-map"; (cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t && mkdir -p thoughts/ledgers && printf '## Goal\n- mine\n' > thoughts/ledgers/ledtest.md && printf '## Goal\n- newer\n' > thoughts/ledgers/zzz-newer.md && echo r > README.md && git add -A && git commit -qm i)
settle "$R/thoughts/ledgers/ledtest.md" 1000000000; settle "$R/thoughts/ledgers/zzz-newer.md" 2000000000
begin; t_eq "F-ledger-name basename match wins over a newer mtime" "$(get "$STAGE/snapshot.json" '(d["ledger"]["name"],d["ledger"]["binding"])')" "('ledtest.md', 'basename')"
rm "$R/thoughts/ledgers/ledtest.md"; begin; t_eq "F-ledger-name without a basename match the newest ledger is used" "$(get "$STAGE/snapshot.json" '(d["ledger"]["name"],d["ledger"]["binding"])')" "('zzz-newer.md', 'newest')"

# ======================================================================================================
# 4. validation: every rule is a reject case (E-types and the rest of 6.3/6.4)
# ======================================================================================================
mkproj v1 || true
bump; begin; t_pre "E-types setup: NEEDS_JUDGEMENT with a staging dir" "$out" "NEEDS_JUDGEMENT"
rej "unknown top-level key" 'J["extra"]=1' "unknown keys: extra"
rej "unknown nested key (project)" 'J["project"]["colour"]="x"' "project has unknown keys"
rej "unknown nested key (part)" 'J["parts"][0]["foo"]=1' "part has unknown keys"
rej "generation of another invocation" 'J["generation"]="inv-00000000"' "does not match this invocation"
rej "project missing" 'del J["project"]' "missing: project"
rej "project.name over 40 bytes" 'J["project"]["name"]="n"*41' "project.name must be 1..40"
rej "project.name counts bytes not characters" 'J["project"]["name"]="é"*21' "project.name must be 1..40"
rej "project.goal over 160 bytes" 'J["project"]["goal"]="g"*161' "project.goal"
rej "run.type FULL on an UPDATE staging" 'J["run"]["type"]="FULL"' "FULL run needs plan.out.json"
rej "run.type invalid" 'J["run"]["type"]="MAYBE"' "run.type must be one of"
rej "headline.tone invalid" 'J["headline"]["tone"]="alarm"' "headline.tone must be one of"
rej "headline.tone 'stale' is script-owned" 'J["headline"]["tone"]="stale"' "headline.tone must be one of ok|watch|blocked"
rej "headline.text over 180 bytes" 'J["headline"]["text"]="h"*181' "headline.text"
rej "parts empty" 'J["parts"]=[]' "parts has 0 entries"
rej "parts 13 entries" 'J["parts"]=[{"id":"p%02d"%i,"label":"x","status":"unknown"} for i in range(13)]' "parts has 13 entries"
rej "part id with an uppercase letter" 'J["parts"][0]["id"]="Bad"' "bad id"
rej "duplicate part id" 'J["parts"][1]["id"]=J["parts"][0]["id"]' "duplicate id"
rej "part label over 40 bytes" 'J["parts"][0]["label"]="l"*41' "label must be 1..40"
rej "part status not_started (3.x word)" 'J["parts"][0]["status"]="not_started"' "status must be one of"
rej "part line over 100 bytes" 'J["parts"][0]["line"]="l"*101' "line must be"
rej "done part without a ref" 'J["parts"][0].pop("ref")' "is done but has no ref"
rej "part ref: file that does not exist" 'J["parts"][0]["ref"]="file:nope/missing.md"' "not an existing regular file"
rej "part ref: file:. (a directory)" 'J["parts"][0]["ref"]="file:."' "not an existing regular file"
rej "part ref: line past the end (file:README.md:999999)" 'J["parts"][0]["ref"]="file:README.md:999999"' "has no line 999999"
rej "part ref: line 0" 'J["parts"][0]["ref"]="file:PLAN.md:0"' "positive integer"
rej "part ref: commit:HEAD" 'J["parts"][0]["ref"]="commit:HEAD"' "7-40 hex"
rej "part ref: commit that is not in the repo" 'J["parts"][0]["ref"]="commit:abcdef1234"' "not found in any known repository"
rej "part ref: cmd: kind no longer accepted" 'J["parts"][0]["ref"]="cmd:make test"' "must start with file: or commit:"
rej "part ref: into .project-map/" 'J["parts"][0]["ref"]="file:.project-map/state.json"' "points into .project-map"
rej "part ref: absolute path" 'J["parts"][0]["ref"]="file:/etc/hosts"' "relative path inside the project"
rej "part ref: .. escape" 'J["parts"][0]["ref"]="file:../x.md"' "relative path inside the project"
rej "stuck part without blocked_by" 'J["parts"][3].pop("blocked_by")' "blocked_by must name another part"
rej "blocked_by unknown id" 'J["parts"][3]["blocked_by"]="ghost"' "blocked_by must name another part"
rej "blocked_by itself" 'J["parts"][3]["blocked_by"]=J["parts"][3]["id"]' "blocked_by must name another part"
rej "current_phase unknown" 'J["current_phase"]="P9"' "current_phase must be one of"
rej "criteria_updates unknown id" 'J["criteria_updates"]=[{"id":"P2.c8","done":False}]' "unknown criterion"
rej "criteria_updates duplicate" 'J["criteria_updates"]=[{"id":"P2.c1","done":False},{"id":"P2.c1","done":False}]' "duplicate P2.c1"
rej "criteria_updates done without a ref" 'J["criteria_updates"]=[{"id":"P2.c1","done":True}]' "done needs a ref"
rej "criteria_updates done with a dangling ref" 'J["criteria_updates"]=[{"id":"P2.c1","done":True,"ref":"file:nope.md"}]' "criteria_updates P2.c1"
rej "criteria_updates done as string" 'J["criteria_updates"]=[{"id":"P2.c1","done":"true","ref":"file:PLAN.md:1"}]' "done must be true or false"
rej "eta without unit" 'J["eta"].pop("unit")' "eta is missing: unit"
rej "eta low is a bool" 'J["eta"]["low"]=True' "eta.low must be an integer"
rej "eta high below low" 'J["eta"]["high"]=0' "eta.high must be >= eta.low"
rej "eta unit invalid" 'J["eta"]["unit"]="years"' "eta.unit must be one of"
rej "eta confidence 'medium' (3.x word)" 'J["eta"]["confidence"]="medium"' "eta.confidence must be one of"
rej "eta basis over 80 bytes" 'J["eta"]["basis"]="b"*81' "eta.basis"
rejraw "eta NaN (non-finite number)" '{"eta":{"low":NaN}}' "non-finite number"
rejraw "eta Infinity" '{"eta":{"low":0,"high":Infinity}}' "non-finite number"
rej "next_step actor 'owner-name' (3.x word)" 'J["next_step"]["actor"]="owner-name"' "next_step.actor must be one of"
rej "next_step.unblocks unknown part" 'J["next_step"]["unblocks"]=["no-such-part"]' "unknown part"
rej "next_step.title over 80 bytes" 'J["next_step"]["title"]="t"*81' "next_step.title"
rej "decisions: 7 entries" 'J["decisions"]=[dict(J["decisions"][0],id="D-%03d"%i) for i in range(7)]' "decisions has 7 entries"
rej "decision id not D-nnn" 'J["decisions"][0]["id"]="D-1"' "bad id"
rej "decision option without an id" 'J["decisions"][0]["options"][0].pop("id")' "option is missing: id"
rej "decision options: only one" 'J["decisions"][0]["options"]=J["decisions"][0]["options"][:1]' "options has 1 entries"
rej "decision option id outside A-E" 'J["decisions"][0]["options"][0]["id"]="Z"' "bad id"
rej "decision default not an option" 'J["decisions"][0]["default"]="Q"' "default must be an option id"
rej "decision recommended not an option" 'J["decisions"][0]["recommended"]="Q"' "recommended must be an option id"
rej "hard_rule with a non-hold default" 'J["decisions"][1]["default"]="A"' "must have default 'hold'"
rej "ready:false with a non-hold default" 'J["decisions"][0]["default"]="A"' "must have default 'hold'"
rej "ready as the string \"false\"" 'J["decisions"][0]["ready"]="false"' "ready must be true or false"
rej "decision deadline not ISO" 'J["decisions"][0]["deadline"]="next week"' "deadline must be an ISO timestamp"
rej "decision deadline year out of range" 'J["decisions"][0]["deadline"]="99999-01-01T00:00:00Z"' "deadline must be an ISO timestamp"
rej "model-supplied decision status" 'J["decisions"][0]["status"]="answered"' "owned by the script"
rej "model-supplied decision answer" 'J["decisions"][0]["answer"]="A"' "owned by the script"
rej "decision q over 140 bytes" 'J["decisions"][0]["q"]="q"*141' "q must be"
rej "loop id not L-nn" 'J["loops"][0]["id"]="loop1"' "bad id"
rej "loop kind 'validation' (3.x word)" 'J["loops"][0]["kind"]="validation"' "loop.kind must be one of"
rej "loop with 3.x keys (attempts)" 'J["loops"][0]["attempts"]=2' "unknown keys: attempts"
rej "risks: 5 entries" 'J["risks"]=[{"id":"R-%d"%i,"text":"x","severity":"low"} for i in range(5)]' "risks has 5 entries"
rej "risk severity invalid" 'J["risks"][0]["severity"]="critical"' "risk.severity must be one of"
rej "template_feedback: 6 entries" 'J["template_feedback"]=[{"where":"a","text":"b"}]*6' "template_feedback has 6 entries"
rej "secret-looking text" 'J["next_step"]["why"]="api_key: abcdefghijklmnop"' "looks like it contains a secret"
rej "E-watch-41 watch with 41 entries" 'J["watch"]=["w%d"%i for i in range(41)]' "watch has 41 entries"
rej "E-watch-long watch with 125 paths" 'J["watch"]=["docs/p%03d"%i for i in range(125)]' "watch has 125 entries"
rej "watch entry absolute" 'J["watch"]=["/etc/passwd"]' "relative path inside the project"
rej "watch entry with .." 'J["watch"]=["../x"]' "relative path inside the project"
rej "repos: 13 entries" 'J["repos"]=["r%d"%i for i in range(13)]' "repos has 13 entries"
rej "judgement over 6144 bytes" 'J["parts"][0]["line"]="x"*100; J["next_step"]["why"]="y"*100; J["watch"]=["docs/"+"z"*190+str(i) for i in range(40)]' "hard limit 6144"
rej "plan.out.json on an UPDATE run" 'open(os.environ.get("STAGE")+"/plan.out.json","w").write("{}")' "only valid for a FULL run"
rm -f "$STAGE/plan.out.json"
rejraw "judgement not an object" '[1,2]' "judgement must be an object"
rejraw "invalid JSON" '{"headline": ' "not valid JSON"
out=$(jud "$INVN" update 'pass'; rm "$STAGE/judgement.out.json"; embed "$INVN"); t_has "E-missing judgement.out.json" "$out" "judgement.out.json is missing"
# positives: the accepted forms
jud "$INVN" update 'J["parts"][0]["ref"]="file:PLAN.md:300"; J["parts"][1]["ref"]="commit:'"$(git -C "$R" rev-parse --short=10 HEAD)"'"'; eo=$(embed "$INVN"); t_pre "E-types accepted: file:PLAN.md:300 (last line) and a real commit:<sha10>" "$eo" "PM_EMBED_OK"
upd 'J["criteria_updates"]=[{"id":"P2.c1","done":True,"ref":"file:REVIEW-LOG.md:200"}]'; t_pre "E-types accepted: criteria_updates with a resolving ref" "$eo" "PM_EMBED_OK"

# FULL-run plan rules
bump; begin
rej "FULL: missing plan.out.json" 'J["run"]["type"]="FULL"' "FULL run needs plan.out.json" update
rej "FULL: plan.out schema" 'P["schema"]="project-map-plan-2"' "plan.schema must be" full
rej "FULL: plan.out generation of another invocation" 'P["generation"]="inv-00000000"' "plan.out.json generation" full
rej "FULL: plan.out origin invalid" 'P["origin"]="guess"' "plan.origin must be one of" full
rej "FULL: plan.out with 8 phases" 'P["phases"]=[{"id":"P%d"%i,"label":"x","criteria":[]} for i in range(1,9)]' "plan.phases has 8 entries" full
rej "FULL: plan.out with 0 phases" 'P["phases"]=[]' "plan.phases has 0 entries" full
rej "FULL: phase id P0" 'P["phases"][0]["id"]="P0"' "bad id" full
rej "FULL: phase id duplicate" 'P["phases"][1]["id"]="P1"' "duplicate id" full
rej "FULL: 9 criteria in one phase" 'P["phases"][1]["criteria"]=[{"id":"P2.c%d"%(i%8+1),"text":"x","done":False} for i in range(9)]' "criteria has 9 entries" full
rej "FULL: criterion id under the wrong phase (P1.c1 inside P2)" 'P["phases"][1]["criteria"][0]["id"]="P1.c5"' "does not belong to phase P2" full
rej "FULL: criterion id format" 'P["phases"][1]["criteria"][0]["id"]="c1"' "bad id" full
rej "FULL: criterion text over 80 bytes" 'P["phases"][1]["criteria"][0]["text"]="t"*81' "text must be" full
rej "FULL: done criterion without ref" 'P["phases"][0]["criteria"][0].pop("ref")' "is done but has no ref" full
rej "FULL: done criterion with a dangling ref" 'P["phases"][0]["criteria"][0]["ref"]="file:gone.md"' "criterion P1.c1" full
rej "FULL: phase label over 60 bytes" 'P["phases"][0]["label"]="l"*61' "label must be" full
rej "FULL: unknown key in a criterion" 'P["phases"][0]["criteria"][0]["why"]="x"' "unknown keys" full
rej "FULL: current_phase must exist in plan.out (not the carried one)" 'J["current_phase"]="P4"' "current_phase must be one of" full
pub 'P["phases"].append({"id":"P4","label":"Extra","criteria":[]}); J["current_phase"]="P4"' full; t_pre "E-FULL re-proposes the plan (4 phases) and publishes" "$eo" "PM_EMBED_OK"
t_eq "E-FULL new plan is the carried plan afterwards" "$(S 'len(d["phases"])')" 4
t_eq "E-FULL run type recorded" "$(S 'd["run"]["type"]')" FULL

# ======================================================================================================
# 5. plan / phase derivation, criteria updates across phases, brief priorities
# ======================================================================================================
mkproj ph || true
upd 'J["criteria_updates"]=[{"id":"P2.c1","done":True,"ref":"file:PLAN.md:1"},{"id":"P2.c2","done":True,"ref":"file:PLAN.md:2"},{"id":"P2.c3","done":True,"ref":"file:PLAN.md:3"},{"id":"P2.c4","done":True,"ref":"file:PLAN.md:4"}]; J["current_phase"]="P2"'
t_pre "E-phases: updates across phases publish" "$eo" "PM_EMBED_OK"
t_eq "E-phases: a phase with every criterion done is done (derived, not declared)" "$(S '[(p["id"],p["state"]) for p in d["phases"]]')" "[('P1', 'done'), ('P2', 'done'), ('P3', 'current')]"
t_eq "E-phases: current_phase done -> first non-done phase becomes current; focus follows" "$(S '(d["focus"]["phase"],d["focus"]["label"])')" "('P3', 'GPU speed-up proven')"
t_eq "E-phases: a phase with zero criteria is never done" "$(S '[p["done"] for p in d["phases"] if p["id"]=="P3"]')" "[0]"
upd 'J["criteria_updates"]=[{"id":"P1.c1","done":False}]; J["current_phase"]="P3"'
t_eq "E-phases: update to an EARLIER phase reopens it" "$(S '[(p["id"],p["state"],p["done"]) for p in d["phases"] if p["id"]=="P1"]')" "[('P1', 'open', 0)]"
t_eq "E-phases: an unfinished earlier phase is flagged blocking" "$(S '[p.get("blocking") for p in d["phases"] if p["id"]=="P1"]')" "[True]"
t_has "E-phases: headline note lists the unfinished phase" "$(S 'd["headline"].get("note")')" "Unfinished earlier phase: Runs real weights"
t_eq "E-phases: focus stays on the model's current phase" "$(S 'd["focus"]["phase"]')" "P3"
t_eq "E-changes: criteria movement appears in changes[]" "$(S 'any("criteria" in c["text"] for c in d["changes"])')" True
t_eq "E-history: run n increments with every judged publish (3 so far)" "$(S 'd["run"]["n"]')" 3
t_eq "E-history: capped list of runs, newest last" "$(S '[h["run"] for h in d["history"]]')" "[1, 2, 3]"
for i in 1 2 3 4 5 6 7 8 9 10; do upd "J[\"headline\"][\"text\"]=\"run $i\""; done
t_eq "E-history capped at 10 entries" "$(S 'len(d["history"])')" 10
t_eq "E-history keeps the newest run last" "$(S 'd["history"][-1]["run"]')" 13
t_true "E-gens: at least one generation per judged run (stale re-renders add more), seq monotonic" "[ \$(ls -d $PM/gen-* | wc -l) -ge 13 ] && [ \$(gen | cut -c1-6 | sed 's/^0*//') -ge 13 ]"
t_true "E-gens: the newest generations are kept complete (older ones are pruned)" "[ -f $PM/$(cur)/manifest.json ] && [ \$(ls -d $PM/gen-* | wc -l) -ge 10 ]"

# brief with 6 decisions (E-brief-6)
mkproj b6 || true
upd 'J["decisions"]=[{"id":"D-%03d"%i,"q":"Question number %d: "%i+"q"*110,"options":[{"id":"A","label":"yes"},{"id":"B","label":"no"}],"recommended":"A","default":"hold","hard_rule":None,"deadline":"2026-12-24T10:00:00+03:00","ready":True} for i in range(1,7)]'
t_pre "E-brief-6 publishes" "$eo" "PM_EMBED_OK"
t_true "E-brief-6 brief <= 1000 bytes including the final newline" "[ \$(wc -c < $PM/brief.txt) -le 1000 ]"
t_has "E-brief-6 '+N more decisions' line present" "$(cat "$PM/brief.txt")" "more decisions"
t_true "E-brief-6 no mid-line cut: every decision line is whole" "! grep -E '^D-[0-9]+ needs you' $PM/brief.txt | grep -v ')\$'"
t_eq "E-brief-6 the generation trailer is last" "$(tail -1 "$PM/brief.txt")" "generation $(gen)"
t_true "E-brief-6 decisions kept in order; the shown count + N = 6" "n=\$(grep -cE '^D-[0-9]+ needs you' $PM/brief.txt); m=\$(grep -o '+[0-9]* more' $PM/brief.txt | tr -dc 0-9); [ \$((n+m)) = 6 ]"
t_has "E-brief-6 a shown decision line has default and deadline" "$(grep 'D-001 needs you' "$PM/brief.txt")" "(default hold, by 2026-12-24)"
t_eq "E-brief-6 state keeps all 6 decisions" "$(S 'len(d["decisions"])')" 6
upd 'J["decisions"]=[]'; t_true "E-brief no decisions -> no 'needs you' lines" "! grep -qE '^D-[0-9]+ needs you' $PM/brief.txt"
t_true "E-brief tokens line dropped when usage is not collected" "! grep -q '^tokens' $PM/brief.txt"
upd 'J["decisions"]=[]; J["headline"]["tone"]="blocked"; J["headline"]["text"]="x"'; t_has "E-brief tone shows in line 1" "$(head -1 "$PM/brief.txt")" "· blocked"

# ======================================================================================================
# 6. answers: lifecycle, frozen decisions, rewrite detection, 12 KB note
# ======================================================================================================
mkproj an || true
printf '{"id":"D-001","answer":"A","at":"2026-10-07T12:00:00+03:00","by":"owner"}\n' > "$PM/answers.jsonl"
out=$(facts); t_has "F-answers pending answer -> NEEDS_JUDGEMENT 1 pending answers" "$out" "1 pending answers"
begin; t_eq "F-answers snapshot applied the answer (D-001 answered)" "$(get "$STAGE/snapshot.json" '[x["status"] for x in d["decisions"] if x["id"]=="D-001"]')" "['answered']"
t_eq "F-answers snapshot.answers: total 1 applied 0" "$(get "$STAGE/snapshot.json" '(d["answers"]["total"],d["answers"]["applied"])')" "(1, 0)"
pub 'J["headline"]["text"]="answer applied"; J["decisions"][0]["q"]="Hacked question"; J["decisions"][0]["options"][0]["label"]="Hacked"'
t_pre "E-answers round published" "$eo" "PM_EMBED_OK"
t_eq "E-answers D-001 answered=A by owner, kept one run" "$(S '[(x["status"],x["answer"],x["answered_by"]) for x in d["decisions"] if x["id"]=="D-001"]')" "[('answered', 'A', 'owner')]"
t_eq "E-answers model rewrite of an answered decision ignored (K)" "$(S '[x["q"] for x in d["decisions"] if x["id"]=="D-001"]')" "['Keep the 1e-2 error bar, or relax it?']"
t_eq "E-answers state.answers applied=1 and the prefix hash recorded" "$(S '(d["answers"]["applied"],len(d["answers"]["applied_hash"]))')" "(1, 64)"
t_eq "F-answers calm after the answer was applied" "$(facts)" "NO_CHANGE nothing moved"
upd 'J["headline"]["text"]="next"; J["decisions"]=[x for x in J["decisions"] if x["id"]!="D-001"]'
t_eq "E-answers closed decision dropped on the following run" "$(S '[x["id"] for x in d["decisions"]]')" "['D-002']"
upd 'J["decisions"]=[x for x in J["decisions"] if x["id"]!="D-002"]'; t_has "E-answers retired id reuse rejected" "$eo" "retired"
printf '{"id":"D-009","answer":"A"}\n' >> "$PM/answers.jsonl"; out=$(facts); t_has "F-answers unknown decision id counted in answers.bad (still pending)" "$out" "pending answers"
begin; t_eq "F-answers bad entry has the physical line number" "$(get "$STAGE/snapshot.json" '[b["line"] for b in d["answers"]["bad"]]')" "[2]"
# F-answers-rewritten
mkproj ar || true
printf '{"id":"D-001","answer":"A"}\n{"id":"D-002","answer":"hold"}\n' > "$PM/answers.jsonl"; upd 'J["headline"]["text"]="two answers"'
t_eq "F-answers-rewritten baseline calm" "$(facts)" "NO_CHANGE nothing moved"
printf '{"id":"D-001","answer":"B"}\n{"id":"D-002","answer":"hold"}\n' > "$PM/answers.jsonl"
out=$(facts); rc=$?; t_true "F-answers-rewritten edited prefix -> ERROR answers rewritten, exit 2" "[ $rc = 2 ] && case '$out' in 'ERROR answers rewritten'*) true;; *) false;; esac"
t_has "F-answers-rewritten the ERROR line carries the recovery command" "$out" "--accept-answers $R"
printf '{"id":"D-001","answer":"A"}\n' > "$PM/answers.jsonl"; out=$(facts); t_pre "F-answers-rewritten a shorter file is also a rewrite" "$out" "ERROR answers rewritten"
n0=$(ndirs); out=$(facts); t_eq "F-answers-rewritten no staging dir is created for the ERROR" "$(ndirs)" "$n0"
out=$(python3 "$HOOKS/project-map-facts.py" --accept-answers "$R"); rc=$?; t_true "F-answers-rewritten --accept-answers re-baselines (exit 0)" "[ $rc = 0 ] && case '$out' in ACCEPTED*) true;; *) false;; esac"
out=$(facts); t_true "F-answers-rewritten after accept: replayed from scratch, verdict NEEDS_JUDGEMENT" "case '$out' in 'NEEDS_JUDGEMENT'*pending*) true;; *) false;; esac"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "F-answers-rewritten the replay saw the whole file (applied 0, total 1)" "$(get "$STAGE/snapshot.json" '(d["answers"]["applied"],d["answers"]["total"])')" "(0, 1)"
out_b=$(facts); t_pre "F-answers-rewritten the re-baseline survives a mechanical re-render in between (second facts, no ERROR)" "$out_b" "NEEDS_JUDGEMENT"
pub 'J["headline"]["text"]="rebaselined"' update; t_pre "F-answers-rewritten publish after accept" "$eo" "PM_EMBED_OK"
t_eq "F-answers-rewritten calm again" "$(facts)" "NO_CHANGE nothing moved"
# E-answer-12k
mkproj a12 || true
python3 - "$PM/answers.jsonl" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({"id": "D-001", "answer": "A", "note": "n" * 12000, "by": "owner"}) + "\n")
PY
out=$(facts); t_pre "E-answer-12k: facts prints a verdict" "$out" "NEEDS_JUDGEMENT"; INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "E-answer-12k: snapshot keeps the note verbatim (12000 bytes)" "$(get "$STAGE/snapshot.json" 'len(d["answers"]["pending"][0]["note"])')" 12000
t_true "E-answer-12k: pack <= 8192 bytes" "[ \$(wc -c < $STAGE/pack.json) -le 8192 ]"
t_eq "E-answer-12k: note cut to 120 bytes in the pack, trimmed.answers set" "$(get "$STAGE/pack.json" '(len(d["answers"]["pending"][0]["note"])<=123, d["trimmed"]["answers"]>=1)')" "(True, True)"
pub 'J["headline"]["text"]="12k"'; t_pre "E-answer-12k: embed completes" "$eo" "PM_EMBED_OK"
t_eq "E-answer-12k: next facts is calm" "$(facts)" "NO_CHANGE nothing moved"
python3 - "$PM/answers.jsonl" <<'PY'
import sys
open(sys.argv[1], "a").write('{"id":"D-002","answer":"A","note":"' + "z" * 17000 + '"}\n')
PY
begin; t_eq "F-answers a note over 16384 bytes is a bad line, not a crash" "$(get "$STAGE/snapshot.json" '[b["why"][:12] for b in d["answers"]["bad"]]')" "['note must be']"
# 100 answers: replay sees the whole file, last wins
mkproj w1 || true
python3 - "$PM/answers.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    for i in range(99):
        fh.write(json.dumps({"id": "D-001", "answer": "A", "note": "n" * 150, "by": "owner"}) + "\n")
    fh.write(json.dumps({"id": "D-001", "answer": "B", "note": "last", "by": "owner"}) + "\n")
PY
begin; t_eq "F-answers 100 answers: last wins, 'answered 100 times' noted" "$(get "$STAGE/snapshot.json" '([x["answer"] for x in d["decisions"] if x["id"]=="D-001"], any("answered 100 times" in b["why"] for b in d["answers"]["bad"]))')" "(['B'], True)"
pub 'J["headline"]["text"]="hundred"'; t_eq "E-answers state.answers.applied = 100" "$(S 'd["answers"]["applied"]')" 100
# deadline lifecycle
mkproj dl || true
upd 'J["decisions"][0].update(ready=True, default="A", recommended="A", deadline=(dt.datetime.now().astimezone()+dt.timedelta(seconds=2)).isoformat(timespec="seconds"))'
sleep 3; out=$(facts); t_has "F-deadline: expiry -> NEEDS_JUDGEMENT deadline passed: D-001" "$out" "deadline passed: D-001"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "F-deadline: snapshot defaulted D-001 to its default (A)" "$(get "$STAGE/snapshot.json" '[(x["status"],x["answer"],x["answered_by"]) for x in d["decisions"] if x["id"]=="D-001"]')" "[('defaulted', 'A', 'deadline')]"
t_eq "F-deadline: the hard_rule decision D-002 is untouched (open)" "$(get "$STAGE/snapshot.json" '[x["status"] for x in d["decisions"] if x["id"]=="D-002"]')" "['open']"
pub 'J["headline"]["text"]="deadline"'; t_eq "E-deadline: defaulted decision published" "$(S '[x["status"] for x in d["decisions"] if x["id"]=="D-001"]')" "['defaulted']"
t_eq "F-deadline: calm after the defaulted publish" "$(facts)" "NO_CHANGE nothing moved"
# overdue hard rule
mkproj od || true
upd 'J["decisions"][1]["deadline"]="2020-01-01T00:00:00+00:00"'; out=$(facts); t_has "F-overdue hard_rule past deadline -> NEEDS_JUDGEMENT deadline passed" "$out" "deadline passed: D-002"
begin; t_eq "F-overdue snapshot: overdue, never defaulted" "$(get "$STAGE/snapshot.json" '[x["status"] for x in d["decisions"] if x["id"]=="D-002"]')" "['overdue']"
pub 'J["decisions"][1]["deadline"]="2020-01-01T00:00:00+00:00"; J["decisions"][1]["hard_rule"]=None; J["decisions"][1]["default"]="hold"; J["headline"]["text"]="rewrote D-002"'
t_eq "E-overdue: hard_rule cannot be cleared by the model on an overdue decision" "$(S '[(x["status"],x["hard_rule"],x["default"]) for x in d["decisions"] if x["id"]=="D-002"]')" "[('overdue', 'upstream_post', 'hold')]"
t_eq "F-overdue: still-waiting overdue ids do not re-trigger judging" "$(facts)" "NO_CHANGE nothing moved"

# ======================================================================================================
# 7. superseded, stage retention, sweep, lock, crash boundaries
# ======================================================================================================
mkproj ss || true
bump; begin; A=$INVN; AS="$STAGE"; jud "$A" update 'J["headline"]["text"]="from A"'
echo y >> "$R/PLAN.md"; begin; B=$INVN; BS="$STAGE"; jud "$B" update 'J["headline"]["text"]="from B"'
G0=$(gen); eo=$(embed "$B"); t_pre "E-superseded: B (same base) publishes first" "$eo" "PM_EMBED_OK"; G1=$(gen); NG1=$(ngens)
printf '{"id":"D-001","answer":"B","by":"owner"}\n' >> "$PM/answers.jsonl"; before=$(shasum "$PM/state.json" | cut -d' ' -f1)
eo=$(embed "$A"); erc=$?
t_eq "E-superseded: A -> exit 4" "$erc" 4
t_eq "E-superseded: line 'SUPERSEDED base <b> current <c>'" "$eo" "SUPERSEDED base $G0 current $G1"
t_eq "E-superseded: current stays on B's generation" "$(gen)" "$G1"
t_eq "E-superseded: state untouched by the refused embed" "$(shasum "$PM/state.json" | cut -d' ' -f1)" "$before"
t_eq "E-superseded: the answer recorded in between is still there" "$(grep -c D-001 "$PM/answers.jsonl")" 1
t_eq "E-superseded: the published headline is B's" "$(S 'd["headline"]["text"]')" "from B"
t_eq "E-superseded: no extra generation was written by the refused embed" "$(ngens)" "$NG1"
t_eq "E-stage-retain: a post-success retry of B is SUPERSEDED too" "$(embed "$B" | cut -d' ' -f1)" "SUPERSEDED"
t_true "E-stage-retain: STAGE B is still on disk after the retry" "[ -f $BS/judgement.out.json ]"
t_true "E-superseded: after the answer the next facts spawns again" "case \"\$(facts)\" in NEEDS_JUDGEMENT*) true;; *) false;; esac"
# E-mech-superseded: current moves while a mechanical re-render is in flight
mkproj ms || true; upd 'J["headline"]["text"]="second"'; GA=$(cur); G2=$(gen)
python3 -c "import os,sys;os.utime(sys.argv[1],None)" "$HOOKS/project-map-template.html"; git -C "$R" log -1 >/dev/null
PM_EMBED_PAUSE_BEFORE_PUBLISH=2 embed --mechanical > "$T/ms.out" & MP=$!; BGPIDS="$BGPIDS $MP"; sleep 1
OLDG=$(ls -d "$PM"/gen-0000* | head -1 | xargs basename); python3 -c "import os,sys;os.symlink(sys.argv[2],sys.argv[1]+'/current.mv');os.rename(sys.argv[1]+'/current.mv',sys.argv[1]+'/current')" "$PM" "$OLDG"; wait $MP; mrc=$?
t_eq "E-mech-superseded: exit 4" "$mrc" 4
t_has "E-mech-superseded: SUPERSEDED base <b> current <c>" "$(cat "$T/ms.out")" "SUPERSEDED base $G2 current "
t_eq "E-mech-superseded: current is untouched by the refused re-render" "$(cur)" "$OLDG"
t_true "E-mech-superseded: no tmp generation left behind" "! ls $PM | grep -q '\\.tmp\$'"
# Claude review round: secrets, watch loops, signed generations, refs, control characters, answers keys
mkproj sc || true; bump; begin
rej "secret: AWS access key id" 'J["next_step"]["why"]="key AKIAABCDEFGHIJKLMNOP here"' "judgement.next_step.why looks like it contains a secret"
rej "secret: sk-ant style key" 'J["parts"][0]["line"]="sk-ant-api03-abcdefghijklmnopqrstu"' "judgement.parts[0].line looks like it contains a secret"
rej "secret: GitHub token" 'J["headline"]["text"]="ghp_abcdefghijklmnopqrstuvwx"' "judgement.headline.text looks like"
rej "secret: github_pat_" 'J["project"]["goal"]="github_pat_11ABCDEFG0abcdef"' "judgement.project.goal looks like"
rej "secret: Slack token" 'J["risks"][0]["text"]="xoxb-1234567890-abcdefghij"' "judgement.risks[0].text looks like"
rej "secret: JWT" 'J["next_step"]["title"]="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkw"' "judgement.next_step.title looks like"
rej "secret: private key block" 'J["next_step"]["why"]="-----BEGIN RSA PRIVATE KEY-----"' "looks like it contains a secret"
rej "secret: Bearer token" 'J["next_step"]["why"]="Authorization: Bearer abcdefghijklmnopqrstu"' "looks like it contains a secret"
rej "secret: password=" 'J["next_step"]["why"]="password = hunter2"' "looks like it contains a secret"
rej "control character (newline) in a string" 'J["next_step"]["why"]="two\nlines"' "judgement.next_step.why contains control characters"
rej "control character (NUL) in a string" 'J["parts"][0]["label"]="a\u0000b"' "contains control characters"
rej "bidi override in a string" 'J["headline"]["text"]="evil \u202e txet"' "judgement.headline.text contains bidirectional override"
rej "bidi isolate in a decision question" 'J["decisions"][0]["q"]="q \u2066 x"' "contains bidirectional override"
rej "watch entry '.'" 'J["watch"]=["."]' "must not be '.'"
rej "watch entry .project-map" 'J["watch"]=[".project-map"]' "must not contain a .project-map component"
rej "watch entry inside .project-map (any case)" 'J["watch"]=["docs/.Project-Map/x"]' "must not contain a .Project-Map component"
rej "watch entry with a .git component" 'J["watch"]=["sub/.git/config"]' "must not contain a .git component"
rej "watch entry .env" 'J["watch"]=[".env"]' "looks like a secret path"
rej "watch entry .env.local" 'J["watch"]=["app/.env.local"]' "looks like a secret path"
rej "watch entry credentials file" 'J["watch"]=["config/credentials.json"]' "looks like a secret path"
rej "watch entry .ssh" 'J["watch"]=[".ssh/id_rsa"]' "looks like a secret path"
rej "watch duplicates" 'J["watch"]=["docs","docs/"]' "is a duplicate"
rej "watch entry docs/../x" 'J["watch"]=["docs/../x"]' "relative path inside the project"
rej "repos entry .git" 'J["repos"]=[".git"]' "must not contain a .git component"
rej "part ref into .git/" 'J["parts"][0]["ref"]="file:.git/config"' "points into .git/"
rej "part ref into .PROJECT-MAP (case-folded)" 'J["parts"][0]["ref"]="file:.PROJECT-MAP/state.json"' "points into .project-map/"
rej "part ref with a .GIT component" 'J["parts"][0]["ref"]="file:docs/.GIT/x"' "points into .git/"
rej "FULL: secret in plan.out criterion text" 'P["phases"][1]["criteria"][0]["text"]="use AKIAABCDEFGHIJKLMNOP"' "plan.phases[1].criteria[0].text looks like it contains a secret" full
rej "FULL: control character in plan.out label" 'P["phases"][0]["label"]="a\nb"' "plan.phases[0].label contains control characters" full
# answers.jsonl: closed key set, by must be owner
mkproj ak || true
printf '{"id":"D-001","answer":"A","extra":1}\n{"id":"D-002","answer":"hold","by":"claude"}\n{"id":"D-002","answer":"hold","by":"owner","at":"2026-10-08T10:00:00+03:00","note":"ok"}\n' > "$PM/answers.jsonl"
begin; t_eq "F-answers closed key set: unknown key and by!=owner are bad lines, the valid one applies" "$(get "$STAGE/snapshot.json" '([b["line"] for b in d["answers"]["bad"]], [(x["id"],x["status"]) for x in d["decisions"] if x["status"]=="answered"])')" "([1, 2], [('D-002', 'answered')])"
# signed generations
mkproj sg || true; upd 'J["headline"]["text"]="second signed"'; facts >/dev/null; eo=$(embed --mechanical); G2=$(gen)
t_true "E-sign: manifest carries an hmac and verify_generation accepts the generation" "python3 -c \"import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;sys.exit(0 if C.verify_generation('$PM/gen-$G2') else 1)\" && grep -q hmac $PM/gen-$G2/manifest.json"
t_eq "E-sign: the key file is mode 0600" "$(python3 -c "import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$HOME/.claude/agent-memory/project-map/key")" "0o600"
python3 - "$PM/current/brief.txt" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("next:", "NEXT:", 1))
PY
t_true "E-sign: a same-size tampered brief fails verification" "! python3 -c \"import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;sys.exit(0 if C.verify_generation('$PM/$(cur)') else 1)\""
out=$(facts); t_eq "E-sign: a tampered generation is never NO_CHANGE -> NEEDS_REFRESH generation unverified" "$out" "NEEDS_REFRESH generation unverified"
t_true "E-sign: the re-render produced a new VERIFIED generation from the last verified one" "python3 -c \"import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;sys.exit(0 if C.verify_generation('$PM/$(cur)') else 1)\" && [ \"\$(gen)\" != $G2 ]"
t_true "E-sign: tampered brief gone; the page content came from the verified generation" "! grep -q NEXT: $PM/brief.txt"
out=$(facts); t_true "E-sign: afterwards the verdict is a normal one (not unverified)" "case '$out' in 'NEEDS_REFRESH generation unverified'*) false;; *) true;; esac"
mkproj sg2 || true; python3 - "$PM/current/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["hmac"] = "0" * 64; json.dump(d, open(p, "w"))
PY
out=$(facts); t_pre "E-sign: a tampered manifest with no verified generation left -> NEEDS_FULL" "$out" "NEEDS_FULL no verified generation inv "
INVN=inv-${out##* }; STAGE="$PM/$INVN"; pub 'J["headline"]["text"]="recovered"' full; t_pre "E-sign: a FULL run replaces the unverified current" "$eo" "PM_EMBED_OK"
t_eq "E-sign: calm afterwards" "$(facts)" "NO_CHANGE nothing moved"
mkproj sg3 || true; upd 'J["headline"]["text"]="x2"'; rm -f "$HOME/.claude/agent-memory/project-map/key"
out=$(facts); t_eq "E-sign: a missing key is regenerated; the current generation is re-rendered once" "$out" "NEEDS_REFRESH generation unverified"
t_true "E-sign: the key file exists again" "[ -s $HOME/.claude/agent-memory/project-map/key ]"
t_eq "E-sign: then calm (one re-render only)" "$(facts)" "NO_CHANGE nothing moved"
t_eq "E-sign: older generations (old key) no longer verify" "$(python3 -c "import sys;sys.path.insert(0,'$HOOKS');import pm_common as C,glob;print(sum(C.verify_generation(g) for g in glob.glob('$PM/gen-*')))")" 1
# Round 2: adoption needs a publish record, more secret shapes, invisible characters, pid leftovers, ack at publish
mkproj ad || true; rm -f "$HOME/.claude/agent-memory/project-map/key"; rm -rf "$HOME/.claude/agent-memory/project-map/published"
out=$(facts); t_pre "E-sign-adopt: key deleted and NO publish record -> the generation is untrusted: NEEDS_FULL no verified generation" "$out" "NEEDS_FULL no verified generation inv "
mkproj ad2 || true; rm -f "$HOME/.claude/agent-memory/project-map/key"
out=$(facts); t_eq "E-sign-adopt: key deleted WITH a matching record -> adopted and re-signed once" "$out" "NEEDS_REFRESH generation unverified"
t_eq "E-sign-adopt: then calm" "$(facts)" "NO_CHANGE nothing moved"
t_true "E-sign-adopt: the record names root, generation and the manifest hash" "python3 - $HOME/.claude/agent-memory/project-map/published/\$(python3 -c \"import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())\" $R) <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); assert d['root'] == '$R' and d['generation'] == '$(gen)' and len(d['manifest_sha256']) == 64
PY"
mkproj ad3 || true; rm -f "$HOME/.claude/agent-memory/project-map/key"; echo "<!-- forged -->" >> "$PM/current/index.html"
out=$(facts); t_pre "E-sign-adopt: a forged file under a matching record is NOT adopted -> NEEDS_FULL" "$out" "NEEDS_FULL no verified generation inv "
mkproj ad4 || true; rm -f "$HOME/.claude/agent-memory/project-map/key"; python3 - "$PM/current/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["hmac"] = "1" * 64; json.dump(d, open(p, "w"))
PY
out=$(facts); t_pre "E-sign-adopt: a manifest edited under a matching record is NOT adopted -> NEEDS_FULL" "$out" "NEEDS_FULL no verified generation inv "
mkproj sc2 || true; bump; begin
rej "secret: Google API key" 'J["next_step"]["why"]="AIza'"$(printf 'a%.0s' $(seq 1 32))"'"' "looks like it contains a secret"
rej "secret: Stripe live key" 'J["next_step"]["why"]="sk_live_abcdefghijklmnop"' "looks like it contains a secret"
rej "secret: GitLab token" 'J["next_step"]["why"]="glpat-abcdefghijklmnop"' "looks like it contains a secret"
rej "secret: npm token" 'J["next_step"]["why"]="npm_'"$(printf 'a%.0s' $(seq 1 30))"'"' "looks like it contains a secret"
rej "secret: HuggingFace token" 'J["next_step"]["why"]="hf_'"$(printf 'a%.0s' $(seq 1 30))"'"' "looks like it contains a secret"
rej "secret: URL with credentials" 'J["next_step"]["why"]="clone postgres://admin:pw1234@db.example/x"' "looks like it contains a secret"
rej "zero-width space in a string" 'J["headline"]["text"]="a\u200bb"' "contains zero-width or line-separator characters"
rej "BOM in a string" 'J["project"]["name"]="\ufeffname"' "contains zero-width or line-separator characters"
rej "U+2028 in a string" 'J["parts"][0]["label"]="a\u2028b"' "contains zero-width or line-separator characters"
rej "U+0085 in a string" 'J["parts"][0]["label"]="a\u0085b"' "contains"
rej "right-to-left mark (U+200F)" 'J["next_step"]["title"]="a\u200fb"' "contains zero-width or line-separator characters"
pub 'J["next_step"]["why"]="plain https://example.com/docs link"' update; t_pre "E-secret: a URL without credentials is fine" "$eo" "PM_EMBED_OK"
# stale pid leftovers
mkproj lo || true; bump; begin; sh -c 'exit 0' & DP=$!; wait $DP
touch "$PM/.state.json.tmp.$DP.abc" "$STAGE/judgement.out.json.in.$DP" "$PM/keep.in.$$"
facts >/dev/null
t_true "F-sweep: .tmp.<pid> and .in.<pid> leftovers of dead processes are removed (PM and staging)" "[ ! -e $PM/.state.json.tmp.$DP.abc ] && [ ! -e $STAGE/judgement.out.json.in.$DP ]"
t_true "F-sweep: a leftover whose process is alive is kept" "[ -e $PM/keep.in.$$ ]"
# ack_hashes at publish
mkproj ak2 || true
t_eq "E-ack: embed writes cache.json ack_hashes (sha256 of template and embed.py) at every publish" "$(get "$PM/cache.json" 'd["ack_hashes"]["template"]=="'"$(shasum -a 256 "$HOOKS/project-map-template.html" | cut -d' ' -f1)"'" and d["ack_hashes"]["embed"]=="'"$(shasum -a 256 "$HOOKS/project-map-embed.py" | cut -d' ' -f1)"'"')" True
# Round 3: --budget between every collection step; guard-equal secret path list
mkproj bs || true; bump; g0=$(gen)
st=$(python3 -c "import time;print(time.time())"); out=$(PM_FACTS_DELAY=1 facts --budget 0.2 --no-stage); rc=$?; el=$(python3 -c "import time,sys;print(round(time.time()-float(sys.argv[1]),2))" $st)
t_eq "F-budget-step: a per-step delay with --budget 0.2 -> best verdict, deferred" "$rc:$out" "0:NEEDS_REFRESH facts incomplete (deferred: budget)"
t_true "F-budget-step: the run stayed near the budget, not N delays (elapsed $el s)" "python3 -c 'import sys;sys.exit(0 if $el < 1.0 else 1)'"
t_eq "F-budget-step: nothing was published by the cut-off run" "$(gen)" "$g0"
out=$(PM_FACTS_DELAY=0.05 facts --budget 10 --no-stage); t_pre "F-budget-step: small per-step delays within budget still produce the normal verdict" "$out" "NEEDS_JUDGEMENT"
rm -rf "$T/nb"; mkdir "$T/nb"; out=$(PM_FACTS_DELAY=1 python3 "$HOOKS/project-map-facts.py" "$T/nb" --budget 0.2); t_eq "F-budget-step: first map out of budget -> NEEDS_FULL without a staging dir" "$out|$([ -e "$T/nb/.project-map" ] && echo made || echo none)" "NEEDS_FULL first map (deferred: budget)|none"
mkproj sp || true; bump; begin
for w in .kube/config deployment.env local.tfstate .envrc .pgpass service-account-x.json .docker/config.json secrets/prod.txt credentials/a.txt .gnupg/pubring.kbx .config/gh/hosts.yml; do
  rej "watch secret path $w" "J[\"watch\"]=[\"$w\"]" "secret path"
done
t_true "C-secret-regex: pm_common --secret-regex matches every one of those paths" "r=\$(python3 $HOOKS/pm_common.py --secret-regex); for w in .kube/config deployment.env local.tfstate .envrc .pgpass service-account-x.json .docker/config.json secrets/prod.txt .config/gh/hosts.yml; do echo \$w | grep -qiE \"\$r\" || exit 1; done"
t_true "C-secret-regex: ... and none of the ordinary watch paths" "r=\$(python3 $HOOKS/pm_common.py --secret-regex); for w in README.md docs/a.md thoughts/ledgers PLAN.md; do echo \$w | grep -qiE \"\$r\" && exit 1; done; true"
rej "word joiner U+2060 in a string" 'J["headline"]["text"]="a\u2060b"' "contains zero-width or line-separator characters"
# usage: the mentions fallback applies only to transcripts without any cwd
mkdir -p "$HOME/.claude/projects/fx" "$T/urt"; UR=$(cd "$T/urt" && pwd -P)
python3 - "$HOME/.claude/projects/fx" "$UR" <<'PY'
import json, sys
d, root = sys.argv[1], sys.argv[2]
def rec(cwd, text):
    r = {"type": "assistant", "message": {"id": "m1", "model": "claude-x", "usage": {"input_tokens": 1000, "output_tokens": 1}, "content": text}, "timestamp": "2026-10-08T10:00:00Z"}
    if cwd: r["cwd"] = cwd
    return json.dumps(r, separators=(",", ":"))
open(d + "/elsewhere.jsonl", "w").write("\n".join(rec("/Users/other/proj", "see " + root) for _ in range(50)) + "\n")
open(d + "/nocwd.jsonl", "w").write("\n".join(rec(None, "see " + root) for _ in range(50)) + "\n")
PY
t_eq "U-usage: a transcript with a cwd elsewhere contributes 0 however often it mentions ROOT; only the cwd-less one counts" "$(python3 "$HOOKS/project-map-usage.py" "$UR" | python3 -c 'import json,sys;d=json.load(sys.stdin)["snapshot_for_state"];print(d["totals"]["claude"], d["totals"]["jobs"])')" "1001 1"
# Codex round: pack overflow, unborn vs broken git, deadline through rendering, total --budget
mkproj cx || true
t_eq "F-pack pathological snapshot (huge root) -> build_pack raises PackOverflow" "$(PYTHONPATH=$HOOKS python3 - <<'PY'
import pm_collect as K
snap = {k: None for k in ("schema","base","root","facts_at","repos","commits","status","watch","ledger","answers","decisions","usage","watch_dropped","dirty_paths","template_hash","key","prev_key")}
snap.update(schema="x", root="r" * 9000, repos=[], commits={"days": []}, status={}, watch=[], answers={"pending": [], "bad": []}, decisions=[], watch_dropped=[], dirty_paths=[], key={}, prev_key=None)
try:
    K.build_pack(snap, "inv-00000000"); print("fit")
except K.PackOverflow as e:
    print("overflow", e)
PY
)" "overflow pack over 8 KB"
# unborn repository: a valid git repo with 0 commits, not a plain folder
mkdir -p "$T/unborn"; R=$(cd "$T/unborn" && pwd -P); PM="$R/.project-map"; (cd "$R" && git init -q -b main && echo r > README.md)
begin; t_eq "F-unborn: a git repo with no commits is vcs git, head null, branch main" "$(get "$STAGE/snapshot.json" '(d["repos"][0]["vcs"],d["repos"][0]["head"],d["repos"][0]["branch"],d["status"]["dirty"])')" "('git', None, 'main', 1)"
# broken index is a collection failure even without commits
mkdir -p "$T/unborn2"; R=$(cd "$T/unborn2" && pwd -P); PM="$R/.project-map"; (cd "$R" && git init -q -b main && echo r > README.md && echo junk > .git/index)
out=$(facts); rc=$?; t_true "F-git-broken: unborn repo with a broken index -> ERROR git_error, exit 2" "[ $rc = 2 ] && case '$out' in 'ERROR git_error'*) true;; *) false;; esac"
# a failing log on a repo that has commits -> ERROR (corrupt object store under HEAD)
mkrepo lg; hd=$(git -C "$R" rev-parse HEAD); rm -f "$R/.git/objects/${hd:0:2}/${hd:2}"; out=$(facts); rc=$?
t_true "F-git-broken: HEAD resolves but log fails (missing commit object) -> ERROR, exit 2" "[ $rc = 2 ] && case '$out' in ERROR*) true;; *) false;; esac"
# --deadline through rendering and right before the switch
mkproj dd || true; g0=$(gen); n0=$(ngens)
st=$(date +%s); eo=$(PM_EMBED_RENDER_DELAY=2.5 embed --mechanical --deadline 0.8); erc=$?; el=$(( $(date +%s) - st ))
t_true "E-mech-deadline: a slow render with --deadline 0.8 -> PM_EMBED_ERROR deadline, exit 1, nothing replaced" "[ $erc = 1 ] && [ '$eo' = 'PM_EMBED_ERROR deadline' ] && [ \"\$(gen)\" = $g0 ] && [ \$(ngens) = $n0 ]"
t_true "E-mech-deadline: no tmp generation left behind after the deadline" "! ls $PM | grep -q '\\.tmp\$'"
bump; begin; g0=$(gen); jud "$INVN" update 'J["headline"]["text"]="dl"'; eo=$(PM_EMBED_RENDER_DELAY=2.5 embed "$INVN" --deadline 0.8); erc=$?
t_true "E-embed-deadline: normal mode honours --deadline too" "[ $erc = 1 ] && [ '$eo' = 'PM_EMBED_ERROR deadline' ] && [ \"\$(gen)\" = $g0 ]"
# facts --budget bounds the whole run
mkproj bg || true; echo "<!-- budget -->" >> "$HOOKS/project-map-template.html"; g0=$(gen)
st=$(date +%s); out=$(PM_FACTS_DELAY_AFTER=1.5 facts --budget 2 --no-stage); el=$(( $(date +%s) - st ))
t_eq "F-budget: out of budget after a slow collection -> the verdict without the refresh" "$out" "NEEDS_REFRESH plugin files changed (deferred: budget)"
t_true "F-budget: no re-render happened and the run stayed near the budget" "[ \"\$(gen)\" = $g0 ] && [ $el -le 4 ]"
out=$(facts --budget 20); t_eq "F-budget: with time left the refresh runs" "$out" "NEEDS_REFRESH plugin files changed"
cp "$SRC/project-map-template.html" "$HOOKS/project-map-template.html"; facts >/dev/null
# --no-stage and generation pruning
mkproj ns || true; bump; n0=$(ndirs); out=$(facts --no-stage); rc=$?
t_true "F-no-stage: same verdict, no inv suffix, exit 0" "[ $rc = 0 ] && case '$out' in NEEDS_JUDGEMENT*) true;; *) false;; esac && ! echo '$out' | grep -q ' inv '"
t_eq "F-no-stage: no staging dir created" "$(ndirs)" "$n0"
rm -rf "$R/.project-map"; out=$(facts --no-stage); t_eq "F-no-stage: first map prints NEEDS_FULL without a suffix and creates nothing" "$out|$([ -e "$R/.project-map" ] && echo made || echo none)" "NEEDS_FULL first map|none"
mkproj pr || true; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do upd "J[\"headline\"][\"text\"]=\"p $i\""; done
rm -rf "$PM"/inv-*; facts >/dev/null; rm -rf "$PM"/inv-*; facts --no-stage >/dev/null
t_eq "F-prune: 14 publishes leave 10 generations" "$(ngens)" 10
t_true "F-prune: current survives and is complete" "[ -f $PM/$(cur)/manifest.json ]"
t_true "F-prune: the oldest generation is gone, the newest kept" "! ls -d $PM/gen-000001-* 2>/dev/null | grep -q . && [ -d $PM/$(cur) ]"
mkproj pb || true; B1=$(gen)
mkdir "$PM/inv-bbbb0001"; printf '{"id":"bbbb0001","created_at":"%s","base":"%s","root":"%s","session_id":null}' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$B1" "$R" > "$PM/inv-bbbb0001/invocation.json"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do upd "J[\"headline\"][\"text\"]=\"q $i\""; done
facts --no-stage >/dev/null
t_true "F-prune: a generation named as base by an active staging dir survives" "[ -d $PM/gen-$B1 ]"
rm -rf "$PM/inv-bbbb0001"; facts --no-stage >/dev/null; t_true "F-prune: once the staging is gone the old base is pruned" "[ ! -d $PM/gen-$B1 ]"
# F-refacts: a second facts run between judgement and embed does not force a re-judge
mkproj rf2 || true
bump; begin; X=$INVN; jud "$X" update 'J["headline"]["text"]="refacts"'
out2=$(facts); t_pre "F-refacts: the second facts run (before embed) still reports the same need" "$out2" "NEEDS_JUDGEMENT"
eo=$(embed "$X"); t_pre "F-refacts: the first staging publishes although facts ran in between" "$eo" "PM_EMBED_OK"
t_eq "F-refacts: after that embed the next facts is calm (no forced re-judge)" "$(facts)" "NO_CHANGE nothing moved"
t_eq "F-refacts: the second staging is simply superseded" "$(embed "inv-${out2##* }" | cut -d' ' -f1)" "SUPERSEDED"
# failed publish -> Edit + embed retry publishes
mkproj rt || true
bump; begin; jud "$INVN" update 'J["headline"]["text"]="x"*200'; eo=$(embed "$INVN"); erc=$?
t_eq "E-stage-retain: a failed publish returns exit 1" "$erc" 1
jud "$INVN" update 'J["headline"]["text"]="fixed"'; eo=$(embed "$INVN"); erc=$?
t_true "E-stage-retain: after a FAILED publish an Edit + embed retry publishes" "[ $erc = 0 ] && case '$eo' in PM_EMBED_OK*) true;; *) false;; esac"
# sweep
mkproj sw || true
bump; begin; KEEP=$INVN
mkinv() { mkdir -p "$PM/$1"; python3 - "$PM/$1/invocation.json" "$2" "$R" <<'PY'
import datetime as dt, json, sys
t = dt.datetime.now().astimezone() - dt.timedelta(hours=float(sys.argv[2]))
json.dump({"id": "x", "created_at": t.isoformat(timespec="seconds"), "base": None, "root": sys.argv[3], "session_id": None}, open(sys.argv[1], "w"))
PY
}
mkinv inv-aaaa0001 48; mkinv inv-aaaa0002 1; mkinv inv-aaaa0003 1; touch "$PM/inv-aaaa0003/released"
mkinv inv-aaaa0004 1; mkinv inv-aaaa0005 1; mkinv inv-aaaa0006 48
mkdir -p "$PM/gen-000099-aaaaaaaa" "$PM/gen-000098-bbbbbbbb.tmp"; touch "$PM/current.tmp" "$PM/index.html.tmp"
export CLAUDE_PLUGIN_DATA="$T/data"; mkdir -p "$T/data/bind/sess1"; cp "$HOME/.claude/agent-memory/project-map/key" "$T/data/key"
printf '{"root":"%s","inv":"inv-aaaa0004","mode":"UPDATE"}' "$R" > "$T/data/bind/sess1/agent1.json"
printf '{"root":"%s","inv":"inv-aaaa0005","mode":"UPDATE"}' "$R" > "$T/data/bind/sess1/agent2.done.json"
printf '{"root":"%s","inv":"inv-aaaa0006","mode":"UPDATE","tool_use_id":"t"}' "$R" > "$T/data/bind/sess1/pending"
out=$(facts); t_pre "F-sweep: facts still prints its verdict" "$out" "NEEDS_JUDGEMENT"
t_true "F-sweep: abandoned (no reference, 48 h old) staging swept" "[ ! -d $PM/inv-aaaa0001 ]"
t_true "F-sweep: young unreferenced staging kept (covers a crash before registration)" "[ -d $PM/inv-aaaa0002 ]"
t_true "F-sweep: staging with a 'released' marker swept" "[ ! -d $PM/inv-aaaa0003 ]"
t_true "F-sweep: staging bound to a non-terminal agent kept" "[ -d $PM/inv-aaaa0004 ]"
t_true "F-sweep: staging whose binding is terminal swept (frees STAGE)" "[ ! -d $PM/inv-aaaa0005 ]"
t_true "F-sweep: a 48 h old staging that a pending record references is kept" "[ -d $PM/inv-aaaa0006 ]"
t_true "F-sweep: incomplete generation dirs (no manifest, .tmp) swept" "[ ! -d $PM/gen-000099-aaaaaaaa ] && [ ! -d $PM/gen-000098-bbbbbbbb.tmp ]"
t_true "F-sweep: leftover current.tmp and stable .tmp links swept" "[ ! -e $PM/current.tmp ] && [ ! -e $PM/index.html.tmp ]"
t_true "F-sweep: current generation untouched, new staging for this run kept" "[ -d $PM/$(cur) ] && [ -d $PM/$KEEP ]"
rm -f "$T/data/bind/sess1/pending"; out=$(facts); t_true "F-sweep: dropping the pending record releases the old staging" "[ ! -d $PM/inv-aaaa0006 ] && [ -d $PM/inv-aaaa0004 ]"
unset CLAUDE_PLUGIN_DATA
mv "$PM/inv-aaaa0004/invocation.json" "$PM/inv-aaaa0004/invocation.json.x"; python3 -c "import os,sys;t=1000000000;os.utime(sys.argv[1],(t,t))" "$PM/inv-aaaa0004"; out=$(facts)
t_true "F-sweep: without bind data an old dir (mtime) is swept after 24 h" "[ ! -d $PM/inv-aaaa0004 ]"
t_eq "F-sweep: sweeping never touches the published map" "$(S 'd["schema"]')" "project-map-4"
# lock liveness
mkproj lk || true
bump; begin; jud "$INVN" update 'J["headline"]["text"]="lock"'
python3 "$TD/pm_testlib.py" holder "$PM" > "$T/holder.out" & HP=$!; BGPIDS="$BGPIDS $HP"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q held "$T/holder.out" && break; sleep 0.2; done
c0=$(cur); eo=$(embed "$INVN"); erc=$?
t_true "E-lock-live: a live holder -> PM_EMBED_ERROR another embed is running, exit 1" "[ $erc = 1 ] && [ '$eo' = 'PM_EMBED_ERROR another embed is running' ]"
t_eq "E-lock-live: nothing replaced while the lock is held" "$(cur)" "$c0"
out=$(facts); t_pre "E-lock-live: facts still answers while the lock is held (sweep skipped)" "$out" "NEEDS_JUDGEMENT"
eo=$(embed --mechanical); erc=$?; t_true "E-lock-live: mechanical embed is refused too" "[ $erc = 1 ] && [ '$eo' = 'PM_EMBED_ERROR another embed is running' ]"
touch -t 200001010000 "$PM/.lock"; eo=$(embed "$INVN"); t_true "E-lock-live: an old .lock mtime never lets a second embed in (no stealing)" "[ '$eo' = 'PM_EMBED_ERROR another embed is running' ]"
kill -9 $HP; wait $HP 2>/dev/null; sleep 0.3
eo=$(embed "$INVN"); erc=$?; t_true "E-lock-live: a dead holder releases the lock; embed proceeds" "[ $erc = 0 ] && case '$eo' in PM_EMBED_OK*) true;; *) false;; esac"
t_true "E-lock-live: the lock file remains but holds nothing" "[ -f $PM/.lock ]"
# crash at every boundary
for stage in tmpdir files manifest gen_rename pointer links; do
  mkproj cr_$stage || continue; bump; begin; OLD=$(gen); jud "$INVN" update 'J["headline"]["text"]="crash '"$stage"'"'
  PM_EMBED_CRASH_AT=$stage embed "$INVN" >/dev/null 2>&1; rc=$?
  t_eq "E-crash-$stage: the embed process was killed (exit 99)" "$rc" 99
  t_true "E-crash-$stage: current is a symlink to a COMPLETE generation" "python3 - $PM <<'PY'
import json, os, sys
pm = sys.argv[1]; g = os.readlink(pm + '/current'); d = pm + '/' + g
m = json.load(open(d + '/manifest.json'))
assert all(os.path.getsize(d + '/' + k) == v['size'] for k, v in m['files'].items())
PY"
  case $stage in tmpdir|files|manifest|gen_rename) exp=old;; *) exp=new;; esac
  if [ $exp = old ]; then t_eq "E-crash-$stage: crash before the pointer rename keeps the previous generation" "$(gen)" "$OLD"; else t_true "E-crash-$stage: crash after the pointer rename leaves the NEW complete generation" "[ \"\$(gen)\" != \"$OLD\" ] && [ \"\$(S 'd[\"headline\"][\"text\"]')\" = 'crash $stage' ]"; fi
  t_eq "E-crash-$stage: no mixed generation (state, meta, brief agree)" "$(lib reader "$PM" 0.3 | cut -d' ' -f2)" 0
  if [ $exp = old ]; then eo=$(embed "$INVN"); erc=$?; t_true "E-crash-$stage: retrying the same staging publishes" "[ $erc = 0 ]"; fi
  out=$(facts); t_true "E-crash-$stage: facts prints a verdict afterwards" "case '$out' in NO_CHANGE*|NEEDS_*) true;; *) false;; esac"
  t_true "E-crash-$stage: facts repaired the four stable links" "for n in index.html mobile.html brief.txt state.json; do [ \"\$(readlink $PM/\$n)\" = current/\$n ] || exit 1; done"
  t_true "E-crash-$stage: incomplete generation dirs were swept" "! ls $PM | grep -q '\\.tmp\$' && for d in $PM/gen-*; do [ -f \$d/manifest.json ] || exit 1; done"
  if [ $exp = new ]; then eo=$(embed "$INVN"); erc=$?; t_true "E-crash-$stage: the staging is SUPERSEDED after the pointer moved" "[ $erc = 4 ]"; fi
done
# a concurrent reader never sees a mixed generation while embeds run
mkproj rd || true
lib reader "$PM" 6 > "$T/reader.out" & RP=$!; BGPIDS="$BGPIDS $RP"
for i in 1 2 3 4 5; do upd "J[\"headline\"][\"text\"]=\"during read $i\""; done
wait $RP; t_eq "E-crash-reader: a concurrent reader never observed a mixed generation" "$(cut -d' ' -f1,2 "$T/reader.out")" "MIXED 0"
t_true "E-crash-reader: the reader actually read generations while embeds ran" "[ \$(cut -d' ' -f4 $T/reader.out) -gt 100 ]"

# ======================================================================================================
# 8. mechanical re-render, refresh verdicts, generation mismatch, REFRESH_FAILED
# ======================================================================================================
mkproj mc || true
n0=$(S 'd["run"]["n"]'); h0=$(S 'len(d["history"])'); g0=$(gen); j0=$(get "$PM/current/judgement.json" 'json.dumps({k:v for k,v in d.items() if k!="generation"},sort_keys=True)'); at0=$(S 'd["judged_at"]')
echo "<!-- restyled -->" >> "$HOOKS/project-map-template.html"
out=$(facts); t_eq "F-refresh template changed -> NEEDS_REFRESH plugin files changed" "$out" "NEEDS_REFRESH plugin files changed"
t_true "F-refresh: a new generation was published" "[ \"\$(gen)\" != \"$g0\" ]"
t_true "F-refresh: the page picked up the template" "grep -q restyled $PM/index.html"
t_eq "F-refresh: run n and history unchanged" "$(S '(d["run"]["n"],len(d["history"]))')" "($n0, $h0)"
t_eq "F-refresh: judgement.json unchanged (same content)" "$(get "$PM/current/judgement.json" 'json.dumps({k:v for k,v in d.items() if k!="generation"},sort_keys=True)')" "$j0"
t_eq "F-refresh: assessment time unchanged" "$(S 'd["judged_at"]')" "$at0"
t_eq "F-refresh: base of the new generation is the old one" "$(S 'd["base"]')" "$g0"
t_eq "F-refresh: invocation/ absent for a mechanical re-render" "$([ -d "$PM/$(cur)/invocation" ] && echo present || echo absent)" absent
t_eq "F-refresh: calm afterwards (no refresh loop)" "$(facts)" "NO_CHANGE nothing moved"
t_eq "F-refresh: stdout stays one line" "$(facts | wc -l | tr -d ' ')" 1
# embed --mechanical directly
eo=$(embed --mechanical); erc=$?; t_true "E-mech: PM_EMBED_OK gen <seq>-<id> <bytes>" "[ $erc = 0 ] && echo '$eo' | grep -qE '^PM_EMBED_OK gen [0-9]{6}-[0-9a-f]{8} [0-9]+\$'"
t_eq "E-mech: seq increments" "$(gen | cut -c1-6)" "$(printf '%06d' $(( $(echo $g0 | cut -c1-6 | sed 's/^0*//') + 2 )))"
eo=$(embed --mechanical --deadline 0.0005); erc=$?; t_true "E-mech-deadline: a tiny total deadline -> PM_EMBED_ERROR deadline, exit 1" "[ $erc = 1 ] && [ '$eo' = 'PM_EMBED_ERROR deadline' ]"
eo=$(embed --mechanical --deadline 20); t_pre "E-mech-deadline: a generous deadline succeeds" "$eo" "PM_EMBED_OK"
eo=$(embed --mechanical --deadline); t_pre "E-mech bad --deadline value -> PM_EMBED_ERROR" "$eo" "PM_EMBED_ERROR"
# generation mismatch
G=$(gen); python3 - "$PM/current/brief.txt" "$G" <<'PY'
import sys
p, g = sys.argv[1], sys.argv[2]
s = open(p).read().replace("generation " + g, "generation 999999-deadbeef")
open(p, "w").write(s)
PY
lib resign "$PM/current"; out=$(facts); t_eq "F-mismatch brief trailer disagrees -> NEEDS_REFRESH generation mismatch" "$out" "NEEDS_REFRESH generation mismatch"
t_eq "F-mismatch the re-render restores a consistent generation" "$(tail -1 "$PM/brief.txt")" "generation $(gen)"
t_eq "F-mismatch then calm" "$(facts)" "NO_CHANGE nothing moved"
python3 - "$PM/current/index.html" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace('name="pm-generation" content="', 'name="pm-generation" content="9', 1)[:-1] + " ")
PY
lib resign "$PM/current"; out=$(facts); t_eq "F-mismatch meta stamp of index.html disagrees -> NEEDS_REFRESH" "$out" "NEEDS_REFRESH generation mismatch"
rm "$PM/current/pack.json"; out=$(facts); t_eq "F-mismatch an incomplete current generation (file missing) is unverified -> NEEDS_REFRESH" "$out" "NEEDS_REFRESH generation unverified"
t_eq "F-mismatch repaired generation is complete" "$([ -f "$PM/current/pack.json" ] && echo yes)" yes
# map older than 1 h
python3 - "$PM/current/state.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["identity"]["snapshot_at"] = "2020-01-01T00:00:00+00:00"; json.dump(d, open(p, "w"), indent=1)
PY
lib resign "$PM/current"
out=$(facts); t_eq "F-refresh a map older than 1 h is re-rendered" "$out" "NEEDS_REFRESH map older than 1 h"
t_eq "F-refresh: snapshot_at is fresh after the re-render" "$(S 'd["identity"]["snapshot_at"][:4]')" "$(date +%Y)"
# stable link repair before NO_CHANGE
rm "$PM/brief.txt"; out=$(facts); t_eq "F-links a missing stable link is repaired before NO_CHANGE" "$out:$(readlink "$PM/brief.txt")" "NO_CHANGE nothing moved:current/brief.txt"
ln -sfn current/state.json "$PM/index.html"; out=$(facts); t_eq "F-links a link pointing elsewhere is repaired" "$out:$(readlink "$PM/index.html")" "NO_CHANGE nothing moved:current/index.html"
rm "$PM/mobile.html"; echo regular > "$PM/mobile.html"; out=$(facts); t_eq "F-links a regular file in place of a link is replaced atomically" "$(readlink "$PM/mobile.html")" "current/mobile.html"
# REFRESH_FAILED
mkproj rf || true
g0=$(gen); cp "$HOOKS/project-map-template.html" "$T/tpl.bak"; python3 - "$HOOKS/project-map-template.html" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("/*__PM_STATE__*/null", "NOPLACEHOLDER"))
PY
out=$(facts); rc=$?; t_true "F-refresh-failed: a failing re-render -> REFRESH_FAILED, exit 3" "[ $rc = 3 ] && case '$out' in REFRESH_FAILED*) true;; *) false;; esac"
t_has "F-refresh-failed: the line names the cause" "$out" "template placeholder missing"
t_eq "F-refresh-failed: previous generation still current" "$(gen)" "$g0"
t_true "F-refresh-failed: no tmp generation left behind" "! ls $PM | grep -q '\\.tmp'"
cp "$T/tpl.bak" "$HOOKS/project-map-template.html"; out=$(facts); t_eq "F-refresh-failed: with the template restored the published hash matches again (calm)" "$out" "NO_CHANGE nothing moved"
cp "$SRC/project-map-template.html" "$HOOKS/project-map-template.html"; facts >/dev/null

# ======================================================================================================
# 9. git failures, helpers that must never run, sub-folder roots
# ======================================================================================================
mkproj gb || true
echo garbage > "$R/.git/index"; out=$(facts); rc=$?
t_true "F-git-broken: a broken index -> ERROR, exit 2" "[ $rc = 2 ] && case '$out' in ERROR*) true;; *) false;; esac"
t_has "F-git-broken: the line says git_error" "$out" "git_error"
t_eq "F-git-broken: never NO_CHANGE; no staging created" "$(ls "$PM" | grep -c '^inv-' | tr -d ' ')" 1
eo=$(embed --mechanical); t_true "F-git-broken: mechanical embed fails too (nothing replaced)" "case '$eo' in PM_EMBED_ERROR*git_error*) true;; *) false;; esac"
# helpers
mkproj gh || true
cat > "$T/helper.sh" <<EOF
#!/bin/sh
echo ran >> "$T/MARK"
exit 0
EOF
chmod +x "$T/helper.sh"; mkdir -p "$T/evilhooks"; for h in post-checkout post-commit post-merge reference-transaction pre-commit; do cp "$T/helper.sh" "$T/evilhooks/$h"; done
git -C "$R" config core.fsmonitor "$T/helper.sh"; git -C "$R" config diff.external "$T/helper.sh"; git -C "$R" config core.pager "$T/helper.sh"
git -C "$R" config core.hooksPath "$T/evilhooks"; git -C "$R" config core.sshCommand "$T/helper.sh"; git -C "$R" config diff.evil.textconv "$T/helper.sh"
echo '*.md diff=evil' > "$R/.gitattributes"
SHA9=$(git -C "$R" rev-parse --short=9 HEAD)
git -C "$R" status >/dev/null 2>&1; t_true "E-git-helpers sanity: raw git runs the configured fsmonitor helper (the test is meaningful)" "[ -f $T/MARK ]"
rm -f "$T/MARK"; bump; echo more >> "$R/docs/a.md"
out=$(facts); INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"; jud "$INVN" update 'J["headline"]["text"]="helpers"; J["parts"][1]["ref"]="commit:'"$SHA9"'"'
eo=$(embed "$INVN"); t_pre "E-git-helpers: facts + embed with every helper configured succeed" "$eo" "PM_EMBED_OK"
eo=$(embed --mechanical); t_true "E-git-helpers: mechanical embed too" "case '$eo' in PM_EMBED_OK*) true;; *) false;; esac"
t_true "E-git-helpers: no configured helper (fsmonitor, textconv, external diff, pager, hooks, ssh) executed" "[ ! -f $T/MARK ]"
# sub-folder of a parent repo
mkdir -p "$T/par/proj"; PAR=$(cd "$T/par" && pwd -P); R="$PAR/proj"; PM="$R/.project-map"
(cd "$PAR" && git init -q -b main && git config user.email t@t && git config user.name t && echo other > other.txt && seq 1 300 > proj/PLAN.md && seq 1 200 > proj/REVIEW-LOG.md && echo r > proj/README.md && git add -A && git commit -qm init)
begin; pub "" full; t_pre "F-subdir: ROOT nested in a parent repo publishes" "$eo" "PM_EMBED_OK"
t_eq "F-subdir: first facts calm" "$(facts)" "NO_CHANGE nothing moved"
t_eq "F-subdir: repo entry carries the scoped head" "$(S '(d["repos"][0]["vcs"], d["repos"][0]["head"]==__import__("subprocess").check_output(["git","-C","'$PAR'","log","-1","--format=%H","--","proj"],text=True).strip()[:12])')" "('git', True)"
echo more >> "$PAR/other.txt"; echo n > "$PAR/elsewhere.txt"; t_eq "F-subdir: edits elsewhere in the parent are invisible" "$(facts)" "NO_CHANGE nothing moved"
git -C "$PAR" add other.txt; git -C "$PAR" commit -qm outside; t_eq "F-subdir: a commit touching only the parent is invisible" "$(facts)" "NO_CHANGE nothing moved"
echo "# in" >> "$R/PLAN.md"; out=$(facts); t_has "F-subdir: an edit inside ROOT is seen" "$out" "working tree changed"
t_eq "F-subdir: dirty paths re-based onto ROOT" "$(get "$PM/inv-${out##* }/snapshot.json" 'd["dirty_paths"]')" "['PLAN.md']"
git -C "$PAR" add proj; git -C "$PAR" commit -qm inside; out=$(facts); t_eq "F-subdir: commits since the judged head are scoped (1, not 2)" "$(get "$PM/inv-${out##* }/snapshot.json" 'd["commits"]["count"]')" 1
# $HOME as the parent repository: a plain folder
mkdir -p "$T/hp/proj"; HP2=$(cd "$T/hp" && pwd -P); (cd "$HP2" && git init -q -b main && git config user.email t@t && git config user.name t && echo o > o.txt && echo r > proj/README.md && seq 1 300 > proj/PLAN.md && seq 1 200 > proj/REVIEW-LOG.md && git add -A && git commit -qm i)
OLDHOME="$HOME"; export HOME="$HP2"; R="$HP2/proj"; PM="$R/.project-map"; begin
t_eq "F-home-parent: a repo whose toplevel is \$HOME is scanned as a plain folder" "$(get "$STAGE/snapshot.json" '(d["repos"][0]["vcs"], d["repos"][0]["files"]>=1)')" "('none', True)"
pub "" full; t_eq "E-state identity.folder is ~-shortened under \$HOME" "$(S 'd["identity"]["folder"]')" "~/proj"
export HOME="$OLDHOME"

# ======================================================================================================
# 10. watched content: 40 entries, 125 files, cache, coverage (F-coverage), snapshot has no cap
# ======================================================================================================
mkproj w40 || true
upd 'base=len(json.dumps(J)); L=max(1,(5900-base)//40-8); J["watch"]=["w%02d-"%i+"x"*L for i in range(40)]'
t_pre "E-watch-40: 40 long watch paths publish" "$eo" "PM_EMBED_OK"
t_eq "E-watch-40: all 40 are in state.watch" "$(S 'len(d["watch"])')" 40
out=$(facts); t_true "E-watch-40: the next facts prints a verdict (no crash, no assert)" "case '$out' in NO_CHANGE*|NEEDS_*) true;; *) false;; esac"
t_eq "E-watch-40: missing watched paths hash as 'missing'" "$(S 'set(d["judged_key"]["watch_hashes"].values())')" "{'missing'}"
mkproj w125 || true
mkdir -p "$R/many"; python3 - "$R/many" <<'PY'
import sys
for i in range(125): open("%s/f%03d.txt" % (sys.argv[1], i), "w").write("content %d\n" % i)
PY
upd 'J["watch"]=["many","README.md"]'; t_pre "E-watch-125: a watched dir of 125 files publishes" "$eo" "PM_EMBED_OK"
bump; out=$(facts)
t_eq "E-watch-125: snapshot keeps all 125 files' worth (n=125), no cap" "$(get "$PM/inv-${out##* }/snapshot.json" '[w["n"] for w in d["watch"] if w["path"]=="many"]')" "[125]"
t_eq "E-watch-125: the watch cache holds every file (identity keys)" "$(get "$PM/cache.json" 'len([k for k in d["watch_cache"] if "/many/" in k])')" 125
t_eq "E-watch-125: cache entries carry dev, ino, size, mtime_ns, ctime_ns, sha256" "$(get "$PM/cache.json" 'sorted(next(v for k,v in d["watch_cache"].items() if "/many/" in k))')" "['ctime_ns', 'dev', 'ino', 'mtime_ns', 'sha256', 'size']"
echo changed > "$R/many/f007.txt"; out=$(facts); t_has "E-watch-125: one edited file inside the dir flips the key" "$out" "watch changed: many"
rm "$R/many/f007.txt"; out=$(facts); t_has "E-watch-125: a deleted file flips it too" "$out" "watch changed: many"
# F-coverage: non-git, over the budget
mkdir -p "$T/cov"; R=$(cd "$T/cov" && pwd -P); PM="$R/.project-map"; seq 1 300 > "$R/PLAN.md"; seq 1 200 > "$R/REVIEW-LOG.md"; echo r > "$R/README.md"; mkdir -p "$R/docs"
python3 - "$R/docs" <<'PY'
import sys
for i in range(60): open("%s/d%03d.md" % (sys.argv[1], i), "w").write("doc %d\n" % i * 20)
PY
begin; pub "" full; t_pre "F-coverage setup: non-git map published" "$eo" "PM_EMBED_OK"
t_eq "F-coverage complete at first" "$(facts)" "NO_CHANGE nothing moved"
rm -f "$PM/cache.json"; out=$(PM_FACTS_SLOW=0.02 facts --budget 1); rc=$?
t_true "F-coverage: over the budget -> NEEDS_REFRESH coverage partial k/n, exit 0" "[ $rc = 0 ] && echo '$out' | grep -qE '^NEEDS_REFRESH coverage partial [0-9]+/[0-9]+( \\(deferred: budget\\))?\$'"
t_not "F-coverage: partial coverage never spawns (no inv token)" "$out" " inv "
t_true "F-coverage: no staging dir was created" "[ \$(ndirs) = 1 ]"
out=$(facts); t_eq "F-coverage: completes on the next run, then calm" "$out" "NO_CHANGE nothing moved"
t_eq "F-coverage: state.coverage complete" "$(S 'd["coverage"]["coverage"]')" complete
# partial + git key moved -> NEEDS_JUDGEMENT as usual (git is not involved for non-git: the status signature)
rm -f "$PM/cache.json"; echo x > "$R/newfile.txt"; out=$(PM_FACTS_SLOW=0.02 facts --budget 1)
t_pre "F-coverage: partial AND the working tree moved -> NEEDS_JUDGEMENT as usual" "$out" "NEEDS_JUDGEMENT"
t_eq "F-coverage: the snapshot for that staging records coverage partial" "$(get "$PM/inv-${out##* }/snapshot.json" 'd["status"]["coverage"]')" partial
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"; pub 'J["headline"]["text"]="partial judged"' update
t_pre "F-coverage: an embed from partial coverage publishes" "$eo" "PM_EMBED_OK"
t_eq "F-coverage: the state records coverage partial" "$(S 'd["coverage"]["coverage"]')" partial
t_has "F-coverage: the brief carries the coverage note" "$(cat "$PM/brief.txt")" "coverage partial"
out=$(facts); t_true "F-coverage: the next full run adopts the hashes (refresh, no judging)" "case '$out' in 'NEEDS_REFRESH coverage'*|NO_CHANGE*) true;; *) false;; esac"
t_eq "F-coverage: then calm" "$(facts)" "NO_CHANGE nothing moved"
echo more >> "$R/docs/d001.md"; out=$(facts); t_has "F-coverage: a real edit after adoption is seen" "$out" "watch changed: docs"

# ======================================================================================================
# 11. invalid state, migration (3.x), pack under stress
# ======================================================================================================
mkproj is || true
g0=$(gen); printf '[]' > "$PM/current/state.json"; lib resign "$PM/current"; out=$(facts); t_pre "E-types state [] -> NEEDS_FULL invalid state" "$out" "NEEDS_FULL invalid state inv "
INV=${out##* }; STAGE="$PM/inv-$INV"; t_eq "E-types invalid state: staging base is the pointed generation (so embed can publish)" "$(get "$STAGE/invocation.json" 'd["base"]')" "$g0"
INVN=inv-$INV; pub 'J["headline"]["text"]="recovered"' full; t_pre "E-types invalid state: a FULL run replaces it" "$eo" "PM_EMBED_OK"
t_eq "E-types invalid state: calm afterwards" "$(facts)" "NO_CHANGE nothing moved"
printf '{"schema":"project-map-3"}' > "$PM/current/state.json"; lib resign "$PM/current"; out=$(facts); t_pre "E-types an older state schema -> NEEDS_FULL schema mismatch" "$out" "NEEDS_FULL schema mismatch"
printf 'not json' > "$PM/current/state.json"; lib resign "$PM/current"; out=$(facts); t_pre "E-types state that is not JSON -> NEEDS_FULL invalid state" "$out" "NEEDS_FULL invalid state"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"; pub 'J["headline"]["text"]="again"' full; t_pre "E-types ... and recovers" "$eo" "PM_EMBED_OK"
mkproj is2 || true; rm "$PM/current/plan.json"; lib resign "$PM/current"; out=$(facts); t_pre "E-types a missing plan.json -> NEEDS_FULL invalid state" "$out" "NEEDS_FULL invalid state"
mkproj is3 || true; ln -sfn gen-000007-zzzz "$PM/current"; out=$(facts); t_pre "E-types a malformed current pointer -> NEEDS_FULL invalid state" "$out" "NEEDS_FULL invalid state"
# migration
mkrepo mg; lib legacy "$R"; mkdir -p "$R/thoughts/ledgers"
begin; t_pre "E-migrate: a 3.x map (regular state.json, no current) -> NEEDS_FULL migrate inv" "$out" "NEEDS_FULL migrate inv "
t_eq "E-migrate: staging base is null" "$(get "$STAGE/invocation.json" 'd["base"]')" None
t_eq "E-migrate: judgement.in.json is the legacy judgement (ids, ledger carried)" "$(get "$STAGE/judgement.in.json" '(d["project"]["ledger"], [p["id"] for p in d["parts"]][:2])')" "('demo-engine', ['ground-truth', 'engine'])"
t_eq "E-migrate: plan.json derived from the 3.x milestone list (5 phases)" "$(get "$STAGE/plan.json" '[p["id"] for p in d["phases"]]')" "['P1', 'P2', 'P3', 'P4', 'P5']"
t_eq "E-migrate: current milestone's criteria land in its phase" "$(get "$STAGE/plan.json" '[len(p["criteria"]) for p in d["phases"]]')" "[0, 4, 0, 0, 0]"
t_eq "E-migrate: the legacy answer is replayed against the carried decisions (applied 0, total 1, D-001 answered)" "$(get "$STAGE/snapshot.json" '(d["answers"]["applied"],d["answers"]["total"],[x["status"] for x in d["decisions"] if x["id"]=="D-001"])')" "(0, 1, ['answered'])"
t_eq "E-migrate: answers baseline hash computed from the legacy applied count (no false ERROR)" "$(get "$STAGE/snapshot.json" 'len(d["answers"]["applied_hash"])')" 64
t_true "E-migrate: legacy top-level files untouched until the switch" "[ -f $PM/judgement.json ] && [ -f $PM/facts.json ] && [ ! -L $PM/state.json ]"
jud "$INVN" full 'J["project"]["ledger"]="demo-engine"'; eo=$(embed "$INVN"); erc=$?
t_true "E-migrate: FULL embed publishes the migration generation" "[ $erc = 0 ] && case '$eo' in 'PM_EMBED_OK gen 000001-'*) true;; *) false;; esac"
t_true "E-migrate: legacy/ keeps copies of the six 3.x files" "for n in state.json judgement.json facts.json index.html mobile.html brief.txt; do [ -f $PM/$(cur)/legacy/\$n ] || exit 1; done"
t_eq "E-migrate: the copy is the old content" "$(cat "$PM/$(cur)/legacy/brief.txt")" "legacy brief"
t_true "E-migrate-links: the four legacy files were replaced by symlinks" "for n in index.html mobile.html brief.txt state.json; do [ -L $PM/\$n ] || exit 1; done"
t_true "E-migrate: legacy judgement.json and facts.json removed only after the switch" "[ ! -e $PM/judgement.json ] && [ ! -e $PM/facts.json ]"
t_eq "E-migrate: retired ids carried over" "$(S '"old-part" in d["retired_ids"] and "D-000" in d["retired_ids"]')" True
t_eq "E-migrate: run counter continues (legacy run 4 -> 5)" "$(S 'd["run"]["n"]')" 5
t_eq "E-migrate: the ledger binding was kept" "$(S 'd["project"]["ledger"]')" demo-engine
t_eq "E-migrate: the manifest base is null" "$(get "$PM/current/manifest.json" 'd["base"]')" None
t_eq "E-migrate: calm afterwards" "$(facts)" "NO_CHANGE nothing moved"
t_eq "E-migrate: answered legacy decision frozen with its answer" "$(S '[(x["status"],x["answer"]) for x in d["decisions"] if x["id"]=="D-001"]')" "[('answered', 'A')]"
# crash during migration after the pointer: links repaired by facts (E-migrate-links)
mkrepo mg2; lib legacy "$R"; begin; jud "$INVN" full ''; PM_EMBED_CRASH_AT=pointer embed "$INVN" >/dev/null 2>&1; rc=$?
t_eq "E-migrate-links: killed after the pointer rename" "$rc" 99
t_true "E-migrate-links: current exists but the stable paths are still legacy regular files" "[ -L $PM/current ] && [ ! -L $PM/state.json ] && [ -f $PM/state.json ]"
out=$(facts); t_true "E-migrate-links: facts repairs the links and does not report NO_CHANGE blindly" "case '$out' in NO_CHANGE*|NEEDS_*) true;; *) false;; esac"
t_true "E-migrate-links: all four stable paths are symlinks into current/" "for n in index.html mobile.html brief.txt state.json; do [ \"\$(readlink $PM/\$n)\" = current/\$n ] || exit 1; done"
t_eq "E-migrate-links: state.json through the stable link is the new schema" "$(S 'd["schema"]')" "project-map-4"
# crash before the pointer during migration keeps the legacy map intact
mkrepo mg3; lib legacy "$R"; begin; jud "$INVN" full ''; PM_EMBED_CRASH_AT=manifest embed "$INVN" >/dev/null 2>&1
t_true "E-migrate-links: a crash before the switch leaves every legacy file in place" "[ ! -e $PM/current ] && [ -f $PM/state.json ] && [ ! -L $PM/state.json ] && [ -f $PM/judgement.json ]"
out=$(facts); t_pre "E-migrate-links: ... and facts still says migrate (after sweeping the half-written dir)" "$out" "NEEDS_FULL migrate"
t_true "E-migrate-links: the half-written generation was swept" "! ls $PM | grep -q '^gen-'"
# pack under stress (G / M)
mkproj g1 || true
for i in $(seq 1 150); do git -C "$R" commit -q --allow-empty -m "fix: revert broken thing number $i with a long long subject line to take space"; done
for i in $(seq 1 120); do echo $i > "$R/dirty-$i.txt"; done
python3 - "$R/thoughts/ledgers/demo-engine.md" <<'PY'
import sys
open(sys.argv[1], 'w').write('## Goal\n' + ''.join('- goal line %d ' % i + 'x' * 150 + '\n' for i in range(40)) + '## Next action\n' + ''.join('%d. next ' % i + 'y' * 150 + '\n' for i in range(40)))
PY
python3 - "$PM/answers.jsonl" <<'PY'
import sys
open(sys.argv[1], "w").write("".join("junk %d %s\n" % (i, "z" * 80) for i in range(600)))
PY
out=$(facts); t_pre "E-pack stress: verdict printed" "$out" "NEEDS_JUDGEMENT"; STAGE="$PM/inv-${out##* }"
t_true "E-pack stress: pack.json <= 8192 bytes" "[ \$(wc -c < $STAGE/pack.json) -le 8192 ]"
t_eq "E-pack stress: snapshot keeps the complete record (120 dirty, 600 bad answer lines)" "$(get "$STAGE/snapshot.json" '(d["status"]["dirty"],len(d["answers"]["bad"]))')" "(121, 600)"
t_eq "E-pack stress: trimmed counters are set (items, ledger, answers)" "$(get "$STAGE/pack.json" '(d["trimmed"]["items"]>0, d["trimmed"]["ledger"], d["trimmed"]["answers"]>=0)')" "(True, True, True)"
t_eq "E-pack stress: commits count in the snapshot is the true incremental count" "$(get "$STAGE/snapshot.json" 'd["commits"]["count"]')" 150
t_eq "E-pack stress: flagged commits among the 40 listed" "$(get "$STAGE/snapshot.json" '(d["commits"]["listed"],d["commits"]["flagged"])')" "(40, 40)"
t_eq "E-pack stress: pack still has the generation stamp and digests" "$(get "$STAGE/pack.json" '(d["generation"]=="'"inv-${out##* }"'", len(d["key_digest"]))')" "(True, 12)"
INVN=inv-${out##* }; pub 'J["headline"]["text"]="stress"' update; t_pre "E-pack stress: publishes (answers.bad does not break state)" "$eo" "PM_EMBED_OK"
t_true "E-pack stress: state.json stays under its cap" "[ \$(wc -c < $PM/current/state.json) -le 65536 ]"
t_true "E-pack stress: the published pack is <= 8192 bytes" "[ \$(wc -c < $PM/current/pack.json) -le 8192 ]"

# ======================================================================================================
# 12. page: escaping, template properties
# ======================================================================================================
mkproj es || true
upd 'J["headline"]["text"]="x <!-- y </script><b>&amp; \U0001F680 end"; J["parts"][2]["line"]="a</script>b"'; t_pre "E-escape: publish with <!-- and </script>" "$eo" "PM_EMBED_OK"
t_eq "E-escape: the state embedded in index.html parses and keeps the text verbatim" "$(python3 - "$PM/index.html" <<'PY'
import json, re, sys
html = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'<script type="application/json" id="state">(.*?)</script>', html, re.S)
S = json.loads(m.group(1))
print(S["headline"]["text"] == "x <!-- y </script><b>&amp; \U0001F680 end" and S["parts"][2]["line"] == "a</script>b" and "<!--" not in m.group(1) and "</script" not in m.group(1))
PY
)" True
t_eq "E-template: only textContent (no innerHTML assignment)" "$(grep -c '\.innerHTML' "$PM/index.html")" 0
t_eq "E-template: no external requests (no http(s) except the SVG namespace)" "$(grep -oE 'https?://[^"'"'"' )]*' "$PM/index.html" | grep -vc 'www.w3.org/2000/svg')" 0
t_true "E-template: prefers-reduced-motion block present" "grep -q 'prefers-reduced-motion' $PM/index.html"
t_true "E-template: identity block, phases and plan-vs-shipped present" "grep -q 'id=\"phase-list\"' $PM/index.html && grep -q 'Plan vs shipped' $PM/index.html && grep -q 'Project phases' $PM/index.html && grep -q 'aria-selected' $PM/index.html"
t_eq "E-template: <title> is the project name" "$(grep -o '<title>[^<]*</title>' "$PM/index.html")" "<title>demo-app - project map</title>"
t_true "E-template: mobile.html wraps index.html and carries the stamp" "grep -q 'index.html' $PM/mobile.html"
t_true "E-template: the page JavaScript parses" "python3 - $PM/index.html <<'PY'
import re, subprocess, sys, shutil
html = open(sys.argv[1], encoding='utf-8').read()
js = re.findall(r'<script>(.*?)</script>', html, re.S)[-1]
node = shutil.which('node')
if not node: sys.exit(0)
open('$T/page.js', 'w').write(js)
sys.exit(subprocess.run([node, '--check', '$T/page.js']).returncode)
PY"
# state is rendered from stale + coverage banners
t_has "E-template: stale notice text exists in the template" "$(cat "$HOOKS/project-map-template.html")" "Assessment may be out of date"
t_has "E-template: coverage notice text exists in the template" "$(cat "$HOOKS/project-map-template.html")" "Coverage partial"

# ======================================================================================================
# 13. exit-code table and misc contract lines
# ======================================================================================================
mkproj ex || true
facts >/dev/null; t_eq "F-exit NO_CHANGE exits 0" "$?" 0
bump; facts >/dev/null; t_eq "F-exit NEEDS_JUDGEMENT exits 0" "$?" 0
t_eq "F-exit the staging snapshot says base = the current generation" "$(get "$PM/inv-$(facts | awk '{print $NF}')/invocation.json" 'd["base"]')" "$(gen)"
t_eq "E-state criteria_updates change the plan carried into the next staging" "$(upd 'J["criteria_updates"]=[{"id":"P2.c2","done":True,"ref":"file:PLAN.md:5"}]'; bump; begin; get "$STAGE/plan.json" '[c["done"] for p in d["phases"] for c in p["criteria"] if c["id"]=="P2.c2"]')" "[True]"
t_eq "E-state plan.json of the generation holds the updated criterion" "$(get "$PM/current/plan.json" '[c["ref"] for p in d["phases"] for c in p["criteria"] if c["id"]=="P2.c2"]')" "['file:PLAN.md:5']"

echo; echo "total $((pass+fail)) pass $pass fail $fail"; [ "$fail" = 0 ]
