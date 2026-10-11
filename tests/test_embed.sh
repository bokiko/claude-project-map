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

if [ "${PM_FC_ONLY:-}" != 1 ] && [ "${PM_DR_ONLY:-}" != 1 ]; then   # PM_FC_ONLY=1 runs section 15 alone, PM_DR_ONLY=1 section 16 alone (the mutation checks); see the `fi` before section 15

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
t_eq "F-stage snapshot key has the 11 components (3.5.0: intent_hash, null on a first map; 3.6.0: evidence_lost, empty)" "$(get "$STAGE/snapshot.json" 'sorted(d["key"])')" "['answers_count', 'branches', 'evidence_lost', 'expired_ids', 'heads', 'intent_hash', 'ledger_hash', 'release', 'schema', 'status_hash', 'watch_hashes']"
t_eq "F-stage snapshot answers baseline: applied 0, no pending" "$(get "$STAGE/snapshot.json" '(d["answers"]["applied"],len(d["answers"]["pending"]))')" "(0, 0)"
t_true "F-stage pack <= 8192 bytes" "[ \$(wc -c < $STAGE/pack.json) -le 8192 ]"
t_eq "F-stage pack drops the raw keys for digests" "$(get "$STAGE/pack.json" '"key" not in d and len(d["key_digest"])==12')" True
t_eq "F-stage pack carries trimmed counters (all zero here)" "$(get "$STAGE/pack.json" 'd["trimmed"]')" "{'items': 0, 'watch': 0, 'ledger': False, 'answers': 0, 'decisions': 0, 'usage': False}"
jud "$INVN" full ""; eo=$(embed "$INVN"); erc=$?
t_true "E-publish: PM_EMBED_OK gen <seq>-<id> <bytes>, exit 0" "[ $erc = 0 ] && echo '$eo' | grep -qE '^PM_EMBED_OK gen 000001-[0-9a-f]{8} [0-9]+\$'"
G=$(gen)
t_true "E-layout current -> gen-000001-<id8> (one symlink)" "[ -L $PM/current ] && [ \"\$(cur)\" = gen-$G ]"
t_true "E-layout stable links index mobile brief state handoff -> current/<name> (five since 3.5.0)" "for n in index.html mobile.html brief.txt state.json handoff.txt; do [ \"\$(readlink $PM/\$n)\" = current/\$n ] || exit 1; done"
t_true "E-layout generation files exist" "for n in manifest.json state.json index.html mobile.html brief.txt handoff.txt snapshot.json pack.json plan.json judgement.json; do [ -f $PM/gen-$G/\$n ] || exit 1; done"
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
t_eq "E-state judged_key holds the facts key; answers baseline recorded" "$(S '(sorted(d["judged_key"])==["answers_count","branches","evidence_lost","expired_ids","heads","intent_hash","ledger_hash","release","schema","status_hash","watch_hashes"], d["answers"]["applied"])')" "(True, 0)"
t_eq "E-state history has one run, run.n 1" "$(S '(len(d["history"]),d["run"]["n"])')" "(1, 1)"
t_eq "E-state decisions: D-001 open (not ready), D-002 hard-rule open" "$(S '[(x["id"],x["status"],x["default"]) for x in d["decisions"]]')" "[('D-001', 'open', 'hold'), ('D-002', 'open', 'hold')]"
t_eq "E-state watch recorded from the first snapshot (README PLAN docs ledgers)" "$(S 'd["watch"]')" "['README.md', 'PLAN.md', 'docs', 'thoughts/ledgers']"
t_eq "E-state stale is null right after publishing" "$(S 'd["stale"]')" None
t_true "E-brief <= 1000 bytes" "[ \$(wc -c < $PM/brief.txt) -le 1000 ]"
t_true "E-brief line 1 folder: last two components after an ellipsis, no mid-component cut" "head -1 $PM/brief.txt | grep -qE ' · …/[^/ ]+/[^/ ]+ · phase'"
t_pre "E-brief line 1 starts with the project name" "$(head -1 "$PM/brief.txt")" "demo-app · "
t_true "E-brief line 1 ends with '· phase k/n <label> · <tone>'" "head -1 $PM/brief.txt | grep -q ' · phase 2/3 Full-model check passes · watch\$'"
t_pre "E-brief line 2 = as of <minute> · assessed <minute> · current" "$(sed -n 2p "$PM/brief.txt")" "as of 20"
t_true "E-brief line 2 names both times: snapshot minute, then assessment minute" "sed -n 2p $PM/brief.txt | grep -qE '^as of 20[0-9-]+T[0-9:]{5} · assessed 20[0-9-]+T[0-9:]{5} · current'"
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
t_true "F-stale-refresh: the brief shows 'behind: 1 new commits' after a verdict that spawns" "sed -n 2p $PM/brief.txt | grep -q 'behind: 1 new commits'"
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
for i in 1 2 3 4 5 6; do printf '{"id":"D-00%s","answer":"hold","by":"owner"}\n' $i >> "$PM/answers.jsonl"; done
upd 'J["decisions"]=[]'; t_true "E-brief no open decisions -> no 'needs you' lines" "! grep -qE '^D-[0-9]+ needs you' $PM/brief.txt"
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
pub 'J["headline"]["text"]="rebaselined"; J["decisions"]=[]' update; t_pre "F-answers-rewritten publish after accept" "$eo" "PM_EMBED_OK"
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
# 3.3.0 one-key: hooks run WITH CLAUDE_PLUGIN_DATA, the skill's Bash calls WITHOUT it; both must accept the same map
VK="import sys,os; sys.path.insert(0,'$HOOKS'); import pm_common as C; pm='$PM'; sys.exit(0 if C.verify_generation(os.path.join(pm, os.readlink(os.path.join(pm,'current')))) else 1)"
t_true "K-one-key: current generation verifies without CLAUDE_PLUGIN_DATA" "python3 -c \"$VK\""
t_true "K-one-key: the same generation verifies with CLAUDE_PLUGIN_DATA set (hook environment)" "CLAUDE_PLUGIN_DATA='$T/hookdata' python3 -c \"$VK\""
t_true "K-one-key: a hook environment never creates a second key" "[ ! -e '$T/hookdata/key' ]"
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
  t_true "E-crash-$stage: facts repaired the five stable links" "for n in index.html mobile.html brief.txt state.json handoff.txt; do [ \"\$(readlink $PM/\$n)\" = current/\$n ] || exit 1; done"
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
t_true "E-migrate-links: all five stable paths are symlinks into current/" "for n in index.html mobile.html brief.txt state.json handoff.txt; do [ \"\$(readlink $PM/\$n)\" = current/\$n ] || exit 1; done"
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
t_eq "E-pack stress: trimmed counters are set (ledger, answers); 3.6.1: every listed commit subject is kept (commit items go last)" "$(get "$STAGE/pack.json" '(d["trimmed"]["items"], d["seen"]["commits"], d["trimmed"]["ledger"], d["trimmed"]["answers"]>=0)')" "(0, 40, True, True)"
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

# ======================================================================================================
# 3.3.0 release facts: tags at HEAD and branch sync, local evidence only
# ======================================================================================================
gx()  { git -C "$R" "$@"; }
gcm() { git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "${2:-c}"; }
rf()  { facts --json --no-stage > "$T/rf.json"; }
rg()  { get "$T/rf.json" "$1"; }
RL='d["snapshot"]["repos"][0]["release"]'
rgl() { rg "$RL$1"; }
mkremote() { # NAME: bare remote + origin on the current R, pushed with upstream; OTH = a second clone of it
  git init -q --bare -b main "$T/$1.git"; gx remote add origin "$T/$1.git"; gx push -q -u origin main 2>/dev/null
  git clone -q "$T/$1.git" "$T/$1-oth" 2>/dev/null; OTH="$T/$1-oth"; git -C "$OTH" config user.email t@t; git -C "$OTH" config user.name t
}
syncs() { echo "$(rgl '["sync"]["state"]'),$(rgl '["sync"]["ahead"]'),$(rgl '["sync"]["behind"]')"; }

mkrepo rl1; rf
t_eq "REL no tags: no head tags" "$(rgl '["head_tags_total"]')" 0
t_eq "REL no tags: no recent tags" "$(rgl '["recent_tags"]')" "[]"
t_eq "REL no upstream: state and null counts (never invented zeros)" "$(syncs)" "no_upstream,None,None"
t_eq "REL head oid is the full pinned HEAD" "$(rgl '["head_oid"]')" "$(gx rev-parse HEAD)"
t_eq "REL release line, no tag and no upstream" "$(rgl '["line"]')" "no tag at HEAD · no upstream"
t_eq "REL snapshot key carries a release entry" "$(rg 'sorted(d["snapshot"]["key"]["release"]["."])')" "['ahead', 'n', 'state', 'tags', 'upstream']"
t_eq "REL not shared in a plain repo" "$(rgl '["shared"]')" False
t_eq "REL not shallow" "$(rgl '["shallow"]')" False

gx tag v1.0; rf
t_eq "REL lightweight tag at HEAD" "$(rgl '["head_tags"]')" "[{'name': 'v1.0', 'kind': 'lightweight', 'tid': 'fa8b919c909d5eb9'}]"
t_eq "REL line: tagged v1.0 at HEAD" "$(rgl '["line"]')" "tagged v1.0 at HEAD · no upstream"
gx tag -d v1.0 >/dev/null; gx -c user.email=t@t -c user.name=t tag -a -m rel v2.0; rf
t_eq "REL annotated tag at HEAD (peeled to the commit)" "$(rgl '["head_tags"]')" "[{'name': 'v2.0', 'kind': 'annotated', 'tid': '7761fa9497f8fb82'}]"
gcm "$R" more; rf
t_eq "REL tag on an older commit only: not a head tag" "$(rgl '["head_tags_total"]')" 0
t_eq "REL tag on an older commit only: still in recent tags" "$(rgl '["recent_tags"][0]["name"]')" v2.0
t_eq "REL line: no tag at HEAD although a tag exists" "$(rgl '["line"]')" "no tag at HEAD · no upstream"
gx tag release-a; gx tag build/7; gx tag zz; gx tag zzz; rf
t_eq "REL several tags at HEAD: sorted, all counted" "$(rgl '["head_tags_total"]'),$(rg '[t["name"] for t in d["snapshot"]["repos"][0]["release"]["head_tags"]]')" "4,['build/7', 'release-a', 'zz', 'zzz']"
t_eq "REL several tags: line names three and counts the rest" "$(rgl '["line"]')" "tagged build/7, release-a, zz +1 at HEAD · no upstream"
t_eq "REL recent tags: at most five" "$(rg 'len(d["snapshot"]["repos"][0]["release"]["recent_tags"])')" 5
gx tag -d release-a build/7 zz zzz >/dev/null

# upstream through a local bare remote: aligned / ahead / behind / diverged
mkremote rem1; rf
t_eq "REL remote upstream aligned" "$(syncs)" "aligned,0,0"
t_eq "REL upstream kind remote and ref" "$(rgl '["sync"]["upstream_kind"]'),$(rgl '["sync"]["upstream_ref"]')" "remote,refs/remotes/origin/main"
t_eq "REL line aligned (local tracking state wording)" "$(rgl '["line"]')" "no tag at HEAD · in sync with origin/main (local tracking state)"
gcm "$R" a1; gcm "$R" a2; gcm "$R" a3; rf
t_eq "REL ahead 3" "$(syncs)" "ahead,3,0"
t_eq "REL line ahead 3" "$(rgl '["line"]')" "no tag at HEAD · 3 commits ahead of origin/main"
gx push -q origin main 2>/dev/null; rf
t_eq "REL after push: aligned again" "$(syncs)" "aligned,0,0"
othpush() { git -C "$OTH" pull -q --ff-only origin main 2>/dev/null; gcm "$OTH" "$1"; git -C "$OTH" push -q origin main 2>/dev/null; }
othpush r1; gx fetch -q origin; rf
t_eq "REL behind 1 after fetch" "$(syncs)" "behind,0,1"
t_eq "REL line behind 1" "$(rgl '["line"]')" "no tag at HEAD · 1 commit behind origin/main"
gcm "$R" local1; rf
t_eq "REL diverged" "$(syncs)" "diverged,1,1"
t_eq "REL line diverged" "$(rgl '["line"]')" "no tag at HEAD · diverged from origin/main (1 ahead, 1 behind)"
# configured but missing tracking ref
mkrepo rl2; gx remote add origin "$T/none.git"; gx config branch.main.remote origin; gx config branch.main.merge refs/heads/gone; rf
t_eq "REL configured but missing upstream" "$(syncs)" "missing_upstream,None,None"
t_eq "REL line missing upstream" "$(rgl '["line"]')" "no tag at HEAD · upstream origin/gone missing locally"
# local branch as upstream
mkrepo rl3; gx checkout -q -b feat; gcm "$R" f1; gx branch -q --set-upstream-to=main feat; rf
t_eq "REL local-branch upstream: kind local, ahead 1" "$(rgl '["sync"]["upstream_kind"]'),$(syncs)" "local,ahead,1,0"
t_eq "REL local upstream line" "$(rgl '["line"]')" "no tag at HEAD · 1 commit ahead of local main"
# detached HEAD
gx checkout -q --detach; rf
t_eq "REL detached HEAD" "$(rgl '["sync"]["state"]'),$(rgl '["sync"]["branch_ref"]')" "detached,None"
t_eq "REL detached line" "$(rgl '["line"]')" "no tag at HEAD · detached HEAD"
# unborn repository
R="$T/rl4"; mkdir -p "$R"; git -C "$R" init -q -b main; PM="$R/.project-map"; rf
t_eq "REL unborn repo" "$(rgl '["sync"]["state"]'),$(rgl '["head_oid"]'),$(rgl '["line"]')" "unborn,None,no commits yet"
# shallow clone
mkrepo rl5s; gcm "$R" s2; gcm "$R" s3; SRCR="$R"; R="$T/rl5"; git clone -q --depth 1 "file://$SRCR" "$R" 2>/dev/null; PM="$R/.project-map"; rf
t_eq "REL shallow clone flagged" "$(rgl '["shallow"]')" True
t_eq "REL shallow clone: upstream known" "$(rgl '["sync"]["upstream_kind"]'),$(rgl '["sync"]["state"]')" "remote,aligned"
t_has "REL shallow line says so" "$(rgl '["line"]')" "shallow clone"
# a sub-folder ROOT of a larger repository: the SHARED repository's state, marked as such
mkrepo rl6; mkdir -p "$R/pkg"; echo x > "$R/pkg/f.txt"; gx add -A; gx -c user.email=t@t -c user.name=t commit -q -m pkg; gx tag shared-v1
R6="$R"; R="$R6/pkg"; PM="$R/.project-map"; rf
t_eq "REL sub-folder ROOT: release is marked shared" "$(rgl '["shared"]')" True
t_eq "REL sub-folder ROOT: shared tag shown" "$(rgl '["head_tags"][0]["name"]')" shared-v1
t_pre "REL sub-folder ROOT: line says shared repo" "$(rgl '["line"]')" "shared repo: tagged shared-v1 at HEAD"
t_eq "REL sub-folder ROOT: head oid is the repository HEAD, not the path-scoped commit" "$(rgl '["head_oid"]')" "$(git -C "$R6" rev-parse HEAD)"
# a nested standalone repository gets its own facts
mkrepo rl7; mkdir -p "$R/inner"; git -C "$R/inner" init -q -b main; gcm "$R/inner" n1; git -C "$R/inner" tag inner-v1; gx tag outer-v1; rf
t_eq "REL nested standalone repo has its own tags" "$(rg '[(r["path"], r["release"]["head_tags"][0]["name"], r["release"]["shared"]) for r in d["snapshot"]["repos"]]')" "[('.', 'outer-v1', False), ('inner', 'inner-v1', False)]"

# ---- transitions on a published map
mkproj rm1 >/dev/null; out=$(facts); t_pre "REL-T baseline: nothing moved -> NO_CHANGE" "$out" "NO_CHANGE"
gx tag v9.0; out=$(facts); t_pre "REL-T tag-only change (no commit) -> NEEDS_JUDGEMENT tags changed" "$out" "NEEDS_JUDGEMENT tags changed"
t_eq "REL-T tag-only: commits_since stays 0 in the stale record" "$(S 'd["stale"]["commits_since"]')" 0
t_has "REL-T tag-only: the brief says why it is behind" "$(cat "$PM/current/brief.txt")" "behind: tags changed"
begin; pub "" update; t_pre "REL-T tag-only: re-judged and published" "$eo" "PM_EMBED_OK"
out=$(facts); t_pre "REL-T tag-only: after the judgement -> NO_CHANGE" "$out" "NO_CHANGE"
t_has "REL-T state carries the release facts" "$(S 'd["repos"][0]["release"]["line"]')" "tagged v9.0 at HEAD"
t_has "REL-T brief carries the git line" "$(cat "$PM/current/brief.txt")" "git: tagged v9.0 at HEAD · no upstream"

mkproj rm2 >/dev/null; mkremote rem2; gcm "$R" p1; gcm "$R" p2; begin; pub "" update
t_eq "REL-T push-only baseline: ahead 2 judged" "$(S 'd["judged_key"]["release"]["."]["state"]+str(d["judged_key"]["release"]["."]["ahead"])')" "ahead2"
out=$(facts); t_pre "REL-T ahead 2 judged -> NO_CHANGE" "$out" "NO_CHANGE"
gx push -q origin main 2>/dev/null; out=$(facts)
t_pre "REL-T push-only (ahead 2 -> aligned, no new commit) -> NEEDS_JUDGEMENT branch sync changed" "$out" "NEEDS_JUDGEMENT branch sync changed"
begin; pub "" update; out=$(facts); t_pre "REL-T push-only: after the judgement -> NO_CHANGE" "$out" "NO_CHANGE"

# behind 1 -> 2 alone must not loop
othpush b1; gx fetch -q origin; out=$(facts); t_pre "REL-T aligned -> behind 1 re-judges once" "$out" "NEEDS_JUDGEMENT branch sync changed"
begin; pub "" update
othpush b2; gx fetch -q origin
out=$(facts); t_pre "REL-T behind 1 -> 2 alone: mechanical refresh, no judgement" "$out" "NEEDS_REFRESH release facts changed"
t_eq "REL-T the refresh shows behind 2" "$(S 'd["repos"][0]["release"]["sync"]["behind"]')" 2
t_eq "REL-T the refresh did not stamp the judgement stale" "$(S 'd["stale"]')" None
out=$(facts); t_pre "REL-T no refresh loop: the next run is NO_CHANGE" "$out" "NO_CHANGE"
out=$(facts); t_pre "REL-T and again" "$out" "NO_CHANGE"

# a key judged before 3.3.0 forces exactly one re-judgement
mkproj rm3 >/dev/null; lib mut "$PM/current/state.json" 'del d["judged_key"]["release"]; [r.pop("release", None) for r in d["repos"]]'; lib resign "$PM/current"
out=$(facts); t_pre "REL-T pre-3.3 key -> NEEDS_JUDGEMENT (not silently adopted)" "$out" "NEEDS_JUDGEMENT tags and branch sync not yet judged"
out=$(facts); t_pre "REL-T pre-3.3 key stays unadopted until judged" "$out" "NEEDS_JUDGEMENT"
begin; pub "" update; t_pre "REL-T pre-3.3 key: one judgement publishes" "$eo" "PM_EMBED_OK"
out=$(facts); t_pre "REL-T pre-3.3 key: exactly one re-judgement, then NO_CHANGE" "$out" "NO_CHANGE"

# a tag created while the judgement was being written is flagged stale at publish time
mkproj rm4 >/dev/null; bump; begin; jud "$INVN" update ""; gx tag during-judgement; eo=$(embed "$INVN")
t_pre "REL-T publish with a tag created during judgement still succeeds" "$eo" "PM_EMBED_OK"
t_has "REL-T ... but is flagged stale" "$eo" "PM_EMBED_STALE tags changed"
out=$(facts); t_pre "REL-T ... and the next run re-judges" "$out" "NEEDS_JUDGEMENT"

# caps with long names
mkrepo rl8
for c in t u w x; do gx tag "$(python3 -c "print('$c'*200)")"; done
LONGB=$(python3 -c "print('b'*200)"); gx checkout -q -b "$LONGB"; git init -q --bare -b main "$T/rem8.git"; gx remote add origin "$T/rem8.git"; gx push -q -u origin "$LONGB" 2>/dev/null; gcm "$R" l1; gx tag "$(python3 -c "print('y'*200)")"; rf
t_true "REL-cap line is at most 200 bytes with long tag and branch names" '[ "$(rgl "[\"line\"]" | wc -c | tr -d " ")" -le 201 ]'
begin; t_true "REL-cap pack within 8192 bytes with long names" '[ "$(wc -c < "$STAGE/pack.json" | tr -d " ")" -le 8192 ]'
t_has "REL-cap pack carries the release line per repo" "$(get "$STAGE/pack.json" 'd["repos"][0]["release_line"]')" "ahead of"
pub "" full >/dev/null; t_pre "REL-cap long names: first map publishes" "$eo" "PM_EMBED_OK"
t_true "REL-cap brief within 1000 bytes with long names" '[ "$(wc -c < "$PM/current/brief.txt" | tr -d " ")" -le 1000 ]'
t_has "REL-cap brief keeps the git line" "$(cat "$PM/current/brief.txt")" "git: "
t_not "REL-cap the line never claims a release" "$(rgl '["line"]')" "released"
t_not "REL-cap ... nor a push" "$(rgl '["line"]')" "pushed"
# pack trimming order: recent tags go first, the release line is the last thing to go
t_eq "REL-cap pack trim: recent_tags first, release_line survives the harshest trim" "$(python3 - "$HOOKS" "$STAGE/snapshot.json" <<'PYEOF'
import json, sys
sys.path.insert(0, sys.argv[1])
import pm_collect as K
snap = json.load(open(sys.argv[2]))
snap["repos"][0]["release"]["recent_tags"] = [{"name": "r%d" % i, "kind": "lightweight", "at": "abcdef0"} for i in range(5)]
big = json.loads(json.dumps(snap))
big["decisions"] = [{"id": "D-%03d" % i, "status": "open", "q": "q" * 400, "options": [{"id": "A", "label": "x" * 100}], "default": "A"} for i in range(40)]
big["commits"]["days"] = [{"day": "2026-01-%02d" % (i % 28 + 1), "n": 5, "items": [{"r": ".", "h": "abcdef0", "s": "s" * 60, "f": "watch"}] * 5} for i in range(40)]
try:
    q = K.build_pack(big, "inv-x")
    r0 = q["repos"][0]
    print("recent_tags" not in r0.get("release", {}) or not r0["release"]["recent_tags"], bool(r0.get("release_line")), len(json.dumps(q)) <= 8192)
except K.PackOverflow:
    print("overflow")
PYEOF
)" "True True True"


# brief: the release line ranks below the next step (3.4.0 display order, 13.6) and never pushes out decisions or the next step
t_eq "REL-brief: line below the next step; decisions and next kept; saturated brief identical with and without it" "$(python3 - "$HOOKS" "$TD/../docs/demo-state.json" <<'PYEOF'
import copy, json, sys
sys.path.insert(0, sys.argv[1])
import pm_render as R
S = json.load(open(sys.argv[2]))
S["repos"][0]["release"] = {"line": "tagged v3.2.3 at HEAD \u00b7 in sync with origin/main (local tracking state)"}
L = R.brief(S).splitlines()
gi = next((i for i, x in enumerate(L) if x.startswith("git: tagged v3.2.3 at HEAD")), -1)
ni = next((i for i, x in enumerate(L) if x.startswith("next:")), 99)
ok1 = 0 < gi and ni < gi and any(x.startswith("D-001 needs you") for x in L)
T = copy.deepcopy(S)
T["decisions"] = [dict(T["decisions"][0], id="D-%03d" % i, q="q" * 140, status="open") for i in range(8)]
A = R.brief(T)
del T["repos"][0]["release"]
B = R.brief(T)
print(ok1, A == B, len(A.encode()) <= 1000)
PYEOF
)" "True True True"

t_has "REL-page: template shows the release line via textContent" "$(grep -o "rlEl.textContent='git: '+relRepo.release.line" "$HOOKS/project-map-template.html")" "rlEl.textContent"
t_not "REL-page: the release line never goes through innerHTML" "$(grep -o "rlEl.innerHTML\|release.line)*innerHTML" "$HOOKS/project-map-template.html")" "innerHTML"
t_has "REL-page: the rendered page carries the release line in its state" "$(cat "$PM/current/index.html")" "ahead of origin"


# ======================================================================================================
# 3.3.0 Codex review round 1 (C330-1 .. C330-7)
# ======================================================================================================
cat > "$T/rr_lib.py" <<'PYEOF'
import importlib.util, json, os, subprocess, sys
H = os.environ["PM_SCRIPTS"]
sys.path.insert(0, H); sys.dont_write_bytecode = True
import pm_common as C, pm_collect as K, pm_git as G
def load_embed():
    sp = importlib.util.spec_from_file_location("pm_embed_mod", os.path.join(H, "project-map-embed.py"))
    m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); return m
def git(repo, *a, inp=None):
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    r = subprocess.run(["git", "-C", repo] + list(a), input=inp, capture_output=True, env=env)
    return r.stdout.decode("utf-8", "replace").strip()
class Hook:
    """Wrap K.grun: after the Nth call whose argv contains MATCH, run ACT(); once, or on every match when EVERY."""
    def __init__(self, match, act, every=False):
        self.match, self.act, self.every, self.done = match, act, every, False
        self.orig = K.grun
        K.grun = self
    def __call__(self, repo, sub, *args, timeout=20.0):
        rc, out = self.orig(repo, sub, *args, timeout=timeout)
        if self.match(sub, args) and (self.every or not self.done):
            self.done = True; self.act()
        return rc, out
    def off(self): K.grun = self.orig
PYEOF
RR() { python3 -c "exec(open('$T/rr_lib.py').read())
$1"; }

# ---- C330-1: a failed / timed-out / unavailable release recheck is never "no change"
mkproj cr1 || true
begin_snap="$PM/snap-cr1.json"
bump; begin; cp "$STAGE/snapshot.json" "$begin_snap"
RRLS='
import json
E = load_embed()
snap = json.load(open("%s"))
root = "%s"
def run(patch=None):
    old = (K.collect_release, G.stream_lines)
    try:
        if patch: patch()
        try:
            r = E.light_stale(root, snap, "2026-01-01T00:00:00+00:00", C.Clock(None))
            return "none" if r is None else r["why"]
        except C.Deadline:
            return "deadline"
    finally:
        K.collect_release, G.stream_lines = old
' 
RRLS=$(printf "$RRLS" "$begin_snap" "$R")
t_eq "C330-1 control: nothing moved -> no stale record" "$(RR "$RRLS
print(run())")" "none"
t_has "C330-1 injected collector failure -> stale, unverified" "$(RR "$RRLS
def p():
    def bad(*a, **k): raise K.GitCollectError('boom')
    K.collect_release = bad
print(run(p))")" "could not be re-verified (unverified)"
t_has "C330-1 tag-list failure (rc 128) -> stale, unverified" "$(RR "$RRLS
def p():
    G.stream_lines = lambda *a, **k: (128, False)
print(run(p))")" "(unverified)"
t_has "C330-1 tag-list timeout (rc 124) -> stale, unverified" "$(RR "$RRLS
def p():
    G.stream_lines = lambda *a, **k: (124, False)
print(run(p))")" "(unverified)"
t_has "C330-1 release-supported -> unavailable (collector returns None) -> stale, unverified" "$(RR "$RRLS
def p():
    K.collect_release = lambda *a, **k: None
print(run(p))")" "unavailable on re-check (unverified)"
t_eq "C330-1 deadline exhaustion propagates as Deadline" "$(RR "$RRLS
def p():
    def bad(*a, **k): raise K.BudgetOut('budget')
    K.collect_release = bad
print(run(p))")" "deadline"
# end to end: a failing recheck publishes flagged stale and the next run re-judges
jud "$INVN" update ""
eo=$(python3 - "$HOOKS" "$R" "$INVN" <<'PYEOF'
import importlib.util, os, sys
H, R, INVN = sys.argv[1:4]
sys.path.insert(0, H); sys.dont_write_bytecode = True
import pm_collect as K
sp = importlib.util.spec_from_file_location("e", os.path.join(H, "project-map-embed.py")); E = importlib.util.module_from_spec(sp); sp.loader.exec_module(E)
def flaky(*a, **k): raise K.GitCollectError("injected")
K.collect_release = flaky
sys.exit(E.main(["x", R, INVN]))
PYEOF
)
t_pre "C330-1 e2e: publish still succeeds when the recheck fails" "$eo" "PM_EMBED_OK"
t_has "C330-1 e2e: ... flagged PM_EMBED_STALE unverified" "$eo" "PM_EMBED_STALE tags and branch sync could not be re-verified (unverified)"
t_eq "C330-1 e2e: the stale record carries the unverified reason" "$(S 'd["stale"]["why"]')" "tags and branch sync could not be re-verified (unverified)"
out=$(facts); t_pre "C330-1 e2e: the next run re-verifies, never reports NO_CHANGE" "$out" "NEEDS_"
mkproj cr1d || true; bump; begin; jud "$INVN" update ""
eo=$(PM_FACTS_DELAY=3 bash "$HOOKS/project-map-embed.sh" "$R" "$INVN" --deadline 1); erc=$?
t_eq "C330-1 e2e: a recheck that outlives --deadline fails on the deadline path, nothing replaced" "$erc:$eo" "1:PM_EMBED_ERROR deadline"

# ---- C330-2: the COMPLETE set of head tags is keyed; only the display is capped
mkrepo cr2; HEADC=$(git -C "$R" rev-parse HEAD); git -C "$R" commit -q --allow-empty -m second; H2=$(git -C "$R" rev-parse HEAD)
python3 -c "
import sys
print(''.join('create refs/tags/t%03d %s\n' % (i, '$H2') for i in range(501)), end='')" | git -C "$R" update-ref --stdin
K2='
r = K.collect_release("%s", 20.0)
print(r["head_tags_total"], len(r["head_tags"]), r["key"]["tags"], r["key"]["n"], r.get("head_tags_partial", False), r["key"].get("partial", False))'
K2=$(printf "$K2" "$R")
A=$(RR "$K2")
t_eq "C330-2 501 tags at HEAD: all counted, display capped at 20" "$(echo "$A" | awk '{print $1,$2,$4}')" "501 20 501"
git -C "$R" update-ref -d refs/tags/t500; B=$(RR "$K2")
t_eq "C330-2 removing a tag beyond the old 500-row prefix: total drops to 500" "$(echo "$B" | awk '{print $1,$4}')" "500 500"
t_true "C330-2 ... and the key hash changes" "[ \"\$(echo $A | awk '{print \$3}')\" != \"\$(echo $B | awk '{print \$3}')\" ]"
git -C "$R" update-ref refs/tags/t499 "$HEADC"; C3=$(RR "$K2")
t_eq "C330-2 retargeting a tag beyond the old prefix: total 499" "$(echo "$C3" | awk '{print $1,$4}')" "499 499"
t_true "C330-2 ... and the key hash changes again" "[ \"\$(echo $B | awk '{print \$3}')\" != \"\$(echo $C3 | awk '{print \$3}')\" ]"
D3=$(PM_MAX_TAG_ROWS=100 RR "$K2")
t_eq "C330-2 truncated listing: partial coverage reported, counts are a lower bound" "$(echo "$D3" | awk '{print $2,$5,$6}')" "20 True True"
CK='
def mk(rel_j, rel_n):
    base = dict(heads={}, branches={}, status_hash="x", ledger_hash=None, answers_count=0, expired_ids=[], schema=C.SCHEMA_STATE, watch_hashes={})
    snap = {"commits": {"count": 0}, "answers": {"pending": []}, "key": {"expired_ids": []}}
    return dict(base, release=rel_j), dict(base, release=rel_n), snap
def ent(**kw):
    e = {"tags": "abc", "n": 100, "upstream": None, "state": "no_upstream", "ahead": None, "partial": True}
    e.update(kw); return e
def cmpk(j, n):
    a, b, snap = mk({".": j}, {".": n})
    r = K.compare_keys(a, b, snap)
    return "%s|%s|%s" % ("release" in r["moved"], r["incomplete"], r["why"])
'
t_eq "C330-2/R2-2 an UNCHANGED partial tag set is incomplete coverage, not a move (no paid re-judgement)" "$(RR "$CK
print(cmpk(ent(), ent()))")" "False|['.']|"
t_eq "C330-2/R2-2 a complete -> partial transition moves the key and says why" "$(RR "$CK
print(cmpk(ent(partial=False), ent()))")" "True|['.']|tag list too large to verify"
t_eq "C330-2/R2-2 a partial set whose retained prefix changed still moves" "$(RR "$CK
print(cmpk(ent(), ent(tags='zzz')))")" "True|['.']|tag list too large to verify and tags changed"
t_eq "C330-2/R2-2 a partial set whose count changed still moves" "$(RR "$CK
print(cmpk(ent(), ent(n=101)))")" "True|['.']|tag list too large to verify"
t_eq "C330-2/R2-2 partial -> complete moves once (coverage changed)" "$(RR "$CK
print(cmpk(ent(), ent(partial=False)))")" "True|[]|tag count or coverage changed"
t_eq "C330-2/R2-2 a partial entry with moved branch sync still moves" "$(RR "$CK
print(cmpk(ent(), ent(state='ahead', ahead=1)))")" "True|['.']|tag list too large to verify and branch sync changed"

# ---- C330-3: sub-folder ROOT, parent-only commits are not activity
mkrepo cr3; PARENT="$R"; mkdir -p "$PARENT/pkg"; cp -R "$PARENT/PLAN.md" "$PARENT/REVIEW-LOG.md" "$PARENT/README.md" "$PARENT/docs" "$PARENT/thoughts" "$PARENT/pkg/"
git -C "$PARENT" add -A; git -C "$PARENT" commit -qm "pkg files"; echo y > "$PARENT/other.txt"; git -C "$PARENT" add -A; git -C "$PARENT" commit -qm "parent only"
R="$PARENT/pkg"; PM="$R/.project-map"; begin; pub "" full
t_pre "C330-3 sub-folder first map publishes" "$eo" "PM_EMBED_OK"
t_not "C330-3 parent-only commits before facts: publication not flagged stale" "$eo" "PM_EMBED_STALE"
t_eq "C330-3 ... state.stale is null (commits_since not inflated)" "$(S 'd["stale"]')" None
echo z >> "$R/PLAN.md"; git -C "$PARENT" add pkg/PLAN.md; git -C "$PARENT" commit -qm "pkg change"; begin
echo q > "$PARENT/other2.txt"; git -C "$PARENT" add other2.txt; git -C "$PARENT" commit -qm "parent only during judgement"
pub "" update
t_not "C330-3 a parent-only commit DURING judgement is not stale either" "$eo" "PM_EMBED_STALE"
echo z >> "$R/PLAN.md"; git -C "$PARENT" add pkg/PLAN.md; git -C "$PARENT" commit -qm "pkg during"; begin; echo zz >> "$R/PLAN.md"; git -C "$PARENT" add pkg/PLAN.md; git -C "$PARENT" commit -qm "pkg during judgement"
pub "" update
t_has "C330-3 a commit under the sub-folder during judgement IS stale (1 new commits)" "$eo" "PM_EMBED_STALE 1 new commits"
bump; git -C "$PARENT" add pkg/PLAN.md; git -C "$PARENT" commit -qm "settle" ; begin; pub "" update; git -C "$PARENT" tag shared-during; begin2=$(facts); t_pre "C330-3 the shared release key still moves separately (tag in the parent)" "$begin2" "NEEDS_JUDGEMENT"

# ---- C330-4: the upstream identity is pinned; a race is unknown or coherent, never mixed
mkrepo cr4; R4="$R"; git -C "$R4" commit -q --allow-empty -m c2; C2=$(git -C "$R4" rev-parse HEAD); C1=$(git -C "$R4" rev-parse HEAD~1)
git -C "$R4" branch other; git -C "$R4" branch base "$C2"; git -C "$R4" update-ref refs/remotes/origin/main "$C1"
git -C "$R4" config remote.origin.url "$T/none.git"; git -C "$R4" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$R4" config branch.main.remote origin; git -C "$R4" config branch.main.merge refs/heads/main
git -C "$R4" config branch.other.remote .; git -C "$R4" config branch.other.merge refs/heads/base
SW='
import json
R = "%s"
def switch_other(): git(R, "symbolic-ref", "HEAD", "refs/heads/other")
def toggle():
    cur = git(R, "symbolic-ref", "HEAD")
    git(R, "symbolic-ref", "HEAD", "refs/heads/other" if cur.endswith("main") else "refs/heads/main")
def isup(sub, a): return sub == "for-each-ref" and a and a[0] == G.UP_FMT
def show(r):
    sy = r["sync"]
    return "%%s|%%s|%%s|%%s|%%s" %% (sy["branch_ref"], sy["upstream_ref"], sy["state"], sy["ahead"], r.get("inconsistent", False))
'
SW=$(printf "$SW" "$R4")
git -C "$R4" symbolic-ref HEAD refs/heads/main
t_eq "C330-4 baseline: main ahead 1 of origin/main" "$(RR "$SW
print(show(K.collect_release(R, 20.0)))")" "refs/heads/main|refs/remotes/origin/main|ahead|1|False"
git -C "$R4" symbolic-ref HEAD refs/heads/main
RACE1=$(RR "$SW
h = Hook(isup, switch_other)
print(show(K.collect_release(R, 20.0)))")
t_true "C330-4 same-OID branch switch between metadata and resolution is coherent (never main + other's upstream counts)" "[ \"$RACE1\" = 'refs/heads/other|refs/heads/base|aligned|0|False' ] || [ \"$RACE1\" = 'refs/heads/main|refs/remotes/origin/main|ahead|1|False' ]"
git -C "$R4" symbolic-ref HEAD refs/heads/main
t_eq "C330-4 the switch is a real race: after it, the collector reports the NEW branch coherently" "$RACE1" "refs/heads/other|refs/heads/base|aligned|0|False"
git -C "$R4" symbolic-ref HEAD refs/heads/main
t_eq "C330-4 a branch that keeps flipping -> unknown, null counts, inconsistent" "$(RR "$SW
h = Hook(isup, toggle, every=True)
print(show(K.collect_release(R, 20.0)))")" "None|None|unknown|None|True"
git -C "$R4" symbolic-ref HEAD refs/heads/main; git -C "$R4" config branch.main.merge refs/heads/main
t_eq "C330-4 upstream config moved once -> re-read coherently" "$(RR "$SW
def moved():
    git(R, 'config', 'branch.main.remote', '.'); git(R, 'config', 'branch.main.merge', 'refs/heads/base')
h = Hook(isup, moved)
print(show(K.collect_release(R, 20.0)))")" "refs/heads/main|refs/heads/base|aligned|0|False"
git -C "$R4" config branch.main.remote origin; git -C "$R4" config branch.main.merge refs/heads/main; git -C "$R4" update-ref refs/remotes/origin/main "$C1"
t_eq "C330-4 upstream ref moved once after resolution -> re-read coherently" "$(RR "$SW
def moved(): git(R, 'update-ref', 'refs/remotes/origin/main', '$C2')
h = Hook(lambda sub, a: sub == 'rev-parse' and a and a[-1].startswith('refs/remotes/'), moved)
print(show(K.collect_release(R, 20.0)))")" "refs/heads/main|refs/remotes/origin/main|aligned|0|False"
git -C "$R4" update-ref refs/remotes/origin/main "$C1"; git -C "$R4" config branch.main.merge refs/heads/main
t_eq "C330-4 upstream ref that keeps moving -> unknown, null counts" "$(RR "$SW
n = {'i': 0}
def mv():
    n['i'] += 1
    git(R, 'update-ref', 'refs/remotes/origin/main', '$C2' if n['i'] % 2 else '$C1')
h = Hook(lambda sub, a: sub == 'rev-parse' and a and a[-1].startswith('refs/remotes/'), mv, every=True)
print(show(K.collect_release(R, 20.0)))")" "None|None|unknown|None|True"

# ---- C330-6: rc 1/128 is not evidence of absence
mkrepo cr6; R6="$R"; git -C "$R6" config remote.origin.url "$T/none.git"; git -C "$R6" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"; git -C "$R6" config branch.main.remote origin; git -C "$R6" config branch.main.merge refs/heads/main
TREE=$(git -C "$R6" rev-parse 'HEAD^{tree}')
SH='
def show(r):
    sy = r["sync"]
    return "%s|%s|%s|%s" % (sy["state"], sy["ahead"], sy["behind"], r["line"])'
t_eq "C330-6 genuinely absent configured upstream -> missing_upstream" "$(RR "$SH
print(show(K.collect_release('$R6', 20.0)))")" "missing_upstream|None|None|no tag at HEAD · upstream origin/main missing locally"
git -C "$R6" update-ref refs/remotes/origin/main "$TREE" 2>/dev/null || printf '%s\n' "$TREE" > "$R6/.git/refs/remotes/origin/main" 2>/dev/null || { mkdir -p "$R6/.git/refs/remotes/origin"; printf '%s\n' "$TREE" > "$R6/.git/refs/remotes/origin/main"; }
t_eq "C330-6 upstream ref pointing at a tree (existing, malformed) -> unknown, null counts" "$(RR "$SH
print(show(K.collect_release('$R6', 20.0)))")" "unknown|None|None|no tag at HEAD · sync unknown"
rm -f "$R6/.git/refs/remotes/origin/main"; printf '1111111111111111111111111111111111111111\n' > "$R6/.git/refs/remotes/origin/main"
t_eq "C330-6 upstream ref to an absent object -> unknown, null counts" "$(RR "$SH
print(show(K.collect_release('$R6', 20.0)))")" "unknown|None|None|no tag at HEAD · sync unknown"
rm -f "$R6/.git/refs/remotes/origin/main"
t_eq "C330-6 control: genuinely unborn attached branch -> unborn" "$(R="$T/cr6u"; mkdir -p "$R"; git -C "$R" init -q -b main; RR "$SH
print(show(K.collect_release('$T/cr6u', 20.0)))")" "unborn|None|None|no commits yet"
printf '1111111111111111111111111111111111111111\n' > "$R6/.git/refs/heads/main"
t_eq "C330-6 branch ref pointing at an absent object -> unknown (not unborn), null counts" "$(RR "$SH
print(show(K.collect_release('$R6', 20.0)))")" "unknown|None|None|sync unknown"
git -C "$R6" update-ref refs/heads/main "$(git -C "$R6" rev-parse refs/heads/other 2>/dev/null || echo $C2)" 2>/dev/null; true

# ---- C330-5: hostile ref names never reach pack, brief, state or HTML raw
mkrepo cr5; R5="$R"; H5=$(git -C "$R5" rev-parse HEAD)
python3 - "$R5" "$H5" <<'PYEOF'
import subprocess, sys
repo, h = sys.argv[1:3]
names = ["v1‮", "z​q", "l s", "ghp_" + "a1B2c3D4" * 4, "café-%41", "pct-%s"]
inp = "".join("create refs/tags/%s %s\n" % (n, h) for n in names).encode("utf-8")
subprocess.run(["git", "-C", repo, "update-ref", "--stdin"], input=inp, check=True)
PYEOF
git -C "$R5" branch "up$(printf '\xe2\x80\xae')stream" 2>/dev/null; git -C "$R5" branch --set-upstream-to="up$(printf '\xe2\x80\xae')stream" main 2>/dev/null
begin; pub "" full
t_pre "C330-5 hostile ref names: first map publishes" "$eo" "PM_EMBED_OK"
t_eq "C330-5 pack.json holds no raw bidi / zero-width / line-separator / token" "$(python3 - "$STAGE/pack.json" "$PM/current/brief.txt" "$PM/current/index.html" "$PM/current/state.json" "$STAGE/snapshot.json" <<'PYEOF'
import re, sys
bad = re.compile("[‪-‮⁦-⁩​-‏  ⁠﻿]|ghp_a1B2")
print([bool(bad.search(open(p, encoding="utf-8").read())) for p in sys.argv[1:]])
PYEOF
)" "[False, False, False, False, False]"
t_has "C330-5 pack shows the escaped bidi form" "$(cat "$STAGE/pack.json")" '\\u202e'
t_has "C330-5 pack shows the escaped zero-width form" "$(cat "$STAGE/pack.json")" '\\u200b'
t_has "C330-5 pack shows the escaped line-separator form" "$(cat "$STAGE/pack.json")" '\\u2028'
t_has "C330-5 token-like tag is redacted" "$(cat "$STAGE/pack.json")" '[redacted]'
t_has "C330-5 ordinary Unicode and a literal % stay as data" "$(S 'd["repos"][0]["release"]["recent_tags"] + d["repos"][0]["release"]["head_tags"]')" 'café-%41'
t_has "C330-5 brief.txt carries the safe line" "$(cat "$PM/current/brief.txt")" "git: tagged"
t_true "C330-5 unsafe_strings finds nothing in the published release facts" "python3 -c \"import sys,json;sys.path.insert(0,'$HOOKS');import pm_common as C;d=json.load(open('$PM/current/state.json'));sys.exit(1 if C.unsafe_strings(d['repos'],'repos') else 0)\""
t_true "C330-5 unsafe_strings finds nothing in the pack" "python3 -c \"import sys,json;sys.path.insert(0,'$HOOKS');import pm_common as C;d=json.load(open('$STAGE/pack.json'));sys.exit(1 if C.unsafe_strings(d,'pack') else 0)\""
t_has "C330-5 the upstream branch name is escaped too" "$(S 'd["repos"][0]["release"]["sync"]["upstream_ref"]')" '\u202e'
t_true "C330-5 two different hostile names never collapse in the key (hash suffix)" "[ \"\$(python3 -c \"import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;print(C.ref_ident('a‮b')!=C.ref_ident('a b') and C.ref_ident('ok-name')=='ok-name')\")\" = True ]"

# ---- C330-7: a map signed by the PRE-3.3.0 per-DATA key is recovered, authenticated
OLDH="$HOME"; export HOME="$T/home7"; mkdir -p "$HOME"
mkproj cr7 || true; PM7="$PM"; G7=$(readlink "$PM7/current")
LEG="$T/legacydata"; mkdir -p "$LEG/published"
cat > "$T/old_sign.py" <<'PYEOF'
# the PRE-3.3.0 key_path / get_key / sign_manifest / write_publish_record, reconstructed: the key lives in $CLAUDE_PLUGIN_DATA
import hashlib, hmac, json, os, sys
H, gdir, data, root = sys.argv[1:5]
sys.path.insert(0, H); import pm_common as C
os.environ["CLAUDE_PLUGIN_DATA"] = data
def old_key_path(): return os.path.join(os.environ["CLAUDE_PLUGIN_DATA"], "key")
kp = old_key_path()
if not os.path.exists(kp):
    fd = os.open(kp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, os.urandom(32)); os.close(fd)
k = open(kp, "rb").read()
m = json.load(open(os.path.join(gdir, "manifest.json")))
m["hmac"] = hmac.new(k, C.canon({"files": m["files"], "generation": m["generation"], "base": m["base"]}).encode(), hashlib.sha256).hexdigest()
open(os.path.join(gdir, "manifest.json"), "w").write(C.dumps(m, indent=1))
rec = os.path.join(data, "published", C.sha256_bytes(os.path.realpath(root).encode()))
open(rec, "w").write(C.dumps({"root": os.path.realpath(root), "generation": m["generation"], "manifest_sha256": C.sha256_file(os.path.join(gdir, "manifest.json")), "at": "x"}))
PYEOF
python3 "$T/old_sign.py" "$HOOKS" "$PM7/$G7" "$LEG" "$R"
VG="import sys,os; sys.path.insert(0,'$HOOKS'); import pm_common as C; sys.exit(0 if C.verify_generation('$PM7/$G7') else 1)"
CANON_BEFORE=$(cat "$HOME/.claude/agent-memory/project-map/key" | od -An -tx1 | tr -d ' \n')
t_true "C330-7 fixture: genuinely old-signed generation does NOT verify with the canonical key alone (skill env, no DATA)" "! python3 -c \"$VG\""
t_true "C330-7 fixture: the OLD scheme verified it with DATA/key" "python3 - '$HOOKS' '$PM7/$G7' '$LEG' <<'PYEOF'
import hashlib, hmac, json, sys
sys.path.insert(0, sys.argv[1]); import pm_common as C
m = json.load(open(sys.argv[2] + '/manifest.json')); k = open(sys.argv[3] + '/key', 'rb').read()
sys.exit(0 if hmac.compare_digest(m['hmac'], hmac.new(k, C.canon({'files': m['files'], 'generation': m['generation'], 'base': m['base']}).encode(), hashlib.sha256).hexdigest()) else 1)
PYEOF"
t_true "C330-7 hook environment (DATA set) recovers the legacy-signed generation" "CLAUDE_PLUGIN_DATA='$LEG' python3 -c \"$VG\""
t_true "C330-7 afterwards the skill environment (no DATA) verifies it with the canonical key" "python3 -c \"$VG\""
t_eq "C330-7 the existing canonical key was never overwritten" "$(cat "$HOME/.claude/agent-memory/project-map/key" | od -An -tx1 | tr -d ' \n')" "$CANON_BEFORE"
out=$(CLAUDE_PLUGIN_DATA="$LEG" facts); t_pre "C330-7 facts in the hook environment: the map is trusted (NO_CHANGE)" "$out" "NO_CHANGE"
out=$(facts); t_pre "C330-7 facts in the skill environment: the same map (NO_CHANGE)" "$out" "NO_CHANGE"
# negatives: never adopt an unsigned map / a map signed by an unrelated key; legacy key must exist
mkproj cr7b >/dev/null || true; G7B=$(readlink "$PM/current"); PM7B="$PM"
python3 - "$PM7B/$G7B/manifest.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1])); m["hmac"] = "0" * 64; json.dump(m, open(sys.argv[1], "w"))
PYEOF
VGB="import sys,os; sys.path.insert(0,'$HOOKS'); import pm_common as C; sys.exit(0 if C.verify_generation('$PM7B/$G7B') else 1)"
t_true "C330-7 a map signed by neither key is NOT recovered (DATA/key present)" "! CLAUDE_PLUGIN_DATA='$LEG' python3 -c \"$VGB\""
python3 - "$PM7B/$G7B/manifest.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1])); m.pop("hmac"); json.dump(m, open(sys.argv[1], "w"))
PYEOF
t_true "C330-7 an unsigned map is NOT adopted" "! CLAUDE_PLUGIN_DATA='$LEG' python3 -c \"$VGB\""
mkproj cr7c >/dev/null || true; G7C=$(readlink "$PM/current"); python3 "$T/old_sign.py" "$HOOKS" "$PM/$G7C" "$LEG" "$R"
python3 -c "
import json,sys
p='$PM/$G7C/state.json'; open(p,'a').write(' ')"
VGC="import sys,os; sys.path.insert(0,'$HOOKS'); import pm_common as C; sys.exit(0 if C.verify_generation('$PM/$G7C') else 1)"
t_true "C330-7 a legacy-signed map whose files were tampered is NOT recovered" "! CLAUDE_PLUGIN_DATA='$LEG' python3 -c \"$VGC\""
mkproj cr7d >/dev/null || true; G7D=$(readlink "$PM/current"); python3 "$T/old_sign.py" "$HOOKS" "$PM/$G7D" "$LEG" "$R"
VGD="import sys,os; sys.path.insert(0,'$HOOKS'); import pm_common as C; sys.exit(0 if C.verify_generation('$PM/$G7D') else 1)"
t_true "C330-7 DATA set but its key file absent: no recovery" "! CLAUDE_PLUGIN_DATA='$T/emptydata' python3 -c \"$VGD\""
export HOME="$OLDH"

# ======================================================================================================
# 3.3.0 Codex review round 2 (C330-R2-1 .. C330-R2-5)
# ======================================================================================================
LSP='
import json
E = load_embed()
snap = json.load(open("%s"))
root = "%s"
def run():
    try:
        r = E.light_stale(root, snap, "2026-01-01T00:00:00+00:00", C.Clock(None))
        return "none" if r is None else r["why"]
    except C.Deadline:
        return "deadline"
'
# ---- C330-R2-1: any partial recheck is unverified on its own, a complete -> partial transition included
mkrepo r21; git -C "$R" tag t1; git -C "$R" tag t2
PM_MAX_TAG_ROWS=2 begin; cp "$STAGE/snapshot.json" "$T/snap-r21.json"
LS21=$(printf "$LSP" "$T/snap-r21.json" "$R")
t_eq "C330-R2-1 setup: two tags at HEAD, limit 2 -> the judged key is complete" "$(python3 -c "import json;print(json.load(open('$T/snap-r21.json'))['key']['release']['.'].get('partial', False))")" "False"
t_eq "C330-R2-1 control: nothing moved -> no stale record" "$(PM_MAX_TAG_ROWS=2 RR "$LS21
print(run())")" "none"
git -C "$R" tag t3
R21W=$(PM_MAX_TAG_ROWS=2 RR "$LS21
print(run())")
t_has "C330-R2-1 a third, later-sorting tag added during judgement: flagged unverified" "$R21W" "tag list too large to verify (unverified)"
t_has "C330-R2-1 ... and the coverage transition is named" "$R21W" "tag count or coverage changed (unverified)"
# the same at the production limit: 20000 complete, tag 20001 lands during judgement (limit lowered for speed; same code path)
git -C "$R" tag -d t3 >/dev/null
t_eq "C330-R2-1 stable partial key (partial before and after) is still unverified, never silent" "$(PM_MAX_TAG_ROWS=1 RR "$LS21
snap['key']['release']['.'] = K.collect_release(root, 20.0)['key']
print(run())")" "tag list too large to verify (unverified)"

# ---- C330-R2-2: an unchanged partial key never re-triggers a paid judgement
mkrepo r22; git -C "$R" tag t1; git -C "$R" tag t2; git -C "$R" tag t3
export PM_MAX_TAG_ROWS=2
begin; pub "" full
t_pre "C330-R2-2 overflow repo: first map publishes" "$eo" "PM_EMBED_OK"
t_has "C330-R2-2 the release line carries the incomplete-tag-list warning" "$(S 'd["repos"][0]["release"]["line"]')" "tag list incomplete"
o1=$(facts); t_pre "C330-R2-2 facts after the first map: refresh, not a judgement" "$o1" "NEEDS_REFRESH"
o2=$(facts); t_pre "C330-R2-2 ... then NO_CHANGE" "$o2" "NO_CHANGE"
t_has "C330-R2-2 NO_CHANGE never claims plain completeness" "$o2" "tag list incomplete"
t_has "C330-R2-2 the brief keeps the warning visible" "$(cat "$PM/brief.txt")" "tag list incomplete"
bump; begin; t_pre "C330-R2-2 a real change (working tree) still judges" "$out" "NEEDS_JUDGEMENT"
pub "" update; t_pre "C330-R2-2 UPDATE publishes" "$eo" "PM_EMBED_OK"
nj=0; seq_out=""; ND22=$(ndirs)
for i in 1 2 3 4; do o=$(facts); seq_out="$seq_out|${o%% *}"; case "$o" in NEEDS_JUDGEMENT*) nj=$((nj+1));; esac; done
t_eq "C330-R2-2 facts after the UPDATE four times: no judgement loop" "$nj" 0
t_eq "C330-R2-2 ... refresh once, then NO_CHANGE for good" "$seq_out" "|NEEDS_REFRESH|NO_CHANGE|NO_CHANGE|NO_CHANGE"
t_eq "C330-R2-2 the unchanged partial runs created no new staging directory" "$(ndirs)" "$ND22"
git -C "$R" tag t0; o=$(facts); t_pre "C330-R2-2 a tag that sorts INTO the retained prefix is a real move" "$o" "NEEDS_JUDGEMENT"
unset PM_MAX_TAG_ROWS

# ---- C330-R2-3: a failed final metadata read is unknown, never absence
mkrepo r23; R23="$R"; git -C "$R23" commit -q --allow-empty -m c2; C23=$(git -C "$R23" rev-parse HEAD)
git -C "$R23" branch other; git -C "$R23" config remote.origin.url "$T/none.git"; git -C "$R23" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
FR='
R = "%s"
def show(r):
    sy = r["sync"]
    return "%%s|%%s|%%s|%%s" %% (sy["state"], sy["upstream_ref"], sy["branch_ref"], r.get("inconsistent", False))
orig = K.grun
def failing(match, nth, act=None, every_even=False):
    st = {"n": 0}
    def wrap(repo, sub, *a, timeout=20.0):
        if match(sub, a):
            st["n"] += 1
            if (every_even and st["n"] %% 2 == 0) or (not every_even and st["n"] == nth):
                if act: act()
                return 124, ""
        return orig(repo, sub, *a, timeout=timeout)
    K.grun = wrap
isup = lambda sub, a: sub == "for-each-ref" and bool(a) and a[0] == G.UP_FMT
issym = lambda sub, a: sub == "symbolic-ref"
isuoid = lambda sub, a: sub == "rev-parse" and bool(a) and a[-1].startswith("refs/remotes/") and a[-1].endswith("^{commit}")
'
FR=$(printf "$FR" "$R23")
git -C "$R23" symbolic-ref HEAD refs/heads/main
t_eq "C330-R2-3 control: no upstream, nothing fails -> no_upstream" "$(RR "$FR
print(show(K.collect_release(R, 20.0)))")" "no_upstream|None|refs/heads/main|False"
t_eq "C330-R2-3 final upstream read times out after a valid no_upstream while an upstream appears -> re-read coherently (never no_upstream)" "$(RR "$FR
def act():
    git(R, 'config', 'branch.main.remote', '.'); git(R, 'config', 'branch.main.merge', 'refs/heads/other')
failing(isup, 2, act)
print(show(K.collect_release(R, 20.0)))")" "aligned|refs/heads/other|refs/heads/main|False"
git -C "$R23" config --unset branch.main.remote; git -C "$R23" config --unset branch.main.merge
t_eq "C330-R2-3 final upstream read keeps timing out after a valid no_upstream -> unknown, inconsistent" "$(RR "$FR
failing(isup, 0, every_even=True)
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|True"
t_eq "C330-R2-3 a transient final-read timeout with nothing changed -> bounded retry, still no_upstream" "$(RR "$FR
failing(isup, 2)
print(show(K.collect_release(R, 20.0)))")" "no_upstream|None|refs/heads/main|False"
git -C "$R23" checkout -q --detach
t_eq "C330-R2-3 control: detached HEAD" "$(RR "$FR
print(show(K.collect_release(R, 20.0)))")" "detached|None|None|False"
t_eq "C330-R2-3 final symbolic-ref read errors after a valid detached state while HEAD is attached -> re-read coherently" "$(RR "$FR
def act(): git(R, 'symbolic-ref', 'HEAD', 'refs/heads/main')
failing(issym, 2, act)
print(show(K.collect_release(R, 20.0)))")" "no_upstream|None|refs/heads/main|False"
git -C "$R23" checkout -q --detach
t_eq "C330-R2-3 final symbolic-ref read keeps failing after detached -> unknown, inconsistent" "$(RR "$FR
failing(issym, 0, every_even=True)
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|True"
git -C "$R23" symbolic-ref HEAD refs/heads/main
git -C "$R23" config branch.main.remote origin; git -C "$R23" config branch.main.merge refs/heads/main
t_eq "C330-R2-3 control: configured upstream absent locally -> missing_upstream" "$(RR "$FR
print(show(K.collect_release(R, 20.0)))")" "missing_upstream|refs/remotes/origin/main|refs/heads/main|False"
t_eq "C330-R2-3 final upstream-oid read times out after an unresolved oid while the ref appears -> re-read coherently" "$(RR "$FR
def act(): git(R, 'update-ref', 'refs/remotes/origin/main', '$C23')
failing(isuoid, 2, act)
print(show(K.collect_release(R, 20.0)))")" "aligned|refs/remotes/origin/main|refs/heads/main|False"
git -C "$R23" update-ref -d refs/remotes/origin/main
t_eq "C330-R2-3 final upstream-oid read keeps failing -> unknown, inconsistent" "$(RR "$FR
failing(isuoid, 0, every_even=True)
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|True"

# ---- C330-R2-4: an empty package gaining its first scoped commit during judgement is stale
mkrepo r24; PAR="$R"; git -C "$PAR" commit -q --allow-empty -m "parent second"
git -C "$PAR" update-ref refs/remotes/origin/main "$(git -C "$PAR" rev-parse HEAD~1)"
git -C "$PAR" config remote.origin.url "$T/none.git"; git -C "$PAR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$PAR" config branch.main.remote origin; git -C "$PAR" config branch.main.merge refs/heads/main
mkdir -p "$PAR/pkg"; echo r > "$PAR/pkg/README.md"; echo p > "$PAR/pkg/PLAN.md"
R="$PAR/pkg"; PM="$R/.project-map"; begin; cp "$STAGE/snapshot.json" "$T/snap-r24.json"
t_eq "C330-R2-4 setup: empty package is a scoped git row with a null head" "$(python3 -c "import json;r=json.load(open('$T/snap-r24.json'))['repos'][0];print(r['vcs'],bool(r.get('scope')),r['head'],r['release']['sync']['state'])")" "git True None ahead"
LS24=$(printf "$LSP" "$T/snap-r24.json" "$R")
t_eq "C330-R2-4 control: nothing moved" "$(RR "$LS24
print(run())")" "none"
git -C "$PAR" commit -q --allow-empty -m "parent only during judgement"
t_eq "C330-R2-4 a parent-only commit during judgement stays quiet (ahead is already true)" "$(RR "$LS24
print(run())")" "none"
git -C "$PAR" add pkg; git -C "$PAR" commit -q -m "first package commit"
t_eq "C330-R2-4 the first scoped commit during judgement is stale (1 new commit)" "$(RR "$LS24
print(run())")" "1 new commits"
echo more >> "$PAR/pkg/PLAN.md"; git -C "$PAR" add pkg; git -C "$PAR" commit -q -m "second package commit"
t_eq "C330-R2-4 two scoped commits are counted" "$(RR "$LS24
print(run())")" "2 new commits"

# ---- C330-R2-5: authenticated legacy re-signing migrates the canonical publish record
OLDH="$HOME"; export HOME="$T/home25"; mkdir -p "$HOME"
mkproj cr25 || true; PM25="$PM"; R25="$R"; G25=$(readlink "$PM25/current"); GS25=${G25#gen-}
LEG25="$T/legacydata25"; mkdir -p "$LEG25/published"
python3 "$T/old_sign.py" "$HOOKS" "$PM25/$G25" "$LEG25" "$R25"
REC25="$(python3 -c "import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;print(C.record_path('$R25'))")"
rm -f "$REC25"   # the pre-3.3.0 code never wrote a canonical record: its record lives next to the per-DATA key
t_true "C330-R2-5 fixture: no canonical record; the legacy DATA record names the legacy-signed manifest" "[ ! -e $REC25 ] && grep -q $(shasum -a 256 "$PM25/$G25/manifest.json" | cut -d' ' -f1) $LEG25/published/*"
LEGH25=$(shasum -a 256 "$PM25/$G25/manifest.json" | cut -d' ' -f1)
t_true "C330-R2-5 hook environment recovers the generation" "CLAUDE_PLUGIN_DATA='$LEG25' python3 -c \"import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;sys.exit(0 if C.verify_generation('$PM25/$G25') else 1)\""
t_true "C330-R2-5 ... re-signing changed the manifest bytes (the legacy record cannot match any more)" "[ \"\$(shasum -a 256 $PM25/$G25/manifest.json | cut -d' ' -f1)\" != \"$LEGH25\" ]"
t_true "C330-R2-5 ... and the canonical record now names the FINAL manifest hash" "grep -q $(shasum -a 256 "$PM25/$G25/manifest.json" | cut -d' ' -f1) $REC25"
cp "$HOME/.claude/agent-memory/project-map/key" "$T/key25.bak"; rm -f "$HOME/.claude/agent-memory/project-map/key"
t_true "C330-R2-5 canonical key lost: the recovered generation is still adoptable through the canonical record" "python3 -c \"import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;sys.exit(0 if C.adoptable('$R25','$GS25','$PM25/$G25') else 1)\""
cp "$T/key25.bak" "$HOME/.claude/agent-memory/project-map/key"
# never for an unauthenticated map
mkproj cr25b >/dev/null || true; G25B=$(readlink "$PM/current"); GS25B=${G25B#gen-}; REC25B="$(python3 -c "import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;print(C.record_path('$R'))")"
python3 "$T/old_sign.py" "$HOOKS" "$PM/$G25B" "$LEG25" "$R"; rm -f "$REC25B"
python3 - "$PM/$G25B/manifest.json" <<'PYEOF2'
import json, sys
m = json.load(open(sys.argv[1])); m["hmac"] = "0" * 64; json.dump(m, open(sys.argv[1], "w"))
PYEOF2
t_true "C330-R2-5 an unauthenticated map is not recovered ..." "! CLAUDE_PLUGIN_DATA='$LEG25' python3 -c \"import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;sys.exit(0 if C.verify_generation('$PM/$G25B') else 1)\""
t_true "C330-R2-5 ... and no publish record is fabricated for it" "[ ! -e '$REC25B' ]"
export HOME="$OLDH"

# ======================================================================================================
# 3.3.0 Codex review round 3 (C330-R3-1, C330-R3-2)
# ======================================================================================================
R3LIB='
R = os.environ["R3R"]
orig = K.grun
def before(match, act):
    """act(n) runs before the n-th call whose (sub, args) matches; the call then goes through."""
    st = {"n": 0}
    def wrap(repo, sub, *a, timeout=20.0):
        if match(sub, a):
            st["n"] += 1
            act(st["n"])
        return orig(repo, sub, *a, timeout=timeout)
    K.grun = wrap
def after(match, act):
    st = {"n": 0}
    def wrap(repo, sub, *a, timeout=20.0):
        r = orig(repo, sub, *a, timeout=timeout)
        if match(sub, a):
            st["n"] += 1
            act(st["n"])
        return r
    K.grun = wrap
def failing(match, act=None, once=None):   # every even matching call times out (only the once-th when once is given)
    st = {"n": 0}
    def wrap(repo, sub, *a, timeout=20.0):
        if match(sub, a):
            st["n"] += 1
            if (st["n"] == once) if once else (st["n"] % 2 == 0):
                if act: act()
                return 124, ""
        return orig(repo, sub, *a, timeout=timeout)
    K.grun = wrap
isuoid = lambda sub, a: sub == "rev-parse" and bool(a) and a[-1] == "refs/remotes/origin/main^{commit}"
ishead = lambda sub, a: sub == "rev-parse" and bool(a) and a[-1] == "HEAD^{commit}"
isup = lambda sub, a: sub == "for-each-ref" and bool(a) and a[0] == G.UP_FMT
def setref(name, val):
    p = os.path.join(R, ".git", name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(val + "\n")
def delref(name):
    try: os.remove(os.path.join(R, ".git", name))
    except OSError: pass
def show(r):
    sy = r["sync"]
    return "%s|%s|%s|%s|%s" % (sy["state"], sy["ahead"], sy["behind"], r.get("inconsistent", False), r["line"])
MISSING = "1" * 40
'
# ---- C330-R3-1: a failed final HEAD / upstream resolution goes through the same existence/type query as the first read
setref() { mkdir -p "$(dirname "$R3R/.git/$1")"; printf '%s\n' "$2" > "$R3R/.git/$1"; }
delref() { rm -f "$R3R/.git/$1"; }
mkrepo r31; R31="$R"; git -C "$R31" config remote.origin.url "$T/none.git"; git -C "$R31" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$R31" config branch.main.remote origin; git -C "$R31" config branch.main.merge refs/heads/main
TREE31=$(git -C "$R31" rev-parse 'HEAD^{tree}'); export R3R="$R31" TREE31
t_eq "C330-R3-1 control: genuinely absent upstream, nothing moves -> missing_upstream, consistent" "$(RR "$R3LIB
print(show(K.collect_release(R, 20.0)))")" "missing_upstream|None|None|False|no tag at HEAD · upstream origin/main missing locally"
t_eq "C330-R3-1 absent -> ref to a TREE before the final upstream read -> unknown (never missing locally), null counts" "$(RR "$R3LIB
before(isuoid, lambda n: setref('refs/remotes/origin/main', os.environ['TREE31']) if n == 2 else None)
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|False|no tag at HEAD · sync unknown"
delref refs/remotes/origin/main
t_eq "C330-R3-1 absent -> ref to a MISSING object before the final upstream read -> unknown, null counts" "$(RR "$R3LIB
before(isuoid, lambda n: setref('refs/remotes/origin/main', MISSING) if n == 2 else None)
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|False|no tag at HEAD · sync unknown"
delref refs/remotes/origin/main
t_eq "C330-R3-1 absent <-> malformed on every final read -> unknown, null counts, inconsistent" "$(RR "$R3LIB
before(isuoid, lambda n: setref('refs/remotes/origin/main', os.environ['TREE31']) if n % 2 == 0 else delref('refs/remotes/origin/main'))
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|True|no tag at HEAD · sync unknown"
delref refs/remotes/origin/main
t_eq "C330-R3-1 absent -> a real commit before the final read -> re-read coherently (aligned)" "$(RR "$R3LIB
before(isuoid, lambda n: setref('refs/remotes/origin/main', git(R, 'rev-parse', 'HEAD')) if n == 2 else None)
print(show(K.collect_release(R, 20.0)))")" "aligned|0|0|False|no tag at HEAD · in sync with origin/main (local tracking state)"
delref refs/remotes/origin/main; setref refs/remotes/origin/main "$TREE31"
t_eq "C330-R3-1 control: a STABLE malformed upstream is coherent unknown (not inconsistent)" "$(RR "$R3LIB
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|False|no tag at HEAD · sync unknown"
delref refs/remotes/origin/main; printf '1111111111111111111111111111111111111111\n' > "$R31/.git/refs/remotes/origin/main"
t_eq "C330-R3-1 control: a STABLE ref to a missing object is coherent unknown (not inconsistent)" "$(RR "$R3LIB
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|False|no tag at HEAD · sync unknown"
delref refs/remotes/origin/main
t_eq "C330-R3-1 a final existence query that times out is unverified, never absence: re-read, then coherent missing_upstream" "$(RR "$R3LIB
failing(lambda sub, a: sub == 'for-each-ref' and bool(a) and a[0] == G.REF_TYPE_FMT and a[1] == 'refs/remotes/origin/main', once=2)
print(show(K.collect_release(R, 20.0)))")" "missing_upstream|None|None|False|no tag at HEAD · upstream origin/main missing locally"
# previously unborn branch that gains a broken ref
R31U="$T/r31u"; mkdir -p "$R31U"; git -C "$R31U" init -q -b main; export R3R="$R31U"
t_eq "C330-R3-1 control: genuinely unborn attached branch -> unborn" "$(RR "$R3LIB
print(show(K.collect_release(R, 20.0)))")" "unborn|None|None|False|no commits yet"
t_eq "C330-R3-1 unborn -> branch ref to a MISSING object before the final HEAD read -> unknown (never unborn)" "$(RR "$R3LIB
before(ishead, lambda n: setref('refs/heads/main', MISSING) if n == 2 else None)
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|False|sync unknown"
rm -f "$R31U/.git/refs/heads/main"
t_eq "C330-R3-1 unborn <-> broken branch ref on every final read -> unknown, inconsistent" "$(RR "$R3LIB
before(ishead, lambda n: setref('refs/heads/main', MISSING) if n % 2 == 0 else delref('refs/heads/main'))
print(show(K.collect_release(R, 20.0)))")" "unknown|None|None|True|tags unknown · sync unknown"
rm -f "$R31U/.git/refs/heads/main"

# ---- C330-R3-2: exhausted re-reads leave tag coverage UNKNOWN; independently verified facts stay; the uncertainty is stable
mkrepo r32; R32="$R"; git -C "$R32" tag already-tagged; git -C "$R32" branch other
git -C "$R32" commit -q --allow-empty -m c2; git -C "$R32" tag second-tag; git -C "$R32" branch other2; export R3R="$R32"
git -C "$R32" branch -f other
R3TOG='
def toggle(n):
    cur = git(R, "symbolic-ref", "HEAD")
    git(R, "symbolic-ref", "HEAD", "refs/heads/other" if cur.endswith("main") else "refs/heads/main")
'
t_eq "C330-R3-2 control: tagged HEAD, nothing moves" "$(RR "$R3LIB
print(show(K.collect_release(R, 20.0)))")" "no_upstream|None|None|False|tagged second-tag at HEAD · no upstream"
RACE32=$(RR "$R3LIB
$R3TOG
after(isup, toggle)
r = K.collect_release(R, 20.0)
print(show(r), r['head_tags_total'], [t['name'] for t in r['head_tags']], r['key'].get('unverified', False))")
t_eq "C330-R3-2 persistent same-OID branch switching with a HEAD tag -> tag kept (verified), no absence claim, sync unknown, unverified key" "$RACE32" "unknown|None|None|True|tagged second-tag at HEAD · sync unknown 1 ['second-tag'] True"
git -C "$R32" symbolic-ref HEAD refs/heads/main
t_not "C330-R3-2 ... and never 'no tag at HEAD'" "$RACE32" "no tag at HEAD"
R32B="$T/r32b"; cp -R "$R32" "$R32B"; export R3R="$R32B"; git -C "$R32B" symbolic-ref HEAD refs/heads/main
C32A=$(git -C "$R32B" rev-parse HEAD~1); C32B=$(git -C "$R32B" rev-parse HEAD); export C32A C32B
t_eq "C330-R3-2 HEAD itself keeps moving (tag exists at one of the commits) -> tags UNKNOWN, not 'no tag at HEAD'" "$(RR "$R3LIB
def flip(n): git(R, 'update-ref', 'refs/heads/main', os.environ['C32A'] if n % 2 else os.environ['C32B'])
after(ishead, flip)
r = K.collect_release(R, 20.0)
print(show(r), r['head_tags'], r['head_tags_total'], r['head_oid'], r['key']['tags'], r['key'].get('unverified', False))")" "unknown|None|None|True|tags unknown · sync unknown None None None unknown True"
git -C "$R32B" update-ref refs/heads/main "$C32B"
t_eq "C330-R3-2 the final HEAD read keeps timing out (HEAD oid unverified) -> tags unknown" "$(RR "$R3LIB
failing(ishead)
r = K.collect_release(R, 20.0)
print(show(r), r['head_tags'])")" "unknown|None|None|True|tags unknown · sync unknown None"
t_eq "C330-R3-2 a single transient final-read failure still converges to the full coherent picture" "$(RR "$R3LIB
st = {'n': 0}
def one(sub, a):
    if ishead(sub, a):
        st['n'] += 1
        return st['n'] == 2
    return False
def wrap(repo, sub, *a, timeout=20.0):
    if one(sub, a): return 124, ''
    return orig(repo, sub, *a, timeout=timeout)
K.grun = wrap
print(show(K.collect_release(R, 20.0)))")" "no_upstream|None|None|False|tagged second-tag at HEAD · no upstream"
# light_stale: an inconsistent recheck is unverified even when the (unknown) key matches the judged one
git -C "$R32" symbolic-ref HEAD refs/heads/main; export R3R="$R32"
R="$R32"; PM="$R/.project-map"; begin; cp "$STAGE/snapshot.json" "$T/snap-r32.json"
export LS32="$T/snap-r32.json" LS32R="$R32"
R3LS='
E = load_embed()
snap = json.load(open(os.environ["LS32"]))
root = os.environ["LS32R"]
def run():
    try:
        r = E.light_stale(root, snap, "2026-01-01T00:00:00+00:00", C.Clock(None))
        return "none" if r is None else r["why"]
    except C.Deadline:
        return "deadline"
'
t_eq "C330-R3-2 control: consistent recheck of the judged world -> no stale record" "$(RR "$R3LIB
$R3LS
print(run())")" "none"
t_eq "C330-R3-2 inconsistent recheck whose key EQUALS the judged key -> still stale, unverified" "$(RR "$R3LIB
$R3LS
$R3TOG
after(isup, toggle)
snap['key']['release']['.'] = K.collect_release(root, 20.0)['key']
print(run())")" "tags and branch sync kept changing during the re-check (unverified)"
git -C "$R32" symbolic-ref HEAD refs/heads/main
# end to end: a stable inconsistent state does not loop paid judgements (a git shim flips HEAD on every upstream-metadata read)
mkdir -p "$T/shim"; cat > "$T/shim/git" <<'SHIMEOF'
#!/bin/bash
if [ -n "$PM_T_FLIP" ]; then
  case "$*" in *'%(upstream)'*)
    cur=$(/usr/bin/git -C "$2" symbolic-ref HEAD 2>/dev/null)
    case "$cur" in */main) n=refs/heads/other;; *) n=refs/heads/main;; esac
    /usr/bin/git -C "$2" symbolic-ref HEAD "$n" ;;
  esac
fi
exec /usr/bin/git "$@"
SHIMEOF
chmod +x "$T/shim/git"
racefacts() { PATH="$T/shim:$PATH" PM_T_FLIP=1 facts "$@"; }
raceembed() { PATH="$T/shim:$PATH" PM_T_FLIP=1 embed "$@"; }
mkrepo r33; git -C "$R" tag already-tagged; git -C "$R" branch other
begin; pub "" full; t_pre "C330-R3-2 e2e: first map (no race) publishes" "$eo" "PM_EMBED_OK"
t_has "C330-R3-2 e2e: the calm map says tagged" "$(S 'd["repos"][0]["release"]["line"]')" "tagged already-tagged at HEAD"
out=$(racefacts); INV=${out##* }; INVN="inv-$INV"; STAGE="$PM/$INVN"
t_pre "C330-R3-2 e2e: the race first shows up as a real change (judgement)" "$out" "NEEDS_JUDGEMENT"
jud "$INVN" update ""; eo=$(raceembed "$INVN")
t_pre "C330-R3-2 e2e: the UPDATE publishes" "$eo" "PM_EMBED_OK"
t_has "C330-R3-2 e2e: ... flagged stale, unverified (not certified current)" "$eo" "(unverified)"
t_has "C330-R3-2 e2e: ... the stale record says so" "$(S 'd["stale"]["why"]')" "(unverified)"
t_has "C330-R3-2 e2e: the line keeps the verified tag and says sync unknown" "$(S 'd["repos"][0]["release"]["line"]')" "tagged already-tagged at HEAD · sync unknown"
t_not "C330-R3-2 e2e: ... and makes no absence claim" "$(cat "$PM/brief.txt")$(S 'd["repos"][0]["release"]["line"]')" "no tag at HEAD"
ND33=$(ndirs); SEQ33=""; NJ33=0
for i in 1 2 3; do o=$(racefacts); SEQ33="$SEQ33|${o%% *}"; case "$o" in NEEDS_JUDGEMENT*) NJ33=$((NJ33+1));; esac; done
t_eq "C330-R3-2 e2e: three more facts runs in the same inconsistent state: no judgement" "$NJ33" 0
t_eq "C330-R3-2 e2e: ... one refresh clears the stale flag, then NO_CHANGE" "$SEQ33" "|NEEDS_REFRESH|NO_CHANGE|NO_CHANGE"
t_has "C330-R3-2 e2e: NO_CHANGE keeps the uncertainty visible" "$(racefacts)" "unverified"
t_eq "C330-R3-2 e2e: no staging directory was created by the unchanged inconsistent runs" "$(ndirs)" "$ND33"
t_has "C330-R3-2 e2e: the brief still carries the warning" "$(cat "$PM/brief.txt")" "sync unknown"
out=$(facts); t_pre "C330-R3-2 e2e: when the race ends (calm refs) the changed picture re-judges once" "$out" "NEEDS_JUDGEMENT"

# ---------------------------------------------------------------- 3.3.0: usage never fails a refresh or a verdict (incremental scan)
# The suite runs with PM_USAGE_SKIP=1; these cases switch it off and give HOME a synthetic transcript folder.
ufacts() { env -u PM_USAGE_SKIP python3 "$HOOKS/project-map-facts.py" "$R" "$@"; }
uembed() { env -u PM_USAGE_SKIP bash "$HOOKS/project-map-embed.sh" "$R" "$@"; }
usess() { # FILES MSGS -> FILES transcripts of MSGS assistant records each, cwd = $R, under the synthetic HOME
  python3 - "$R" "$1" "$2" <<'PY'
import json, os, sys
root, nf, nm = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = os.path.join(os.environ["HOME"], ".claude", "projects", "-u33")
os.makedirs(d, exist_ok=True)
for f in range(nf):
    with open(os.path.join(d, "s%d.jsonl" % f), "w") as fh:
        for i in range(nm):
            fh.write(json.dumps({"type": "assistant", "cwd": root, "timestamp": "2026-10-08T10:00:%02dZ" % (i % 60),
                                 "message": {"id": "m%d-%d" % (f, i), "model": "claude-x", "usage": {"input_tokens": 10, "output_tokens": 1}}}) + "\n")
PY
}
old_usage() { # state.usage = 1234 tokens measured two hours ago (so the next refresh wants a new scan); "aged": the map itself is that old too
  [ "$1" = aged ] && lib mut "$PM/current/state.json" 'd["identity"]["snapshot_at"]=(dt.datetime.now().astimezone()-dt.timedelta(hours=2)).isoformat(timespec="seconds")'
  lib mut "$PM/current/state.json" 'd["usage"]={"at": (dt.datetime.now().astimezone()-dt.timedelta(hours=2)).isoformat(timespec="seconds"), "approximate": False, "sources": {"claude": "ok", "codex": "unavailable"}, "totals": {"claude": 1234, "codex": None, "all": 1234, "jobs": 3}, "by_model": [], "jobs": [], "jobs_omitted": 0}'
  lib resign "$PM/current"
}
UPD="$HOME/.claude/agent-memory/project-map/usage"   # the usage scan's private cache directory (never inside the project)
usnap() { get "$PM/inv-${out##* }/snapshot.json" "$1"; }   # a field of the snapshot staged by the facts run whose line is in $out
rm -rf "$HOME/.claude/projects/-u33" "$HOME/.codex"

mkproj u33 >/dev/null; usess 4 40; old_usage aged
AT0=$(S 'd["usage"]["at"]'); C0=$(cur)
out=$(PM_USAGE_SLOW=0.5 uembed --mechanical --deadline 1.2); rc=$?
t_pre "U33-mech: a 1.2 s deadline with a slow usage scan still publishes" "$out" "PM_EMBED_OK"
t_eq "U33-mech: ... exit 0" "$rc" 0
t_true "U33-mech: ... a new generation" '[ "$(cur)" != "$C0" ]'
t_eq "U33-mech: the previous usage numbers are kept" "$(S 'd["usage"]["totals"]["all"]')" 1234
t_eq "U33-mech: ... marked stale" "$(S 'd["usage"].get("stale")')" True
t_eq "U33-mech: ... with their ORIGINAL as-of time" "$(S 'd["usage"]["at"]')" "$AT0"
t_has "U33-mech: the brief says what the numbers are from" "$(cat "$PM/brief.txt")" "usage as of ${AT0:0:10} ${AT0:11:5}"
t_has "U33-mech: the brief still carries the totals" "$(cat "$PM/brief.txt")" "tokens"
t_has "U33-mech: the page script shows 'usage as of' for stale numbers" "$(cat "$PM/index.html")" "usage as of"
t_eq "U33-mech: the stale usage is not a staleness of the judgement" "$(S 'd["stale"]')" None

# a scan that needs several refreshes: progress is kept, the numbers become exact and the marker disappears
NR=0; FIN=0
for i in 1 2 3 4 5 6 7 8; do
  NR=$((NR+1)); o=$(PM_USAGE_SLOW=0.4 uembed --mechanical --deadline 3); case "$o" in PM_EMBED_OK*) ;; *) bad "U33-resume: refresh $i" "$o";; esac
  if [ "$(S 'd["usage"].get("stale")')" = None ]; then FIN=1; break; fi
done
t_true "U33-resume: usage completes over several budgeted refreshes ($NR), each one published" '[ "$FIN" = 1 ] && [ "$NR" -gt 1 ]'
t_eq "U33-resume: the exact totals (4 x 40 x 11) replace the old numbers" "$(S 'd["usage"]["totals"]["all"]')" 1760
t_eq "U33-resume: the as-of time is new" "$(S 'd["usage"]["at"][:4]')" "$(date +%Y)"
t_not "U33-resume: the brief no longer says 'usage as of'" "$(cat "$PM/brief.txt")" "usage as of"
o=$(PM_USAGE_SLOW=0.4 uembed --mechanical --deadline 1.2)
t_eq "U33-resume: fresh numbers are not re-scanned within the hour" "$(S 'd["usage"]["totals"]["all"]'):$(S 'd["usage"].get("stale")')" "1760:None"

# the measured failure: the hook's 3.5 s deadline and a usage scan that takes much longer than that (it used to be PM_EMBED_ERROR deadline)
old_usage aged; rm -rf "$UPD"; C0=$(cur); T0=$(python3 -c 'import time;print(time.time())')
out=$(PM_USAGE_SLOW=1.0 uembed --mechanical --deadline 3.5); rc=$?; T1=$(python3 -c 'import time;print(time.time())')
t_pre "U33-mech35: --deadline 3.5 with a usage scan far over that publishes" "$out" "PM_EMBED_OK"
t_true "U33-mech35: ... a new generation, within the deadline" '[ "$(cur)" != "$C0" ] && python3 -c "import sys;sys.exit(0 if float(sys.argv[2])-float(sys.argv[1]) < 3.5 else 1)" "$T0" "$T1"'
t_eq "U33-mech35: ... with the previous numbers, stale" "$(S 'd["usage"]["totals"]["all"]'):$(S 'd["usage"].get("stale")')" "1234:True"

# a crashing / garbage usage script: no error, previous numbers kept
old_usage aged; cp "$HOOKS/project-map-usage.py" "$T/usage.py.keep"
printf 'import sys\nprint("garbage")\nsys.exit(3)\n' > "$HOOKS/project-map-usage.py"
out=$(uembed --mechanical --deadline 3.5); t_pre "U33-crash: a failing usage script does not fail the refresh" "$out" "PM_EMBED_OK"
t_eq "U33-crash: previous numbers kept, stale" "$(S 'd["usage"]["totals"]["all"]'):$(S 'd["usage"].get("stale")')" "1234:True"
bump; out=$(ufacts); t_pre "U33-crash: facts returns its verdict, not ERROR" "$out" "NEEDS_JUDGEMENT"
t_eq "U33-crash: the staged snapshot keeps the previous usage, stale" "$(usnap 'd["usage"]["totals"]["all"]'):$(usnap 'd["usage"].get("stale")')" "1234:True"
INV=${out##* }; INVN="inv-$INV"; STAGE="$PM/$INVN"; pub "" update
t_pre "U33-crash: the judged publish succeeds" "$eo" "PM_EMBED_OK"
t_eq "U33-crash: ... and keeps the numbers (not None)" "$(S 'd["usage"]["totals"]["all"]'):$(S 'd["usage"].get("stale")')" "1234:True"
cp "$T/usage.py.keep" "$HOOKS/project-map-usage.py"

# facts: a usage scan that cannot finish in its budget keeps the previous numbers and still returns the verdict
old_usage; bump; env PM_USAGE_SKIP=1 python3 "$HOOKS/project-map-facts.py" "$R" >/dev/null   # the one mechanical re-render that flags the page stale
rm -rf "$UPD"   # a cold scan again
out=$(PM_USAGE_SLOW=1.0 ufacts --budget 3); frc=$?
t_pre "U33-facts: usage out of budget: the verdict, not an error" "$out" "NEEDS_JUDGEMENT"
t_eq "U33-facts: ... exit 0" "$frc" 0
t_eq "U33-facts: the staged snapshot carries the previous numbers, stale" "$(usnap 'd["usage"]["totals"]["all"]'):$(usnap 'd["usage"].get("stale")')" "1234:True"
INV=${out##* }; INVN="inv-$INV"; STAGE="$PM/$INVN"; pub "" update
t_pre "U33-facts: the judged publish succeeds" "$eo" "PM_EMBED_OK"
t_eq "U33-facts: ... and the state keeps the numbers with the marker" "$(S 'd["usage"]["totals"]["all"]'):$(S 'd["usage"].get("stale")')" "1234:True"
bump; out=$(ufacts); t_pre "U33-facts: with time to scan, the next facts run has the verdict" "$out" "NEEDS_JUDGEMENT"
t_eq "U33-facts: ... and exact fresh usage in the staged snapshot" "$(usnap 'd["usage"]["totals"]["all"]'):$(usnap 'd["usage"].get("stale")')" "1760:None"

# no previous numbers at all and a scan that fails: no error, usage stays absent, no marker
mkproj u33n >/dev/null; printf 'import sys\nsys.exit(3)\n' > "$HOOKS/project-map-usage.py"
out=$(uembed --mechanical --deadline 3.5); t_pre "U33-none: no previous numbers and a failing scan: the refresh still publishes" "$out" "PM_EMBED_OK"
t_eq "U33-none: usage stays absent (no invented numbers)" "$(S 'd["usage"]')" None
t_not "U33-none: and the brief has no marker" "$(cat "$PM/brief.txt")" "usage as of"
cp "$T/usage.py.keep" "$HOOKS/project-map-usage.py"

# ---------------------------------------------------------------- 3.3.0 audit U330-1: counters only, private cache, legacy files swept
# Transcripts hold conversation text and other projects' paths; none of it may reach the state, the pack, the page or the brief,
# and the cache that does hold raw paths lives outside the project (the guard denies the map agent that directory).
rm -rf "$HOME/.claude/projects" "$HOME/.codex" "$UPD"
mkproj u330 >/dev/null
python3 - "$R" "$T" <<'PY'
import json, os, sys
root, T = sys.argv[1], sys.argv[2]
cp = os.path.join(os.environ["HOME"], ".claude", "projects")
def w(path, recs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        for r in recs:
            fh.write(json.dumps(r, separators=(",", ":")) + "\n")   # compact, like the real transcripts
def asst(i, cwd, mid):
    d = {"type": "assistant", "timestamp": "2026-10-08T10:00:%02dZ" % i, "message": {"id": mid, "model": "claude-x", "usage": {"input_tokens": 10, "output_tokens": 1}}}
    if cwd: d["cwd"] = cwd
    return d
w(cp + "/-u330/main.jsonl", [asst(i, root, "a%d" % i) for i in range(4)] + [asst(5, T + "/foreign-q7", "f1"), {"type": "ai-title", "aiTitle": "Direct Title"}])
w(cp + "/-u330/men.jsonl", [asst(i, None, "m%d" % i) for i in range(2)] + [{"type": "user", "message": {"content": "see %s/f%d" % (root, i)}} for i in range(30)] + [{"type": "ai-title", "aiTitle": "MENTION-TITLE-q7"}])
w(cp + "/-u330/main/subagents/agent-1.jsonl", [asst(i, None, "s%d" % i) for i in range(2)])
open(cp + "/-u330/main/subagents/agent-1.meta.json", "w").write('{"description":"META-DESC-q7","agentType":"Explore-q7"}')
w(cp + "/-other-q7/z.jsonl", [asst(i, T + "/foreign-q7", "z%d" % i) for i in range(3)])
xd = os.path.join(os.environ["HOME"], ".codex", "sessions", "2026", "10", "08")
w(xd + "/rollout-2026-10-08T10-00-00-eeeeeeee.jsonl",
  [{"type": "session_meta", "payload": {"id": "sess-e1", "cwd": root}}, {"type": "turn_context", "payload": {"model": "gpt-x", "turn_id": "turn-1"}},
   {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "SECRET-EXCERPT-q7 rotate the key at /Users/x/foreign-q7"}]}},
   {"type": "event_msg", "timestamp": "2026-10-08T10:00:30Z", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 100, "cached_input_tokens": 40, "cache_write_input_tokens": 0, "output_tokens": 10}}}}])
PY
printf x > "$PM/usage-cache.json"; printf x > "$PM/usage-last.json"; printf x > "$PM/.usage-last.json.tmp.7"
env PM_USAGE_SKIP=1 python3 "$HOOKS/project-map-facts.py" "$R" >/dev/null
t_eq "U330-1 facts: the legacy usage-cache.json / usage-last.json / temp file in the project are deleted (one-time migration)" "$(ls -A "$PM" | grep -c 'usage')" 0
printf x > "$PM/usage-cache.json"
out=$(uembed --mechanical --deadline 8); t_pre "U330-1: a mechanical refresh with real transcripts publishes" "$out" "PM_EMBED_OK"
t_eq "U330-1: usage counted (claude: main 4 + mentions 2 + inherited subagent 2 messages x 11; codex 110)" "$(S 'd["usage"]["totals"]["claude"]'):$(S 'd["usage"]["totals"]["codex"]')" "88:110"
t_eq "U330-1: the legacy file is gone after the usage scan itself too" "$(ls -A "$PM" | grep -c 'usage')" 0
t_true "U330-1: the cache and last result are in the private directory, mode 0600/0700" '[ "$(ls "$UPD" | grep -c "cache.json$")" = 1 ] && [ "$(ls "$UPD" | grep -c "last.json$")" = 1 ] && [ "$(stat -f %Lp "$UPD" 2>/dev/null || stat -c %a "$UPD")" = 700 ] && [ -z "$(find "$UPD" -type f ! -perm 600)" ]'
t_eq "U330-1: the direct session keeps its title; every other label is generic" "$(S 'sorted(j["label"] for j in d["usage"]["jobs"])')" "['Claude session main', 'Claude session men', 'Codex session sess-e1', 'Direct Title']"
t_true "U330-1: state.json carries no excerpt, foreign cwd, other title, subagent description or transcript path" '! grep -q -e q7 -e "/.claude/projects" -e "/.codex/" "$PM/state.json"'
t_true "U330-1: the page (index.html, mobile.html) carries none either" '! grep -q -e q7 -e "/.claude/projects" -e "/.codex/" "$PM/index.html" "$PM/mobile.html"'
t_true "U330-1: ... nor does the brief" '! grep -q -e q7 -e "/.claude/projects" "$PM/brief.txt"'
bump; out=$(ufacts); t_pre "U330-1: facts stage" "$out" "NEEDS_JUDGEMENT"
t_true "U330-1: the staged pack and snapshot carry no transcript-derived text either" '! grep -rq -e q7 -e "/.claude/projects" -e "/.codex/" "$PM/inv-${out##* }/pack.json" "$PM/inv-${out##* }/snapshot.json"'
t_eq "U330-1: a stored usage from an older build (no label allowlist stamp) loses its free-text job labels" "$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import pm_collect as K
u = {"at": "2026-10-01T00:00:00+00:00", "totals": {"all": 5}, "jobs": [{"label": "SECRET-EXCERPT"}], "by_model": [{"model": "m"}]}
a = K.stale_usage(u); b = K.clean_usage(dict(u, allow=2))
print(a["jobs"], a["stale"], a["by_model"][0]["model"], b["jobs"][0]["label"])' "$HOOKS")" "[] True m SECRET-EXCERPT"

# ======================================================================================================
# OV. 3.3.0: decisions overtaken by events (INTERFACES section 12)
# ======================================================================================================
# The scenario seen live: a hard-rule "tag and push now?" decision, then the owner did it by hand. The closure predicate is bound
# when the decision is RAISED (resolves_when); the script evaluates it; the model's words never retire a question by themselves.
RW_TP='{"kind":"tag_at_head","repo":".","name":"v1.0.0"}'
RW_SY='{"kind":"branch_in_sync","repo":"."}'
ovraise() { # PREDICATES [CODE]: raise D-002 with a closure predicate set
  printf '%s' 'J["decisions"][1]["resolves_when"]=['"$1"']; '"$2"
}
ovj() { # CODE: a judgement that closes D-002 by events unless CODE says otherwise (D-001 is carried and made ready)
  printf '%s' 'J["decisions"][0]["ready"]=True; J["decisions"][1]["overtaken"]={"why":"Owner tagged v1.0.0 and pushed by hand"}; '"$1"
}
ovpush() { # make the repository tagged v1.0.0 and in sync with a local bare origin ($1 = origin name)
  (cd "$R" && git tag v1.0.0 && git init -q --bare "$T/$1-origin.git" && git remote add origin "$T/$1-origin.git" && git push -q -u origin main 2>/dev/null)
}

# ---- raise-time validation: nothing is published for a malformed predicate (FULL run on a fresh repository)
mkrepo ovr; begin
rej "OV-raise: unknown predicate kind" 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_pushed","repo":"."}]' "resolves_when[1] kind must be one of tag_at_head|branch_in_sync|commit|file" full
rej "OV-raise: an empty list" 'J["decisions"][1]["resolves_when"]=[]' "resolves_when must be a list of 1-3 predicates" full
rej "OV-raise: four predicates" 'J["decisions"][1]["resolves_when"]=['"$RW_SY,$RW_SY,$RW_SY,$RW_SY"']' "resolves_when must be a list of 1-3 predicates" full
rej "OV-raise: an object instead of a list" 'J["decisions"][1]["resolves_when"]='"$RW_SY" "resolves_when must be a list of 1-3 predicates" full
rej "OV-raise: a missing repo" 'J["decisions"][1]["resolves_when"]=[{"kind":"branch_in_sync"}]' "resolves_when[1] (branch_in_sync) is missing: repo" full
rej "OV-raise: an unknown key" 'J["decisions"][1]["resolves_when"]=[{"kind":"branch_in_sync","repo":".","branch":"main"}]' "has unknown keys: branch" full
rej "OV-raise: a repo that is not in the snapshot" 'J["decisions"][1]["resolves_when"]=[{"kind":"branch_in_sync","repo":"nope"}]' "repo nope is not a repository of this project" full
rej "OV-raise: a commit sha that is HEAD, not hex" 'J["decisions"][1]["resolves_when"]=[{"kind":"commit","repo":".","sha":"HEAD"}]' "sha must be 7-40 lowercase hex" full
rej "OV-raise: a tag name that is not a string" 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_at_head","repo":".","name":7}]' "name must be a tag name" full
rej "OV-raise: a path that climbs out of the project" 'J["decisions"][1]["resolves_when"]=[{"kind":"file","path":"../x"}]' "must be a relative path inside the project" full
rej "OV-raise: an absolute path" 'J["decisions"][1]["resolves_when"]=[{"kind":"file","path":"/etc/passwd"}]' "must be a relative path inside the project" full
rej "OV-raise: a path into .git" 'J["decisions"][1]["resolves_when"]=[{"kind":"file","path":".git/config"}]' "points into .git/" full
rej "OV-raise: a path into .project-map" 'J["decisions"][1]["resolves_when"]=[{"kind":"file","path":".project-map/state.json"}]' "points into .project-map/" full
rej "OV-raise: exists is not a boolean" 'J["decisions"][1]["resolves_when"]=[{"kind":"file","path":"README.md","exists":"yes"}]' "exists must be true or false" full

# ---- the closure scenario: raise with a predicate set, then tag and push by hand
mkproj ov "$(ovraise "$RW_TP,$RW_SY")" || true
t_eq "OV-raise: stored on the decision, normalized" "$(S '[x.get("resolves_when") for x in d["decisions"] if x["id"]=="D-002"]')" "[[{'kind': 'tag_at_head', 'repo': '.', 'name': 'v1.0.0', 'tid': '2485f4d55aae6c5b'}, {'kind': 'branch_in_sync', 'repo': '.'}]]"
t_eq "OV-raise: a decision raised without one has none" "$(S '["resolves_when" in x for x in d["decisions"] if x["id"]=="D-001"]')" "[False]"
bump; begin
t_eq "OV-pack: resolved is false while the predicates do not hold (and absent without resolves_when)" "$(get "$STAGE/pack.json" '[(x["id"], x.get("resolved")) for x in d["decisions"]]')" "[('D-001', None), ('D-002', False)]"
rej "OV-premature: overtaken while no predicate holds" "$(ovj '')" "decision D-002: overtaken, but resolves_when does not hold yet (tag v1.0.0 at HEAD of .; . in sync with its upstream)"
(cd "$R" && git tag v1.0.0); bump; begin
t_eq "OV-pack: a tag alone leaves the set unresolved" "$(get "$STAGE/pack.json" '[x.get("resolved") for x in d["decisions"] if x["id"]=="D-002"]')" "[False]"
rej "OV-partial: ALL predicates must hold (a tag is not a push)" "$(ovj '')" "resolves_when does not hold yet (. in sync with its upstream)"
(cd "$R" && git init -q --bare "$T/ov-origin.git" && git remote add origin "$T/ov-origin.git" && git push -q -u origin main 2>/dev/null); bump; begin
t_has "OV-facts: the staged snapshot shows tag and sync" "$(get "$STAGE/snapshot.json" '[(r["release"]["head_tags"][0]["name"], r["release"]["sync"]["state"]) for r in d["repos"]]')" "('v1.0.0', 'aligned')"
t_eq "OV-pack: resolved is true once the script sees every predicate hold" "$(get "$STAGE/pack.json" '[(x["id"], x.get("resolved")) for x in d["decisions"]]')" "[('D-001', None), ('D-002', True)]"
H7=$(git -C "$R" rev-parse --short=7 HEAD)
Q2=$(get "$STAGE/snapshot.json" '[x["q"] for x in d["decisions"] if x["id"]=="D-002"][0]')
# the model can neither close an unbound decision nor change what a decision waits for
rej "OV-unbound: a decision raised without resolves_when cannot be closed by events" 'J["decisions"][0]["overtaken"]={"why":"x"}' "decision D-001: overtaken needs the resolves_when predicate set when the decision was raised"
rej "OV-unbound: ... a hard rule and a matching tag do not change that" 'J["decisions"][0]["ready"]=True; J["decisions"][0]["hard_rule"]="upstream_post"; J["decisions"][0]["default"]="hold"; J["decisions"][0]["overtaken"]={"why":"x","ref":"tag:v1.0.0"}' "overtaken needs the resolves_when predicate set when the decision was raised"
rej "OV-ref: evidence that is not among the checked predicates" "$(ovj 'J["decisions"][1]["overtaken"]["ref"]="sync:ahead"')" "overtaken.ref must be one of the checked evidence strings: tag:v1.0.0, sync:aligned"
rej "OV-ref: an unrelated true fact is not evidence either" "$(ovj 'J["decisions"][1]["overtaken"]["ref"]="file:README.md"')" "overtaken.ref must be one of the checked evidence strings"
rej "OV-ref: not a string" "$(ovj 'J["decisions"][1]["overtaken"]["ref"]=7')" "overtaken.ref must be one of the checked evidence strings"
rej "OV-frozen: the predicate of a carried decision cannot be changed" 'J["decisions"][1]["resolves_when"]=[{"kind":"file","path":"README.md"}]' "decision D-002: resolves_when is fixed when the decision is raised"
rej "OV-frozen: ... nor added to a decision that was raised without one" 'J["decisions"][0]["resolves_when"]=['"$RW_SY"']' "decision D-001: resolves_when is fixed when the decision is raised"
rej "OV-why over 120 bytes" "$(ovj 'J["decisions"][1]["overtaken"]["why"]="w"*121')" "overtaken.why must be"
rej "OV-why missing" "$(ovj 'J["decisions"][1]["overtaken"].pop("why")')" "overtaken is missing: why"
rej "OV-extra key inside overtaken" "$(ovj 'J["decisions"][1]["overtaken"]["by"]="owner"')" "overtaken has unknown keys: by"
rej "OV-model-supplied status overtaken" "$(ovj 'J["decisions"][1]["status"]="overtaken"')" "status is owned by the script"
rej "OV-model-supplied closed_by" "$(ovj 'J["decisions"][1]["closed_by"]="events"')" "closed_by is owned by the script"
rej "OV-model-supplied overtaken_ref" "$(ovj 'J["decisions"][1]["overtaken_ref"]="tag:v1.0.0"')" "overtaken_ref is owned by the script"
rej "OV-overtaken on a decision that is not open (new id)" 'J["decisions"][0]["ready"]=True; J["decisions"].append(dict(J["decisions"][1], id="D-003", overtaken={"why":"x"}))' "decision D-003: overtaken closes an open or overdue decision only"
rej "OV-never-vanish: an omitted decision with a predicate" 'J["decisions"]=[J["decisions"][0]]' "decision D-002 is open: carry it, or close it with overtaken{why} once its resolves_when holds"
rej "OV-never-vanish: ... and one without" 'J["decisions"]=[J["decisions"][1]]' "decision D-001 is open and has no resolves_when: carry it unchanged, only the owner's answer closes it"
rej "OV-never-vanish: no decisions at all names every open one" 'J["decisions"]=[]' "decision D-001 is open and has no resolves_when"
t_true "OV-nothing written by the rejected runs (answers.jsonl untouched)" "[ ! -s $PM/answers.jsonl ]"
# valid: the model rewrites the question in the same judgement; the script keeps the original (OV330-2)
jud "$INVN" update "$(ovj 'J["decisions"][1].update(q="Should we push main?", hard_rule=None, default="A", ready=True, deadline=None, recommended="B", options=[{"id":"A","label":"Yes"},{"id":"B","label":"No"}]); J["decisions"][1]["resolves_when"]=['"$RW_TP,$RW_SY"']; J["decisions"][1]["overtaken"]["ref"]="tag:v1.0.0"')"; eo=$(embed "$INVN"); erc=$?
t_pre "OV-tag: a hard-rule decision closed once its bound predicates hold publishes" "$eo" "PM_EMBED_OK"
t_eq "OV-tag: status overtaken, closed by events, why kept, ref = the checked evidence" "$(S '[(x["status"],x["closed_by"],x["overtaken_why"],x["overtaken_ref"]) for x in d["decisions"] if x["id"]=="D-002"]')" "[('overtaken', 'events', 'Owner tagged v1.0.0 and pushed by hand', 'tag:v1.0.0 + sync:aligned')]"
t_eq "OV-original: the record is the STAGED decision verbatim (q, options, hard rule, default, ready, deadline, raised_at, predicates)" "$(python3 -c 'import json,sys
s=json.load(open(sys.argv[1])); t=json.load(open(sys.argv[2]))
a=[x for x in s["decisions"] if x["id"]=="D-002"][0]; b=[x for x in t["decisions"] if x["id"]=="D-002"][0]
print(all(a[k]==b[k] for k in a if k!="status"), sorted(set(b)-set(a)), b["q"]==sys.argv[3])' "$STAGE/snapshot.json" "$PM/state.json" "$Q2")" "True ['closed_at', 'closed_by', 'overtaken_ref', 'overtaken_why'] True"
t_eq "OV-original: the model's rewrite is gone (hard rule and hold default of the original)" "$(S '[(x["hard_rule"],x["default"],x["q"]!="Should we push main?","answer" in x) for x in d["decisions"] if x["id"]=="D-002"]')" "[('upstream_post', 'hold', True, False)]"
t_eq "OV-tag: closed_at is the snapshot time" "$(S '[x["closed_at"]==d["identity"]["snapshot_at"] for x in d["decisions"] if x["id"]=="D-002"]')" "[True]"
t_true "OV-tag: nothing was written to answers.jsonl" "[ ! -s $PM/answers.jsonl ]"
t_eq "OV-tag: D-001 stays open" "$(S '[x["status"] for x in d["decisions"] if x["id"]=="D-001"]')" "['open']"
t_has "OV-tag: the brief has the overtaken line" "$(cat "$PM/brief.txt")" "D-002 overtaken by events: Owner tagged v1.0.0 and pushed by hand (tag:v1.0.0 + sync:aligned)"
t_eq "OV-tag: ... and it is not a needs-you line (only D-001 is)" "$(grep -c ' needs you: ' "$PM/brief.txt"):$(grep ' needs you: ' "$PM/brief.txt" | cut -c1-5)" "1:D-001"
t_true "OV-tag: the overtaken line sits after the headline and before the generation trailer" "[ \$(grep -n 'D-002 overtaken' $PM/brief.txt | cut -d: -f1) -gt 3 ] && [ \$(grep -n 'D-002 overtaken' $PM/brief.txt | cut -d: -f1) -lt \$(grep -n '^generation ' $PM/brief.txt | cut -d: -f1) ]"
t_true "OV-tag: brief <= 1000 bytes" "[ \$(wc -c < $PM/brief.txt) -le 1000 ]"
t_has "OV-tag: the page has the Resolved by events panel (textContent only)" "$(cat "$PM/index.html")" "Resolved by events"
t_eq "OV-tag: the template has no innerHTML at all (textContent only)" "$(grep -c 'innerHTML' "$HOOKS/project-map-template.html")" 0
t_eq "OV-tag: history entry names it" "$(S '[c["text"] for c in d["history"][-1]["changed"] if c["id"]=="D-002"]')" "['overtaken: Owner tagged v1.0.0 and pushed by hand']"
t_eq "OV-tag: history decisions_closed lists it, changes[] has it" "$(S '(d["history"][-1]["decisions_closed"], [c["text"] for c in d["changes"] if c["id"]=="D-002"])')" "(['D-002'], ['overtaken: Owner tagged v1.0.0 and pushed by hand'])"
# one generation only, and frozen under the same id: the stale stamp that precedes the next judgement is a mechanical refresh,
# which already drops the shown notice (OV-mech below); a judgement that still copies the id from judgement.in.json is refused
bump; begin
t_not "OV-gone: the next staged snapshot no longer has the closed decision" "$(get "$STAGE/snapshot.json" '[x["id"] for x in d["decisions"]]')" "D-002"
rej "OV-gone: a judgement that still copies the closed id is refused with a hint (ids are never reused)" 'J["decisions"][0]["ready"]=True' "decision id D-002 was retired, ids are never reused (drop it from decisions[])"
pub 'J["decisions"]=[x for x in J["decisions"] if x["id"]=="D-001"]; J["headline"]["text"]="after"'
t_pre "OV-reopen: ... and a judgement without it publishes" "$eo" "PM_EMBED_OK"
t_eq "OV-reopen: ... only D-001 is left, the overtaken one was not reopened" "$(S '[x["id"] for x in d["decisions"]]')" "['D-001']"
t_not "OV-reopen: no overtaken line in the next brief" "$(cat "$PM/brief.txt")" "overtaken by events"
t_has "OV-retired: the dropped id is retired" "$(S 'd["retired_ids"]')" "D-002"
t_eq "OV-retired: ... and tombstoned for good" "$(S 'd["retired_decisions"]')" "D-002"
bump; begin
rej "OV-retired: a new question under the old id is rejected" 'J["decisions"][0]["ready"]=True' "decision id D-002 was retired"

# ---- unrelated evidence cannot close a decision: a different predicate, a hard rule alone, a true sync or an existing file
mkproj ovx "$(ovraise '{"kind":"tag_at_head","repo":".","name":"v2.0.0"}')" || true
ovpush ovx; H7=$(git -C "$R" rev-parse --short=7 HEAD); bump; begin
t_eq "OV-unrelated: the facts show a tag and an aligned branch, yet resolved is false for a v2.0.0 predicate" "$(get "$STAGE/pack.json" '[x.get("resolved") for x in d["decisions"] if x["id"]=="D-002"]')" "[False]"
for ref in tag:v1.0.0 sync:aligned file:README.md commit:$H7; do
  rej "OV-unrelated: $ref does not close a decision waiting for tag v2.0.0" 'J["decisions"][0]["ready"]=True; J["decisions"][1]["overtaken"]={"why":"done","ref":"'"$ref"'"}' "decision D-002: overtaken, but resolves_when does not hold yet (tag v2.0.0 at HEAD of .)"
done
mkproj ovn || true
ovpush ovn; bump; begin
rej "OV-unbound: a hard-rule decision with no predicate is not closed by a tag at HEAD and an aligned branch" "$(ovj '')" "decision D-002: overtaken needs the resolves_when predicate set when the decision was raised"
rej "OV-unbound: ... the message says only the owner's answer closes it" "$(ovj '')" "so only the owner's answer closes it"
pub 'J["decisions"][0]["ready"]=True; J["headline"]["text"]="carried"'
t_pre "OV-unbound: carrying it open is fine" "$eo" "PM_EMBED_OK"
t_eq "OV-unbound: ... and it is still open" "$(S '[x["status"] for x in d["decisions"] if x["id"]=="D-002"]')" "['open']"
printf '{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"; upd 'J["decisions"][0]["ready"]=True'
t_eq "OV-unbound: the owner's answer closes it" "$(S '[x["status"] for x in d["decisions"] if x["id"]=="D-002"]')" "['answered']"
# a predicate whose facts already hold and which the model still carries open is fine: the script never closes it by itself
mkproj ovh "$(ovraise "$RW_TP,$RW_SY")" || true
ovpush ovh; bump; begin
pub 'J["decisions"][0]["ready"]=True'
t_pre "OV-carry: predicates that hold, decision carried open: publishes" "$eo" "PM_EMBED_OK"
t_eq "OV-carry: ... and the script did not close it" "$(S '[x["status"] for x in d["decisions"] if x["id"]=="D-002"]')" "['open']"

# ---- the other predicate kinds: commit, file exists, file absent
mkrepo ovk; H7=$(git -C "$R" rev-parse --short=7 HEAD); begin
pub 'J["decisions"][0]["resolves_when"]=[{"kind":"commit","repo":".","sha":"'"$H7"'"},{"kind":"file","path":"README.md","exists":False}]; J["decisions"][1]["resolves_when"]=[{"kind":"file","path":"RELEASE-NOTES.md"},{"kind":"commit","repo":".","sha":"deadbee"}]' full
t_pre "OV-kinds: commit, file absent, file exists (default) and a commit that is not there yet publish at raise" "$eo" "PM_EMBED_OK"
t_eq "OV-kinds: exists defaults to true in the stored predicate" "$(S '[x["resolves_when"][0] for x in d["decisions"] if x["id"]=="D-002"]')" "[{'kind': 'file', 'path': 'RELEASE-NOTES.md', 'exists': True}]"
bump; begin
t_eq "OV-kinds: neither set holds yet" "$(get "$STAGE/pack.json" '[(x["id"], x["resolved"]) for x in d["decisions"]]')" "[('D-001', False), ('D-002', False)]"
rej "OV-kinds: a file that is still there is not absent" 'J["decisions"][0]["ready"]=True; J["decisions"][0]["overtaken"]={"why":"gone"}' "decision D-001: overtaken, but resolves_when does not hold yet (file README.md is absent)"
rm -f "$R/README.md"; echo notes > "$R/RELEASE-NOTES.md"; bump; begin
t_eq "OV-kinds: absent file + listed commit hold; the unknown commit keeps D-002 unresolved" "$(get "$STAGE/pack.json" '[(x["id"], x["resolved"]) for x in d["decisions"]]')" "[('D-001', True), ('D-002', False)]"
rej "OV-kinds: a predicate set with one unmet commit does not close" 'J["decisions"][0]["ready"]=True; J["decisions"][1]["overtaken"]={"why":"notes written"}' "decision D-002: overtaken, but resolves_when does not hold yet (commit deadbee in .)"
pub 'J["decisions"][1]["ready"]=True; J["decisions"][0]["overtaken"]={"why":"README removed in the release commit","ref":"absent:README.md"}'
t_pre "OV-kinds: commit + absent file close D-001" "$eo" "PM_EMBED_OK"
t_eq "OV-kinds: the evidence strings are joined" "$(S '[x["overtaken_ref"] for x in d["decisions"] if x["status"]=="overtaken"]')" "['commit:$H7 + absent:README.md']"

# ---- predicate evaluator, unit level (synthetic snapshot): every state that is not "aligned" or "named tag present" is false
cat > "$T/ov_unit1.py" <<'PY'
import os, sys, tempfile
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import subprocess
import pm_validate as V
import pm_common as C
root = os.path.realpath(tempfile.mkdtemp(prefix="ovunit.", dir=sys.argv[2]))
open(os.path.join(root, "README.md"), "w").write("x\n")
os.mkdir(os.path.join(root, "sub"))
for d in (root, os.path.join(root, "sub")):   # repositories are re-confirmed on disk at every evaluation
    subprocess.run(["git", "init", "-q", d], check=True)
rel = lambda state, tags: {"head_tags": [{"name": t, "tid": C.tag_tid(t)} for t in tags], "sync": {"state": state}}
snap = {"repos": [{"path": ".", "vcs": "git", "release": rel("aligned", ["v1", "v2"])},
                  {"path": "sub", "vcs": "git", "release": rel("ahead", [])}, {"path": "plain", "vcs": "none"}], "commits": {"days": []}}
E = lambda p: V.eval_predicate(root, snap, p)[0]
out = [E({"kind": "tag_at_head", "repo": ".", "name": None}), E({"kind": "tag_at_head", "repo": ".", "name": "v2"}),
       E({"kind": "tag_at_head", "repo": ".", "name": "v3"}), E({"kind": "tag_at_head", "repo": "sub", "name": None}),
       E({"kind": "branch_in_sync", "repo": "."}), E({"kind": "branch_in_sync", "repo": "sub"}),
       E({"kind": "branch_in_sync", "repo": "plain"}), E({"kind": "branch_in_sync", "repo": "missing"}),
       E({"kind": "commit", "repo": ".", "sha": "0000000"}), E({"kind": "file", "path": "README.md", "exists": True}),
       E({"kind": "file", "path": "../README.md", "exists": True}), E({"kind": "file", "path": "../nope", "exists": False}),
       E({"kind": "file", "path": ".git/HEAD", "exists": True})]
s2 = dict(snap, repos=[{"path": ".", "vcs": "git", "release": rel("unknown", [])}])
out.append(V.eval_predicate(root, s2, {"kind": "branch_in_sync", "repo": "."})[0])
print(out)
PY
t_eq "OV-eval: tag any/named/absent, sync states, commit and file edge cases" "$(python3 -I "$T/ov_unit1.py" "$HOOKS" "$T")" "[True, True, False, False, True, False, False, False, False, True, False, False, False, False]"

# ---- owner-answer precedence at publication (OV330-3): an answer appended AFTER the facts and BEFORE embed
mkproj ova "$(ovraise "$RW_TP,$RW_SY")" || true
ovpush ova; bump; begin
jud "$INVN" update "$(ovj '')"
printf '{"id":"D-002","answer":"hold","by":"owner","at":"2026-10-10T10:00:00+00:00"}\n' >> "$PM/answers.jsonl"
cp "$PM/answers.jsonl" "$T/ova-answers.before"
eo=$(embed "$INVN"); erc=$?
t_pre "OV-answer: an answer written after the facts: the map still publishes" "$eo" "PM_EMBED_OK"
t_has "OV-answer: ... and the result says the owner's answer won" "$eo" "PM_EMBED_NOTE owner answer for D-002 arrived during the judgement and wins over its closure by events"
t_eq "OV-answer: D-002 is published as answered, with the lifecycle fields, not as overtaken" "$(S '[(x["status"],x["answer"],x["answered_by"],x["answered_at"],"overtaken_why" in x,"closed_by" in x) for x in d["decisions"] if x["id"]=="D-002"]')" "[('answered', 'hold', 'owner', '2026-10-10T10:00:00+00:00', False, False)]"
t_eq "OV-answer: the owner's record is untouched (no synthetic answer, no rewrite)" "$(cmp -s "$PM/answers.jsonl" "$T/ova-answers.before" && echo same)" "same"
t_eq "OV-answer: the line is applied, not bad input" "$(S '(d["answers"]["applied"], d["answers"]["total"], d["answers"]["bad"])')" "(1, 1, [])"
t_not "OV-answer: no overtaken line in the brief" "$(cat "$PM/brief.txt")" "overtaken by events"
t_eq "OV-answer: the history does not claim a closure by events" "$(S '(d["history"][-1]["decisions_closed"], [c for c in d["history"][-1]["changed"] if "overtaken" in c["text"]])')" "(['D-002'], [])"
bump; out=$(facts)
t_pre "OV-answer: the map is stale for the answer: the next verdict re-judges" "$out" "NEEDS_JUDGEMENT"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "OV-answer: ... and the replay has nothing pending or bad" "$(get "$STAGE/snapshot.json" '(d["answers"]["pending"], d["answers"]["bad"])')" "([], [])"
pub 'J["decisions"]=[x for x in J["decisions"] if x["id"]=="D-001"]'
t_pre "OV-answer: the next judgement publishes" "$eo" "PM_EMBED_OK"
t_eq "OV-answer: D-002 was shown for its one generation and is gone" "$(S '[x["id"] for x in d["decisions"]]')" "['D-001']"
# a later line cannot be applied alone (the applied count is a prefix): every line appended meanwhile is applied in order
mkproj ovb "$(ovraise "$RW_TP,$RW_SY")" || true
ovpush ovb; bump; begin
jud "$INVN" update "$(ovj '')"
printf '{"id":"D-001","answer":"hold","by":"owner"}\n{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_has "OV-answer: two lines appended, the second one for the closed decision: owner wins" "$eo" "PM_EMBED_NOTE owner answer for D-002"
t_eq "OV-answer: ... the prefix is applied in order: D-001 answered too, applied 2" "$(S '([(x["id"],x["status"]) for x in d["decisions"]], d["answers"]["applied"])')" "([('D-001', 'answered'), ('D-002', 'answered')], 2)"
# no conflict: answers appended during a judgement stay pending exactly as before (stale/re-judge semantics)
mkproj ovc "$(ovraise "$RW_TP,$RW_SY")" || true
ovpush ovc; bump; begin
jud "$INVN" update "$(ovj '')"
printf '{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_pre "OV-answer: an answer for a decision the judgement does not close: publishes" "$eo" "PM_EMBED_OK"
t_not "OV-answer: ... with no note" "$eo" "PM_EMBED_NOTE"
t_eq "OV-answer: ... the closure stands and the answer stays pending" "$(S '([(x["id"],x["status"]) for x in d["decisions"]], d["answers"]["applied"])')" "([('D-001', 'open'), ('D-002', 'overtaken')], 0)"
bump; out=$(facts); t_has "OV-answer: ... the next verdict sees the pending answer" "$out" "pending answers"
# an invalid answer (not an option) does not win
mkproj ovd "$(ovraise "$RW_TP,$RW_SY")" || true
ovpush ovd; bump; begin
jud "$INVN" update "$(ovj '')"
printf '{"id":"D-002","answer":"Z","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_not "OV-answer: an invalid option does not outrank the closure: no note" "$eo" "PM_EMBED_NOTE"
t_eq "OV-answer: ... the closure is published" "$(S '[x["status"] for x in d["decisions"] if x["id"]=="D-002"]')" "['overtaken']"
# a rewritten prefix while the judgement was written
mkproj ove "$(ovraise "$RW_TP,$RW_SY")" || true
printf '{"id":"D-001","answer":"hold","by":"owner"}\n' > "$PM/answers.jsonl"; upd 'J["decisions"]=[x for x in J["decisions"] if x["id"]=="D-002"]'
ovpush ove; bump; begin
jud "$INVN" update "$(ovj 'J["decisions"]=[x for x in J["decisions"] if x["id"]=="D-002"]')"
printf '{"id":"D-001","answer":"A","by":"owner"}\n{"id":"D-002","answer":"hold","by":"owner"}\n' > "$PM/answers.jsonl"
g0=$(cur); eo=$(embed "$INVN")
t_has "OV-answer: a staged prefix that no longer matches is an error, nothing replaced" "$eo" "PM_EMBED_ERROR answers rewritten while the judgement was written"
t_eq "OV-answer: ... current did not move" "$(cur)" "$g0"

# ---- permanent decision tombstones (OV330-4)
mkproj ovt || true
printf '{"id":"D-002","answer":"hold","by":"owner"}\n' > "$PM/answers.jsonl"; upd 'J["decisions"][0]["ready"]=True'
upd 'J["decisions"][0]["ready"]=True'
t_eq "OV-tombstone: a dropped decision is in the permanent set" "$(S 'd["retired_decisions"]')" "D-002"
lib mut "$PM/current/state.json" 'd["retired_ids"]=["p-%03d"%i for i in range(200)]'; lib resign "$PM/current"
t_eq "OV-tombstone: the 200-id window has rolled over (D-002 is no longer in it)" "$(S '("D-002" in d["retired_ids"], len(d["retired_ids"]))')" "(False, 200)"
bump; begin
rej "OV-tombstone: the oldest retired decision id cannot be raised again after the window forgot it" 'J["decisions"][0]["ready"]=True' "decision id D-002 was retired, ids are never reused"
rej "OV-tombstone: ... the same through the model carrying a fresh question under it" 'J["decisions"]=[dict(J["decisions"][1], q="A brand new question")]' "decision id D-002 was retired"
cat > "$T/ov_unit2.py" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
S = {"retired_ids": [], "retired_decisions": ""}
for i in range(230):
    V.retire_decisions(S, ["D-%03d" % i])
legacy = {"retired_ids": ["D-007", "old-part"]}   # a state from before the permanent set: seeded from the window
print(len(S["retired_ids"]), "D-000" in S["retired_ids"], "D-000" in V.retired_decision_ids(S), len(V.retired_decision_ids(S)),
      S["retired_decisions"], V.retired_decision_ids(legacy) == {"D-007"}, V.encode_decision_ids(["D-001", "D-003", "D-004", "D-005", "D-999"]),
      sorted(V.decode_decision_ids("D-001,D-003..D-005,junk")))
PY
t_eq "OV-tombstone: unit: 230 retirements keep every id, the window keeps 200, the encoding stays compact" "$(python3 -I "$T/ov_unit2.py" "$HOOKS")" "200 False True 230 D-000..D-229 True D-001,D-003..D-005,D-999 ['D-001', 'D-003', 'D-004', 'D-005']"

# ---- the one-generation notice holds through mechanical refreshes (OV330-5)
mkproj ovm "$(ovraise "$RW_TP,$RW_SY")" || true
ovpush ovm; bump; begin
pub "$(ovj '')"
t_pre "OV-mech: setup: overtaken published" "$eo" "PM_EMBED_OK"
t_has "OV-mech: ... the notice is in the brief of that generation" "$(cat "$PM/brief.txt")" "D-002 overtaken by events"
g0=$(gen); eo=$(embed --mechanical)
t_pre "OV-mech: a mechanical refresh publishes" "$eo" "PM_EMBED_OK"
t_true "OV-mech: ... a new generation" "[ \"\$(gen)\" != \"$g0\" ]"
t_eq "OV-mech: ... the shown overtaken decision is dropped, the open one stays" "$(S '[(x["id"],x["status"]) for x in d["decisions"]]')" "[('D-001', 'open')]"
t_not "OV-mech: ... the brief notice is gone" "$(cat "$PM/brief.txt")" "overtaken by events"
t_eq "OV-mech: ... its id is retired for good" "$(S '(d["retired_decisions"], "D-002" in d["retired_ids"])')" "('D-002', True)"
t_eq "OV-mech: a second refresh changes nothing about the decisions" "$(embed --mechanical >/dev/null; S '[(x["id"],x["status"]) for x in d["decisions"]]')" "[('D-001', 'open')]"
bump; begin
rej "OV-mech: the dropped id cannot come back as a question" 'J["decisions"][0]["ready"]=True' "decision id D-002 was retired"
# staging filter: judgement.in.json is the accepted judgement minus the decisions retired in the pinned state
t_eq "STG-retired: the retired decision is gone from judgement.in.json, the open one is there" "$(get "$STAGE/judgement.in.json" '[x["id"] for x in d["decisions"]]')" "['D-001']"
cat > "$T/stg_cmp.py" <<'PY'
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
print("D-002" in [x["id"] for x in a["decisions"]], b == dict(a, decisions=[x for x in a["decisions"] if x["id"] != "D-002"]), list(a) == list(b))
PY
t_eq "STG-retired: the accepted judgement still listed it, and ONLY decisions[] differs (same keys, same order)" "$(python3 -I "$T/stg_cmp.py" "$PM/current/judgement.json" "$STAGE/judgement.in.json")" "True True True"
pub 'J["decisions"]=__import__("json").load(open("'"$STAGE"'/judgement.in.json"))["decisions"]; J["headline"]["text"]="copied"'
t_pre "STG-copy: an UPDATE that copies decisions[] from judgement.in.json verbatim publishes without error" "$eo" "PM_EMBED_OK"
t_eq "STG-copy: ... and D-001 is still open, D-002 stays retired" "$(S '([(x["id"],x["status"]) for x in d["decisions"]], d["retired_decisions"])')" "([('D-001', 'open')], 'D-002')"
# answered and defaulted decisions follow the same rule; a not-yet-applied answer is never lost
mkproj ovm2 || true
printf '{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"; upd 'J["decisions"][1]["ready"]=True'
t_eq "OV-mech: setup: D-001 answered, shown in this generation" "$(S '[(x["id"],x["status"]) for x in d["decisions"]]')" "[('D-001', 'answered'), ('D-002', 'open')]"
printf '{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed --mechanical)
t_pre "OV-mech: refresh with a second answer waiting" "$eo" "PM_EMBED_OK"
t_eq "OV-mech: the answered decision is dropped after its generation, the other stays open" "$(S '[(x["id"],x["status"]) for x in d["decisions"]]')" "[('D-002', 'open')]"
t_eq "OV-mech: ... the waiting answer was not consumed (applied stays 1 of 2)" "$(S '(d["answers"]["applied"], d["answers"]["total"], d["retired_decisions"])')" "(1, 1, 'D-001')"
out=$(facts); t_pre "OV-mech: ... the next verdict re-judges for it" "$out" "NEEDS_JUDGEMENT"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "OV-mech: ... and the replay sees it as pending, not bad" "$(get "$STAGE/snapshot.json" '(len(d["answers"]["pending"]), d["answers"]["bad"])')" "(1, [])"
pub 'J["decisions"]=[x for x in J["decisions"] if x["id"]=="D-002"]'
t_eq "OV-mech: ... the next judgement answers D-002 (not lost)" "$(S '[(x["id"],x["status"],x["answer"]) for x in d["decisions"]]')" "[('D-002', 'answered', 'hold')]"

# ---- an overdue decision may be overtaken; omitting an answered or defaulted one is fine
mkproj ov6 || true
printf '{"id":"D-001","answer":"hold","by":"owner"}\n' > "$PM/answers.jsonl"; bump; begin
pub 'J["decisions"]=[x for x in J["decisions"] if x["id"]!="D-001"]'
t_pre "OV-never-vanish: omitting an answered decision is fine" "$eo" "PM_EMBED_OK"
t_eq "OV-never-vanish: ... and the answered one is still shown for its one generation" "$(S '[(x["id"],x["status"]) for x in d["decisions"]]')" "[('D-002', 'open'), ('D-001', 'answered')]"
upd 'J["decisions"]=[x for x in J["decisions"] if x["id"]=="D-002"]'
t_pre "OV-never-vanish: ... and omitting it again once dropped is fine" "$eo" "PM_EMBED_OK"
mkproj ov7 "$(ovraise "$RW_TP,$RW_SY")" || true
upd 'J["decisions"][1]["deadline"]="2020-01-01T00:00:00+00:00"'
ovpush ov7; bump; begin
t_eq "OV-overdue: the snapshot has D-002 overdue" "$(get "$STAGE/snapshot.json" '[x["status"] for x in d["decisions"] if x["id"]=="D-002"]')" "['overdue']"
t_eq "OV-overdue: ... and the pack says its predicates hold" "$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-002"]')" "[True]"
rej "OV-overdue: omitting an overdue decision is rejected" 'J["decisions"]=[J["decisions"][0]]' "decision D-002 is open: carry it, or close it with overtaken{why} once its resolves_when holds"
pub "$(ovj '')"
t_pre "OV-overdue: an overdue hard-rule decision may be overtaken" "$eo" "PM_EMBED_OK"
t_eq "OV-overdue: overtaken, hard rule and hold kept" "$(S '[(x["status"],x["hard_rule"],x["default"]) for x in d["decisions"] if x["id"]=="D-002"]')" "[('overtaken', 'upstream_post', 'hold')]"
t_true "OV-overdue: answers.jsonl still not written" "[ ! -s $PM/answers.jsonl ]"
# FULL path
mkproj ov8 "$(ovraise "$RW_TP")" || true
bump; begin
rej "OV-full: closing before the predicate holds is an error on a FULL run too" 'J["decisions"][1]["overtaken"]={"why":"x"}' "overtaken, but resolves_when does not hold yet" full
rej "OV-full: omitting an open decision is an error on a FULL run too" 'J["decisions"]=[J["decisions"][0]]' "decision D-002 is open: carry it, or close it with overtaken{why} once its resolves_when holds" full
(cd "$R" && git tag v1.0.0); bump; begin
pub 'J["decisions"][1]["overtaken"]={"why":"Owner tagged v1.0.0"}; J["decisions"][0]["ready"]=True' full
t_pre "OV-full: a FULL run closes a decision by events" "$eo" "PM_EMBED_OK"
t_eq "OV-full: overtaken in the state, run type FULL" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-002"], d["run"]["type"])')" "(['overtaken'], 'FULL')"

# ======================================================================================================
# OV Codex round 2 (decisions): staged answer prefix, complete lines only, tag identity, absence of an entry, live repo confinement
# ======================================================================================================
# ---- OV330-R2-1: late_answers verifies the staged prefix whatever was appended (same count, shorter, unreadable)
ovstaged() { # NAME: D-001 answered by an applied owner line, then a staged snapshot (1 line) and a judgement closing D-002 by events
  mkproj "$1" "$(ovraise "$RW_TP,$RW_SY")" || true
  printf '{"id":"D-001","answer":"hold","by":"owner"}\n' > "$PM/answers.jsonl"; upd 'J["decisions"]=[x for x in J["decisions"] if x["id"]=="D-002"]'
  ovpush "$1"; bump; begin
  jud "$INVN" update "$(ovj 'J["decisions"]=[x for x in J["decisions"] if x["id"]=="D-002"]')"
  g0=$(cur)
}
ovstaged ovr1a
t_eq "OV-R2-1: setup: the staged snapshot covers exactly one answer line" "$(get "$STAGE/snapshot.json" 'd["answers"]["total"]')" 1
printf '{"id":"D-002","answer":"hold","by":"owner"}\n' > "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_has "OV-R2-1: a staged line replaced by a hold for the closing decision (same line count) is an error, not a publish" "$eo" "PM_EMBED_ERROR answers rewritten while the judgement was written"
t_eq "OV-R2-1: ... current did not move" "$(cur)" "$g0"
t_not "OV-R2-1: ... D-002 was not published as overtaken" "$(S '[x["status"] for x in d["decisions"] if x["id"]=="D-002"]')" "overtaken"
ovstaged ovr1b
: > "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_has "OV-R2-1: an answers file truncated below the staged count is an error" "$eo" "PM_EMBED_ERROR answers rewritten while the judgement was written"
t_eq "OV-R2-1: ... current did not move" "$(cur)" "$g0"
ovstaged ovr1c
rm -f "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_has "OV-R2-1: ... and so is a deleted one (it had a staged line)" "$eo" "PM_EMBED_ERROR answers rewritten while the judgement was written"
ovstaged ovr1d
if [ "$(id -u)" = 0 ]; then ok "OV-R2-1: unreadable answers.jsonl (skipped: running as root)"; ok "OV-R2-1: ... that says it could not be read (skipped: root)"; ok "OV-R2-1: ... current did not move (skipped: root)"; else
  chmod 000 "$PM/answers.jsonl"; eo=$(embed "$INVN"); chmod 600 "$PM/answers.jsonl"
  t_pre "OV-R2-1: an unreadable answers.jsonl is an error, not an empty file" "$eo" "PM_EMBED_ERROR"
  t_has "OV-R2-1: ... that says it could not be read" "$eo" "cannot be read"
  t_eq "OV-R2-1: ... current did not move" "$(cur)" "$g0"
fi
cat > "$T/ov_unit4.py" <<'PY'
import os, sys, tempfile, stat
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
pm = tempfile.mkdtemp(prefix="ovunit4.", dir=sys.argv[2])
ap = os.path.join(pm, "answers.jsonl")
empty = K.prefix_hash([], 0)
snap = lambda n, h: {"answers": {"total": n, "total_hash": h, "applied": 0, "pending": [], "bad": []}, "decisions": []}
res = []
res.append(K.late_answers(pm, snap(0, empty), ["D-002"]))   # no file at all and nothing staged: genuinely empty
open(ap, "wb").close()
res.append(K.late_answers(pm, snap(0, empty), ["D-002"]))   # an empty file
try:
    K.late_answers(pm, snap(1, "x" * 64), ["D-002"]); res.append("no error")   # missing/short vs a staged line
except K.AnswersRewritten:
    res.append("rewritten")
if os.getuid() != 0:
    os.chmod(ap, 0)
    try:
        K.late_answers(pm, snap(0, empty), ["D-002"]); res.append("no error")
    except K.AnswersUnreadable:
        res.append("unreadable")
    except K.AnswersRewritten:
        res.append("wrong error")
    os.chmod(ap, 0o600)
else:
    res.append("unreadable")
print(res)
PY
t_eq "OV-R2-1: unit: a missing or empty file with nothing staged is empty (None); a short one is rewritten; an unreadable one is its own error" "$(python3 -I "$T/ov_unit4.py" "$HOOKS" "$T")" "[None, None, 'rewritten', 'unreadable']"

# ---- OV330-R2-2: only complete (newline-terminated) lines are consumed; an unfinished tail stays pending
mkproj ovp "$(ovraise "$RW_TP,$RW_SY")" || true
ovpush ovp; bump; begin
jud "$INVN" update "$(ovj '')"
printf '{"id":"D-002","answer":"hold","by":"owner"}\n{"id":"D-001","ans' >> "$PM/answers.jsonl"
cp "$PM/answers.jsonl" "$T/ovp-answers.before"
eo=$(embed "$INVN")
t_has "OV-R2-2: a valid answer followed by an unfinished record: the first one wins at publication" "$eo" "PM_EMBED_NOTE owner answer for D-002"
t_eq "OV-R2-2: ... only the complete line is applied and counted, the unfinished tail is not bad input" "$(S '(d["answers"]["applied"], d["answers"]["total"], d["answers"]["bad"])')" "(1, 1, [])"
t_eq "OV-R2-2: ... answers.jsonl is untouched" "$(cmp -s "$PM/answers.jsonl" "$T/ovp-answers.before" && echo same)" "same"
printf 'wer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
bump; out=$(facts)
t_not "OV-R2-2: the owner's append completes: the next facts run is not an 'answers rewritten' error" "$out" "ERROR"
t_pre "OV-R2-2: ... it is a normal append: the map re-judges" "$out" "NEEDS_JUDGEMENT"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "OV-R2-2: ... the completed line is the one pending answer, nothing bad" "$(get "$STAGE/snapshot.json" '(d["answers"]["total"], len(d["answers"]["pending"]), d["answers"]["bad"])')" "(2, 1, [])"
mkproj ovq || true
printf '{"id":"D-001","answer":"hold","by":"owner"}\n{"id":"D-002","ans' > "$PM/answers.jsonl"
bump; begin
t_eq "OV-R2-2: facts: a valid line and an unfinished one: one line counted, one pending, nothing bad" "$(get "$STAGE/snapshot.json" '(d["answers"]["total"], len(d["answers"]["pending"]), d["answers"]["bad"], d["key"]["answers_count"])')" "(1, 1, [], 1)"
printf 'wer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
bump; begin
t_not "OV-R2-2: facts: the completed record is accepted without an error" "$out" "ERROR"
t_eq "OV-R2-2: ... both lines counted and pending, nothing bad" "$(get "$STAGE/snapshot.json" '(d["answers"]["total"], len(d["answers"]["pending"]), d["answers"]["bad"])')" "(2, 2, [])"
printf '{"id":"D-001","answer":"hold","by":"owner"}\r\n   \n' > "$PM/answers.jsonl"
bump; begin
t_eq "OV-R2-2: a CRLF line and a blank line are complete lines (one answer, nothing bad)" "$(get "$STAGE/snapshot.json" '(d["answers"]["total"], len(d["answers"]["pending"]), d["answers"]["bad"])')" "(1, 1, [])"

# ---- OV330-R2-3: tag identity (hash of the raw ref name) instead of the display string
TA='sk-aaaaaaaaaaaaaaaaaaaaaaaa1'; TB='sk-bbbbbbbbbbbbbbbbbbbbbbbb2'
mkrepo ovt3; (cd "$R" && git tag "$TA" && git tag "$TB"); begin
t_eq "OV-R2-3: setup: two different secret-shaped tags both display as [redacted] (with different identities)" "$(get "$STAGE/snapshot.json" '([t["name"] for t in d["repos"][0]["release"]["head_tags"]], len({t["tid"] for t in d["repos"][0]["release"]["head_tags"]}))')" "(['[redacted]', '[redacted]'], 2)"
t_not "OV-R2-3: ... and the identity is not shown to the model (not in the pack)" "$(cat "$STAGE/pack.json")" '"tid"'
rej "OV-R2-3: a predicate raised with the ambiguous display name is rejected" 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_at_head","repo":".","name":"[redacted]"}]' "matches 2 tags at HEAD of .; it is ambiguous" full
rej "OV-R2-3: an escaped display form of a tag that is not at HEAD is rejected too" 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_at_head","repo":".","name":"v1\\u202e2"}]' "is not a tag at HEAD of . and is not a plain tag name" full
mkrepo ovt4; BIDI_TAG=$(printf 'v1\xe2\x80\xae2'); (cd "$R" && git tag "$BIDI_TAG"); begin
t_eq "OV-R2-3: setup: the bidi tag is shown with a visible escape" "$(get "$STAGE/snapshot.json" '[t["name"] for t in d["repos"][0]["release"]["head_tags"]]')" "['v1\\\\u202e2']"
pub 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_at_head","repo":".","name":"v1\\u202e2"}]' full
t_pre "OV-R2-3: a bidi tag can be raised by its display name" "$eo" "PM_EMBED_OK"
t_eq "OV-R2-3: ... the stored predicate binds the identity of the raw name" "$(S '[(x["resolves_when"][0]["name"], len(x["resolves_when"][0]["tid"])) for x in d["decisions"] if x["id"]=="D-002"]')" "[('v1\\\\u202e2', 16)]"
bump; begin
t_eq "OV-R2-3: ... it holds while that raw tag is at HEAD" "$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-002"]')" "[True]"
(cd "$R" && echo n > new.txt && git add new.txt && git commit -qm next && git tag v2); bump; begin
t_eq "OV-R2-3: ... and not after a new commit with another tag (the raw tag is no longer at HEAD)" "$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-002"]')" "[False]"
cat > "$T/ov_unit3.py" <<'PY'
import os, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
import pm_common as C
root = os.path.realpath(tempfile.mkdtemp(prefix="ovunit3.", dir=sys.argv[2]))
subprocess.run(["git", "init", "-q", root], check=True)
A, B = "sk-aaaaaaaaaaaaaaaaaaaaaaaa1", "sk-bbbbbbbbbbbbbbbbbbbbbbbb2"
snap = lambda raw: {"repos": [{"path": ".", "vcs": "git", "release": {"head_tags": [{"name": C.display_safe(t), "tid": C.tag_tid(t)} for t in raw],
                                                                          "sync": {"state": "aligned"}}}], "commits": {"days": []}}
pred = {"kind": "tag_at_head", "repo": ".", "name": "[redacted]", "tid": C.tag_tid(A)}
E = lambda raw, p=pred: V.eval_predicate(root, snap(raw), p)[0]
out = [E([A]), E([B]), E([A, B]), E([]),
       E([B], {"kind": "tag_at_head", "repo": ".", "name": None}),                 # name null: any tag at HEAD
       E([], {"kind": "tag_at_head", "repo": ".", "name": None}),
       E(["v1.0.0"], {"kind": "tag_at_head", "repo": ".", "name": "v1.0.0"}),     # no stored identity: the plain name's own
       E([A], {"kind": "tag_at_head", "repo": ".", "name": "[redacted]"})]        # a display-only predicate matches no raw tag
print(out)
PY
t_eq "OV-R2-3: unit: the identity decides, not the display string; name null = any tag; no identity falls back to the plain name only" "$(python3 -I "$T/ov_unit3.py" "$HOOKS" "$T")" "[True, False, True, False, True, False, True, False]"

# ---- OV330-R2-4: exists:false is about the directory entry, not its dereferenced target
mkrepo ovf
ln -s missing-target "$R/dangling"
begin
pub 'J["decisions"][1]["resolves_when"]=[{"kind":"file","path":"dangling","exists":False}]' full
t_pre "OV-R2-4: setup: a decision waiting for a path to be absent is raised" "$eo" "PM_EMBED_OK"
bump; begin
t_eq "OV-R2-4: a dangling symlink at the path is an entry that exists: not resolved" "$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-002"]')" "[False]"
rej "OV-R2-4: ... and the closure is rejected" 'J["decisions"][0]["ready"]=True; J["decisions"][1]["overtaken"]={"why":"gone"}' "decision D-002: overtaken, but resolves_when does not hold yet (file dangling is absent)"
rm -f "$R/dangling"; bump; begin
t_eq "OV-R2-4: removing the symlink itself makes the path absent" "$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-002"]')" "[True]"
cat > "$T/ov_unit5.py" <<'PY'
import os, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
root = os.path.realpath(tempfile.mkdtemp(prefix="ovunit5.", dir=sys.argv[2]))
os.symlink("missing-target", os.path.join(root, "dangling"))
os.symlink("/nonexistent-outside-target", os.path.join(root, "dangling-out"))
os.symlink("dangling-loop2", os.path.join(root, "dangling-loop1")); os.symlink("dangling-loop1", os.path.join(root, "dangling-loop2"))
open(os.path.join(root, "afile"), "w").write("x")
os.mkdir(os.path.join(root, "locked")); os.chmod(os.path.join(root, "locked"), 0)
snap = {"repos": [], "commits": {"days": []}}
F = lambda path, ex: V.evaluate_resolves_when_ex(root, snap, [{"kind": "file", "path": path, "exists": ex}])
out = [F("dangling", False)[0], F("dangling", True)[0], F("dangling-out", False)[0], F("nothing", False)[0], F("afile/under", False)[0],
       F("afile", False)[0], F("dangling-loop1", False)[0]]
r = F("locked/x", False)
out += [r[0], bool(r[3]) if os.getuid() != 0 else True, bool(F("nothing", False)[3])]
os.chmod(os.path.join(root, "locked"), 0o700)
print(out)
PY
t_eq "OV-R2-4: unit: dangling (inside / pointing outside / loop) = exists; missing or under a file = absent; unreadable parent = unknown with a reason (not absence)" "$(python3 -I "$T/ov_unit5.py" "$HOOKS" "$T")" "[False, False, False, True, True, False, False, $( [ "$(id -u)" = 0 ] && echo True || echo False ), True, False]"

# ---- OV330-R2-5: the live repository directory is re-confirmed (inside ROOT, still its own git work tree)
OUTR="$T/ovs-outside"; mkdir -p "$OUTR"; (cd "$OUTR" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && echo o > o.txt && git add -A && git commit -qm outside)
SXO=$(git -C "$OUTR" rev-parse --short=7 HEAD)
mkrepo ovs; mkdir "$R/sub"; (cd "$R/sub" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && echo s > s.txt && git add -A && git commit -qm inner)
begin
pub 'J["decisions"][1]["resolves_when"]=[{"kind":"commit","repo":"sub","sha":"'"$SXO"'"}]' full
t_pre "OV-R2-5: setup: a commit predicate in the nested repository (a commit it does not have yet) is raised" "$eo" "PM_EMBED_OK"
bump; begin
t_eq "OV-R2-5: ... unresolved while the nested repository lacks the commit" "$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-002"]')" "[False]"
t_eq "OV-R2-5: ... the staged snapshot lists the nested repository (a real one at facts time)" "$(get "$STAGE/snapshot.json" 'any(r["path"]=="sub" for r in d["repos"])')" True
cp "$STAGE/snapshot.json" "$T/ovs-snapshot.json"
rm -rf "$R/sub"; ln -s "$OUTR" "$R/sub"   # swapped for a link to a repository outside ROOT AFTER the facts were staged
rej "OV-R2-5: closing by events is rejected although the commit exists in the repository the path now leads to" 'J["decisions"][0]["ready"]=True; J["decisions"][1]["overtaken"]={"why":"done"}' "overtaken, but resolves_when does not hold yet (commit $SXO in sub) [could not be established: sub: repo path escaped or changed; refresh facts]"
rej "OV-R2-5: raising a predicate on that repository is rejected too" 'J["decisions"][0]["ready"]=True; J["decisions"].append(dict(J["decisions"][1], id="D-003", resolves_when=[{"kind":"branch_in_sync","repo":"sub"}]))' "repo sub: repo path escaped or changed; refresh facts" full
t_eq "OV-R2-5: the pack of a stale snapshot says resolved false and why" "$(python3 -I -c '
import json, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
snap = json.load(open(sys.argv[2]))
p = K.build_pack(snap, "inv-x")
print([(x["resolved"], x.get("resolved_why")) for x in p["decisions"] if x["id"] == "D-002"])' "$HOOKS" "$T/ovs-snapshot.json")" "[(False, 'sub: repo path escaped or changed; refresh facts')]"
cat > "$T/ov_unit6.py" <<'PY'
import os, shutil, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
import pm_common as C
base = os.path.realpath(tempfile.mkdtemp(prefix="ovunit6.", dir=sys.argv[2]))
root, outside = os.path.join(base, "proj"), os.path.join(base, "outside")
def repo(d, sha_msg):
    os.makedirs(d)
    g = lambda *a: subprocess.run(["git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + list(a), check=True, capture_output=True, text=True).stdout.strip()
    g("init", "-q", "-b", "main"); open(os.path.join(d, "f"), "w").write(sha_msg); g("add", "-A"); g("commit", "-qm", sha_msg)
    return g("rev-parse", "--short=7", "HEAD")
repo(root, "root"); sub_sha = repo(os.path.join(root, "sub"), "inner"); out_sha = repo(outside, "outside")
rel = {"head_tags": [{"name": "v1", "tid": C.tag_tid("v1")}], "sync": {"state": "aligned"}}
snap = {"repos": [{"path": ".", "vcs": "git", "release": rel}, {"path": "sub", "vcs": "git", "release": rel}], "commits": {"days": []}}
P = [{"kind": "commit", "repo": "sub", "sha": sub_sha}, {"kind": "commit", "repo": "sub", "sha": out_sha},
     {"kind": "tag_at_head", "repo": "sub", "name": "v1"}, {"kind": "branch_in_sync", "repo": "sub"}]
E = lambda: [V.eval_predicate(root, snap, p)[0] for p in P]
res = [E()]                                                    # a real nested repository
shutil.rmtree(os.path.join(root, "sub")); os.symlink(outside, os.path.join(root, "sub"))
res.append(E())                                                # replaced by a link to a repository outside ROOT
os.unlink(os.path.join(root, "sub")); res.append(E())          # missing
os.mkdir(os.path.join(root, "sub")); res.append(E())           # a plain directory (no repository any more)
res.append(V.predicates_in_snapshot(root, snap, [P[0]]))       # raise-time check
print(res)
PY
t_eq "OV-R2-5: unit: real nested repo; link to an outside repo, missing dir and plain dir all fail closed for commit, tag and sync predicates" "$(python3 -I "$T/ov_unit6.py" "$HOOKS" "$T")" "[[True, False, True, True], [False, False, False, False], [False, False, False, False], [False, False, False, False], ['resolves_when[1] repo sub: repo path escaped or changed; refresh facts']]"

# ======================================================================================================
# OV Codex round 3 (decisions): no tid in the pack, future tag names are git-legal, closure waits for an uncommitted answer tail
# ======================================================================================================
# ---- OV330-R3-1: the pack carries public predicate fields only; a verbatim copy of it round-trips
mkproj ovt1 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_at_head","repo":".","name":"v-future"},{"kind":"branch_in_sync","repo":"."}]' || true
t_true "OV-R3-1: setup: the stored predicate binds a tid (the script keeps it)" "[ \"\$($(declare -f S >/dev/null; echo :))\" = '' ] || true"
t_eq "OV-R3-1: setup: ... in the state" "$(S '[("tid" in x["resolves_when"][0]) for x in d["decisions"] if x["id"]=="D-002"]')" "[True]"
bump; begin
t_not "OV-R3-1: a carried named-tag decision: the pack has no tid anywhere" "$(cat "$STAGE/pack.json")" '"tid"'
t_eq "OV-R3-1: ... the staged snapshot still has it for the script" "$(get "$STAGE/snapshot.json" '[("tid" in x["resolves_when"][0]) for x in d["decisions"] if x["id"]=="D-002"]')" "[True]"
t_eq "OV-R3-1: ... the pack still shows the name, the verdict and the other predicate" "$(get "$STAGE/pack.json" '[(x["resolves_when"], x["resolved"]) for x in d["decisions"] if x["id"]=="D-002"]')" "[([{'kind': 'tag_at_head', 'repo': '.', 'name': 'v-future'}, {'kind': 'branch_in_sync', 'repo': '.'}], False)]"
pub 'J["decisions"]=[{k: x[k] for k in ("id","q","options","recommended","default","hard_rule","deadline","ready","resolves_when") if k in x} for x in json.load(open("'"$STAGE"'/pack.json"))["decisions"]]; J["headline"]["text"]="pack copied"'
t_pre "OV-R3-1: the pack's decisions copied verbatim (resolves_when included) into the judgement publish" "$eo" "PM_EMBED_OK"
t_eq "OV-R3-1: ... and the stored predicate keeps its identity" "$(S '[("tid" in x["resolves_when"][0], x["status"]) for x in d["decisions"] if x["id"]=="D-002"]')" "[(True, 'open')]"
(cd "$R" && git tag v-future); bump; begin
t_not "OV-R3-1: with the tag at HEAD the pack still has no tid (head_tags and predicates)" "$(cat "$STAGE/pack.json")" '"tid"'
t_eq "OV-R3-1: ... the script resolves the named tag by its identity" "$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-002"]')" "[False]"

# ---- OV330-R3-2: a future tag name must be a legal git tag name when the decision is raised
mkrepo ovt2; begin
for nm in 'bad:name' 'a..b' 'bad tag' 'trailing.' 'name.lock' '@{x}' 'a/.b' 'x~1' 'x^y' 'q?' 'st*r' '.lead' 'sl//ash' 'end/'; do
  rej "OV-R3-2: future tag name '$nm' is refused" 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_at_head","repo":".","name":"'"$nm"'"}]' "is not a legal git tag name" full
done
rej "OV-R3-2: a lone @ is refused" 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_at_head","repo":".","name":"@"}]' "is not a legal git tag name" full
pub 'J["decisions"][1]["resolves_when"]=[{"kind":"tag_at_head","repo":".","name":"release/v-2.0_rc1"}]' full
t_pre "OV-R3-2: a legal future tag name (with a slash) is accepted" "$eo" "PM_EMBED_OK"
t_eq "OV-R3-2: ... and stored with its identity" "$(S '[x["resolves_when"][0]["name"] for x in d["decisions"] if x["id"]=="D-002"]')" "['release/v-2.0_rc1']"
cat > "$T/ov_unit7.py" <<'PY'
import os, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
import pm_git as G
root = os.path.realpath(tempfile.mkdtemp(prefix="ovunit7.", dir=sys.argv[2]))
subprocess.run(["git", "init", "-q", "-b", "main", root], check=True)
snap = {"repos": [{"path": ".", "vcs": "git", "release": {"head_tags": [], "sync": {"state": "aligned"}}}], "commits": {"days": []}}
P = lambda n: [{"kind": "tag_at_head", "repo": ".", "name": n}]
res = [bool(V.predicates_in_snapshot(root, snap, P(n))) for n in ("bad:name", "a..b", "bad tag", "trailing.", "name.lock", "@{x}", "v-future", "release/1")]
# the git leg alone: a name the Python rules accept but git refuses is still refused (simulated by patching the Python rule)
real = G.tag_name_problem
G.tag_name_problem = lambda n: None
res.append(bool(V.predicates_in_snapshot(root, snap, P("a..b"))))
res.append(bool(V.predicates_in_snapshot(root, snap, P("v-future"))))
G.tag_name_problem = real
# git cannot say (tag_name_git_ok -> None): the Python verdict stands
G.tag_name_git_ok = lambda r, n: None
res.append(bool(V.predicates_in_snapshot(root, snap, P("v-future"))))
res.append(bool(V.predicates_in_snapshot(root, snap, P("a..b"))))
print(res)
PY
t_eq "OV-R3-2: unit: Python rules and real git both refuse; git alone refuses; without git the Python rules stand" "$(python3 -I "$T/ov_unit7.py" "$HOOKS" "$T")" "[True, True, True, True, True, True, False, False, True, False, False, True]"

# ---- OV330-R3-3: an uncommitted answer tail defers a closure by events
ovtail() { # NAME: D-002 waits for v1.0.0 + sync, the repository got both, a staged judgement closes D-002 by events
  mkproj "$1" "$(ovraise "$RW_TP,$RW_SY")" || true
  ovpush "$1"; bump; begin
}
# (a) the only answer is a complete JSON object without its newline
ovtail ovl1
printf '{"id":"D-002","answer":"hold","by":"owner"}' > "$PM/answers.jsonl"
jud "$INVN" update "$(ovj '')"
eo=$(embed "$INVN")
t_pre "OV-R3-3: a complete answer object without a newline + a closure by events: published" "$eo" "PM_EMBED_OK"
t_has "OV-R3-3: ... with the deferral note" "$eo" "PM_EMBED_NOTE uncommitted answer tail; events closure of D-002 deferred"
t_eq "OV-R3-3: ... D-002 is still open (not overtaken), D-001 unchanged" "$(S '[(x["id"], x["status"]) for x in d["decisions"]]')" "[('D-001', 'open'), ('D-002', 'open')]"
t_eq "OV-R3-3: ... the tail is neither applied nor counted" "$(S '(d["answers"]["applied"], d["answers"]["total"], d["judged_key"]["answers_count"])')" "(0, 0, 0)"
t_eq "OV-R3-3: ... and the state remembers the deferral" "$(S 'd["judged_key"].get("closure_deferred")')" "['D-002']"
t_eq "OV-R3-3: ... answers.jsonl is untouched (no newline added)" "$(wc -c < "$PM/answers.jsonl" | tr -d ' ')" "$(printf '{"id":"D-002","answer":"hold","by":"owner"}' | wc -c | tr -d ' ')"
out=$(facts)
t_has "OV-R3-3: facts warns about the uncommitted last line" "$out" "answers.jsonl has an uncommitted last line"
t_not "OV-R3-3: ... and waits while the tail is still there (no re-judgement yet)" "$out" "NEEDS_JUDGEMENT"
printf '\n' >> "$PM/answers.jsonl"
out=$(facts)
t_pre "OV-R3-3: the newline arrives: the next facts run re-judges" "$out" "NEEDS_JUDGEMENT"
t_has "OV-R3-3: ... because of pending answers" "$out" "pending answers"
t_not "OV-R3-3: ... and the warning is gone" "$out" "uncommitted last line"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "OV-R3-3: ... the staged decision is answered by the owner's now-committed hold" "$(get "$STAGE/snapshot.json" '[(x["status"], x.get("answer")) for x in d["decisions"] if x["id"]=="D-002"]')" "[('answered', 'hold')]"
pub 'J["decisions"][0]["ready"]=True'
t_pre "OV-R3-3: ... the judgement publishes" "$eo" "PM_EMBED_OK"
t_eq "OV-R3-3: ... the owner's answer wins (applied, not bad input)" "$(S '([(x["id"], x["status"], x.get("answer")) for x in d["decisions"] if x["id"]=="D-002"], d["answers"]["applied"], d["answers"]["bad"])')" "([('D-002', 'answered', 'hold')], 1, [])"
# (b) a tail present already when facts staged: warning in the verdict, deferral at publication
ovtail ovl2
printf '{"id":"D-002","ans' > "$PM/answers.jsonl"; bump; begin
t_has "OV-R3-3: facts with an unfinished record on disk warns in its verdict line" "$out" "(warning: answers.jsonl has an uncommitted last line)"
t_eq "OV-R3-3: ... the staged snapshot does not count it" "$(get "$STAGE/snapshot.json" '(d["answers"]["total"], len(d["answers"]["pending"]), d["answers"]["bad"])')" "(0, 0, [])"
t_not "OV-R3-3: ... and the pack does not show the internal flag" "$(cat "$STAGE/pack.json")" '"tail"'
jud "$INVN" update "$(ovj '')"
eo=$(embed "$INVN")
t_has "OV-R3-3: garbage tail: the closure is deferred" "$eo" "PM_EMBED_NOTE uncommitted answer tail; events closure of D-002 deferred"
t_eq "OV-R3-3: ... D-002 published open" "$(S '[(x["id"], x["status"]) for x in d["decisions"]]')" "[('D-001', 'open'), ('D-002', 'open')]"
printf 'wer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
out=$(facts)
t_pre "OV-R3-3: the owner finishes the line: the next facts run re-judges" "$out" "NEEDS_JUDGEMENT"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
pub 'J["decisions"][0]["ready"]=True'
t_eq "OV-R3-3: ... and the finished answer applies" "$(S '[(x["id"], x["status"], x.get("answer")) for x in d["decisions"] if x["id"]=="D-002"]')" "[('D-002', 'answered', 'hold')]"
# (c) the tail is garbage the owner removes: the closure can be made again
ovtail ovl3
printf '{"id":"D-002","ans' > "$PM/answers.jsonl"
jud "$INVN" update "$(ovj '')"; eo=$(embed "$INVN")
t_has "OV-R3-3: tail removed later: setup: deferred" "$eo" "events closure of D-002 deferred"
: > "$PM/answers.jsonl"
out=$(facts)
t_pre "OV-R3-3: ... the tail is removed: the next facts run re-judges (answers pending)" "$out" "NEEDS_JUDGEMENT"
t_has "OV-R3-3: ... with the reason" "$out" "answers pending"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
pub "$(ovj '')"
t_pre "OV-R3-3: ... and the closure by events is made now" "$eo" "PM_EMBED_OK"
t_eq "OV-R3-3: ... D-002 overtaken, no deferral left in the key" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-002"], "closure_deferred" in d["judged_key"])')" "(['overtaken'], False)"
# (d) a COMMITTED late answer still wins over the closure even with a tail behind it (no deferral for that decision)
ovtail ovl4
printf '{"id":"D-002","answer":"hold","by":"owner"}\n{"id":"D-001","ans' > "$PM/answers.jsonl"
jud "$INVN" update "$(ovj '')"; eo=$(embed "$INVN")
t_has "OV-R3-3: a committed answer + a tail: the answer wins" "$eo" "PM_EMBED_NOTE owner answer for D-002"
t_not "OV-R3-3: ... and nothing is deferred (the closing decision was won)" "$eo" "deferred"
t_eq "OV-R3-3: ... D-002 answered, no deferral key" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-002"], "closure_deferred" in d["judged_key"])')" "(['answered'], False)"
# (e) no closure, no deferral: a tail alone changes nothing about a normal publication
ovtail ovl5
printf '{"id":"D-002","ans' > "$PM/answers.jsonl"
pub 'J["decisions"][0]["ready"]=True'
t_not "OV-R3-3: a tail without a closure by events: no deferral note" "$eo" "deferred"
t_eq "OV-R3-3: ... and no deferral key" "$(S '"closure_deferred" in d["judged_key"]')" "False"
# (f) mechanical refresh keeps the deferral mark, and the next facts still waits on the tail
ovtail ovl6
printf '{"id":"D-002","answer":"hold","by":"owner"}' > "$PM/answers.jsonl"
jud "$INVN" update "$(ovj '')"; eo=$(embed "$INVN")
t_has "OV-R3-3: mechanical: setup: deferred" "$eo" "events closure of D-002 deferred"
eo=$(embed --mechanical)
t_pre "OV-R3-3: a mechanical refresh publishes" "$eo" "PM_EMBED_OK"
t_eq "OV-R3-3: ... and keeps the deferral mark" "$(S 'd["judged_key"].get("closure_deferred")')" "['D-002']"
printf '\n' >> "$PM/answers.jsonl"
out=$(facts); t_pre "OV-R3-3: ... so the committed answer is still picked up afterwards" "$out" "NEEDS_JUDGEMENT"

# ---- OV330-R4-1: the tail flag and the late answers come from ONE read of answers.jsonl
res=$(python3 - "$HOOKS" "$T" <<'PY'
import sys, json, os
sys.path.insert(0, sys.argv[1]); import pm_collect as K
T = sys.argv[2]; pm = os.path.join(T, "ov-r4-nodir"); assert not os.path.exists(pm)
snap = {"answers": {"total": 0, "total_hash": K.prefix_hash([], 0), "bad": [], "applied": 0, "applied_hash": None}, "decisions": [
    {"id": "D-002", "status": "open", "q": "q", "options": [{"id": "A", "label": "a"}, {"id": "B", "label": "b"}], "default": "hold"}]}
out = []
# 1. with an image the file is never opened (the folder does not even exist)
img = [(1, json.dumps({"id": "D-002", "answer": "A", "at": "2026-10-10T00:00:00Z", "by": "owner"}).encode())]
r = K.late_answers(pm, snap, ["D-002"], image=img); out.append(r["won"] if r else None)
# 2. an empty image: nothing new, no read either
out.append(K.late_answers(pm, snap, ["D-002"], image=[]))
# 3. without an image the file IS read (missing file -> empty -> None)
out.append(K.late_answers(pm, snap, ["D-002"]))
print(json.dumps(out))
PY
)
t_eq "OV-R4-1: late_answers works from the caller's read image (file never opened)" "$res" '[["D-002"], null, null]'
# the embed block performs exactly one read for both checks (static guard against a second read creeping back)
n=$(grep -c "K.read_answers_ex(pm)" "$HOOKS/project-map-embed.py"); t_eq "OV-R4-1: embed reads answers.jsonl once in the closure block" "$n" "1"
t_true "OV-R4-1: embed passes that read to late_answers" "grep -q 'K.late_answers(pm, snap, closing, image=lines)' '$HOOKS/project-map-embed.py'"

# ======================================================================================================
# 14. 3.4.0: make returning easy (RB-*): since, seen, assurance, brief, page (INTERFACES-3.2 section 13)
# ======================================================================================================
HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
rbpage() { PAGE=$(node "$TD/pm_page.js" "$PM/index.html" "$@" 2>&1); }   # [STATE_PATCH_JSON]: what the page JavaScript renders
pj()  { printf '%s' "$PAGE" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(eval(sys.argv[1]))' "$1"; }
ax()  { AXJ=$(lib assure "$PM/state.json" "$1"); }                      # CODE edits the published state in memory, then assurance()
axq() { printf '%s' "$AXJ" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(eval(sys.argv[1]))' "$1"; }
bf()  { lib brief "$PM/state.json" "$1"; }                               # CODE edits the published state in memory, then the brief
RB_D3='J["decisions"].append({"id":"D-003","q":"Third question?","options":[{"id":"A","label":"Yes"},{"id":"B","label":"No"}],"recommended":"A","default":"hold","hard_rule":None,"deadline":None,"ready":True})'
RB_CLOSE='J["decisions"][1]["overtaken"]={"why":"Owner tagged v1.0.0 and pushed by hand"}'
RB_RDY2='J["decisions"][1]["ready"]=True'
RB_SEEN_KEYS="['answers_dropped', 'commits', 'commits_total', 'criteria_cut', 'decisions_cut', 'dirty', 'dirty_total', 'ledger_cut', 'repos_cut', 'watch_moved', 'watch_moved_cut']"

# ---- RB-required: since is required exactly when the pack carries a baseline
mkrepo rb0; begin
t_eq "RB-required: a first map's pack has since null and the seen record (3.6.2: with criteria_cut)" "$(get "$STAGE/pack.json" '(d["since"], sorted(d["seen"]))')" "(None, $RB_SEEN_KEYS)"
t_eq "RB-required: ... and the snapshot has since null too" "$(get "$STAGE/snapshot.json" 'd["since"]')" "None"
rej "RB-required: a first map must not carry since" 'J["since"]={"changes":[],"attention":{"kind":"continue","text":"x","why":"y"}}' "since must be absent or null" full
pub '' full
t_pre "RB-required: a first map without since publishes" "$eo" "PM_EMBED_OK"
t_eq "RB-required: ... state.since is null; judged_seen is the seen of the pack the model read" "$(S '(d["since"], d["judged_seen"]["commits"], d["judged_seen"]["commits_total"])')" "(None, 1, 1)"
t_eq "RB-required: ... the first map is not 'ok': attention was never assessed" "$(S '(d["assurance"]["ok"], d["assurance"]["why"])')" "(False, ['attention not assessed'])"

mkproj rb1 || true
GB=$(gen); AB=$(S 'd["judged_at"]')
bump; begin
t_eq "RB-required: an update's pack carries the baseline: the judged generation, its assessment time, counts, hours" "$(get "$STAGE/pack.json" '(d["since"]["generation"]=="'"$GB"'", d["since"]["assessed_at"]=="'"$AB"'", d["since"]["commits"], d["since"]["dirty"], d["since"]["hours"])')" "(True, True, 0, 1, 0)"
rej "RB-required: an update without since is rejected" 'del J["since"]' "since is required"
rej "RB-required: since:null on an update is rejected" 'J["since"]=None' "since is required"
rej "RB-required: unknown key inside since" 'J["since"]["extra"]=1' "since has unknown keys: extra"
rej "RB-required: unknown key inside a change" 'J["since"]["changes"]=[{"text":"a","state":"uncommitted","x":1}]' "since.changes[1] has unknown keys: x"
rej "RB-required: more than 3 changes" 'J["since"]["changes"]=[{"text":"c%d"%i,"state":"uncommitted"} for i in range(4)]' "since.changes has 4 entries, allowed 0..3"
rej "RB-required: duplicate change texts (case and spacing ignored)" 'J["since"]["changes"]=[{"text":"Same text","state":"uncommitted"},{"text":"same  TEXT","state":"uncommitted"}]' "duplicates another change"
rej "RB-required: a change text over 120 bytes" 'J["since"]["changes"]=[{"text":"x"*121,"state":"uncommitted"}]' "since.changes[1] text must be 1..120 bytes"
rej "RB-required: there is no 'checked' state" 'J["since"]["changes"]=[{"text":"Works","state":"checked"}]' "since.changes[1] state must be one of landed|uncommitted"
rej "RB-required: attention text over 120 bytes" 'J["since"]["attention"]["text"]="x"*121' "since.attention.text must be 1..120 bytes"
rej "RB-required: attention why over 120 bytes" 'J["since"]["attention"]["why"]="x"*121' "since.attention.why must be 1..120 bytes"
rej "RB-required: unknown attention kind" 'J["since"]["attention"]["kind"]="maybe"' "since.attention.kind must be one of decision|continue|waiting|unchecked"
rej "RB-required: more than 3 not_checked entries" 'J["since"]["not_checked"]=["a","b","c","d"]' "since.not_checked has 4 entries, allowed 0..3"
rej "RB-required: a not_checked entry over 80 bytes" 'J["since"]["not_checked"]=["x"*81]' "since.not_checked[1] must be 1..80 bytes"
rej "RB-required: a secret-looking token inside since is refused" 'J["since"]["changes"]=[{"text":"key AKIAIOSFODNN7EXAMPLE added","state":"uncommitted"}]' "looks like it contains a secret"
rej "RB-required: attention id on a kind that is not decision" 'J["since"]["attention"]["id"]="D-001"' "since.attention.id must be absent unless kind is decision"
pub 'J["since"]["not_checked"]=["Nothing here shows the full-model check passes"]'
t_pre "RB-required: a valid since publishes" "$eo" "PM_EMBED_OK"
t_eq "RB-required: ... state.since carries the script counts, the model block and the listed count" "$(S '(sorted(d["since"]), d["since"]["commits"], d["since"]["dirty"], d["since"]["listed"], d["since"]["not_checked"])')" "(['attention', 'changes', 'commits', 'dirty', 'from', 'hours', 'listed', 'not_checked'], 0, 1, 0, ['Nothing here shows the full-model check passes'])"

# ---- RB-landed-ref: landed needs a commit that resolves; uncommitted needs a file ref or none
bump; begin
SHA7=$(git -C "$R" rev-parse --short=7 HEAD)
rej "RB-landed-ref: landed without a ref" 'J["since"]["changes"]=[{"text":"Import landed","state":"landed"}]' "since.changes[1] is landed but has no ref"
rej "RB-landed-ref: landed with a null ref" 'J["since"]["changes"]=[{"text":"Import landed","state":"landed","ref":None}]' "is landed but has no ref"
rej "RB-landed-ref: landed with a file ref in a project that has git" 'J["since"]["changes"]=[{"text":"Import landed","state":"landed","ref":"file:PLAN.md"}]' "is landed: its ref must be commit:<sha7+>, not file:PLAN.md"
rej "RB-landed-ref: landed with a commit that does not exist" 'J["since"]["changes"]=[{"text":"Import landed","state":"landed","ref":"commit:0123456"}]' "commit 0123456 not found in any known repository"
rej "RB-landed-ref: landed with a branch name" 'J["since"]["changes"]=[{"text":"Import landed","state":"landed","ref":"commit:main"}]' "commit ref must be 7-40 hex characters"
rej "RB-landed-ref: uncommitted with a commit ref" 'J["since"]["changes"]=[{"text":"Plan edits","state":"uncommitted","ref":"commit:'"$SHA7"'"}]' "is uncommitted: its ref must be file:<rel>[:line] or null"
rej "RB-landed-ref: uncommitted with a file that does not exist" 'J["since"]["changes"]=[{"text":"Plan edits","state":"uncommitted","ref":"file:nope.md"}]' "since.changes[1] ref: file ref nope.md is not an existing regular file"
rej "RB-landed-ref: uncommitted with a ref outside the project" 'J["since"]["changes"]=[{"text":"Plan edits","state":"uncommitted","ref":"file:../x"}]' "must be a relative path inside the project"
pub 'J["since"]["changes"]=[{"text":"Import landed; nothing here shows it works","state":"landed","ref":"commit:'"$SHA7"'"},{"text":"Plan edits are not committed yet","state":"uncommitted","ref":"file:PLAN.md"},{"text":"Scratch notes added","state":"uncommitted"}]'
t_pre "RB-landed-ref: a landed commit, an uncommitted file and a bare uncommitted change publish" "$eo" "PM_EMBED_OK"
t_eq "RB-landed-ref: ... all three are stored verbatim, most consequential first" "$(S '[(c["state"], c.get("ref")) for c in d["since"]["changes"]]')" "[('landed', 'commit:$SHA7'), ('uncommitted', 'file:PLAN.md'), ('uncommitted', None)]"
t_has "RB-landed-ref: the brief says 'committed, not verified yet' and never 'checked' alone" "$(cat "$PM/brief.txt")" "- Import landed; nothing here shows it works · committed, not verified yet"
t_has "RB-landed-ref: ... and 'uncommitted' for the working-tree work" "$(cat "$PM/brief.txt")" "- Plan edits are not committed yet · uncommitted"
# a project without git: landed may point at a file (that is all the evidence there is)
rm -rf "$T/rbng"; mkdir -p "$T/rbng"; R=$(cd "$T/rbng" && pwd -P); PM="$R/.project-map"; seq 1 300 > "$R/PLAN.md"; seq 1 200 > "$R/REVIEW-LOG.md"; echo r > "$R/README.md"
begin; pub '' full
t_pre "RB-landed-ref: a project without git maps" "$eo" "PM_EMBED_OK"
echo more >> "$R/PLAN.md"; begin
rej "RB-landed-ref: without git a commit ref cannot resolve" 'J["since"]["changes"]=[{"text":"Plan landed","state":"landed","ref":"commit:0123456"}]' "not found in any known repository"
rej "RB-landed-ref: without git a landed file ref must still be a real file" 'J["since"]["changes"]=[{"text":"Plan landed","state":"landed","ref":"file:nope.md"}]' "since.changes[1] ref: file ref nope.md is not an existing regular file"
pub 'J["since"]["changes"]=[{"text":"Plan landed","state":"landed","ref":"file:PLAN.md"}]'
t_pre "RB-landed-ref: without git a landed file ref publishes" "$eo" "PM_EMBED_OK"

# ---- RB-attention-decision: a ready open decision is always the primary attention
mkproj rb2 "$(ovraise "$RW_TP,$RW_SY" "$RB_RDY2")" || true
t_eq "RB-attention: setup: D-001 is not ready, D-002 is open and ready" "$(S '[(x["id"], x["status"], x["ready"]) for x in d["decisions"]]')" "[('D-001', 'open', False), ('D-002', 'open', True)]"
bump; begin
rej "RB-attention: an open ready decision + continue is rejected" 'J["since"]["attention"]={"kind":"continue","text":"Work goes on","why":"Nothing blocks it"}' "since.attention.kind must be decision (id D-002): D-002 open and ready"
rej "RB-attention: ... waiting is rejected too" 'J["since"]["attention"]={"kind":"waiting","text":"Waiting for CI","why":"CI is slow"}' "since.attention.kind must be decision (id D-002)"
rej "RB-attention: ... and unchecked" 'J["since"]["attention"]={"kind":"unchecked","text":"Not sure","why":"No data"}' "since.attention.kind must be decision (id D-002)"
rej "RB-attention: kind decision needs an id" 'J["since"]["attention"]={"kind":"decision","text":"Decide","why":"It blocks"}' "since.attention.id is required when kind is decision"
rej "RB-attention: an id that is open but not ready (ready:false) is not eligible" 'J["since"]["attention"]={"kind":"decision","id":"D-001","text":"Decide","why":"It blocks"}' "since.attention.id D-001 is not an open decision that needs the owner (open and ready: D-002)"
rej "RB-attention: an id that does not exist is not eligible" 'J["since"]["attention"]={"kind":"decision","id":"D-009","text":"Decide","why":"It blocks"}' "since.attention.id D-009 is not an open decision"
rej "RB-attention: a malformed id" 'J["since"]["attention"]={"kind":"decision","id":"first","text":"Decide","why":"It blocks"}' "since.attention.id is required when kind is decision: a decision id (D-nnn)"
pub "$RB_RDY2"
t_pre "RB-attention: the open ready decision as the attention publishes" "$eo" "PM_EMBED_OK"
t_eq "RB-attention: ... kept as judged (D-002 is still open and ready: no script replacement)" "$(S '(d["since"]["attention"]["kind"], d["since"]["attention"]["id"], "by" in d["since"]["attention"], "attention_judged" in d["since"])')" "('decision', 'D-002', False, False)"
t_has "RB-attention: ... the brief shows the D line" "$(cat "$PM/brief.txt")" "D-002 needs you:"
t_not "RB-attention: ... and no separate attention line (the D line already says it)" "$(cat "$PM/brief.txt")" "attention:"
# ready:false does not force; a decision closed by overtaken in the same judgement does not force
mkproj rb3 || true
upd ''
t_pre "RB-attention: with only ready:false decisions, continue is accepted" "$eo" "PM_EMBED_OK"
t_eq "RB-attention: ... and stays continue" "$(S 'd["since"]["attention"]["kind"]')" "continue"
mkproj rb4 "$(ovraise "$RW_TP,$RW_SY" "$RB_RDY2")" || true
ovpush rb4; bump; begin
rej "RB-attention: D-002 is open and ready and not closed here: continue rejected" 'J["since"]["attention"]={"kind":"continue","text":"Work goes on","why":"Nothing blocks it"}' "since.attention.kind must be decision (id D-002)"
pub "$RB_CLOSE"
t_pre "RB-attention: a decision closed by overtaken in the same judgement does not force (continue publishes)" "$eo" "PM_EMBED_OK"
t_eq "RB-attention: ... D-002 overtaken, attention continue kept" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-002"], d["since"]["attention"]["kind"], "attention_judged" in d["since"])')" "(['overtaken'], 'continue', False)"
# a decision raised in this judgement (ready) forces it as well
mkproj rb5 || true
bump; begin
rej "RB-attention: a decision raised ready in this judgement forces the attention" 'J["decisions"].append({"id":"D-003","q":"Third question?","options":[{"id":"A","label":"Yes"},{"id":"B","label":"No"}],"recommended":"A","default":"hold","hard_rule":None,"deadline":None,"ready":True}); J["since"]["attention"]={"kind":"continue","text":"Work goes on","why":"Nothing blocks it"}' "since.attention.kind must be decision (id D-003)"
pub "$RB_D3"
t_eq "RB-attention: ... and publishes with that decision as the attention" "$(S '(d["since"]["attention"]["kind"], d["since"]["attention"]["id"])')" "('decision', 'D-003')"

# ---- RB-seen: what the model saw is measured on the pack it read
mkproj rbs || true
i=0; while [ $i -lt 60 ]; do git -C "$R" commit -q --allow-empty -m "change $i: a long enough subject so the pack has some weight to it"; i=$((i+1)); done
begin
t_eq "RB-seen: 60 commits since the assessment: commits_total 60, since.commits 60" "$(get "$STAGE/pack.json" '(d["seen"]["commits_total"], d["since"]["commits"])')" "(60, 60)"
t_eq "RB-seen: ... the retained commits are at most 40 and equal the items the pack lists" "$(get "$STAGE/pack.json" 'd["seen"]["commits"] == sum(len(x["items"]) for x in d["commits"]["days"]) and 0 < d["seen"]["commits"] <= 40')" "True"
t_true "RB-seen: ... the pack with its seen record is still <= 8192 bytes" "[ \$(wc -c < $STAGE/pack.json) -le 8192 ]"
SEEN0=$(get "$STAGE/pack.json" 'json.dumps(d["seen"], sort_keys=True)')
pub ''
t_pre "RB-seen: the judgement publishes" "$eo" "PM_EMBED_OK"
t_eq "RB-seen: state.judged_seen is the seen of STAGE/pack.json" "$(S 'json.dumps(d["judged_seen"], sort_keys=True)')" "$SEEN0"
t_eq "RB-seen: since.listed equals the retained commit count" "$(S 'd["since"]["listed"]')" "$(get "$STAGE/pack.json" 'd["seen"]["commits"]')"
t_has "RB-seen: assurance says how many commits the model saw" "$(S 'd["assurance"]["why"]')" "of 60 commits"
t_eq "RB-seen: ... and the assessment is not ok" "$(S 'd["assurance"]["ok"]')" "False"
t_has "RB-seen: brief line 7 carries '<listed> of 60 shown'" "$(grep '^since ' "$PM/brief.txt")" "of 60 shown"
t_has "RB-seen: brief line 2 carries the qualifier (nothing needs the owner, but the model saw part of the work)" "$(sed -n 2p "$PM/brief.txt")" "· current · map read $(get "$STAGE/pack.json" 'd["seen"]["commits"]') of 60 commits"
if [ $HAVE_NODE = 1 ]; then
  rbpage
  t_eq "RB-seen: the page says 'the map read N of 60 commits'" "$(pj '[x for x in d["since"] if " of 60 commits" in x and "map read" in x]')" "['60 commits · 0 uncommitted files · the map read $(get "$STAGE/pack.json" 'd["seen"]["commits"]') of 60 commits']"
  t_eq "RB-seen: ... and the pill is the incomplete-assessment wording, not the denial" "$(pj 'd["pill"]')" "Nothing found that needs you (partial check)"
fi
# a publication that goes through the late-answer path still keeps the seen of the pack the model read
mkproj rbs2 "$(ovraise "$RW_TP,$RW_SY" "$RB_RDY2")" || true
ovpush rbs2; bump; begin
lib mut "$STAGE/pack.json" 'd["seen"]["commits"]=7; d["seen"]["commits_total"]=9'
jud "$INVN" update "$RB_CLOSE"
printf '{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_has "RB-seen: a late answer wins (setup)" "$eo" "PM_EMBED_NOTE owner answer for D-002"
t_eq "RB-seen: ... judged_seen is still the staged file's seen, not a rebuilt pack's" "$(S '(d["judged_seen"]["commits"], d["judged_seen"]["commits_total"], d["since"]["listed"])')" "(7, 9, 7)"
t_eq "RB-seen: ... while the generation's own pack.json is the rebuilt one" "$(get "$PM/current/pack.json" '(d["seen"]["commits"], d["seen"]["commits_total"])')" "(0, 0)"
# a pack without a (valid) seen record: unknown coverage, never a guess
mkproj rbs3 || true
bump; begin
lib mut "$STAGE/pack.json" 'del d["seen"]'
pub ''
t_eq "RB-seen: a staged pack without seen -> judged_seen null, assurance says pack coverage unknown" "$(S '(d["judged_seen"], d["assurance"]["why"])')" "(None, ['pack coverage unknown'])"
bump; begin
lib mut "$STAGE/pack.json" 'd["seen"]["commits"]="many"'
pub ''
t_eq "RB-seen: ... a malformed seen is treated the same way" "$(S 'd["judged_seen"]')" "None"
bump; begin
lib mut "$STAGE/pack.json" 'd["generation"]="inv-deadbeef"'
pub ''
t_eq "RB-seen: ... and so is a pack stamped for another invocation" "$(S 'd["judged_seen"]')" "None"

# seen is computed on the FINAL pack object and counted in the size check (units on build_pack)
cat > "$T/rb_unit1.py" <<'PYEOF'
import copy, json, os, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_common as C, pm_collect as K
snap = json.load(open(sys.argv[2]))
snap["generation"] = "inv-x"
out = []
def sz(p): return len(C.dumps(p).encode())
# 1. every size the pending-answer count can produce stays inside the cap WITH seen (seen is never added after the last check)
ok, seen_in_every, edge = True, True, 0
for n in range(0, 140, 3):
    s = copy.deepcopy(snap)
    s["answers"]["pending"] = [{"id": "D-001", "answer": "A", "at": None, "by": "owner", "note": "n" * 100, "line": i} for i in range(n)]
    s["answers"]["total"] = n
    try:
        p = K.build_pack(s, "inv-x")
    except K.PackOverflow:
        continue
    ok = ok and sz(p) <= 8192
    seen_in_every = seen_in_every and K.valid_seen(p.get("seen"))
    edge += 1 if p["trimmed"]["answers"] and sz(p) > 8192 - 400 else 0
out += [ok, seen_in_every, edge > 0]   # the sweep reaches packs within 400 bytes of the cap that had to drop answers
# 2. a pack too big for any early step: every omission field is measured on the FINAL pack
s = copy.deepcopy(snap)
s["status"]["dirty"] = 134
s["dirty_paths"] = ["f%d.txt" % i for i in range(20)]
s["commits"] = {"count": 500, "listed": 40, "flagged": 0, "days": [{"day": "2026-10-10", "n": 40, "items": [{"r": ".", "h": "%07x" % i, "s": "subject %d" % i} for i in range(40)]}]}
s["decisions"] = [{"id": "D-00%d" % i, "status": "open", "q": "q" * 300, "options": [{"id": "A", "label": "a"}, {"id": "B", "label": "b" * 90}], "default": "hold"} for i in range(1, 4)]
s["answers"]["pending"] = [{"id": "D-001", "answer": "A", "at": None, "by": "owner", "note": "n" * 5000, "line": i} for i in range(1, 40)]
s["ledger"] = {"path": "/x/l.md", "name": "l", "goal": "g" * 900, "now": "n", "next": "x", "blockers": "b", "hash": "h"}
s["repos"] = [dict(copy.deepcopy(s["repos"][0]), path="r%d" % i) for i in range(11)]
for r in s["repos"]:
    r["pad"] = "p" * 600   # nothing trims this: the repos list itself has to be cut
p = K.build_pack(s, "inv-x")
se = p["seen"]
out.append([se["commits_total"] == 500, se["commits"] == sum(len(x["items"]) for x in p["commits"]["days"]) < 40, se["dirty_total"] == 134, se["dirty"] == len(p["dirty_paths"]) <= 20, se["decisions_cut"] >= 1,
            se["answers_dropped"] == 39, se["ledger_cut"] is True, se["repos_cut"] == 11 - len(p["repos"]) > 0, sz(p) <= 8192])
# 3. watch_moved against the judged key; watch_moved_cut counts what ANY step removed (the whole-list drop included)
s = copy.deepcopy(snap)
paths = ["w/%03d/%s.md" % (i, "z" * 150) for i in range(40)]
s["watch"] = [{"path": q, "kind": "file", "hash": "h%d" % i * 8, "n": 1} for i, q in enumerate(paths)]
s["key"]["watch_hashes"] = {q: "a%d" % i for i, q in enumerate(paths)}
s["prev_key"] = dict(s["key"], watch_hashes=dict(s["key"]["watch_hashes"]))
s["prev_key"]["watch_hashes"][paths[3]] = "old"           # moved
s["prev_key"]["watch_hashes"][paths[7]] = "partial"      # a partial hash is not a move
s["prev_key"]["watch_hashes"].pop(paths[9])               # a path the judged key did not have is not a move
s["decisions"] = [{"id": "D-00%d" % i, "status": "open", "q": "q" * 140, "options": [{"id": "A", "label": "a" * 60}, {"id": "B", "label": "b" * 60}], "default": "hold"} for i in range(1, 7)]
s["ledger"] = {"path": "/x/l.md", "name": "l", "goal": "g" * 200, "now": "n" * 200, "next": "x" * 200, "blockers": "b" * 200, "hash": "h"}
p = K.build_pack(s, "inv-x")
out.append((p["seen"]["watch_moved"], p["watch"], p["seen"]["watch_moved_cut"], sz(p) <= 8192))
# 4. a pack where the watch list survives lists the moved path: nothing cut
s2 = copy.deepcopy(snap)
s2["watch"] = [{"path": "README.md", "kind": "file", "hash": "h", "n": 1}]
s2["key"]["watch_hashes"] = {"README.md": "new"}
s2["prev_key"] = dict(s2["key"], watch_hashes={"README.md": "old"})
p2 = K.build_pack(s2, "inv-x")
out.append((p2["seen"]["watch_moved"], p2["seen"]["watch_moved_cut"]))
# 5. no judged key (first map): nothing moved
s3 = copy.deepcopy(snap); s3["prev_key"] = None
out.append(K.build_pack(s3, "inv-x")["seen"]["watch_moved"])
print(json.dumps(out))
PYEOF
mkproj rbu || true; bump; begin
t_eq "RB-seen-units: the cap holds with seen counted; every omission field is measured on the final pack; watch moves and cuts" "$(python3 -I "$T/rb_unit1.py" "$HOOKS" "$STAGE/snapshot.json")" '[true, true, true, [true, true, true, true, true, true, true, true, true], [1, [], 1, true], [1, 0], 0]'
cat > "$T/rb_unit2.py" <<'PYEOF'
import json, os, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V, pm_render as R
S = json.load(open(sys.argv[2]))
out = []
# the omitted-work phrases are short and the assurance carries them; every field alone flips ok
base = V.assurance(S)
out.append(base["ok"])
for k, v in (("commits", 12), ("dirty", 3), ("decisions_cut", 2), ("answers_dropped", 1), ("ledger_cut", True), ("repos_cut", 2), ("watch_moved_cut", 1)):
    T = json.loads(json.dumps(S))
    T["judged_seen"].update(commits_total=30, dirty_total=9)
    T["judged_seen"][k] = v
    if k != "commits": T["judged_seen"]["commits"] = 30
    if k != "dirty": T["judged_seen"]["dirty"] = 9
    a = V.assurance(T)
    out.append((k, a["ok"], a["why"][0], all(len(w.encode()) <= 40 for w in a["why"])))
print(json.dumps(out))
PYEOF
upd ''
t_eq "RB-seen-units: each field of seen alone makes the assurance not ok, with a reason of at most 40 bytes" "$(python3 -I "$T/rb_unit2.py" "$HOOKS" "$PM/state.json")" '[true, ["commits", false, "map read 12 of 30 commits", true], ["dirty", false, "map read 3 of 9 changed files", true], ["decisions_cut", false, "2 decisions only partly read", true], ["answers_dropped", false, "1 answers not read", true], ["ledger_cut", false, "ledger only partly read", true], ["repos_cut", false, "2 repos not read", true], ["watch_moved_cut", false, "1 changed watch files not read", true]]'

# ---- RB-assurance: ONE predicate; each clause flips ok; the three-way wording in the page and the brief
mkproj rba || true
upd ''
ax ''
t_eq "RB-assurance: a complete judged update is ok: case b, 'Nothing needs you'" "$(axq '(d["assurance"]["ok"], d["assurance"]["why"], d["case"], d["text"])')" "(True, [], 'b', 'Nothing needs you')"
t_eq "RB-assurance: ... and the stored state agrees with the function" "$(S '(d["assurance"]["ok"], d["assurance"]["why"])')" "(True, [])"
ax 'd["decisions"][0]["ready"]=True'
t_eq "RB-assurance: a ready open decision -> not ok, case a, 'Needs you'" "$(axq '(d["assurance"]["ok"], d["assurance"]["why"], d["case"], d["text"])')" "(False, ['decision open'], 'a', 'Needs you')"
ax 'd["decisions"][0]["ready"]=False'
t_eq "RB-assurance: ready:false does not count as a decision open" "$(axq 'd["assurance"]["ok"]')" "True"
ax 'd["stale"]={"judged_at":"x","commits_since":2,"why":"2 new commits"}'
t_eq "RB-assurance: stale -> not ok: case c, the reason names the stale why" "$(axq '(d["assurance"]["ok"], d["assurance"]["why"], d["case"], d["text"])')" "(False, ['assessment behind: 2 new commits'], 'c', 'Nothing found that needs you (partial check)')"
ax 'd["coverage"]["coverage"]="partial"'
t_eq "RB-assurance: partial coverage -> not ok" "$(axq '(d["assurance"]["ok"], d["assurance"]["why"])')" "(False, ['coverage partial'])"
ax 'd["repos"][0]["release"].setdefault("key", {})["unverified"]=True'
t_eq "RB-assurance: an unverified release entry -> not ok" "$(axq '(d["assurance"]["ok"], d["assurance"]["why"])')" "(False, ['tags unverified'])"
ax 'd["repos"][0]["release"].setdefault("key", {})["partial"]=True'
t_eq "RB-assurance: a partial release entry -> not ok" "$(axq 'd["assurance"]["why"]')" "['tags unverified']"
ax 'd["status"]["git_error"]="boom"'
t_eq "RB-assurance: a git error -> not ok" "$(axq '(d["assurance"]["ok"], d["assurance"]["why"])')" "(False, ['git error'])"
ax 'd["since"]["attention"]["kind"]="waiting"'
t_eq "RB-assurance: attention waiting -> not ok" "$(axq '(d["assurance"]["ok"], d["assurance"]["why"])')" "(False, ['attention: waiting'])"
ax 'd["since"]["attention"]["kind"]="unchecked"'
t_eq "RB-assurance: attention unchecked -> not ok" "$(axq 'd["assurance"]["why"]')" "['attention: not fully checked']"
ax 'd["since"]=None'
t_eq "RB-assurance: no attention block at all -> not ok (never assessed)" "$(axq 'd["assurance"]["why"]')" "['attention not assessed']"
ax 'd["judged_seen"]["commits_total"]=30; d["judged_seen"]["commits"]=12'
t_eq "RB-assurance: 12 of 30 commits shown -> not ok, with the number" "$(axq 'd["assurance"]["why"]')" "['map read 12 of 30 commits']"
ax 'd["judged_seen"]=None'
t_eq "RB-assurance: unknown pack coverage -> not ok" "$(axq 'd["assurance"]["why"]')" "['pack coverage unknown']"
ax 'del d["since"]; del d["judged_seen"]; del d["assurance"]'
t_eq "RB-assurance: a state from before 3.4 (no since, seen or assurance) is assessed, never assumed fine" "$(axq 'd["assurance"]["why"]')" "['attention not assessed', 'pack coverage unknown']"
ax 'd["decisions"][0]["ready"]=True; d["stale"]={"judged_at":"x","commits_since":2,"why":"2 new commits"}'
t_eq "RB-assurance: a ready open decision + stale -> 'Needs you', never the denial" "$(axq '(d["case"], d["text"], d["assurance"]["why"][:2])')" "('a', 'Needs you', ['decision open', 'assessment behind: 2 new commits'])"
# the same wording in brief line 2: current / behind, with and without the qualifier (case c only)
t_eq "RB-brief-2: ok and current: no qualifier" "$(bf '' | sed -n 2p | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{5}/T/g')" "as of T · assessed T · current"
t_eq "RB-brief-2: case c and current: the first reason qualifies it" "$(bf 'd["coverage"]["coverage"]="partial"; d["assurance"]=None' | sed -n 2p | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{5}/T/g')" "as of T · assessed T · current · coverage partial"
t_eq "RB-brief-2: ... a reason is cut to 40 bytes with a marker, never mid-line" "$(bf 'd["assurance"]={"ok":False,"why":["x"*100]}' | sed -n 2p | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{5}/T/g')" "as of T · assessed T · current · $(printf 'x%.0s' $(seq 1 37))..."
t_eq "RB-brief-2: behind: the stale reason, once (the qualifier does not repeat it)" "$(bf 'd["stale"]={"judged_at":"x","commits_since":2,"why":"2 new commits"}; d["assurance"]=None' | sed -n 2p | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{5}/T/g')" "as of T · assessed T · behind: 2 new commits"
t_eq "RB-brief-2: behind and another reason: 'behind: ... · <that reason>'" "$(bf 'd["stale"]={"judged_at":"x","commits_since":2,"why":"2 new commits"}; d["coverage"]["coverage"]="partial"; d["assurance"]=None' | sed -n 2p | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{5}/T/g')" "as of T · assessed T · behind: 2 new commits · coverage partial"
t_eq "RB-brief-2: the stale reason is cut to 60 bytes" "$(bf 'd["stale"]={"judged_at":"x","commits_since":2,"why":"w"*100}; d["assurance"]=None' | sed -n 2p | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{5}/T/g' | sed -E 's/w{57}\.\.\./CUT/')" "as of T · assessed T · behind: CUT"
t_not "RB-brief-2: a ready open decision + stale: case a, no denial and no qualifier" "$(bf 'd["decisions"][0]["ready"]=True; d["stale"]={"judged_at":"x","commits_since":2,"why":"2 new commits"}; d["assurance"]=None' | sed -n 2p)" "· decision open"
# the page: three-way pill and tile, the reasons, the stale line (the real page JavaScript)
if [ $HAVE_NODE = 1 ]; then
  rbpage
  t_eq "RB-assurance page: ok -> 'Nothing needs you', tile 'Nothing'" "$(pj '(d["error"], d["pill"], d["count"], d["note"])')" "(None, 'Nothing needs you', 'Nothing', '')"
  rbpage '{"decisions":[{"id":"D-001","status":"open","q":"Q?","options":[{"id":"A","label":"a"}],"default":"hold","ready":true}],"stale":{"judged_at":"x","commits_since":1,"why":"1 new commits"},"assurance":{"ok":false,"why":["decision open","assessment behind: 1 new commits"]}}'
  t_eq "RB-assurance page: a ready decision + stale -> 'Needs you', tile 1 decision, stale line kept, never the denial" "$(pj '(d["pill"], d["count"], d["note"], d["stale"])')" "('Needs you', '1', 'decision', ['Assessment may be out of date · 1 new commits'])"
  rbpage '{"assurance":{"ok":false,"why":["coverage partial","map read 12 of 30 commits","attention: waiting"]}}'
  t_eq "RB-assurance page: none open + not ok -> the incomplete wording, tile lists the first two reasons" "$(pj '(d["pill"], d["count"], d["note"])')" "('Nothing found that needs you (partial check)', 'None found', 'coverage partial · map read 12 of 30 commits')"
  t_has "RB-assurance page: ... and the snapshot lists every reason" "$(pj '[r for r in d["snapshot"] if r[0]=="Assurance"]')" "coverage partial · map read 12 of 30 commits · attention: waiting"
  rbpage '{"assurance":null,"stale":{"judged_at":"x","commits_since":1,"why":"1 new commits"}}'
  t_eq "RB-assurance page: a state without assurance (before 3.4) keeps the earlier pill" "$(pj 'd["pill"]')" "Assessment may be out of date"
fi

# ---- RB-baseline: the baseline is the previous assessment; a mechanical refresh keeps it
mkproj rbb || true
G0=$(gen); JA0=$(S 'd["judged_at"]')
upd ''
t_eq "RB-baseline: since.from is the previous generation and its assessment time" "$(S '(d["since"]["from"]["generation"], d["since"]["from"]["assessed_at"])')" "$(printf "('%s', '%s')" "$G0" "$JA0")"
JA1=$(S 'd["judged_at"]'); G1=$(gen)
upd ''
t_eq "RB-baseline: after a second judgement the baseline moves to the first one's assessment" "$(S '(d["since"]["from"]["generation"], d["since"]["from"]["assessed_at"])')" "$(printf "('%s', '%s')" "$G1" "$JA1")"
git -C "$R" add -A; git -C "$R" commit -qm settle; begin; pub ''
t_eq "RB-baseline: a judgement on a clean tree: 1 commit, 0 uncommitted files" "$(S '(d["since"]["commits"], d["since"]["dirty"])')" "(1, 0)"
SB=$(S 'json.dumps([d["since"], d["judged_seen"]], sort_keys=True)'); JA2=$(S 'd["judged_at"]')
echo x > "$R/rb-scratch.txt"; out=$(facts)
t_pre "RB-baseline: a new file: the verdict re-judges" "$out" "NEEDS_JUDGEMENT"
t_eq "RB-baseline: ... the refresh that flagged the map stale kept since and judged_seen as they were" "$(S 'json.dumps([d["since"], d["judged_seen"]], sort_keys=True)')" "$SB"
t_eq "RB-baseline: ... and the assurance was recomputed from the new stale record" "$(S '(d["stale"] is not None, d["assurance"]["ok"], d["assurance"]["why"][0].startswith("assessment behind"))')" "(True, False, True)"
t_true "RB-baseline: ... the brief says 'behind: ...' on line 2" "sed -n 2p $PM/brief.txt | grep -q ' · behind: '"
rm -f "$R/rb-scratch.txt"; out=$(facts)
t_pre "RB-baseline: the new file is gone: the stale flag clears without a judgement" "$out" "NEEDS_REFRESH stale cleared"
t_eq "RB-baseline: ... and the assurance is ok again" "$(S '(d["stale"], d["assurance"]["ok"])')" "(None, True)"
t_eq "RB-baseline: ... and since is still the judged batch's" "$(S 'json.dumps([d["since"], d["judged_seen"]], sort_keys=True)')" "$SB"
t_eq "RB-baseline: the refreshes moved the snapshot time but never the assessment time" "$(S '(d["identity"]["snapshot_at"] != "'"$JA2"'", d["judged_at"] == "'"$JA2"'")')" "(True, True)"
upd ''
t_eq "RB-baseline: the next judgement's baseline is the previous ASSESSMENT, not the last refresh or visit" "$(S 'd["since"]["from"]["assessed_at"]')" "$JA2"
# a 3.x (legacy) migration has no previous assessment to compare with
mkdir -p "$T/rblg"; R=$(cd "$T/rblg" && pwd -P); PM="$R/.project-map"; lib legacy "$R"
(cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && seq 1 300 > PLAN.md && seq 1 200 > REVIEW-LOG.md && echo r > README.md && git add -A && git commit -qm init)
begin
t_eq "RB-baseline: a migration from 3.x has since null (no previous assessment)" "$(get "$STAGE/snapshot.json" 'd["since"]')" "None"

# ---- RB-brief-max: every capped field at its maximum, six decisions, a 200+ byte folder
rbmax() { # the judgement CODE for the maximal state (name, label, headline, next step, six ready decisions)
  printf '%s' 'J["project"]["name"]="N"*40; J["headline"]["text"]="H"*180; J["headline"]["tone"]="blocked"
P["phases"][1]["label"]="L"*60
J["parts"]=[{"id":"engine","label":"Engine","status":"unknown"}]; J["loops"]=[]; J["risks"]=[]; J["eta"]=None
J["next_step"]={"title":"T"*80,"why":"w","actor":"external","unblocks":[]}
J["decisions"]=[{"id":"D-%03d"%i,"q":"Q%d"%i+"q"*138,"options":[{"id":"A","label":"a"},{"id":"B","label":"b"}],"recommended":"A","default":"hold","hard_rule":None,"deadline":"2030-01-0%dT00:00:00+00:00"%i,"ready":True} for i in range(1,7)]'
}
RBX="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
mkproj "$RBX/$RBX/rbmax" "$(rbmax)" || true
t_true "RB-brief-max: setup: the project folder is over 200 bytes" "[ \${#R} -gt 200 ]"
t_pre "RB-brief-max: the maximal first map publishes" "$eo" "PM_EMBED_OK"
t_true "RB-brief-max: brief <= 1000 bytes including the newline" "[ \$(wc -c < $PM/brief.txt) -le 1000 ]"
t_eq "RB-brief-max: line 1 folder is bounded: an ellipsis and the last components, at most 60 bytes" "$(python3 -c 'import sys;l=open(sys.argv[1],encoding="utf-8").readline().split(" \u00b7 ");print(len(l[1].encode())<=60 and l[1].startswith("\u2026/"))' "$PM/brief.txt")" "True"
t_true "RB-brief-max: lines 1 to 3, the next step and the trailer are all present" "head -1 $PM/brief.txt | grep -q '^NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN · ' && sed -n 2p $PM/brief.txt | grep -q '^as of ' && sed -n 3p $PM/brief.txt | grep -q '^HHHH' && grep -q '^next: TTT' $PM/brief.txt && [ \"\$(tail -1 $PM/brief.txt)\" = 'generation $(gen)' ]"
t_true "RB-brief-max: with six ready decisions the lower lines collapse to '+N more decisions'" "grep -q '^+[0-9] more decisions\$' $PM/brief.txt"
bump; begin
SHAX=$(git -C "$R" rev-parse --short=7 HEAD)
MAXSINCE='J["since"]={"changes":[{"text":"A"+"a"*119,"state":"landed","ref":"commit:'"$SHAX"'"},{"text":"B"+"b"*119,"state":"uncommitted","ref":"file:PLAN.md"},{"text":"C"+"c"*119,"state":"uncommitted"}],"attention":{"kind":"decision","id":"D-001","text":"X"*120,"why":"Y"*120},"not_checked":["n"*80,"m"*80,"k"*80]}'
jud "$INVN" update "$(rbmax); $MAXSINCE"; eo=$(embed "$INVN")
t_pre "RB-brief-max: the maximal update (3 changes, attention, six decisions) publishes" "$eo" "PM_EMBED_OK"
t_true "RB-brief-max: ... brief <= 1000 bytes" "[ \$(wc -c < $PM/brief.txt) -le 1000 ]"
t_true "RB-brief-max: ... line 2, line 3, the next step and the trailer survive every drop" "sed -n 2p $PM/brief.txt | grep -q '^as of ' && sed -n 3p $PM/brief.txt | grep -q '^HHHH' && grep -q '^next: TTT' $PM/brief.txt && [ \"\$(tail -1 $PM/brief.txt)\" = 'generation $(gen)' ]"
t_true "RB-brief-max: ... every line is whole (no D line is cut mid-line)" "! grep -E '^D-[0-9]+ needs you' $PM/brief.txt | grep -v ')\$'"
t_true "RB-brief-max: ... the primary decision's D line is shown and its attention line is omitted" "grep -q '^D-001 needs you' $PM/brief.txt && ! grep -q '^attention:' $PM/brief.txt"
cat > "$T/rb_unit3.py" <<'PYEOF'
import copy, json, os, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_render as R, pm_common as C
S = json.load(open(sys.argv[2]))
# every optional line present: tokens, git, three changes, since, attention (not a decision), overtaken, stale, coverage
S["identity"].update(name="demo", folder="~/d"); S["focus"]["label"] = "Phase"; S["headline"]["tone"] = "ok"; S["assurance"] = None
S["usage"] = {"totals": {"all": 1.5e9, "claude": 1.0e9, "codex": 0.5e9}}
S["repos"][0]["release"] = {"line": "tagged v3.2.3 at HEAD · in sync with origin/main (local tracking state)"}
S["decisions"] = [d for d in S["decisions"] if d["status"] not in ("open", "overdue")]
S["decisions"].append({"id": "D-009", "status": "overtaken", "q": "q", "overtaken_why": "Owner did it by hand", "overtaken_ref": "tag:v1"})
S["stale"] = {"judged_at": "x", "commits_since": 3, "why": "3 new commits"}
S["coverage"] = {"coverage": "partial", "covered": 3, "total": 9}
S["since"] = {"from": {"generation": "g", "assessed_at": "2026-10-10T09:00:00+00:00"}, "commits": 7, "listed": 7, "dirty": 2, "hours": 3,
              "changes": [{"text": "Change %d is about this" % i, "state": "landed" if i == 1 else "uncommitted", "ref": None} for i in (1, 2, 3)],
              "attention": {"kind": "waiting", "text": "Waiting on the vendor", "why": "Nothing moves without it"}, "not_checked": []}
def lines(pad):
    T = copy.deepcopy(S); T["headline"]["text"] = "h" * pad
    return R.brief(T).splitlines()
MARK = [("tokens", lambda L: any(x.startswith("tokens") for x in L)), ("git", lambda L: any(x.startswith("git:") for x in L)),
        ("change3", lambda L: any(x.startswith("- Change 3") for x in L)), ("change2", lambda L: any(x.startswith("- Change 2") for x in L)),
        ("change1", lambda L: any(x.startswith("- Change 1") for x in L)), ("since", lambda L: any(x.startswith("since ") for x in L)),
        ("attention", lambda L: any(x.startswith("attention:") for x in L)), ("overtaken", lambda L: any("overtaken by events" in x for x in L)),
        ("coverage", lambda L: any(x.startswith("coverage partial") for x in L)), ("stale", lambda L: any(x.startswith("stale:") for x in L))]
gone = {}
for pad in range(1, 900):
    L = lines(pad)
    assert len(("\n".join(L) + "\n").encode()) <= 1000 and L[-1].startswith("generation ") and L[1].startswith("as of ")
    for name, f in MARK:
        if name not in gone and not f(L):
            gone[name] = pad
order = [n for n, _ in sorted(gone.items(), key=lambda kv: kv[1])]
full = lines(1)
print(json.dumps([order, len(gone) == len(MARK), [x for x in full if x.startswith("- ")] == ["- Change 1 is about this · committed, not verified yet", "- Change 2 is about this · uncommitted", "- Change 3 is about this · uncommitted"],
                  full.index(next(x for x in full if x.startswith("attention:"))) < full.index(next(x for x in full if x.startswith("next:"))) < full.index(next(x for x in full if x.startswith("since "))) < full.index(next(x for x in full if x.startswith("- Change 1"))) < full.index(next(x for x in full if "overtaken" in x)) < full.index(next(x for x in full if x.startswith("git:"))) < full.index(next(x for x in full if x.startswith("stale:"))) < full.index(next(x for x in full if x.startswith("tokens")))]))
PYEOF
t_eq "RB-brief-max: the drop order is exact: tokens, git, change 3, 2, 1, since, attention, overtaken, coverage, stale (and the display order holds)" "$(python3 -I "$T/rb_unit3.py" "$HOOKS" "$PM/state.json")" '[["tokens", "git", "change3", "change2", "change1", "since", "attention", "overtaken", "coverage", "stale"], true, true, true]'

# ---- RB-page: rows and inert text (the real page JavaScript, no browser)
mkproj rbp || true
bump; begin
SHAP=$(git -C "$R" rev-parse --short=7 HEAD)
pub 'J["since"]["changes"]=[{"text":"<script>alert(1)</script> landed","state":"landed","ref":"commit:'"$SHAP"'"},{"text":"Plan <b>edited</b>","state":"uncommitted","ref":"file:PLAN.md"}]; J["since"]["not_checked"]=["<img src=x onerror=alert(1)>"]'
t_pre "RB-page: markup-looking text in since publishes" "$eo" "PM_EMBED_OK"
t_true "RB-page: the template has a #since section between the header and the tiles, and still no innerHTML" "python3 - $PM/index.html <<'PY'
import sys
h = open(sys.argv[1], encoding='utf-8').read()
a, b, c = h.index('</header>'), h.index('id=\"since\"'), h.index('class=\"tiles\"')
sys.exit(0 if a < b < c and '.innerHTML' not in h else 1)
PY"
t_true "RB-page: the since CSS lives in the existing tokens (card, 1px line border, 16px radius) with a mobile rule" "grep -q '.since{background:var(--card);border:1px solid var(--line);border-radius:16px' $PM/index.html && grep -q '.since{padding:16px' $PM/index.html"
if [ $HAVE_NODE = 1 ]; then
  rbpage
  t_eq "RB-page: the page script ran without error and the section is shown" "$(pj '(d["error"], d["sinceHidden"])')" "(None, False)"
  t_has "RB-page: eyebrow: Since the previous assessment · <date>" "$(pj 'd["since"][0]')" "Since the previous assessment · 20"
  t_eq "RB-page: the count line is '<N> commits · <M> uncommitted files'" "$(pj 'd["since"][1]')" "0 commits · 1 uncommitted files"
  t_eq "RB-page: the attention row, the focus row (3.5.0), the fit row (3.6.0, under the focus row) and both change rows" "$(pj 'd["since"][2:7]')" "['Attention · continue | Work can continue without the owner | Nothing is blocked on you', 'focus: Ship the engine import (proposed, not confirmed)', 'fit: not judged', '<script>alert(1)</script> landed | committed, not verified yet', 'Plan <b>edited</b> | uncommitted']"
  t_eq "RB-page: not checked: ..." "$(pj 'd["since"][7]')" "not checked: <img src=x onerror=alert(1)>"
  t_eq "RB-page: the text from the repository stayed text: no script or iframe element was ever created" "$(pj '(d["scripts"], "img" in d["created"], "script" in d["created"])')" "(0, False, False)"
  mkproj rbp0 || true
  rbpage
  t_eq "RB-page: a first map has no since state: the section stays hidden" "$(pj '(d["sinceHidden"], d["since"])')" "(True, [])"
fi

# ---- RB-reconcile: the attention is reconciled with the decisions that are open AT PUBLICATION (one code path)
rbtail() { # NAME: D-002 (ready, with predicates) is closed by events in the judgement, an uncommitted tail is appended after staging
  mkproj "$1" "$(ovraise "$RW_TP,$RW_SY" "$RB_RDY2")" || true
  ovpush "$1"; bump; begin
}
rbtail rbr1
printf '{"id":"D-002","answer":"hold","by":"owner"}' > "$PM/answers.jsonl"
jud "$INVN" update "$RB_CLOSE"
t_eq "RB-reconcile: setup: the judged attention is continue (D-002 is closed by this judgement)" "$(get "$STAGE/judgement.out.json" 'd["since"]["attention"]["kind"]')" "continue"
eo=$(embed "$INVN")
t_has "RB-reconcile: the closure is deferred behind the uncommitted tail" "$eo" "events closure of D-002 deferred"
t_eq "RB-reconcile: ... D-002 is published open" "$(S '[(x["id"], x["status"]) for x in d["decisions"] if x["id"]=="D-002"]')" "[('D-002', 'open')]"
t_eq "RB-reconcile: ... so since.attention is the script's decision item" "$(S '(d["since"]["attention"]["kind"], d["since"]["attention"]["id"], d["since"]["attention"]["by"], d["since"]["attention"]["why"])')" "('decision', 'D-002', 'script', 'still open at publication')"
t_eq "RB-reconcile: ... its text is the decision's question; the model's block is kept as attention_judged" "$(S '(d["since"]["attention"]["text"]==[x["q"] for x in d["decisions"] if x["id"]=="D-002"][0][:120], d["since"]["attention_judged"]["kind"])')" "(True, 'continue')"
t_has "RB-reconcile: the brief lists D-002 as needing the owner" "$(cat "$PM/brief.txt")" "D-002 needs you:"
t_not "RB-reconcile: ... and does not claim the work can simply continue" "$(cat "$PM/brief.txt")" "Work can continue"
t_eq "RB-reconcile: the assurance is not ok: a decision is open" "$(S '(d["assurance"]["ok"], d["assurance"]["why"][0])')" "(False, 'decision open')"
if [ $HAVE_NODE = 1 ]; then
  rbpage
  t_eq "RB-reconcile: the page's attention row is the decision D-002" "$(pj '(d["attention"], d["pill"], d["since"][2].startswith("Attention · decision D-002"))')" "(['decision'], 'Needs you', True)"
fi
# two committed late answers answer the primary D-001 (and the closing D-002); D-003 stays open: the attention moves to D-003
mkproj rbr2 "$(ovraise "$RW_TP,$RW_SY" 'J["decisions"][0]["ready"]=True; '"$RB_RDY2; $RB_D3")" || true
ovpush rbr2; bump; begin
jud "$INVN" update 'J["decisions"][0]["ready"]=True; '"$RB_RDY2; $RB_D3; $RB_CLOSE"
t_eq "RB-reconcile: setup: the judged primary attention is D-001" "$(get "$STAGE/judgement.out.json" '(d["since"]["attention"]["kind"], d["since"]["attention"]["id"])')" "('decision', 'D-001')"
printf '{"id":"D-002","answer":"hold","by":"owner"}\n{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_has "RB-reconcile: the owner's answers arrived during the judgement and won" "$eo" "PM_EMBED_NOTE owner answer for D-002"
t_eq "RB-reconcile: ... D-001 and D-002 answered, D-003 open" "$(S '[(x["id"], x["status"]) for x in d["decisions"]]')" "[('D-001', 'answered'), ('D-002', 'answered'), ('D-003', 'open')]"
t_eq "RB-reconcile: ... the attention moved to D-003 (script item), the judged D-001 block is kept" "$(S '(d["since"]["attention"]["id"], d["since"]["attention"]["by"], d["since"]["attention"]["text"], d["since"]["attention_judged"]["id"])')" "('D-003', 'script', 'Third question?', 'D-001')"
t_has "RB-reconcile: the brief shows D-003 as needing the owner" "$(cat "$PM/brief.txt")" "D-003 needs you:"
t_not "RB-reconcile: ... and an answered decision is never shown as one that needs the owner" "$(cat "$PM/brief.txt")" "D-001 needs you"
# the primary answered and nothing left: the unchecked fallback, never an answered id rendered as current
mkproj rbr3 "$(ovraise "$RW_TP,$RW_SY" 'J["decisions"][0]["ready"]=True; '"$RB_RDY2")" || true
ovpush rbr3; bump; begin
jud "$INVN" update 'J["decisions"][0]["ready"]=True; '"$RB_RDY2; $RB_CLOSE"
printf '{"id":"D-002","answer":"hold","by":"owner"}\n{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_eq "RB-reconcile: both answered, none left: the attention is the unchecked fallback" "$(S '(d["since"]["attention"]["kind"], "id" in d["since"]["attention"], d["since"]["attention"]["text"], d["since"]["attention"]["why"], d["since"]["attention"]["by"], d["since"]["attention_judged"]["id"])')" "('unchecked', False, 'D-001 was answered after the assessment; attention not reassessed', 'pending the next judgement', 'script', 'D-001')"
t_has "RB-reconcile: ... the brief says so" "$(cat "$PM/brief.txt")" "attention: D-001 was answered after the assessment; attention not reassessed · pending the next judgement"
t_not "RB-reconcile: ... and no D line for the answered decisions" "$(cat "$PM/brief.txt")" "needs you:"
t_eq "RB-reconcile: ... the assurance names the unchecked attention" "$(S 'd["assurance"]["why"]')" "['attention: not fully checked']"
if [ $HAVE_NODE = 1 ]; then
  rbpage
  t_eq "RB-reconcile: the page shows the unchecked row, never an answered id as current" "$(pj '(d["attention"], d["pill"], d["since"][2])')" "(['unchecked'], 'Nothing found that needs you (partial check)', 'Attention · not fully checked | D-001 was answered after the assessment; attention not reassessed | pending the next judgement')"
fi
# a decision the judgement itself flips to ready is not forcing (the STAGED flag decides) and is picked up at publication
mkproj rbr5 || true
upd 'J["decisions"][0]["ready"]=True'
t_pre "RB-reconcile: a judgement that flips D-001 ready while saying continue publishes" "$eo" "PM_EMBED_OK"
t_eq "RB-reconcile: ... and D-001 is the script's attention item, the judged continue kept" "$(S '(d["since"]["attention"]["kind"], d["since"]["attention"]["id"], d["since"]["attention"]["by"], d["since"]["attention_judged"]["kind"])')" "('decision', 'D-001', 'script', 'continue')"
# no replacement when the judged attention still names an open ready decision
mkproj rbr4 "$(ovraise "$RW_TP,$RW_SY" "$RB_RDY2")" || true
bump; begin; pub "$RB_RDY2"
t_eq "RB-reconcile: a judged attention that is still right is kept verbatim (no by, no attention_judged)" "$(S '(d["since"]["attention"]["id"], "by" in d["since"]["attention"], "attention_judged" in d["since"])')" "('D-002', False, False)"

# ---- RB-watch-omitted: cap pressure drops the whole watch list while only watched files moved
cat > "$T/rb_unit4.py" <<'PYEOF'
import copy, json, os, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K, pm_validate as V, pm_render as R
snap = json.load(open(sys.argv[2])); snap["generation"] = "inv-x"
S = json.load(open(sys.argv[3]))
paths = ["w/%03d/%s.md" % (i, "z" * 150) for i in range(40)]
snap["watch"] = [{"path": q, "kind": "file", "hash": "h%d" % i * 8, "n": 1} for i, q in enumerate(paths)]
snap["key"]["watch_hashes"] = {q: "a%d" % i for i, q in enumerate(paths)}
snap["prev_key"] = dict(snap["key"], watch_hashes=dict(snap["key"]["watch_hashes"], **{paths[5]: "old"}))
snap["status"]["dirty"] = 0; snap["dirty_paths"] = []
snap["decisions"] = [{"id": "D-00%d" % i, "status": "open", "q": "q" * 140, "options": [{"id": "A", "label": "a" * 60}, {"id": "B", "label": "b" * 60}], "default": "hold", "ready": False} for i in range(1, 7)]
snap["ledger"] = None   # only watched files moved and only the watch list is lost
p = K.build_pack(snap, "inv-x")
seen = p["seen"]
S["judged_seen"] = dict(seen, commits=seen["commits_total"], dirty=seen["dirty_total"])
S["decisions"] = [d for d in S["decisions"] if d["status"] not in ("open", "overdue")]
S["since"]["attention"] = {"kind": "continue", "text": "x", "why": "y"}
S["stale"] = None; S["coverage"] = {"coverage": "complete", "covered": 1, "total": 1}
S["assurance"] = V.assurance(S)
q = R.brief(S).splitlines()[1].split(" \u00b7 ", 2)[2]
print(json.dumps([p["watch"], seen["watch_moved"], seen["watch_moved_cut"], len(json.dumps(p)) <= 8192, S["assurance"], q.startswith("current"), q.endswith("1 changed watch files not read")]))
PYEOF
mkproj rbw || true; upd ''
bump; begin
t_eq "RB-watch-omitted: only a watched file moved, the cap dropped the whole watch list: cut counted, assurance false, qualifier shown (3.6.2: the dropped checklist items too)" "$(python3 -I "$T/rb_unit4.py" "$HOOKS" "$STAGE/snapshot.json" "$PM/state.json")" '[[], 1, 1, true, {"ok": false, "why": ["1 changed watch files not read", "4 checklist items not shown"]}, true, true]'

# ---- RB-pubwatch: a path the judgement adds to `watch` is hashed at publication; an incomplete check is partial coverage
mkproj rbpw || true; upd ''
t_eq "RB-pubwatch: the baseline update is complete and certified" "$(S '(d["coverage"]["coverage"], d["assurance"]["ok"])')" "('complete', True)"
echo new > "$R/docs/added.md"; bump; begin
cov0=$(get "$STAGE/snapshot.json" '(d["status"]["covered"], d["status"]["total"])')
jud "$INVN" update 'J["watch"]=J.get("watch",[])+["docs/added.md"]'; eo=$(PM_EMBED_WATCH_DEADLINE=0 embed "$INVN")
t_pre "RB-pubwatch: publishes" "$eo" "PM_EMBED_OK gen"
t_eq "RB-pubwatch: the added path's hash is partial in the judged key" "$(S 'd["judged_key"]["watch_hashes"].get("docs/added.md")')" "partial"
t_eq "RB-pubwatch: published coverage is partial and counts the unchecked file" "$(S '(d["coverage"]["coverage"], d["coverage"]["covered"], d["coverage"]["total"])')" "$(python3 -c "import sys; c,t=eval(sys.argv[1]); print(('partial', c, t+1))" "$cov0")"
t_eq "RB-pubwatch: the assurance is not ok, wording case c" "$(S '(d["assurance"]["ok"], d["assurance"]["why"])')" "(False, ['coverage partial'])"
t_eq "RB-pubwatch: brief line 2 carries the coverage qualifier" "$(sed -n 2p "$PM/brief.txt" | sed 's/.* · //')" "coverage partial"
if [ "$HAVE_NODE" = 1 ]; then rbpage; t_eq "RB-pubwatch: the page pill says no decision identified" "$(pj 'd["pill"]')" "Nothing found that needs you (partial check)"; fi
# an added DIRECTORY whose walk is cut before it finds a file: hash partial with nothing counted (0 of 0); the partial hash
# alone must make the coverage partial
upd ''
t_eq "RB-pubwatch-dir: the baseline is complete again" "$(S '(d["coverage"]["coverage"], d["assurance"]["ok"])')" "('complete', True)"
mkdir -p "$R/docs/newdir"; echo x > "$R/docs/newdir/a.md"; bump; begin
cov0=$(get "$STAGE/snapshot.json" '(d["status"]["covered"], d["status"]["total"])')
jud "$INVN" update 'J["watch"]=J.get("watch",[])+["docs/newdir"]'; eo=$(PM_EMBED_WATCH_DEADLINE=0 embed "$INVN")
t_pre "RB-pubwatch-dir: publishes" "$eo" "PM_EMBED_OK gen"
t_eq "RB-pubwatch-dir: the added directory's hash is partial" "$(S 'd["judged_key"]["watch_hashes"].get("docs/newdir")')" "partial"
t_eq "RB-pubwatch-dir: counts unchanged (0 of 0 added), coverage partial" "$(S '(d["coverage"]["coverage"], d["coverage"]["covered"], d["coverage"]["total"])')" "$(python3 -c "import sys; c,t=eval(sys.argv[1]); print(('partial', c, t))" "$cov0")"
t_eq "RB-pubwatch-dir: the assurance is not ok" "$(S '(d["assurance"]["ok"], d["assurance"]["why"])')" "(False, ['coverage partial'])"
t_eq "RB-pubwatch-dir: brief line 2 carries the coverage qualifier" "$(sed -n 2p "$PM/brief.txt" | sed 's/.* · //')" "coverage partial"
if [ "$HAVE_NODE" = 1 ]; then rbpage; t_eq "RB-pubwatch-dir: the page pill says no decision identified" "$(pj 'd["pill"]')" "Nothing found that needs you (partial check)"; fi
# another added path hashed in time keeps the coverage complete and the counts truthful
bump; begin
cov0=$(get "$STAGE/snapshot.json" '(d["status"]["covered"], d["status"]["total"])')
echo new2 > "$R/docs/added2.md"
jud "$INVN" update 'J["watch"]=J.get("watch",[])+["docs/added2.md"]'
eo=$(embed "$INVN")
t_pre "RB-pubwatch: a timely check publishes" "$eo" "PM_EMBED_OK gen"
t_eq "RB-pubwatch: a timely check keeps coverage complete and adds its counts" "$(S '(d["coverage"]["coverage"], d["coverage"]["covered"], d["coverage"]["total"])')" "$(python3 -c "import sys; c,t=eval(sys.argv[1]); print(('complete', c+1, t+1))" "$cov0")"

fi   # PM_FC_ONLY=1 skips sections 0-14 (used for the 3.5.0 mutation checks); the helpers below are self-contained

# ======================================================================================================
# 15. 3.5.0: confirmed focus and handoff (FC-*): intent, F-set, model-free confirmation, handoff.txt (INTERFACES-3.2 section 14)
# ======================================================================================================
HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
rbpage() { PAGE=$(node "$TD/pm_page.js" "$PM/index.html" "$@" 2>&1); }   # [STATE_PATCH_JSON]: what the page JavaScript renders
pj()  { printf '%s' "$PAGE" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(eval(sys.argv[1]))' "$1"; }
bf()  { lib brief "$PM/state.json" "$1"; }                               # CODE edits the published state in memory, then the brief
ax()  { AXJ=$(lib assure "$PM/state.json" "$1"); }
axq() { printf '%s' "$AXJ" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(eval(sys.argv[1]))' "$1"; }
RW_TP='{"kind":"tag_at_head","repo":".","name":"v1.0.0"}'; RW_SY='{"kind":"branch_in_sync","repo":"."}'
ovraise() { printf '%s' 'J["decisions"][1]["resolves_when"]=['"$1"']; '"$2"; }
ovj() { printf '%s' 'J["decisions"][0]["ready"]=True; J["decisions"][1]["overtaken"]={"why":"Owner tagged v1.0.0 and pushed by hand"}; '"$1"; }
ovpush() { (cd "$R" && git tag v1.0.0 && git init -q --bare "$T/$1-origin.git" && git remote add origin "$T/$1-origin.git" && git push -q -u origin main 2>/dev/null); }
FC_O="Ship the engine import"; FC_D="The import runs on the fixture project"   # pm_testlib.PROPOSAL, the fixed proposal every judgement makes
fcset() { # OUTCOME DONE_WHEN [EXCLUSIONS_JSON]: append an F-set line (the owner's record) to answers.jsonl
  python3 - "$PM/answers.jsonl" "$@" <<'PY'
import json, sys
p, o, d = sys.argv[1:4]
r = {"id": "F-set", "answer": o, "note": d, "at": "2026-10-11T10:00:00+03:00", "by": "owner"}
if len(sys.argv) > 4 and sys.argv[4]:
    r["exclusions"] = json.loads(sys.argv[4])
open(p, "a").write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}
fcraw() { printf '%s\n' "$1" >> "$PM/answers.jsonl"; }
fch() { python3 -I -c 'import sys,json;sys.path.insert(0,sys.argv[1]);sys.dont_write_bytecode=True;import pm_common as C;print(C.intent_hash(sys.argv[2],sys.argv[3],json.loads(sys.argv[4]) if len(sys.argv)>4 else []))' "$HOOKS" "$@"; }
fcbg() { # NAME SECONDS COMMAND...: run a command in the background with stdout to $T/NAME.out, wait SECONDS before returning
  local n=$1 w=$2; shift 2; ( "$@" > "$T/$n.out" 2>&1 ) & FCP=$!; BGPIDS="$BGPIDS $FCP"; sleep "$w"
}

if [ "${PM_DR_ONLY:-}" != 1 ]; then   # sections 15 (FC-*) ... up to the `fi` before section 16

# ---- FC-hash: the one identity function
t_eq "FC-hash: sha256[:16] of the canonical JSON [outcome, done_when, sorted exclusions]; NFC; whitespace collapsed; order of exclusions irrelevant" "$(python3 -I - "$HOOKS" <<'PY'
import sys, json, hashlib
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_common as C
h = C.intent_hash
ref = hashlib.sha256(json.dumps(["Ship it", "Done", ["a", "b"]], separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()[:16]
print(json.dumps([h("Ship it", "Done", ["b", "a"]) == ref, len(ref) == 16, h("é", "x") == h("é", "x"), h("a   b\t\nc", "x") == h("a b c", "x"),
                  h(" a ", "x") == h("a", "x"), h("a", "b", ["x", "y"]) == h("a", "b", ["y", "x"]), h("a", "b", ["x"]) != h("a", "b", []),
                  h("a", "b") == h("a", "b", []), h("a", "b") != h("b", "a"), h("a", "b", [" x  y "]) == h("a", "b", ["x y"])]))
PY
)" '[true, true, true, true, true, true, true, true, true, true]'

# ---- FC-required: intent is required on every UPDATE and FULL; the pack reserves it; the state records it
mkrepo fc0; begin
t_eq "FC-required: a first map's pack carries the reserved intent, empty" "$(get "$STAGE/pack.json" 'd["intent"]')" "{'accepted': None, 'proposed': None}"
t_eq "FC-required: ... its snapshot has no intent state yet and the key component is null" "$(get "$STAGE/snapshot.json" '(d["intent"], d["key"]["intent_hash"])')" "({'accepted': None, 'proposed': None, 'target': None}, None)"
t_eq "FC-required: ... the pack key order puts intent before every optional detail" "$(get "$STAGE/pack.json" 'list(d).index("intent") < min(list(d).index(k) for k in ("repos","commits","watch","ledger","answers","decisions","usage"))')" "True"
rej "FC-required: a first map without intent" 'del J["intent"]' "judgement is missing: intent" full
rej "FC-required: a FULL run needs it too: intent is not an object" 'J["intent"]="ship it"' "intent must be an object" full
rej "FC-required: unknown key exclusions (script-owned)" 'J["intent"]["exclusions"]=["no deploy"]' "intent has unknown keys: exclusions" full
rej "FC-required: unknown key hash" 'J["intent"]["hash"]="x"' "intent has unknown keys: hash" full
rej "FC-required: the model cannot write accepted" 'J["intent"]["accepted"]={"outcome":"a","done_when":"b"}' "intent has unknown keys: accepted" full
rej "FC-required: outcome over 120 bytes" 'J["intent"]["outcome"]="x"*121' "intent.outcome must be 1..120 bytes (is 121)" full
rej "FC-required: done_when empty" 'J["intent"]["done_when"]=""' "intent.done_when must be 1..120 bytes (is 0)" full
rej "FC-required: a secret-shaped outcome" 'J["intent"]["outcome"]="deploy with AKIAABCDEFGHIJKLMNOP"' "judgement.intent.outcome looks like it contains a secret" full
rej "FC-required: a bidi override in done_when" 'J["intent"]["done_when"]="a‮b"' "judgement.intent.done_when contains bidirectional override" full
jud "$INVN" full ""; eo=$(embed "$INVN")
t_pre "FC-required: a valid intent publishes" "$eo" "PM_EMBED_OK"
t_eq "FC-required: ... state.intent: no accepted record, the model's text is the proposal and the target, no exclusions" "$(S '(d["intent"]["accepted"], d["intent"]["proposed"]["outcome"], d["intent"]["target"]["outcome"], d["intent"]["target"]["exclusions"], d["intent"]["proposed"]["hash"] == d["intent"]["target"]["hash"])')" "(None, 'Ship the engine import', 'Ship the engine import', [], True)"
t_eq "FC-required: ... the target's hash is the identity of its words" "$(S 'd["intent"]["target"]["hash"]')" "$(fch "$FC_O" "$FC_D" '[]')"
t_eq "FC-required: ... judged_key.intent_hash is the target's hash" "$(S 'd["judged_key"]["intent_hash"] == d["intent"]["target"]["hash"]')" "True"
t_eq "FC-required: ... judgement.json keeps the model's intent verbatim" "$(get "$PM/current/judgement.json" 'd["intent"]')" "{'outcome': 'Ship the engine import', 'done_when': 'The import runs on the fixture project'}"
t_eq "FC-required: ... state.focus keeps its 3.2 meaning (phase, label, done, total, next_step)" "$(S 'sorted(d["focus"])')" "['done', 'label', 'next_step', 'phase', 'total']"
bump; begin
rej "FC-required: an update without intent" 'del J["intent"]' "judgement is missing: intent"
rej "FC-required: an update with unknown intent keys" 'J["intent"]["revision"]=2' "intent has unknown keys: revision"
t_eq "FC-required: the update's pack carries the standing proposal" "$(get "$STAGE/pack.json" 'd["intent"]')" "{'accepted': None, 'proposed': {'outcome': 'Ship the engine import', 'done_when': 'The import runs on the fixture project'}}"

# ---- FC-set: the F-set line (shape, safety), the reducer, "the last one wins", never a decision answer
mkproj fcs || true
fcraw '{"id":"D-001","answer":"hold","exclusions":["x"],"by":"owner"}'
fcraw '{"id":"F-set","answer":"deploy with AKIAABCDEFGHIJKLMNOP","note":"d","by":"owner"}'
fcraw '{"id":"F-set","answer":"Outcome without a note","by":"owner"}'
fcraw '{"id":"F-set","answer":"o","note":"d","exclusions":["a","b","c","d"],"by":"owner"}'
python3 -c 'import json,sys;print(json.dumps({"id":"F-set","answer":"o","note":"d","exclusions":["x"*81],"by":"owner"}))' >> "$PM/answers.jsonl"
python3 -c 'import json,sys;print(json.dumps({"id":"F-set","answer":"o"*121,"note":"d","by":"owner"}))' >> "$PM/answers.jsonl"
fcraw '{"id":"F-set","answer":"o","note":"d","by":"claude"}'
python3 -c 'import json,sys;print(json.dumps({"id":"F-set","answer":"o","note":"a‮b","by":"owner"}))' >> "$PM/answers.jsonl"
fcraw '{"id":"F-set","answer":"o","note":"d","extra":1,"by":"owner"}'
fcraw '{"id":"F-set","answer":"o","note":"d","exclusions":"oops","by":"owner"}'
fcset "Alpha outcome" "Alpha is done" '["no deploy","no schema change"]'
fcset "Bravo outcome" "Bravo is done"
begin
t_pre "FC-set: only F-set lines pending, a different identity: NEEDS_JUDGEMENT focus set by owner" "$out" "NEEDS_JUDGEMENT focus set by owner inv "
t_eq "FC-set: the ten malformed lines are bad, the two valid ones are pending (lines 11 and 12)" "$(get "$STAGE/snapshot.json" '([b["line"] for b in d["answers"]["bad"]], [(a["id"], a["line"]) for a in d["answers"]["pending"]])')" "([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], [('F-set', 11), ('F-set', 12)])"
t_eq "FC-set: exclusions on a D- line: unknown keys" "$(get "$STAGE/snapshot.json" 'd["answers"]["bad"][0]["why"]')" "unknown keys: exclusions"
t_eq "FC-set: a secret-shaped outcome is bad, never stored" "$(get "$STAGE/snapshot.json" 'd["answers"]["bad"][1]["why"]')" "F-set text holds control characters or looks like a secret"
t_eq "FC-set: a missing note is bad" "$(get "$STAGE/snapshot.json" 'd["answers"]["bad"][2]["why"]')" "F-set note (done when) must be a string of 1..120 bytes"
t_eq "FC-set: four exclusions are bad" "$(get "$STAGE/snapshot.json" 'd["answers"]["bad"][3]["why"]')" "F-set exclusions must be at most 3 strings of 1..80 bytes"
t_eq "FC-set: ... so is one over 80 bytes, an outcome over 120, by claude, a bidi character, an extra key, a non-list" "$(get "$STAGE/snapshot.json" '[b["why"][:24] for b in d["answers"]["bad"][4:]]')" "['F-set exclusions must be', 'F-set answer (the outcom', 'by must be \"owner\"', 'F-set text holds control', 'unknown keys: extra', 'F-set exclusions must be']"
t_eq "FC-set: the staged snapshot's intent: accepted is the LAST F-set line (line 12, no exclusions), hash = the identity of its words" "$(get "$STAGE/snapshot.json" '(d["intent"]["accepted"]["outcome"], d["intent"]["accepted"]["line"], d["intent"]["accepted"]["exclusions"], d["intent"]["accepted"]["hash"], d["intent"]["accepted"]["at"])')" "('Bravo outcome', 12, [], '$(fch "Bravo outcome" "Bravo is done" '[]')', '2026-10-11T10:00:00+03:00')"
t_eq "FC-set: ... the key component is the accepted hash" "$(get "$STAGE/snapshot.json" 'd["key"]["intent_hash"] == d["intent"]["accepted"]["hash"]')" "True"
t_eq "FC-set: ... an F-set line is never a decision answer: D-001 is still open, nothing 'unknown or closed decision F-set'" "$(get "$STAGE/snapshot.json" '([x["status"] for x in d["decisions"]], [b["why"] for b in d["answers"]["bad"] if "F-set" in b["why"] and "unknown or closed" in b["why"]])')" "(['open', 'open'], [])"
t_eq "FC-set: ... the pack shows the accepted record (words and exclusions only)" "$(get "$STAGE/pack.json" 'd["intent"]["accepted"]')" "{'outcome': 'Bravo outcome', 'done_when': 'Bravo is done', 'exclusions': []}"
pub ''
t_pre "FC-set: the judgement publishes (the model copied the accepted words)" "$eo" "PM_EMBED_OK"
t_eq "FC-set: ... accepted is Bravo with its line, proposed is null (the model said what the record says), target = accepted" "$(S '(d["intent"]["accepted"]["outcome"], d["intent"]["accepted"]["line"], d["intent"]["proposed"], d["intent"]["target"]["hash"] == d["intent"]["accepted"]["hash"], d["judged_key"]["intent_hash"] == d["intent"]["accepted"]["hash"])')" "('Bravo outcome', 12, None, True, True)"
t_eq "FC-set: ... all twelve lines are consumed (applied 12), the bad ones recorded" "$(S '(d["answers"]["applied"], d["answers"]["total"], d["answers"]["bad"])')" "(12, 12, [1, 2, 3, 4, 5])"
t_eq "FC-set: ... the next facts run is quiet: accepted == target, nothing moved" "$(facts)" "NO_CHANGE nothing moved"
t_not "FC-set: ... and the assurance does not say the focus changed" "$(S 'd["assurance"]["why"]')" "focus changed"

# ---- FC-proposed / FC-ab: a different model text is only a suggestion; the operative intention stays the owner's
mkproj fcp || true
fcset "$FC_O" "$FC_D" '["no deploy"]'
begin; t_pre "FC-proposed: setup: the proposal's words with new exclusions are another identity: judged" "$out" "NEEDS_JUDGEMENT focus set by owner inv "
pub ''
t_eq "FC-proposed: model text == accepted words (the record has exclusions the model cannot set): no proposed; target keeps the exclusions" "$(S '(d["intent"]["accepted"]["exclusions"], d["intent"]["proposed"], d["intent"]["target"]["exclusions"])')" "(['no deploy'], None, ['no deploy'])"
bump; begin >/dev/null
t_eq "FC-proposed: ... the next pack carries accepted with its exclusions and no proposed" "$(get "$STAGE/pack.json" 'd["intent"]')" "{'accepted': {'outcome': 'Ship the engine import', 'done_when': 'The import runs on the fixture project', 'exclusions': ['no deploy']}, 'proposed': None}"
pub 'J["intent"]={"outcome":"Rewrite the importer","done_when":"All fixtures pass"}'
t_pre "FC-proposed: a model text that differs from accepted publishes" "$eo" "PM_EMBED_OK"
t_eq "FC-proposed: ... accepted is unchanged, the model's text is published as proposed, the target is still the accepted record" "$(S '(d["intent"]["accepted"]["outcome"], d["intent"]["proposed"]["outcome"], d["intent"]["target"]["outcome"], d["intent"]["target"]["exclusions"], d["intent"]["target"]["hash"] == d["intent"]["accepted"]["hash"])')" "('Ship the engine import', 'Rewrite the importer', 'Ship the engine import', ['no deploy'], True)"
t_eq "FC-proposed: ... proposed.hash is the identity of the F-set that would confirm it (the accepted exclusions kept)" "$(S 'd["intent"]["proposed"]["hash"]')" "$(fch "Rewrite the importer" "All fixtures pass" '["no deploy"]')"
t_eq "FC-proposed: ... the map is complete: the assurance has no focus reason" "$(S 'd["assurance"]["why"]')" "[]"
t_has "FC-proposed: the brief shows the accepted focus as confirmed, not the proposal" "$(cat "$PM/brief.txt")" "focus: Ship the engine import (confirmed)"
t_not "FC-proposed: ... and never the proposal" "$(cat "$PM/brief.txt")" "Rewrite the importer"
t_has "FC-proposed: the handoff serves the accepted focus and its exclusions" "$(cat "$PM/handoff.txt")" "Not in scope (owner): no deploy"
bump; begin >/dev/null
t_eq "FC-proposed: the next pack carries both: the owner's record and the standing suggestion" "$(get "$STAGE/pack.json" 'd["intent"]')" "{'accepted': {'outcome': 'Ship the engine import', 'done_when': 'The import runs on the fixture project', 'exclusions': ['no deploy']}, 'proposed': {'outcome': 'Rewrite the importer', 'done_when': 'All fixtures pass'}}"
pub 'J["intent"]={"outcome":"Rewrite the importer","done_when":"All fixtures pass"}'
# FC-ab: accepted A, proposed B, the owner confirms B: a different identity than the served intention: never model-free
fcset "Rewrite the importer" "All fixtures pass" '["no deploy"]'
out=$(facts)
t_pre "FC-ab: accepted A, proposed B, F-set B (with the exclusions) -> NEEDS_JUDGEMENT focus set by owner, never model-free" "$out" "NEEDS_JUDGEMENT focus set by owner inv "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FC-ab: ... nothing was consumed by the refresh that flagged the map (applied still 1, A still accepted)" "$(S '(d["answers"]["applied"], d["intent"]["accepted"]["outcome"])')" "(1, 'Ship the engine import')"
t_eq "FC-ab: ... the staged snapshot shows B as the accepted record, the proposal reconciled away, the F-set pending" "$(get "$STAGE/snapshot.json" '(d["intent"]["accepted"]["outcome"], d["intent"]["proposed"], [a["id"] for a in d["answers"]["pending"]])')" "('Rewrite the importer', None, ['F-set'])"
pub ''
t_eq "FC-ab: ... after the judgement B is the accepted record and the target, applied 2" "$(S '(d["intent"]["accepted"]["outcome"], d["intent"]["target"]["outcome"], d["intent"]["proposed"], d["answers"]["applied"], d["judged_key"]["intent_hash"] == d["intent"]["accepted"]["hash"])')" "('Rewrite the importer', 'Rewrite the importer', None, 2, True)"

# ---- FC-confirm-mech / FC-first-confirm: the owner confirms exactly the proposal: no model, nothing staged, nothing re-judged
mkproj fcc || true
G0=$(gen); N0=$(ndirs); JK0=$(S 'json.dumps([d["judged_key"]["intent_hash"], d["judged_at"], d["since"], d["judged_seen"]], sort_keys=True)')
fcset "$FC_O" "$FC_D"
LH=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$PM/answers.jsonl")
out=$(facts); rc=$?
t_eq "FC-confirm-mech: a proposal-only map + the F-set that confirms it -> NEEDS_REFRESH focus confirmed (no inv)" "$rc:$out" "0:NEEDS_REFRESH focus confirmed"
t_eq "FC-confirm-mech: ... no staging dir was created" "$(ndirs)" "$N0"
t_true "FC-confirm-mech: ... one new generation was published" "[ \"\$(gen)\" != \"$G0\" ] && [ \"\$(ngens)\" = 2 ]"
t_eq "FC-confirm-mech: ... accepted is the owner's record (line 1, its time), proposed is gone, target unchanged" "$(S '(d["intent"]["accepted"]["outcome"], d["intent"]["accepted"]["line"], d["intent"]["accepted"]["at"], d["intent"]["proposed"], d["intent"]["target"]["outcome"], d["intent"]["accepted"]["hash"] == d["intent"]["target"]["hash"])')" "('Ship the engine import', 1, '2026-10-11T10:00:00+03:00', None, 'Ship the engine import', True)"
t_eq "FC-confirm-mech: ... applied advanced through exactly the line; the prefix hash verifies against the file" "$(S '(d["answers"]["applied"], d["answers"]["total"], d["answers"]["applied_hash"] == "'"$LH"'")')" "(1, 1, True)"
t_eq "FC-confirm-mech: ... the judged key took the new count; intent_hash, the assessment, since and judged_seen are untouched" "$(S 'json.dumps([d["judged_key"]["intent_hash"], d["judged_at"], d["since"], d["judged_seen"]], sort_keys=True)')" "$JK0"
t_eq "FC-confirm-mech: ... answers_count in the key is 1 and the map is not stale" "$(S '(d["judged_key"]["answers_count"], d["stale"])')" "(1, None)"
t_has "FC-confirm-mech: ... the brief now says confirmed" "$(cat "$PM/brief.txt")" "focus: Ship the engine import (confirmed)"
t_has "FC-confirm-mech: ... and the handoff names the date" "$(cat "$PM/handoff.txt")" "Focus (confirmed 2026-10-11): Ship the engine import"
t_eq "FC-confirm-mech: ... the new generation's snapshot agrees with the state: applied 1, nothing pending" "$(get "$PM/current/snapshot.json" '(d["answers"]["applied"], d["answers"]["pending"], d["intent"]["accepted"]["line"])')" "(1, [], 1)"
t_eq "FC-confirm-mech: ... answers.jsonl was not touched" "$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$PM/answers.jsonl")" "$LH"
t_eq "FC-confirm-mech: the next run is NO_CHANGE (first confirm: intent_hash unchanged, nothing pending)" "$(facts)" "NO_CHANGE nothing moved"
t_eq "FC-first-confirm: ... and the one after it too, with no new generation" "$(facts; ngens)" "NO_CHANGE nothing moved
2"
# a later judgement keeps the owner's record exactly once
upd ''
t_eq "FC-no-double: a later judgement keeps the same record (line 1) and applied stays 1" "$(S '(d["intent"]["accepted"]["line"], d["answers"]["applied"], d["intent"]["proposed"])')" "(1, 1, None)"

# ---- FC-confirm-exclusions: the identity includes the exclusions
mkproj fcx || true
fcset "$FC_O" "$FC_D" '["no deploy","no schema change"]'
begin; t_pre "FC-confirm-exclusions: setup: an accepted record with exclusions is a new identity: judged" "$out" "NEEDS_JUDGEMENT focus set by owner inv "
pub ''
fcset "$FC_O" "  The   import runs on the fixture project " '["no schema change","no deploy"]'
t_eq "FC-confirm-exclusions: the same words (whitespace and exclusion order aside) confirm the served intention: model-free" "$(facts)" "NEEDS_REFRESH focus confirmed"
t_eq "FC-confirm-exclusions: ... the exclusions are kept, the record is the NEW line (2)" "$(S '(d["intent"]["accepted"]["exclusions"], d["intent"]["accepted"]["line"], d["answers"]["applied"])')" "(['no schema change', 'no deploy'], 2, 2)"
fcset "$FC_O" "$FC_D"
out=$(facts)
t_pre "FC-confirm-exclusions: a confirmation that DROPS the exclusions is another identity: NEEDS_JUDGEMENT" "$out" "NEEDS_JUDGEMENT focus set by owner inv "
t_eq "FC-confirm-exclusions: ... nothing was applied by the flagging refresh (applied 2, exclusions kept in the state)" "$(S '(d["answers"]["applied"], d["intent"]["accepted"]["exclusions"])')" "(2, ['no schema change', 'no deploy'])"
mkproj fcx2 || true
fcset "$FC_O" "$FC_D" '["no deploy"]'; begin; pub ''
fcset "$FC_O" "$FC_D" '["no deploy","no schema change"]'
t_pre "FC-confirm-exclusions: ... and one that ADDS an exclusion too" "$(facts)" "NEEDS_JUDGEMENT focus set by owner inv "

# ---- FC-gate: embed re-validates the whole predicate under its lock on ITS image of answers.jsonl (a gated append)
# (a) a D- line appended after facts collected and before the refresh read the file
mkproj fcg1 || true; fcset "$FC_O" "$FC_D"; G0=$(gen)
fcbg fcg1 1 env PM_FACTS_DELAY_AFTER=2 python3 "$HOOKS/project-map-facts.py" "$R"
printf '{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"; wait $FCP
out=$(cat "$T/fcg1.out")
t_pre "FC-gate: a D- line appended meanwhile: the refresh declines, facts re-collects and stages the judgement" "$out" "NEEDS_JUDGEMENT 2 pending answers inv "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_true "FC-gate: ... the decline still published a refresh, and the staging is based on THAT generation" "[ \"\$(gen)\" != \"$G0\" ] && [ \"\$(get $STAGE/invocation.json 'd[\"base\"]')\" = \"\$(gen)\" ]"
t_eq "FC-gate: ... nothing was consumed: applied 0, accepted null" "$(S '(d["answers"]["applied"], d["intent"]["accepted"])')" "(0, None)"
t_eq "FC-gate: ... the staged snapshot carries the line that declined the path AND the new one, both pending" "$(get "$STAGE/snapshot.json" '[a["id"] for a in d["answers"]["pending"]]')" "['F-set', 'D-001']"
t_eq "FC-gate: ... so does the pack the model reads" "$(get "$STAGE/pack.json" '[a["id"] for a in d["answers"]["pending"]]')" "['F-set', 'D-001']"
pub ''
t_eq "FC-gate: ... the judgement consumes both lines: D-001 answered, the focus confirmed, applied 2" "$(S '([(x["id"], x["status"]) for x in d["decisions"] if x["id"]=="D-001"], d["intent"]["accepted"]["line"], d["answers"]["applied"])')" "([('D-001', 'answered')], 1, 2)"
# (b) a DIFFERENT F-set appended meanwhile
mkproj fcg2 || true; fcset "$FC_O" "$FC_D"
fcbg fcg2 1 env PM_FACTS_DELAY_AFTER=2 python3 "$HOOKS/project-map-facts.py" "$R"
fcset "Other outcome" "Other done"; wait $FCP
t_pre "FC-gate: a different F-set appended meanwhile: NEEDS_JUDGEMENT focus set by owner" "$(cat "$T/fcg2.out")" "NEEDS_JUDGEMENT focus set by owner inv "
t_eq "FC-gate: ... the refresh applied nothing" "$(S '(d["answers"]["applied"], d["intent"]["accepted"])')" "(0, None)"
# (c) a bad line appended meanwhile
mkproj fcg3 || true; fcset "$FC_O" "$FC_D"
fcbg fcg3 1 env PM_FACTS_DELAY_AFTER=2 python3 "$HOOKS/project-map-facts.py" "$R"
printf 'this is not json\n' >> "$PM/answers.jsonl"; wait $FCP
out=$(cat "$T/fcg3.out")
t_pre "FC-gate: a bad line appended meanwhile: the fast path is declined (a bad line is no confirmation)" "$out" "NEEDS_JUDGEMENT 1 pending answers inv "
INV=${out##* }; STAGE="$PM/inv-$INV"
t_eq "FC-gate: ... the staged snapshot reports the bad line and keeps the F-set pending" "$(get "$STAGE/snapshot.json" '([b["line"] for b in d["answers"]["bad"]], [a["id"] for a in d["answers"]["pending"]])')" "([2], ['F-set'])"
# (d) `current` moved while the refresh was in flight: SUPERSEDED, nothing consumed
mkproj fcg4 || true; upd ''; fcset "$FC_O" "$FC_D"
OLDG=$(ls -d "$PM"/gen-0000* | head -1 | xargs basename); AL=$(cat "$PM/answers.jsonl")
fcbg fcg4 1.5 env PM_EMBED_PAUSE_BEFORE_PUBLISH=3 python3 "$HOOKS/project-map-facts.py" "$R"
python3 -c "import os,sys;os.symlink(sys.argv[2],sys.argv[1]+'/current.mv');os.rename(sys.argv[1]+'/current.mv',sys.argv[1]+'/current')" "$PM" "$OLDG"; wait $FCP
t_pre "FC-gate: current moved during the --apply-answers refresh: REFRESH_FAILED SUPERSEDED" "$(cat "$T/fcg4.out")" "REFRESH_FAILED SUPERSEDED base "
t_eq "FC-gate: ... nothing was consumed (the line is still pending, the record is not accepted, current is where the other writer put it)" "$(S '(d["answers"]["applied"], d["intent"]["accepted"])'):$(cur):$([ "$(cat "$PM/answers.jsonl")" = "$AL" ] && echo same)" "(0, None):$OLDG:same"
# (e) out of budget
mkproj fcg5 || true; fcset "$FC_O" "$FC_D"
out=$(PM_FACTS_DELAY_AFTER=1 facts --budget 1.6)
t_eq "FC-gate: no budget left for the refresh: NEEDS_REFRESH focus confirmed (deferred: budget), nothing applied" "$out:$(S 'd["answers"]["applied"]')" "NEEDS_REFRESH focus confirmed (deferred: budget):0"
mkproj fcg6 || true; fcset "$FC_O" "$FC_D"; N0=$(ndirs)
fcbg fcg6 1 env PM_FACTS_DELAY_AFTER=1.5 PM_FACTS_DELAY_AFTER_REFRESH=4 python3 "$HOOKS/project-map-facts.py" "$R" --budget 5
printf '{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"; wait $FCP
out=$(cat "$T/fcg6.out")
t_eq "FC-gate: the refresh declined and the budget cannot afford a second collection: deferred, no staging" "$out:$(ndirs)" "NEEDS_JUDGEMENT 1 pending answers (deferred: budget):$N0"
t_eq "FC-gate: ... still nothing consumed" "$(S '(d["answers"]["applied"], d["intent"]["accepted"])')" "(0, None)"
# (g) the predicate inside embed, called directly (the same function facts uses, evaluated on embed's own image)
mkproj fcg7 || true; fcset "$FC_O" "$FC_D"; printf '{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed --mechanical --apply-answers)
t_pre "FC-gate: embed alone, a D- line next to the F-set: the refresh publishes" "$eo" "PM_EMBED_OK"
t_has "FC-gate: ... but applies nothing and says why, after PM_EMBED_OK" "$eo" "PM_EMBED_NOTE answers not applied: the new lines are not a plain confirmation of the focus"
t_eq "FC-gate: ... both lines stay pending (applied 0, accepted null)" "$(S '(d["answers"]["applied"], d["intent"]["accepted"])')" "(0, None)"
mkproj fcg8 || true; fcset "$FC_O" "$FC_D"; printf '{"id":"F-set","answer":"half a lin' >> "$PM/answers.jsonl"
eo=$(embed --mechanical --apply-answers)
t_has "FC-gate: embed alone, an unfinished last line: never applied" "$eo" "PM_EMBED_NOTE answers not applied: answers.jsonl has an uncommitted last line"
t_eq "FC-gate: ... nothing consumed" "$(S 'd["answers"]["applied"]')" "0"
mkproj fcg9 || true; fcset "$FC_O" "$FC_D"; bump
eo=$(embed --mechanical --apply-answers)
t_has "FC-gate: embed alone, the project moved too (a watched file changed): not applied, the reason names what moved" "$eo" "PM_EMBED_NOTE answers not applied: other facts moved: "
t_eq "FC-gate: ... nothing consumed, and the map is flagged stale by the same refresh" "$(S '(d["answers"]["applied"], d["stale"] is not None)')" "(0, True)"
mkproj fcg10 || true; fcset "$FC_O" "$FC_D"
eo=$(embed --mechanical --apply-answers)
t_pre "FC-gate: embed alone, a plain confirmation: applied without a note" "$eo" "PM_EMBED_OK"
t_not "FC-gate: ... no PM_EMBED_NOTE" "$eo" "PM_EMBED_NOTE"
t_eq "FC-gate: ... applied 1, accepted line 1, no stale flag" "$(S '(d["answers"]["applied"], d["intent"]["accepted"]["line"], d["stale"])')" "(1, 1, None)"
# (f) --apply-answers is for the mechanical mode only
out=$(bash "$HOOKS/project-map-embed.sh" "$R" inv-00000000 --apply-answers); t_pre "FC-gate: --apply-answers without --mechanical is a usage error" "$out" "PM_EMBED_ERROR usage:"

# ---- FC-new-judged: a different intention costs one judgement and then stands
mkproj fcn || true
fcset "Collect the benchmark numbers" "Three runs are recorded" '["no new models"]'
out=$(facts); t_pre "FC-new-judged: a new intention: NEEDS_JUDGEMENT focus set by owner" "$out" "NEEDS_JUDGEMENT focus set by owner inv "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FC-new-judged: ... the pack the model reads shows it as the owner's objective" "$(get "$STAGE/pack.json" 'd["intent"]["accepted"]')" "{'outcome': 'Collect the benchmark numbers', 'done_when': 'Three runs are recorded', 'exclusions': ['no new models']}"
pub ''
t_eq "FC-new-judged: ... published: accepted = target, intent_hash rebased to the new identity, applied 1" "$(S '(d["intent"]["accepted"]["hash"] == d["intent"]["target"]["hash"] == d["judged_key"]["intent_hash"], d["intent"]["accepted"]["exclusions"], d["answers"]["applied"])')" "(True, ['no new models'], 1)"
t_eq "FC-new-judged: ... and the next run is quiet" "$(facts)" "NO_CHANGE nothing moved"
t_eq "FC-new-judged: ... the assurance has no focus reason" "$(S '[w for w in d["assurance"]["why"] if "focus" in w]')" "[]"

# ---- FC-mixed: an F-set with a decision answer is never model-free
mkproj fcm || true
fcset "$FC_O" "$FC_D"; printf '{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
out=$(facts)
t_pre "FC-mixed: an F-set that confirms the target + a D- answer: NEEDS_JUDGEMENT (2 pending answers)" "$out" "NEEDS_JUDGEMENT 2 pending answers inv "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FC-mixed: ... the flagging refresh applied nothing (applied 0, accepted null)" "$(S '(d["answers"]["applied"], d["intent"]["accepted"])')" "(0, None)"
t_eq "FC-mixed: ... the staged snapshot has both lines pending, D-001 answered by the lifecycle, the focus accepted" "$(get "$STAGE/snapshot.json" '([a["id"] for a in d["answers"]["pending"]], [x["status"] for x in d["decisions"] if x["id"]=="D-001"], d["intent"]["accepted"]["line"])')" "(['F-set', 'D-001'], ['answered'], 1)"
pub ''
t_eq "FC-mixed: ... the judgement consumes both (applied 2)" "$(S '(d["answers"]["applied"], d["intent"]["accepted"]["line"], [x["status"] for x in d["decisions"] if x["id"]=="D-001"])')" "(2, 1, ['answered'])"
# a decision answer BEFORE the F-set in the file: the F-set line is still not a decision answer, D- keeps its meaning
mkproj fcm2 || true
printf '{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"; fcset "$FC_O" "$FC_D"
out=$(facts); t_pre "FC-mixed: a D- line first, then the F-set: not model-free either" "$out" "NEEDS_JUDGEMENT 2 pending answers inv "

# ---- FC-late: publication re-reads answers.jsonl; every appended line goes through the shared reducer
ovtail() { mkproj "$1" "$(ovraise "$RW_TP,$RW_SY")" || true; ovpush "$1"; bump; begin; }
ovtail fcl1
jud "$INVN" update 'J["decisions"][1]["overtaken"]={"why":"Owner tagged v1.0.0 and pushed by hand"}'   # D-001 stays not ready: nothing needs the owner
fcset "Other outcome" "Other done"; printf '{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
eo=$(embed "$INVN")
t_has "FC-late: an F-set then a winning D- answer arrive while a closure by events is judged: the answer wins" "$eo" "PM_EMBED_NOTE owner answer for D-002"
t_eq "FC-late: ... both lines were reduced: D-002 answered, the F-set is the accepted record (line 1), applied 2 of 2" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-002"], d["intent"]["accepted"]["outcome"], d["intent"]["accepted"]["line"], d["answers"]["applied"], d["answers"]["total"])')" "(['answered'], 'Other outcome', 1, 2, 2)"
t_eq "FC-late: ... the target is the STAGED intention (the model's text), not the late record: they differ" "$(S '(d["intent"]["target"]["outcome"], d["intent"]["accepted"]["hash"] != d["intent"]["target"]["hash"], d["judged_key"]["intent_hash"] == d["intent"]["target"]["hash"])')" "('Ship the engine import', True, True)"
t_eq "FC-late: ... so the assurance says the focus changed after the assessment (and a decision is not open)" "$(S '(d["assurance"]["ok"], [w for w in d["assurance"]["why"] if "focus" in w])')" "(False, ['focus changed after the assessment'])"
t_has "FC-late: ... and line 2 of the brief says so" "$(sed -n 2p "$PM/brief.txt")" "focus changed after the assessment"
t_has "FC-late: ... and so does line 2 of the handoff" "$(sed -n 2p "$PM/handoff.txt")" "focus changed after the assessment"
out=$(facts)
t_pre "FC-late: ... the next facts run re-judges" "$out" "NEEDS_JUDGEMENT focus set by owner"
# an F-set ALONE during a closing judgement is not a late answer: the closure proceeds, the line stays pending
ovtail fcl2
jud "$INVN" update "$(ovj '')"
fcset "$FC_O" "$FC_D"
eo=$(embed "$INVN")
t_pre "FC-late: an F-set alone: the closure by events proceeds" "$eo" "PM_EMBED_OK"
t_not "FC-late: ... without a note" "$eo" "PM_EMBED_NOTE"
t_eq "FC-late: ... D-002 overtaken, the line stays pending (applied 0, accepted null)" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-002"], d["answers"]["applied"], d["intent"]["accepted"])')" "(['overtaken'], 0, None)"
out=$(facts)
t_eq "FC-late: ... and it is a plain confirmation of the target: the next run applies it without a model" "$out" "NEEDS_REFRESH focus confirmed"
t_eq "FC-late: ... applied 1 and the record is accepted" "$(S '(d["answers"]["applied"], d["intent"]["accepted"]["line"])')" "(1, 1)"

# ---- FC-no-double: a line is consumed exactly once, whichever path consumes it; the staging refresh never applies it
mkproj fcd || true
fcset "$FC_O" "$FC_D"; out=$(facts)
t_eq "FC-no-double: setup: the confirmation is applied" "$out" "NEEDS_REFRESH focus confirmed"
A1=$(S 'json.dumps(d["intent"], sort_keys=True)'); H1=$(S 'd["answers"]["applied_hash"]'); G1=$(gen)
eo=$(embed --mechanical --apply-answers)
t_pre "FC-no-double: a second --apply-answers finds nothing after applied: ordinary refresh" "$eo" "PM_EMBED_OK"
t_has "FC-no-double: ... with the note that nothing was applied" "$eo" "PM_EMBED_NOTE answers not applied: no new answer lines"
t_eq "FC-no-double: ... the record, applied and its hash are exactly what they were" "$(S 'json.dumps(d["intent"], sort_keys=True)'):$(S 'd["answers"]["applied_hash"]')" "$A1:$H1"
# the refresh inside NEEDS_JUDGEMENT never applies a line: a staged snapshot carries it as pending
fcset "$FC_O" "$FC_D"; bump; out=$(facts)
t_pre "FC-no-double: a confirming F-set + a repository change: NEEDS_JUDGEMENT (the F-set cannot go model-free next to other news)" "$out" "NEEDS_JUDGEMENT "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FC-no-double: ... the stale-stamping refresh did NOT apply the line (applied still 1)" "$(S '(d["answers"]["applied"], d["intent"]["accepted"]["line"], d["stale"] is not None)')" "(1, 1, True)"
t_eq "FC-no-double: ... the staged snapshot carries it as pending, and accepted is the new record (line 2)" "$(get "$STAGE/snapshot.json" '([a["id"] for a in d["answers"]["pending"]], d["intent"]["accepted"]["line"], d["answers"]["applied"])')" "(['F-set'], 2, 1)"
pub ''
t_eq "FC-no-double: ... the judgement consumes it once: applied 2, accepted line 2" "$(S '(d["answers"]["applied"], d["intent"]["accepted"]["line"])')" "(2, 2)"

# ---- FC-replay: --accept-answers replays the whole file through the one reducer
mkproj fcr || true
fcset "Alpha outcome" "Alpha is done"; printf '{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
fcset "Bravo outcome" "Bravo is done" '["no deploy"]'; printf '{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
bump; begin; pub ''
t_eq "FC-replay: setup: two F-set lines with D- answers between: the last F-set is accepted (line 3), applied 4" "$(S '(d["intent"]["accepted"]["outcome"], d["intent"]["accepted"]["line"], d["answers"]["applied"])')" "('Bravo outcome', 3, 4)"
grep -v '"F-set"' "$PM/answers.jsonl" > "$T/fcr.tmp"; cat "$T/fcr.tmp" > "$PM/answers.jsonl"
out=$(facts); t_pre "FC-replay: the owner removed every F-set line: ERROR answers rewritten" "$out" "ERROR answers rewritten"
out=$(python3 "$HOOKS/project-map-facts.py" --accept-answers "$R"); rc=$?
t_has "FC-replay: --accept-answers says the focus is gone" "$out" "focus after the replay: none (no F-set line)"
t_eq "FC-replay: ... the override in cache.json records accepted null next to applied 0" "$(get "$PM/cache.json" '(d["answers_accept"]["applied"], d["answers_accept"]["accepted"])')" "(0, None)"
bump; begin
t_eq "FC-replay: the next staged snapshot has no accepted record; the pack either" "$(get "$STAGE/snapshot.json" 'd["intent"]["accepted"]'):$(get "$STAGE/pack.json" 'd["intent"]["accepted"]')" "None:None"
pub 'J["decisions"]=[]'
t_eq "FC-replay: after the judgement the accepted focus is gone (null) and the model's text is the proposal; the replayed D- lines are consumed" "$(S '(d["intent"]["accepted"], d["intent"]["proposed"]["outcome"], d["answers"]["applied"])')" "(None, 'Ship the engine import', 2)"
# a replay with two F-set lines and D- lines between: the LAST F-set line, whatever the published state said
mkproj fcr2 || true
fcset "Alpha outcome" "Alpha is done"; printf '{"id":"D-001","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
fcset "Bravo outcome" "Bravo is done" '["no deploy"]'; printf '{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"
out=$(python3 "$HOOKS/project-map-facts.py" --accept-answers "$R")
t_has "FC-replay: a replay of two F-set lines names the last one" "$out" 'focus after the replay: "Bravo outcome" (line 3)'
t_eq "FC-replay: ... stored with its exclusions and line" "$(get "$PM/cache.json" '(d["answers_accept"]["accepted"]["outcome"], d["answers_accept"]["accepted"]["exclusions"], d["answers_accept"]["accepted"]["line"])')" "('Bravo outcome', ['no deploy'], 3)"
bump; begin
t_eq "FC-replay: ... and the staged snapshot starts from it (accepted = Bravo, line 3)" "$(get "$STAGE/snapshot.json" '(d["intent"]["accepted"]["outcome"], d["intent"]["accepted"]["line"], d["answers"]["applied"])')" "('Bravo outcome', 3, 0)"
pub ''
t_eq "FC-replay: ... the published record is Bravo with its exclusions" "$(S '(d["intent"]["accepted"]["outcome"], d["intent"]["accepted"]["exclusions"], d["answers"]["applied"])')" "('Bravo outcome', ['no deploy'], 4)"

# ---- FC-handoff: handoff.txt in every generation: signed, linked, bounded, the decision never denied
RDY2='J["decisions"][1]["ready"]=True'
mkproj fch "$RDY2" || true
fcset "$FC_O" "$FC_D" '["no deploy","no schema change"]'; bump; begin; pub "$RDY2"
t_pre "FC-handoff: setup: a map with a ready decision and an accepted focus with exclusions" "$eo" "PM_EMBED_OK"
t_eq "FC-handoff: handoff.txt is listed in the signed manifest with size and sha256, and the generation verifies" "$(get "$PM/current/manifest.json" '"handoff.txt" in d["files"] and sorted(d["files"]["handoff.txt"]) == ["sha256","size"] and "handoff.txt" in json.load(open("'"$PM"'/current/state.json"))["generation_files"]'):$(python3 -c "import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;print(C.verify_generation('$PM/gen-$(gen)'))")" "True:True"
t_eq "FC-handoff: the fifth stable symlink points into current/" "$(readlink "$PM/handoff.txt")" "current/handoff.txt"
t_true "FC-handoff: <= 1500 bytes including the final newline" "[ \$(wc -c < $PM/handoff.txt) -le 1500 ] && [ \"\$(tail -c 1 $PM/handoff.txt | od -An -c | tr -d ' ')\" = '\\n' ]"
t_eq "FC-handoff: state.handoff is the same text (the page prints it, no second renderer)" "$(S 'd["handoff"] == open("'"$PM"'/current/handoff.txt", encoding="utf-8").read()')" "True"
HF=$(cat "$PM/handoff.txt")
t_pre "FC-handoff: line 1 is 'Handoff · <name> · as of <minute> · assessed <minute>'" "$(sed -n 1p "$PM/handoff.txt")" "Handoff · demo-app · as of 20"
t_pre "FC-handoff: line 2 names the decision that needs the owner (never a denial)" "$(sed -n 2p "$PM/handoff.txt")" "Status: Needs you: D-002 Post another status comment on #12?"
t_eq "FC-handoff: lines 3 to 5: the confirmed focus with its date, what done means, the owner's exclusions" "$(sed -n 3,5p "$PM/handoff.txt")" "Focus (confirmed 2026-10-11): Ship the engine import
Done when: The import runs on the fixture project
Not in scope (owner): no deploy; no schema change"
t_has "FC-handoff: where it stands, since, next, the decisions, the risk, the evidence" "$HF" "Where it stands: "
t_has "FC-handoff: ... since" "$HF" "Since 20"
t_has "FC-handoff: ... next" "$HF" "Next: Finish the cycle-2 diagnosis report (claude): "
t_has "FC-handoff: ... every ready open decision, with its default" "$HF" "Needs the owner: D-002 Post another status comment on #12? (default hold)"
t_has "FC-handoff: ... the highest-severity risk" "$HF" "Open risk: R-1 Router bounds"
t_has "FC-handoff: ... the local git evidence" "$HF" "Evidence: git: "
t_eq "FC-handoff: the last line is the standing reminder: context, not permission" "$(tail -n 1 "$PM/handoff.txt")" "Context only, not permission: no push, delete, spend, deploy or infrastructure change without the owner."
# a stale map with an open decision still names it (Q8): the handoff never denies a known decision
echo x > "$R/fc-scratch.txt"; facts >/dev/null
t_eq "FC-handoff: the map is stale (flagged by the refresh) and the decision is still named on line 2, never 'Nothing needs you'" "$(S 'd["stale"] is not None'):$(sed -n 2p "$PM/handoff.txt" | cut -c1-30)" "True:Status: Needs you: D-002 Post "
rm -f "$R/fc-scratch.txt"
# tampering with the file is caught by the signature like any other generation file
echo tamper >> "$PM/gen-$(gen)/handoff.txt"
t_eq "FC-handoff: an edited handoff.txt makes the generation unverified" "$(python3 -c "import sys;sys.path.insert(0,'$HOOKS');import pm_common as C;print(C.verify_generation('$PM/gen-$(gen)'))")" "False"
# markup-looking text stays text
mkproj fch2 "$RDY2" || true
bump; begin; pub 'J["intent"]={"outcome":"<script>alert(1)</script> & <b>ship</b>","done_when":"<img src=x onerror=alert(1)>"}'
t_pre "FC-handoff: markup-looking intent publishes" "$eo" "PM_EMBED_OK"
t_has "FC-handoff: ... verbatim in the plain-text file" "$(cat "$PM/handoff.txt")" "Focus (proposed, not confirmed): <script>alert(1)</script> & <b>ship</b>"
t_eq "FC-handoff: ... and never raw inside the page's state blob (escaped like all state)" "$(grep -c '<script>alert(1)' "$PM/index.html")" "0"
# unit: the drop order is exact (a cap sweep), the never-dropped lines survive any cap, line 2 keeps the primary decision
cat > "$T/fc_unit1.py" <<'PYEOF'
import copy, json, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_render as R, pm_validate as V
S = json.load(open(sys.argv[2]))
S["identity"].update(name="N" * 40, snapshot_at="2026-10-11T10:00:00+03:00"); S["judged_at"] = "2026-10-11T09:00:00+03:00"
S["intent"] = {"accepted": {"outcome": "O" * 120, "done_when": "W" * 120, "exclusions": ["e" * 80] * 3, "hash": "h", "at": "2026-10-11T10:00:00+03:00", "line": 1},
               "proposed": None, "target": {"outcome": "O" * 120, "done_when": "W" * 120, "exclusions": ["e" * 80] * 3, "hash": "h"}}
S["headline"] = {"text": "H" * 180, "tone": "ok"}
S["next_step"] = {"title": "T" * 80, "why": "Y" * 160, "actor": "external", "unblocks": []}
S["since"] = {"from": {"generation": "g", "assessed_at": "2026-10-10T09:00:00+00:00"}, "commits": 9, "listed": 9, "dirty": 2, "hours": 3,
              "changes": [{"text": "Change%d " % i + "c" * 100, "state": "landed" if i == 1 else "uncommitted", "ref": None} for i in (1, 2, 3)],
              "attention": {"kind": "decision", "id": "D-003", "text": "x", "why": "y"}, "not_checked": []}
S["decisions"] = [{"id": "D-%03d" % i, "status": "open", "ready": True, "q": "Question %d " % i + "q" * 130, "default": "hold",
                   "options": [{"id": "A", "label": "a"}, {"id": "B", "label": "b"}]} for i in range(1, 7)]
S["risks"] = [{"id": "R-1", "text": "r" * 120, "severity": "low"}, {"id": "R-2", "text": "s" * 120, "severity": "high"}, {"id": "R-3", "text": "t" * 120, "severity": "med"}]
S["repos"][0]["release"] = {"line": "g" * 200}
S["assurance"] = None
def lines(cap):
    R.HANDOFF_MAX = cap
    return R.handoff(S).splitlines()
full = lines(10000)
MARK = [("evidence", lambda L: any(x.startswith("Evidence:") for x in L)), ("risk2", lambda L: sum(x.startswith("Open risk:") for x in L) >= 2),
        ("risk1", lambda L: any(x.startswith("Open risk:") for x in L)), ("change3", lambda L: any(x.startswith("- Change3") for x in L)),
        ("change2", lambda L: any(x.startswith("- Change2") for x in L)), ("change1", lambda L: any(x.startswith("- Change1") for x in L)),
        ("since", lambda L: any(x.startswith("Since ") for x in L)), ("where", lambda L: any(x.startswith("Where it stands") for x in L)),
        ("collapse", lambda L: any(x.startswith("Needs the owner:") and "more" in x for x in L)),
        ("needs", lambda L: any(x.startswith("Needs the owner:") for x in L)), ("next", lambda L: any(x.startswith("Next:") for x in L)),
        ("done", lambda L: any(x.startswith("Done when:") for x in L))]
gone, seen_more = {}, None
for cap in range(2700, 0, -1):
    L = lines(cap)
    sz = len(("\n".join(L) + "\n").encode())
    for name, f in MARK:
        if name == "collapse":
            if f(L) and "collapse" not in gone:
                gone["collapse"] = cap   # first cap at which the list is collapsed
        elif name not in gone and not f(L):
            gone[name] = cap
order = [n for n, _ in sorted(gone.items(), key=lambda kv: -kv[1])]
tiny = lines(1)
ok = [x for x in tiny if x.startswith("Handoff · ")] and [x for x in tiny if x.startswith("Status: ")] and [x for x in tiny if x.startswith("Focus (")]
# primary decision: the attention's decision; without it the lowest ready open id
a = lines(1)[1]
T2 = copy.deepcopy(S); T2["since"]["attention"] = {"kind": "continue", "text": "x", "why": "y"}
R.HANDOFF_MAX = 1
b = R.handoff(T2).splitlines()[1]
print(json.dumps([order, len(gone) == len(MARK) + 0, bool(ok), tiny[-1] == R.HANDOFF_GUARD, any(x.startswith("Not in scope (owner): ") for x in tiny),
                  a.startswith("Status: Needs you: D-003 "), b.startswith("Status: Needs you: D-001 "), full[-1] == R.HANDOFF_GUARD,
                  [i for i, x in enumerate(full) if x.startswith(("Handoff", "Status:", "Focus (", "Done when:", "Not in scope", "Where it stands", "Since ", "- Change", "Next:", "Needs the owner:", "Open risk:", "Evidence:", "Context only"))] == list(range(len(full)))]))
PYEOF
t_eq "FC-handoff: the drop order is exact (cap sweep): evidence, second risk, first risk, change 3/2/1, since, where it stands, collapse of the owner list, the list, next, done-when; the never-dropped lines and the primary decision survive any cap" "$(python3 -I "$T/fc_unit1.py" "$HOOKS" "$PM/state.json")" '[["evidence", "risk2", "risk1", "change3", "change2", "change1", "since", "where", "collapse", "needs", "next", "done"], true, true, true, true, true, true, true, true]'

# ---- FC-brief: line 6b, after the next step; dropped after the since line, before the attention line
mkproj fcb || true
t_eq "FC-brief: a proposal-only map: line 6b follows the next step and says how to confirm it" "$(awk '/^next: /{print; getline; print}' "$PM/brief.txt")" "next: Finish the cycle-2 diagnosis report (claude)
focus: Ship the engine import (proposed: say \"confirm focus\")"
fcset "$FC_O" "$FC_D"; facts >/dev/null
t_has "FC-brief: after the confirmation: '(confirmed)'" "$(cat "$PM/brief.txt")" "focus: Ship the engine import (confirmed)"
cat > "$T/fc_unit2.py" <<'PYEOF'
import copy, json, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_render as R
S = json.load(open(sys.argv[2]))
S["identity"].update(name="demo", folder="~/d"); S["focus"]["label"] = "Phase"; S["headline"]["tone"] = "ok"; S["assurance"] = None
S["usage"] = {"totals": {"all": 1.5e9, "claude": 1.0e9, "codex": 0.5e9}}
S["repos"][0]["release"] = {"line": "tagged v3.2.3 at HEAD · in sync with origin/main (local tracking state)"}
S["decisions"] = [d for d in S["decisions"] if d["status"] not in ("open", "overdue")]
S["decisions"].append({"id": "D-009", "status": "overtaken", "q": "q", "overtaken_why": "Owner did it by hand", "overtaken_ref": "tag:v1"})
S["stale"] = {"judged_at": "x", "commits_since": 3, "why": "3 new commits"}
S["coverage"] = {"coverage": "partial", "covered": 3, "total": 9}
S["intent"] = {"accepted": None, "proposed": {"outcome": "F" * 120, "done_when": "d", "hash": "h"}, "target": {"outcome": "F" * 120, "done_when": "d", "exclusions": [], "hash": "h"}}
S["since"] = {"from": {"generation": "g", "assessed_at": "2026-10-10T09:00:00+00:00"}, "commits": 7, "listed": 7, "dirty": 2, "hours": 3,
              "changes": [{"text": "Change %d is about this" % i, "state": "landed" if i == 1 else "uncommitted", "ref": None} for i in (1, 2, 3)],
              "attention": {"kind": "waiting", "text": "Waiting on the vendor", "why": "Nothing moves without it"}, "not_checked": []}
def lines(pad):
    T = copy.deepcopy(S); T["headline"]["text"] = "h" * pad
    return R.brief(T).splitlines()
MARK = [("tokens", lambda L: any(x.startswith("tokens") for x in L)), ("git", lambda L: any(x.startswith("git:") for x in L)),
        ("change3", lambda L: any(x.startswith("- Change 3") for x in L)), ("change2", lambda L: any(x.startswith("- Change 2") for x in L)),
        ("change1", lambda L: any(x.startswith("- Change 1") for x in L)), ("since", lambda L: any(x.startswith("since ") for x in L)),
        ("focus", lambda L: any(x.startswith("focus: ") for x in L)), ("attention", lambda L: any(x.startswith("attention:") for x in L)),
        ("overtaken", lambda L: any("overtaken by events" in x for x in L)), ("coverage", lambda L: any(x.startswith("coverage partial") for x in L)),
        ("stale", lambda L: any(x.startswith("stale:") for x in L))]
gone = {}
for pad in range(1, 900):
    L = lines(pad)
    assert len(("\n".join(L) + "\n").encode()) <= 1000 and L[-1].startswith("generation ") and L[1].startswith("as of ")
    for name, f in MARK:
        if name not in gone and not f(L):
            gone[name] = pad
order = [n for n, _ in sorted(gone.items(), key=lambda kv: kv[1])]
full = lines(1)
idx = lambda p: next(i for i, x in enumerate(full) if x.startswith(p))
print(json.dumps([order, len(gone) == len(MARK), idx("next:") + 1 == idx("focus: ") and idx("focus: ") + 1 == idx("since ")]))
PYEOF
t_eq "FC-brief: the drop order is exact: tokens, git, change 3, 2, 1, since, FOCUS, attention, overtaken, coverage, stale (and 6b sits between next and since)" "$(python3 -I "$T/fc_unit2.py" "$HOOKS" "$PM/state.json")" '[["tokens", "git", "change3", "change2", "change1", "since", "focus", "attention", "overtaken", "coverage", "stale"], true, true]'

# ---- FC-assessed: the focus clause of the ONE assurance predicate
mkproj fca || true; upd ''
ax ''
t_eq "FC-assessed: a complete map with no accepted record has no focus reason" "$(axq 'd["assurance"]["why"]')" "[]"
ax 'd["intent"]["accepted"]={"outcome":"x","done_when":"y","exclusions":[],"hash":"0000000000000000","at":None,"line":1}'
t_eq "FC-assessed: an accepted record that is not the served intention -> not ok, 'focus changed after the assessment', case c" "$(axq '(d["assurance"]["ok"], d["assurance"]["why"], d["case"], d["text"])')" "(False, ['focus changed after the assessment'], 'c', 'Nothing found that needs you (partial check)')"
ax 'd["intent"]["accepted"]=dict(d["intent"]["target"], at=None, line=1)'
t_eq "FC-assessed: ... an accepted record equal to the target is fine" "$(axq 'd["assurance"]["why"]')" "[]"
ax 'del d["intent"]'
t_eq "FC-assessed: ... a state from before 3.5 (no intent) adds no focus reason" "$(axq '[w for w in d["assurance"]["why"] if "focus" in w]')" "[]"
ax 'd["intent"]["accepted"]={"outcome":"x","done_when":"y","exclusions":[],"hash":"0000000000000000","at":None,"line":1}; d["decisions"][1]["status"]="open"; d["decisions"][1]["ready"]=True'
t_eq "FC-assessed: ... with a ready decision open the wording is 'Needs you', never the denial" "$(axq '(d["case"], d["text"], d["assurance"]["why"][:2])')" "('a', 'Needs you', ['decision open', 'focus changed after the assessment'])"
t_has "FC-assessed: brief line 2 carries the reason when nothing else needs the owner" "$(bf 'd["intent"]["accepted"]={"outcome":"x","done_when":"y","exclusions":[],"hash":"0000000000000000","at":None,"line":1}; d["assurance"]=None' | sed -n 2p)" "· focus changed after the assessment"

# ---- FC-page: the Handoff disclosure is FIRST, the focus row sits under the attention row, Copy never claims success it did not get
mkproj fcp2 || true; bump; begin; pub ''
if [ $HAVE_NODE = 1 ]; then
  rbpage
  t_eq "FC-page: the page script ran; the first disclosure of the context list is Handoff" "$(pj '(d["error"], [x for x in d["disclosures"] if not x.startswith("Later decisions")][:2])')" "(None, ['Handoff', 'Plan vs shipped'])"
  t_eq "FC-page: ... its <pre> holds exactly handoff.txt" "$(pj 'd["handoff"] == open("'"$PM"'/handoff.txt", encoding="utf-8").read()')" "True"
  t_eq "FC-page: ... the focus row under the attention row says the proposal is not confirmed" "$(pj '(d["focus"], d["since"][2].startswith("Attention"), d["since"][3])')" "([['proposed', 'focus: Ship the engine import (proposed, not confirmed)']], True, 'focus: Ship the engine import (proposed, not confirmed)')"
  t_eq "FC-page: ... the section is still hidden on a first map (its focus is in the Handoff only)" "$(mkproj fcp3 >/dev/null 2>&1; rbpage; pj '(d["sinceHidden"], d["focus"], d["disclosures"][0], "Focus (proposed, not confirmed): Ship the engine import" in d["handoff"])')" "(True, [], 'Handoff', True)"
  # the confirmed record, with and without a different standing proposal
  R=$(cd "$T/fcp2" && pwd -P); PM="$R/.project-map"
  fcset "$FC_O" "$FC_D" '["no deploy"]'; bump; begin; pub 'J["intent"]={"outcome":"Rewrite the importer","done_when":"All fixtures pass"}'
  rbpage
  t_eq "FC-page: an accepted record + a different proposal: the confirmed focus with its date, then the suggestion" "$(pj '(d["focus"], d["since"][3:5])')" "([['confirmed', 'focus: Ship the engine import (confirmed 2026-10-11)']], ['focus: Ship the engine import (confirmed 2026-10-11)', 'the map suggests a different focus: Rewrite the importer'])"
  t_has "FC-page: ... and the Handoff text carries the exclusions" "$(pj 'd["handoff"]')" "Not in scope (owner): no deploy"
  for m in ok deny missing sync; do
    PAGE=$(PM_PAGE_CLIP=$m node "$TD/pm_page.js" "$PM/index.html" 2>&1)
    case $m in
      ok)      t_eq "FC-page: Copy with a clipboard that resolves: 'Copied.', the whole handoff written, nothing selected" "$(pj '(d["copy"]["note"], d["copy"]["written"] == d["handoff"], d["copy"]["selected"])')" "('Copied.', True, None)";;
      deny)    t_eq "FC-page: Copy with a clipboard that rejects: never 'Copied', the text is selected and the note says so" "$(pj '("Copied" in d["copy"]["note"], d["copy"]["selected"], d["copy"]["note"][:20])')" "(False, 'handoff-text', 'Copy was not allowed')";;
      missing) t_eq "FC-page: Copy where there is no clipboard API: the same honest fallback" "$(pj '("Copied" in d["copy"]["note"], d["copy"]["selected"], d["error"])')" "(False, 'handoff-text', None)";;
      sync)    t_eq "FC-page: Copy where writeText returns no promise: not a success either" "$(pj '("Copied" in d["copy"]["note"], d["copy"]["selected"])')" "(False, 'handoff-text')";;
    esac
  done
  t_eq "FC-page: the button's own label never promises more than it does ('Copy handoff') and the page made no script or iframe" "$(pj '(d["copyLabel"], d["scripts"], "script" in d["created"], "img" in d["created"])')" "('Copy handoff', 0, False, False)"
  # the markup-looking intent of FC-handoff stays inert on the page
  R=$(cd "$T/fch2" && pwd -P); PM="$R/.project-map"
  rbpage
  t_eq "FC-page: markup-looking text in the handoff stays text: no script or img element, the <pre> shows it verbatim" "$(pj '(d["scripts"], "script" in d["created"], "img" in d["created"], "<script>alert(1)</script> & <b>ship</b>" in d["handoff"])')" "(0, False, False, True)"
else
  echo "SKIP: FC-page (node is missing)"
fi
t_true "FC-page: the template has the Handoff disclosure before 'Plan vs shipped', textContent only (no innerHTML), and the focus CSS" "python3 - $PM/index.html <<'PY'
import sys
h = open(sys.argv[1], encoding='utf-8').read()
sys.exit(0 if h.index(\"disclosure('Handoff')\") < h.index(\"disclosure('Plan vs shipped')\") and '.innerHTML' not in h and '.since-focus{' in h and '.handoff-text{' in h else 1)
PY"

# ---- FC-links: the fifth stable path
mkproj fcl3 || true
t_true "FC-links: five stable symlinks into current/" "for n in index.html mobile.html brief.txt state.json handoff.txt; do [ \"\$(readlink $PM/\$n)\" = current/\$n ] || exit 1; done"
rm "$PM/handoff.txt"; out=$(facts); t_eq "FC-links: a missing handoff link is repaired before NO_CHANGE" "$out:$(readlink "$PM/handoff.txt")" "NO_CHANGE nothing moved:current/handoff.txt"
t_true "FC-links: the sweep removes a stale handoff.txt.tmp left by a crash" "ln -s current/handoff.txt $PM/handoff.txt.tmp && facts >/dev/null && [ ! -e $PM/handoff.txt.tmp ] && [ ! -L $PM/handoff.txt.tmp ]"

# ---- FC-pre35: a 3.4 map (no intent, no handoff, no intent_hash in its judged key) is re-rendered, never re-judged for it
mkproj fcu || true
G=$(gen)
lib mut "$PM/gen-$G/state.json" 'del d["intent"]; del d["handoff"]; del d["judged_key"]["intent_hash"]; d["generation_files"]=[x for x in d["generation_files"] if x!="handoff.txt"]; d["template_hash"]="old"'
rm -f "$PM/gen-$G/handoff.txt" "$PM/handoff.txt"; lib resign "$PM/gen-$G"
out=$(facts)
t_eq "FC-pre35: a 3.4 generation: the upgrade is a mechanical re-render (the plugin files changed), not a judgement" "$out" "NEEDS_REFRESH plugin files changed"
t_true "FC-pre35: ... the new generation has handoff.txt and the fifth link; the focus is 'not recorded yet'" "[ -f $PM/current/handoff.txt ] && [ \"\$(readlink $PM/handoff.txt)\" = current/handoff.txt ] && sed -n 3p $PM/handoff.txt | grep -q '^Focus (not recorded yet): '"
t_eq "FC-pre35: ... the state does not invent an intent, the brief has no focus line" "$(S '"intent" in d'):$(grep -c '^focus:' "$PM/brief.txt")" "False:0"
t_eq "FC-pre35: ... and the map is quiet afterwards (a judged key without intent_hash never moves)" "$(facts)" "NO_CHANGE nothing moved"
fcset "$FC_O" "$FC_D"
out=$(facts)
t_pre "FC-pre35: an F-set on a map without a served intention is never model-free (no target to confirm)" "$out" "NEEDS_JUDGEMENT "

# ---- FC-at (Codex I1): an owner line's `at` is validated like every other string it can put into the state, the page and the handoff
fcat() { # AT_AS_JSON [ID]: append an owner line carrying that `at` (an F-set that confirms the proposal, or a D-001 hold)
  python3 - "$PM/answers.jsonl" "$1" "${2:-F-set}" "$FC_O" "$FC_D" <<'PY'
import json, sys
p, at, i, o, d = sys.argv[1:6]
r = {"id": i, "answer": o if i == "F-set" else "hold", "by": "owner", "at": json.loads(at)}
if i == "F-set":
    r["note"] = d
open(p, "a").write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}
t_eq "FC-at: at_problem: absent, null, date-only, minutes, Z, offsets, fractions, a space separator are fine; control, bidi, zero-width, trailing newline, text, secrets, numbers, bad dates and long values are not" "$(python3 -I - "$HOOKS" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
ok = [None, "2026-10-11", "2026-10-11T10:00", "2026-10-11T10:00:00Z", "2026-10-11T10:00:00+03:00", "2026-10-11T10:00:00+0300", "2026-10-11T10:00:00.5+03:00", "2026-10-11 10:00:00"]
bad = ["", "x\nFAKE:ok", "2026-10-11\n", "2026-10-11T10:00:00+03:00\nFAKE:ok", "2026-10-11‮", "2026-10-11​", "2026-10-11 x", "tomorrow", "AKIAABCDEFGHIJKLMNOP",
       123, True, ["2026-10-11"], "2026-13-45", "2026-10-11T25:99", "2026-10-11T10:00:00+03:00" + "0" * 20, "20261011", " 2026-10-11"]
print(json.dumps([[K.at_problem(x) for x in ok], [bool(K.at_problem(x)) for x in bad]]))
PY
)" '[[null, null, null, null, null, null, null, null], [true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true]]'
mkproj fct || true
for a in '"x\nFAKE:ok"' '"2026-10-11T10:00:00+03:00\nFAKE:ok"' '"2026-10-11‮"' '"2026-10-11​"' '"tomorrow"' '"AKIAABCDEFGHIJKLMNOP"' '123' '"2026-13-45"'; do fcat "$a"; done
fcat '"x\nFAKE:ok"' D-001
begin
t_pre "FC-at: confirming F-sets with a hostile at are bad lines, so the confirmation is NOT model-free" "$out" "NEEDS_JUDGEMENT 1 pending answers inv "
t_eq "FC-at: ... all nine lines are bad, none is pending, nothing is accepted" "$(get "$STAGE/snapshot.json" '([b["line"] for b in d["answers"]["bad"]], d["answers"]["pending"], d["intent"]["accepted"])')" "([1, 2, 3, 4, 5, 6, 7, 8, 9], [], None)"
t_eq "FC-at: ... with a reason that names the timestamp, not the text" "$(get "$STAGE/snapshot.json" 'sorted({b["why"][:18] for b in d["answers"]["bad"]})')" "['at must be an ISO-']"
t_eq "FC-at: ... a D- answer with a hostile at does not answer the decision either" "$(get "$STAGE/snapshot.json" '[x["status"] for x in d["decisions"] if x["id"]=="D-001"]')" "['open']"
pub ''
t_eq "FC-at: ... published: no accepted record, nine lines consumed" "$(S '(d["intent"]["accepted"], d["answers"]["applied"])')" "(None, 9)"
t_eq "FC-at: ... no hostile text anywhere in the handoff, the brief or the page" "$(cat "$PM/handoff.txt" "$PM/brief.txt" "$PM/index.html" | grep -c 'FAKE')" "0"
# valid timestamps still work; an absent or null `at` is explicit, not an error
mkproj fct2 || true; fcat 'null'; out=$(facts)
t_eq "FC-at: a confirming F-set with at:null is model-free" "$out" "NEEDS_REFRESH focus confirmed"
t_eq "FC-at: ... accepted.at is null and the handoff says 'confirmed' without a date" "$(S 'd["intent"]["accepted"]["at"]'):$(sed -n 3p "$PM/handoff.txt")" "None:Focus (confirmed): Ship the engine import"
mkproj fct3 || true; fcat '"2026-10-11"'; out=$(facts)
t_eq "FC-at: a date-only at is fine" "$out:$(sed -n 3p "$PM/handoff.txt")" "NEEDS_REFRESH focus confirmed:Focus (confirmed 2026-10-11): Ship the engine import"
# defence in depth: a hostile at that somehow sits in a published state is never rendered beyond its date
cat > "$T/fc_unit3.py" <<'PYEOF'
import json, sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_render as R
S = json.load(open(sys.argv[2]))
rec = {"outcome": "o", "done_when": "d", "exclusions": [], "hash": "h", "line": 1}
S["intent"] = {"accepted": dict(rec, at="2026-10-11\nFAKE:ok"), "proposed": None, "target": dict(rec)}
a = R.handoff(S).splitlines()
S["intent"]["accepted"]["at"] = "x\nFAKE:ok"
b = R.handoff(S).splitlines()
print(json.dumps([a[2], b[2], not any(x.startswith("FAKE") for x in a + b), len(a) == len(b)]))
PYEOF
t_eq "FC-at: the handoff renderer shows only a date, whatever a state holds" "$(python3 -I "$T/fc_unit3.py" "$HOOKS" "$PM/state.json")" '["Focus (confirmed 2026-10-11): o", "Focus (confirmed): o", true, true]'
if [ $HAVE_NODE = 1 ]; then
  rbpage '{"since":{"from":{"generation":"g","assessed_at":"2026-10-10T09:00:00+00:00"},"commits":0,"listed":0,"dirty":0,"hours":0,"changes":[],"attention":{"kind":"continue","text":"x","why":"y"},"not_checked":[]},"intent":{"accepted":{"outcome":"o","done_when":"d","exclusions":[],"hash":"h","at":"x\nFAKE:ok","line":1},"proposed":null,"target":{"outcome":"o","done_when":"d","exclusions":[],"hash":"h"}}}'
  t_eq "FC-at: ... and the page script shows 'confirmed' without the hostile text" "$(pj 'd["focus"]')" "[['confirmed', 'focus: o (confirmed)']]"
fi

# ---- FC-replay-equal (Codex I2): a replay that removes the accepted focus is JUDGED even when the line count and the intent hash do not move
mkproj fcq || true
fcset "$FC_O" "$FC_D"; out=$(facts)
t_eq "FC-replay-equal: setup: the confirmation is applied (applied 1, accepted line 1, one answer line)" "$out:$(S '(d["answers"]["applied"], d["intent"]["accepted"]["line"], d["judged_key"]["answers_count"], [x["status"] for x in d["decisions"] if x["id"]=="D-001"])')" "NEEDS_REFRESH focus confirmed:(1, 1, 1, ['open'])"
printf '{"id":"D-001","answer":"hold","by":"owner"}\n' > "$PM/answers.jsonl"
out=$(facts); t_pre "FC-replay-equal: the owner rewrites the only line (F-set -> a D-001 answer): same line count, ERROR answers rewritten" "$out" "ERROR answers rewritten"
out=$(python3 "$HOOKS/project-map-facts.py" --accept-answers "$R"); t_has "FC-replay-equal: --accept-answers says the focus is gone" "$out" "focus after the replay: none (no F-set line)"
eo=$(embed --mechanical)
t_pre "FC-replay-equal: a plain mechanical refresh (plugin update, hourly) in between" "$eo" "PM_EMBED_OK"
t_eq "FC-replay-equal: ... keeps the map honest: behind, because the rebaseline is outstanding; the old record is still what was judged" "$(S '(d["stale"]["why"], d["intent"]["accepted"]["line"], d["answers"]["applied"])')" "('answers replayed', 1, 1)"
t_has "FC-replay-equal: ... brief line 2 says so" "$(sed -n 2p "$PM/brief.txt")" "behind: answers replayed"
begin
t_pre "FC-replay-equal: with NO repository change the next facts run stages a judgement (before: NO_CHANGE and D-001 pending forever)" "$out" "NEEDS_JUDGEMENT answers replayed inv "
t_eq "FC-replay-equal: ... the staged snapshot has no accepted record and the replacement answer applied by the lifecycle" "$(get "$STAGE/snapshot.json" '(d["intent"]["accepted"], [a["id"] for a in d["answers"]["pending"]], [x["status"] for x in d["decisions"] if x["id"]=="D-001"], d["answers"]["applied"])')" "(None, ['D-001'], ['answered'], 0)"
pub ''
t_pre "FC-replay-equal: the judgement publishes" "$eo" "PM_EMBED_OK"
t_eq "FC-replay-equal: ... accepted is null (the model's text is the proposal), D-001 is answered, the replayed line is consumed" "$(S '(d["intent"]["accepted"], d["intent"]["proposed"]["outcome"], [x["status"] for x in d["decisions"] if x["id"]=="D-001"], d["answers"]["applied"], d["stale"])')" "(None, 'Ship the engine import', ['answered'], 1, None)"
t_eq "FC-replay-equal: ... and the next facts run is quiet" "$(facts)" "NO_CHANGE nothing moved"
t_eq "FC-replay-equal: ... the handoff no longer calls the focus confirmed" "$(sed -n 3p "$PM/handoff.txt")" "Focus (proposed, not confirmed): Ship the engine import"

# ---- FC-image (Codex I3): embed --apply-answers uses the ONE image it took, at the boundary between taking it and collecting
fcseam() { # NAME ACTION: run `embed --mechanical --apply-answers` paused right after it took its answers image; ACTION (eval'd) runs at the seam
  local n=$1 act=$2 i
  ( PM_EMBED_AFTER_IMAGE="$T/$n.sig" embed --mechanical --apply-answers > "$T/$n.out" 2>&1 ) & FCP=$!; BGPIDS="$BGPIDS $FCP"
  for i in $(seq 1 400); do [ -e "$T/$n.sig" ] && break; sleep 0.05; done
  [ -e "$T/$n.sig" ] || bad "FC-image $n" "the embed never reached the seam"
  eval "$act"
  : > "$T/$n.sig.go"; wait $FCP
}
# (a) a D- answer is appended right after the image: the image has ONE line, the publication must say exactly that
mkproj fci1 || true; fcset "$FC_O" "$FC_D"
L1=$(head -n 1 "$PM/answers.jsonl" | shasum -a 256 | cut -d' ' -f1)
fcseam fci1 'printf "{\"id\":\"D-001\",\"answer\":\"hold\",\"by\":\"owner\"}\n" >> "$PM/answers.jsonl"'
t_pre "FC-image: a D- line appended right after the image: the confirmation of the image's one line is applied" "$(cat "$T/fci1.out")" "PM_EMBED_OK"
t_not "FC-image: ... without a note" "$(cat "$T/fci1.out")" "PM_EMBED_NOTE"
t_eq "FC-image: ... the state consumed exactly the image: applied 1 of 1, the judged key counts 1, accepted line 1" "$(S '(d["answers"]["applied"], d["answers"]["total"], d["judged_key"]["answers_count"], d["intent"]["accepted"]["line"])')" "(1, 1, 1, 1)"
t_eq "FC-image: ... applied_hash is the hash of that ONE line, not of the two-line file" "$(S 'd["answers"]["applied_hash"]')" "$L1"
t_eq "FC-image: ... the generation's snapshot agrees: total 1, applied 1, nothing pending, key count 1" "$(get "$PM/current/snapshot.json" '(d["answers"]["total"], d["answers"]["applied"], d["answers"]["pending"], d["key"]["answers_count"])')" "(1, 1, [], 1)"
out=$(facts)
t_pre "FC-image: ... the next facts run sees the D- answer and stages the judgement" "$out" "NEEDS_JUDGEMENT 1 pending answers inv "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FC-image: ... whose snapshot has that line pending and answered by the lifecycle" "$(get "$STAGE/snapshot.json" '([a["id"] for a in d["answers"]["pending"]], [x["status"] for x in d["decisions"] if x["id"]=="D-001"])')" "(['D-001'], ['answered'])"
pub ''
t_eq "FC-image: ... and the judgement answers D-001 (applied 2)" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-001"], d["answers"]["applied"])')" "(['answered'], 2)"
# (a2) a SECOND confirming F-set is appended right after the image: it is a later append, picked up by the next run
mkproj fci2 || true; fcset "$FC_O" "$FC_D"
fcseam fci2 'fcset "$FC_O" "$FC_D"'
t_eq "FC-image: a second confirming F-set appended right after the image: the first is applied, the judged key counts 1" "$(S '(d["answers"]["applied"], d["judged_key"]["answers_count"], d["intent"]["accepted"]["line"])')" "(1, 1, 1)"
out=$(facts)
t_eq "FC-image: ... and the next run consumes the second one model-free (it would be NO_CHANGE if the key had counted both)" "$out:$(S '(d["answers"]["applied"], d["intent"]["accepted"]["line"])')" "NEEDS_REFRESH focus confirmed:(2, 2)"
# (b) an unfinished last line becomes complete right after the image: the tail flag and the counts are the image's
mkproj fci3 || true; fcset "$FC_O" "$FC_D"; printf '{"id":"D-001","answer":"hold","by":"owner"}' >> "$PM/answers.jsonl"
fcseam fci3 'printf "\n" >> "$PM/answers.jsonl"'
t_has "FC-image: an unfinished last line completed right after the image: not applied (the image had a tail)" "$(cat "$T/fci3.out")" "PM_EMBED_NOTE answers not applied: answers.jsonl has an uncommitted last line"
t_eq "FC-image: ... nothing consumed (applied 0, accepted null) and the stale reason counts the IMAGE's one complete line" "$(S '(d["answers"]["applied"], d["intent"]["accepted"], d["stale"]["why"])')" "(0, None, '1 pending answers')"
out=$(facts)
t_pre "FC-image: ... the next run sees both complete lines and stages the judgement (a D- answer is never model-free)" "$out" "NEEDS_JUDGEMENT 2 pending answers inv "

fi   # PM_DR_ONLY=1 skips section 15

# ======================================================================================================
# 16. 3.6.0: lost completion evidence and drift (DR-*), INTERFACES-3.2 section 15
# ======================================================================================================
if [ "${PM_FC_ONLY:-}" != 1 ]; then   # PM_FC_ONLY=1 stops after section 15
HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
rbpage() { PAGE=$(node "$TD/pm_page.js" "$PM/index.html" "$@" 2>&1); }
pj()  { printf '%s' "$PAGE" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(eval(sys.argv[1]))' "$1"; }
bf()  { lib brief "$PM/state.json" "$1"; }
ax()  { AXJ=$(lib assure "$PM/state.json" "$1"); }
axq() { printf '%s' "$AXJ" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(eval(sys.argv[1]))' "$1"; }
fcset() { # OUTCOME DONE_WHEN [EXCLUSIONS_JSON]: append an F-set line (the owner's record) to answers.jsonl
  python3 - "$PM/answers.jsonl" "$@" <<'PY'
import json, sys
p, o, d = sys.argv[1:4]
r = {"id": "F-set", "answer": o, "note": d, "at": "2026-10-11T10:00:00+03:00", "by": "owner"}
if len(sys.argv) > 4 and sys.argv[4]:
    r["exclusions"] = json.loads(sys.argv[4])
open(p, "a").write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}
FC_O="Ship the engine import"; FC_D="The import runs on the fixture project"   # pm_testlib.PROPOSAL, the fixed proposal every judgement makes
ovraise() { printf '%s' 'J["decisions"][1]["resolves_when"]=['"$1"']; '"$2"; }
ovj() { printf '%s' 'J["decisions"][0]["ready"]=True; J["decisions"][1]["overtaken"]={"why":"Owner tagged v1.0.0 and pushed by hand"}; '"$1"; }
ISROOT=0; [ "$(id -u)" = 0 ] && ISROOT=1
# the DR-* project: completion refs P1.c1 (file:ev/c1.md:3), P1.c2 (file:ev/c2.md), P1.c3 (commit:<init sha>) and the done parts
# ground-truth (file:PLAN.md:295) and engine (file:ev/p1.md:2): five refs, every one resolving when the map is published
drfiles() { mkdir -p "$R/ev"; local f; for f in c1 c2 p1 p2; do seq 1 5 > "$R/ev/$f.md"; done; (cd "$R" && git add -A && git commit -qm "evidence files"); }
drsha() { (cd "$R" && git rev-parse --short=7 HEAD); }
drcode() { # SHA7 [EXTRA PYTHON]: the FULL judgement edit that makes the DR plan
  printf '%s' 'P["phases"][0]["criteria"]=[{"id":"P1.c1","text":"Weights load","done":True,"ref":"file:ev/c1.md:3"},{"id":"P1.c2","text":"Engine builds","done":True,"ref":"file:ev/c2.md"},{"id":"P1.c3","text":"Import landed","done":True,"ref":"commit:'"$1"'"}]; [p for p in J["parts"] if p["id"]=="engine"][0]["ref"]="file:ev/p1.md:2"; '"${2:-}"
}
DRE='[p for p in J["parts"] if p["id"]=="engine"][0]["ref"]="file:ev/p1.md:2"'   # an UPDATE copies the part as it was (the fixture parts carry other refs)
drproj() { # NAME [EXTRA PYTHON]
  mkrepo "$1"; drfiles; begin; pub "$(drcode "$(drsha)" "${2:-}")" full
  case "$eo" in "PM_EMBED_OK gen "*) return 0;; *) bad "drproj $1" "$out | $eo"; return 1;; esac
}
drcommit() { (cd "$R" && echo "$RANDOM$RANDOM" >> docs/a.md && git add docs/a.md && git commit -qm "${1:-work}"); }
drcrit() { S '[c for ph in d["phases"] for c in ph["criteria"] if c["id"]=="'"$1"'"][0]'; }     # one criterion of the published state
drpart() { S '[p for p in d["parts"] if p["id"]=="'"$1"'"][0]'; }
evrec() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]+"/cache.json")).get("evidence");print(json.dumps(d) if len(sys.argv)<3 else eval(sys.argv[2]))' "$PM" "$@"; }

# ---- DR-lost-file: a completion ref that is gone is a LOSS: marked, never flipped, queued, repaired by the next judgement
drproj dr1 || true
t_eq "DR-lost-file: the published state carries the evidence view: 5 refs visited, none lost, key and record agree" "$(S '(d["evidence"], d["judged_key"]["evidence_lost"])')" "({'checked': 'complete', 'n': 5, 'done': 5, 'lost': [], 'unknown': []}, [])"
t_eq "DR-lost-file: ... the publication seeded the cache record under the new generation (5 results, epoch 1)" "$(evrec 'sorted(set(r["status"] for r in d["results"].values())),len(d["results"]),d["epoch"],d["gen"]=="'$(gen)'"')" "(['ok'], 5, 1, True)"
out=$(facts); t_eq "DR-lost-file: a later facts run with nothing moved is quiet" "${out%% *}" "NO_CHANGE"
rm "$R/ev/c2.md"; (cd "$R" && git add -A && git commit -qm "drop c2"); begin
t_pre "DR-lost-file: the verdict names the loss" "$out" "NEEDS_JUDGEMENT 1 new commits; completion evidence lost: P1.c2 inv "
t_eq "DR-lost-file: ... the snapshot: one loss (criteria are listed by id), the pass is complete, the key component names it" "$(get "$STAGE/snapshot.json" '(d["evidence"]["lost"], d["evidence"]["checked"], d["evidence"]["done"], d["key"]["evidence_lost"], [e["id"] for e in d["evidence"]["ok"]])')" "([{'id': 'P1.c2', 'ref': 'file:ev/c2.md', 'why': 'file missing'}], 'complete', 5, ['P1.c2'], ['P1.c1', 'P1.c3', 'engine', 'ground-truth'])"
t_eq "DR-lost-file: ... the pack lists it as a repair (RESERVED: before every optional detail)" "$(get "$STAGE/pack.json" '(d["repairs"], list(d).index("repairs") < list(d).index("repos"))')" "({'lost': [{'id': 'P1.c2', 'ref': 'file:ev/c2.md', 'why': 'file missing'}], 'more': 0}, True)"
t_eq "DR-lost-file: ... the stale-stamping refresh already marked the criterion unverified (done stays true) and says why" "$(drcrit P1.c2 | sed 's/^/ /' >/dev/null; S '([c for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P1.c2"][0].get("unverified"), [c for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P1.c2"][0]["done"], d["evidence"]["lost"][0]["why"], d["stale"]["why"])')" "(True, True, 'file missing', '1 new commits; completion evidence lost: P1.c2')"
t_has "DR-lost-file: ... brief line 11b names it with its ref" "$(cat "$PM/brief.txt")" "evidence lost: P1.c2 (file:ev/c2.md)"
t_eq "DR-lost-file: ... the assurance says so (P1.c2 unverified), never 'Nothing needs you'" "$(S '(d["assurance"]["ok"], [w for w in d["assurance"]["why"] if "unverified" in w])')" "(False, ['P1.c2 unverified'])"
if [ "$HAVE_NODE" = 1 ]; then
  rbpage '{"focus":{"phase":"P1"}}'
  t_eq "DR-page: the criterion row says 'completion unverified' with the reason; the others do not" "$(pj '[(c[0], c[2]) for c in d["criteria"]]')" "[('P1.c1', False), ('P1.c2', True), ('P1.c3', False)]"
  t_has "DR-page: ... the row text" "$(pj '[c[1] for c in d["criteria"] if c[0]=="P1.c2"][0]')" "completion unverified · file missing"
  t_eq "DR-page: the progress tile counts it, the done total is untouched" "$(pj 'd["progress"]')" "3 of 7 (1 unverified)"
  t_has "DR-page: Plan vs shipped marks the row" "$(pj '" | ".join(d["bodies"]["Plan vs shipped"])')" "Shipped · completion unverified"
  t_eq "DR-page: the script wrote only textContent (no script or iframe element)" "$(pj 'd["scripts"]')" "0"
fi
rej "DR-lost-file: a listed loss left done with its old ref is not accepted (the repair is an obligation)" 'J["criteria_updates"]=[u for u in J.get("criteria_updates",[]) if u["id"]!="P1.c2"]' "P1.c2 completion evidence is lost (file missing"
rej "DR-lost-file: ... done:true again with the old ref does not resolve" 'J["criteria_updates"]=[{"id":"P1.c2","done":True,"ref":"file:ev/c2.md"}]' "criteria_updates P1.c2: file ref ev/c2.md is not an existing regular file"
pub '' update
t_pre "DR-lost-file: the default repair (done:false) publishes" "$eo" "PM_EMBED_OK"
t_eq "DR-lost-file: ... P1.c2 is open again, nothing is lost, the key is rebased, the mark is gone" "$(S '([c for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P1.c2"][0], d["evidence"]["lost"], d["judged_key"]["evidence_lost"], d["assurance"]["ok"])')" "({'id': 'P1.c2', 'text': 'Engine builds', 'done': False, 'ref': None}, [], [], True)"
out=$(facts); t_eq "DR-lost-file: ... and the next run is quiet" "${out%% *}" "NO_CHANGE"

# ---- DR-lost-line: the file is there, the line is not
drproj dr2 || true
seq 1 2 > "$R/ev/c1.md"; (cd "$R" && git add -A && git commit -qm "shrink c1"); begin
t_pre "DR-lost-line: a ref to line 3 of a 2-line file is a loss" "$out" "NEEDS_JUDGEMENT 1 new commits; completion evidence lost: P1.c1 inv "
t_eq "DR-lost-line: ... why: line past end" "$(get "$STAGE/snapshot.json" 'd["evidence"]["lost"]')" "[{'id': 'P1.c1', 'ref': 'file:ev/c1.md:3', 'why': 'line past end'}]"
pub '' update; t_pre "DR-lost-line: the repair publishes" "$eo" "PM_EMBED_OK"

# ---- DR-lost-commit: a commit that is no longer in any known repository (an absent answer from a repository that still works)
# 3.6.2 (17.3): evidence must be in the checked-out history, so the cited commit is on HEAD; a reset drops it and gc prunes it
mkrepo dr3; drfiles; (cd "$R" && echo s > side.txt && git add -A && git commit -qm side)
SIDE=$(cd "$R" && git rev-parse --short=7 HEAD); begin; pub "$(drcode "$SIDE")" full
t_pre "DR-lost-commit: setup: the map cites a commit that exists" "$eo" "PM_EMBED_OK"
(cd "$R" && git reset -q --hard HEAD~1 && git reflog expire --expire=now --all && git gc -q --prune=now); begin
t_pre "DR-lost-commit: the pruned commit is a loss" "$out" "NEEDS_JUDGEMENT"
t_has "DR-lost-commit: ... named in the verdict" "$out" "completion evidence lost: P1.c3"
t_eq "DR-lost-commit: ... why: commit missing" "$(get "$STAGE/snapshot.json" '[(e["id"], e["why"]) for e in d["evidence"]["lost"]]')" "[('P1.c3', 'commit missing')]"
pub '' update; t_pre "DR-lost-commit: the repair publishes" "$eo" "PM_EMBED_OK"

# ---- DR-lost-part: a done part is a completion ref too
drproj dr4 || true
rm "$R/ev/p1.md"; (cd "$R" && git add -A && git commit -qm "drop p1"); begin
t_pre "DR-lost-part: the verdict names the part" "$out" "NEEDS_JUDGEMENT 1 new commits; completion evidence lost: engine inv "
t_eq "DR-lost-part: ... pack repairs and state: unverified, still done" "$(get "$STAGE/pack.json" 'd["repairs"]["lost"]')|$(S '(d["parts"][[p["id"] for p in d["parts"]].index("engine")]["unverified"], d["parts"][[p["id"] for p in d["parts"]].index("engine")]["status"])')" "[{'id': 'engine', 'ref': 'file:ev/p1.md:2', 'why': 'file missing'}]|(True, 'done')"
t_has "DR-lost-part: ... brief line 11b" "$(cat "$PM/brief.txt")" "evidence lost: engine (file:ev/p1.md:2)"
rej "DR-lost-part: a listed part left done with its old ref" '[p for p in J["parts"] if p["id"]=="engine"][0].update(status="done", ref="file:ev/p1.md:2")' "engine completion evidence is lost (file missing"
pub '[p for p in J["parts"] if p["id"]=="engine"][0].update(status="done", ref="file:ev/p2.md:2")' update
t_pre "DR-lost-part: a new resolving ref repairs it" "$eo" "PM_EMBED_OK"
t_eq "DR-lost-part: ... still done, not unverified, nothing lost, the key rebased" "$(S '([p for p in d["parts"] if p["id"]=="engine"][0].get("unverified"), d["evidence"]["lost"], d["judged_key"]["evidence_lost"])')" "(None, [], [])"
t_true "DR-lost-part: ... judgement.json (the model's file) carries no script mark" "! grep -q unverified $PM/current/judgement.json"

# ---- DR-queue: 24 lost criteria + 1 lost done part: batches of 12, the rest carried verbatim as unverified
mkrepo drq; drfiles; for i in $(seq -w 1 24); do echo x > "$R/ev/q$i.md"; done; (cd "$R" && git add -A && git commit -qm "q files"); begin
DRQ='P["phases"]=[{"id":"P%d"%(i+1),"label":"Phase %d"%(i+1),"criteria":[{"id":"P%d.c%d"%(i+1,j+1),"text":"Criterion %d.%d"%(i+1,j+1),"done":True,"ref":"file:ev/q%02d.md"%(i*8+j+1)} for j in range(8)]} for i in range(3)]+[{"id":"P4","label":"Later","criteria":[{"id":"P4.c1","text":"Open one","done":False}]}]; [p for p in J["parts"] if p["id"]=="engine"][0]["ref"]="file:ev/p1.md:2"'
pub "$DRQ" full; t_pre "DR-queue: setup: 24 done criteria and a done part publish" "$eo" "PM_EMBED_OK"
rm "$R"/ev/q*.md "$R/ev/p1.md"; (cd "$R" && git add -A && git commit -qm "lose everything"); begin
t_pre "DR-queue: 25 losses: the verdict names the first three and counts the rest" "$out" "NEEDS_JUDGEMENT 1 new commits; completion evidence lost: P1.c1, P1.c2, P1.c3 +22 inv "
t_true "DR-queue: ... the pack with 12 repairs and the reserved drift stays inside 8192 bytes" "[ \$(wc -c < $STAGE/pack.json) -le 8192 ]"
t_eq "DR-queue: ... the pack lists the first 12 (criteria by id), 13 more wait" "$(get "$STAGE/pack.json" '([e["id"] for e in d["repairs"]["lost"]], d["repairs"]["more"])')" "(['P1.c1', 'P1.c2', 'P1.c3', 'P1.c4', 'P1.c5', 'P1.c6', 'P1.c7', 'P1.c8', 'P2.c1', 'P2.c2', 'P2.c3', 'P2.c4'], 13)"
rej "DR-queue: an UNLISTED loss cannot be recertified with its old ref" 'J["criteria_updates"]=J.get("criteria_updates",[])+[{"id":"P3.c1","done":True,"ref":"file:ev/q17.md"}]' "criteria_updates P3.c1: file ref ev/q17.md is not an existing regular file"
pub "$DRE" update; t_pre "DR-queue: the first batch is repaired; the 13 others are carried verbatim and publish" "$eo" "PM_EMBED_OK"
t_eq "DR-queue: ... 13 carried: judged key, evidence view and marks agree (12 criteria + the part), still done" "$(S '(len(d["judged_key"]["evidence_lost"]), len(d["evidence"]["lost"]), sum(1 for ph in d["phases"] for c in ph["criteria"] if c.get("unverified") and c["done"]), [p.get("unverified") for p in d["parts"] if p["id"]=="engine"])')" "(13, 13, 12, [True])"
t_eq "DR-queue: ... the assurance names the first and counts the others" "$(S '[w for w in d["assurance"]["why"] if "unverified" in w]')" "['P2.c5 unverified +12']"
out=$(facts); t_pre "DR-queue: the carried ones force the next batch (repairs left)" "$out" "NEEDS_JUDGEMENT 13 completion repairs pending inv "; INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "DR-queue: ... the second pack lists the next 12 (P2.c5 ...), one more waits" "$(get "$STAGE/pack.json" '([e["id"] for e in d["repairs"]["lost"]][:2], len(d["repairs"]["lost"]), d["repairs"]["more"])')" "(['P2.c5', 'P2.c6'], 12, 1)"
pub "$DRE" update; t_pre "DR-queue: the second batch publishes" "$eo" "PM_EMBED_OK"
out=$(facts); t_pre "DR-queue: only the part is left (1 repair pending)" "$out" "NEEDS_JUDGEMENT 1 completion repairs pending inv "; INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "DR-queue: ... the third pack lists exactly that part" "$(get "$STAGE/pack.json" '(d["repairs"]["lost"], d["repairs"]["more"])')" "([{'id': 'engine', 'ref': 'file:ev/p1.md:2', 'why': 'file missing'}], 0)"
pub '' update; t_pre "DR-queue: the last repair publishes (the listed part stops being done)" "$eo" "PM_EMBED_OK"
t_eq "DR-queue: ... nothing is lost or marked any more" "$(S '(d["evidence"]["lost"], d["judged_key"]["evidence_lost"], len(__import__("json").loads(__import__("json").dumps(d))["parts"]), [p.get("unverified") for p in d["parts"]])')" "([], [], 6, [None, None, None, None, None, None])"
out=$(facts); t_eq "DR-queue: ... and the next run is NO_CHANGE" "${out%% *}" "NO_CHANGE"

# ---- DR-cursor: ONE fair schedule (least recently checked first, unvisited first), 40 checks per pass; driven pass by pass
mkrepo drc; mkdir -p "$R/.project-map" "$R/ev"; for i in $(seq -w 1 60); do echo x > "$R/ev/r$i.md"; done; rm "$R/ev/r55.md"
t_eq "DR-cursor: 60 refs, cap 40: the first pass is partial, the loss at ref 55 is found by the second, the set change and the repair follow" "$(python3 -I - "$HOOKS" "$R" <<'PY'
import sys, os, time, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
root = sys.argv[2]
items = [("P%d.c%d" % (i // 8 + 1, i % 8 + 1), "file:ev/r%02d.md" % (i + 1)) for i in range(56)] + [(n, "file:ev/r%02d.md" % (57 + k)) for k, n in enumerate(["engine", "ground-truth", "qualification", "upstream"])]
gen, cache = "000001-aaaaaaaa", {}
run = lambda its, g=gen: K.check_evidence(root, [], its, cache, time.monotonic() + 30, g)
v1, r1 = run(items)
v2, r2 = run(items)
out = [(len(r1), v1["checked"], v1["done"], v1["lost"]), (len(r2), v2["checked"], v2["done"], [e["id"] for e in v2["lost"]], v2["lost"][0]["why"])]
sid = cache["evidence"]["set"]
extra = items[:59] + [("P8.c1", "file:ev/r60.md")]   # the set changes: one ref swapped
v3, r3 = run(extra)
out.append((cache["evidence"]["set"] != sid, len(cache["evidence"]["results"]), v3["done"], v3["checked"], "P8.c1|file:ev/r60.md" in r3))
open(root + "/ev/r55.md", "w").write("x\n")   # the loss is repaired in the world; the record learns it when the turn of that ref comes
n = 0
while any(e["id"] == "P7.c7" for e in v3["lost"]) and n < 5:
    v3, _r = run(extra); n += 1
out.append((n <= 2, [e["id"] for e in v3["lost"]]))
print(json.dumps(out))
PY
)" '[[40, "partial", 40, []], [40, "complete", 60, ["P7.c7"], "file missing"], [true, 60, 60, "complete", true], [true, []]]'
if [ "$ISROOT" = 0 ]; then
mkrepo drc2; mkdir -p "$R/.project-map" "$R/ev/lk"; for i in $(seq -w 1 60); do if [ "$i" -le 40 ]; then echo x > "$R/ev/lk/r$i.md"; else echo x > "$R/ev/r$i.md"; fi; done; rm "$R/ev/r55.md"; chmod 000 "$R/ev/lk"
t_eq "DR-cursor: the 40 first refs stay unreadable (unknown, never lost): the loss at ref 55 is still found within two passes" "$(python3 -I - "$HOOKS" "$R" <<'PY'
import sys, time, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
root = sys.argv[2]
items = [("P%d.c%d" % (i // 8 + 1, i % 8 + 1), ("file:ev/lk/r%02d.md" if i < 40 else "file:ev/r%02d.md") % (i + 1)) for i in range(56)] + [(n, "file:ev/r%02d.md" % (57 + k)) for k, n in enumerate(["engine", "ground-truth", "qualification", "upstream"])]
cache = {}
v1, _ = K.check_evidence(root, [], items, cache, time.monotonic() + 30, "000001-aaaaaaaa")
v2, _ = K.check_evidence(root, [], items, cache, time.monotonic() + 30, "000001-aaaaaaaa")
print(json.dumps([(v1["checked"], len(v1["unknown"]), v1["lost"]), (v2["checked"], [e["id"] for e in v2["lost"]], len(v2["unknown"]))]))
PY
)" '[["partial", 40, []], ["partial", ["P7.c7"], 40]]'
chmod 755 "$R/ev/lk"
else echo "SKIP DR-cursor unreadable refs (running as root)"; fi

# ---- DR-cache-merge: the merge rules (pure), the one critical section (gated), a busy lock
t_eq "DR-cache-merge: older gen discards; newer gen / changed set replaces and keeps the keys still in the set; the higher epoch wins; an equal epoch by rank" "$(python3 -I - "$HOOKS" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
def rec(gen, sid, epoch, **res):
    return {"set": sid, "gen": gen, "epoch": epoch, "results": {k: {"status": v[0], "why": "", "at": "t", "epoch": v[1]} for k, v in res.items()}}
st = lambda r: {k: (v["status"], v["epoch"]) for k, v in r["results"].items()}
out = []
out.append(st(K.evidence_merge(rec("000002-b", "S", 5, a=("lost", 5)), rec("000001-a", "S", 9, a=("ok", 9)), {"a"})))                       # older gen: its own results are discarded
m = K.evidence_merge(rec("000001-a", "S", 2, a=("lost", 2), b=("ok", 2)), rec("000002-b", "T", 3, c=("ok", 3)), {"a", "c"})                    # newer gen, changed set
out.append((st(m), m["set"], m["gen"], m["epoch"]))
m = K.evidence_merge(rec("000002-b", "S", 2, a=("lost", 2), b=("ok", 2)), rec("000002-b", "T", 3, c=("ok", 3)), {"a", "c"})                    # same gen, changed set
out.append((st(m), m["set"]))
out.append(st(K.evidence_merge(rec("000002-b", "S", 5, a=("lost", 5)), rec("000002-b", "S", 4, a=("ok", 4)), {"a"})))                          # an OLDER epoch never overrides a newer loss
out.append(st(K.evidence_merge(rec("000002-b", "S", 5, a=("lost", 5)), rec("000002-b", "S", 6, a=("ok", 6)), {"a"})))                          # a later successful check does
out.append([st(K.evidence_merge(rec("000002-b", "S", 5, a=(x, 5)), rec("000002-b", "S", 5, a=(y, 5)), {"a"}))["a"][0] for x, y in (("ok", "lost"), ("lost", "ok"), ("ok", "unknown"), ("unknown", "lost"))])
out.append(K.evidence_merge(None, rec("000001-a", "S", 1, a=("ok", 1)), {"a"})["epoch"])
print(json.dumps(out))
PY
)" '[{"a": ["lost", 5]}, [{"a": ["lost", 2], "c": ["ok", 3]}, "T", "000002-b", 3], [{"a": ["lost", 2], "c": ["ok", 3]}, "T"], {"a": ["lost", 5]}, {"a": ["ok", 6]}, ["lost", "lost", "unknown", "lost"], 1]'

t_eq "DR-cache-merge: a pass whose generation is OLDER than the stored one discards its own results: it checks nothing and the record is untouched" "$(python3 -I - "$HOOKS" "$R" <<'PY'
import sys, os, time, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
root = sys.argv[2]
os.makedirs(root + "/.project-map", exist_ok=True); os.makedirs(root + "/ev", exist_ok=True); open(root + "/ev/x.md", "w").write("x\n")
items = [("P1.c1", "file:ev/x.md")]
rec = {"set": K.evidence_set(items), "gen": "000009-zzzzzzzz", "epoch": 7, "results": {"P1.c1|file:ev/x.md": {"status": "lost", "why": "file missing", "at": "t", "epoch": 7}}}
json.dump({"evidence": rec}, open(root + "/.project-map/cache.json", "w"))
view, ran = K.check_evidence(root, [], items, {}, time.monotonic() + 5, "000001-aaaaaaaa")
print(json.dumps([ran, view["lost"] and view["lost"][0]["id"], json.load(open(root + "/.project-map/cache.json"))["evidence"] == rec]))
PY
)" '[{}, "P1.c1", true]'
drproj drm || true
E0=$(evrec 'd["epoch"]')
GATE="$T/drm.gate"; rm -f "$GATE" "$GATE.go"
( PM_EVIDENCE_GATE="$GATE" python3 "$HOOKS/project-map-facts.py" "$R" > "$T/drm-a.out" 2>&1 ) & DRMP=$!; BGPIDS="$BGPIDS $DRMP"
for i in $(seq 1 200); do [ -e "$GATE" ] && break; sleep 0.05; done
t_true "DR-cache-merge: facts A reached the gate inside its critical section" "[ -e $GATE ]"
outB=$(facts)
t_eq "DR-cache-merge: facts B met a busy lock: the pass is skipped, the record is untouched, nothing is claimed" "$(evrec 'd["epoch"]'):${outB%% *}" "$E0:NO_CHANGE"
touch "$GATE.go"; wait $DRMP 2>/dev/null
t_eq "DR-cache-merge: A's pass completed after the gate: the epoch moved up by exactly one" "$(evrec 'd["epoch"]')" "$((E0 + 1))"
rm "$R/ev/c1.md"; (cd "$R" && git add -A && git commit -qm "drop c1"); outC=$(facts)
t_eq "DR-cache-merge: the file deleted between the passes: the next pass records the loss at a higher epoch, no ok survives for it" "$(evrec 'd["results"]["P1.c1|file:ev/c1.md:3"]["status"],d["results"]["P1.c1|file:ev/c1.md:3"]["epoch"] > '$((E0 + 1))):${outC%% *}" "('lost', True):NEEDS_JUDGEMENT"

# ---- DR-fp-routes: ONE content fingerprint per file, frozen at collection, whichever route makes the file eligible
mkrepo drf; echo base > "$R/zz.md"; (cd "$R" && git add -A && git commit -qm zz); begin; pub 'J["watch"]=["PLAN.md","zz.md"]' full
for i in $(seq -w 1 24); do echo "dirty $i" > "$R/d$i"; done; echo "changed" >> "$R/zz.md"
FPZ=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$R/zz.md"); FPD=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$R/d03")
begin
t_eq "DR-fp-routes: a watched file (not among the 20 retained dirty paths) and a retained dirty path each have one fingerprint; a directory and a path beyond 20 have none" "$(get "$STAGE/snapshot.json" '(d["file_fp"]["zz.md"], d["file_fp"]["d03"], "d21" in d["file_fp"], "docs" in d["file_fp"], len(d["dirty_paths"]))')" "({'fp': '$FPZ', 'status': 'verified'}, {'fp': '$FPD', 'status': 'verified'}, False, False, 20)"
ID1=$(python3 -I - "$HOOKS" "$STAGE" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
snap = json.load(open(sys.argv[2] + "/snapshot.json")); pack = json.load(open(sys.argv[2] + "/pack.json"))
print(V.resolve_observation("file:zz.md", snap, pack)[0], V.resolve_observation("file:d03:7", snap, pack)[0], V.resolve_observation("file:docs", snap, pack)[1][:40], V.resolve_observation("file:d22", snap, pack)[1][:40])
PY
)
t_eq "DR-fp-routes: ... the observation identity is path + fingerprint (a line number is not part of it); a directory or a path the pack did not list is no evidence" "$(printf '%s' "$ID1" | sed 's/ *$//')" "file:zz.md:$FPZ file:d03:$FPD file docs is not a changed file the pack file d22 is not a changed file the pack"
(cd "$R" && git add d01 d02 d03 d04 d05 d06 d07 d08 d09 d10 d11 d12 d13 d14 d15 d16 d17 d18 d19 d20 && git commit -qm "commit twenty"); begin
t_eq "DR-fp-routes: after the earlier dirty paths were committed the same file enters the retained dirty list: the SAME fingerprint, one entry" "$(get "$STAGE/snapshot.json" '(d["file_fp"]["zz.md"]["fp"], "zz.md" in d["dirty_paths"], d["file_fp"]["d21"]["fp"] != "", "d03" in d["file_fp"])')" "('$FPZ', True, True, False)"
ID2=$(python3 -I - "$HOOKS" "$STAGE" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
snap = json.load(open(sys.argv[2] + "/snapshot.json")); pack = json.load(open(sys.argv[2] + "/pack.json"))
print(V.resolve_observation("file:zz.md", snap, pack)[0])
PY
)
t_eq "DR-fp-routes: ... so the observation identity does not depend on the route" "$ID2" "file:zz.md:$FPZ"

# ---- DR-restore: carried (unlisted) losses restored by the owner between batches clear mechanically
mkrepo drq2; printf 'ign/\n' >> "$R/.gitignore"; mkdir -p "$R/ign"; for i in $(seq -w 1 16); do echo x > "$R/ign/q$i.md"; done; echo p > "$R/ign/p1.md"; (cd "$R" && git add -A && git commit -qm "ign setup"); begin
DRQ2='P["phases"]=[{"id":"P%d"%(i+1),"label":"Phase %d"%(i+1),"criteria":[{"id":"P%d.c%d"%(i+1,j+1),"text":"Criterion %d.%d"%(i+1,j+1),"done":True,"ref":"file:ign/q%02d.md"%(i*8+j+1)} for j in range(8)]} for i in range(2)]+[{"id":"P3","label":"Later","criteria":[{"id":"P3.c1","text":"Open one","done":False}]}]; [p for p in J["parts"] if p["id"]=="engine"][0]["ref"]="file:ign/p1.md"'
pub "$DRQ2" full; t_pre "DR-restore: setup" "$eo" "PM_EMBED_OK"
rm "$R"/ign/q0[1-9].md "$R"/ign/q1[0-4].md; begin
t_pre "DR-restore: 14 losses with no change visible to git: only the evidence moves the key" "$out" "NEEDS_JUDGEMENT completion evidence lost: P1.c1, P1.c2, P1.c3 +11 inv "
DRE2='[p for p in J["parts"] if p["id"]=="engine"][0]["ref"]="file:ign/p1.md"'
pub "$DRE2" update; t_pre "DR-restore: the first batch of 12 publishes; P2.c5 and P2.c6 are carried" "$eo" "PM_EMBED_OK"
t_eq "DR-restore: ... carried and unverified" "$(S '(d["judged_key"]["evidence_lost"], [c["id"] for ph in d["phases"] for c in ph["criteria"] if c.get("unverified")])')" "(['P2.c5', 'P2.c6'], ['P2.c5', 'P2.c6'])"
echo x > "$R/ign/q13.md"; echo x > "$R/ign/q14.md"
out=$(facts)
t_eq "DR-restore: the owner restored both carried files: the evidence view changed, no key moved (R6)" "$out" "NEEDS_REFRESH evidence status changed"
t_eq "DR-restore: ... the mechanical refresh cleared the marks, emptied the lost list and rebased the key" "$(S '(d["judged_key"]["evidence_lost"], d["evidence"]["lost"], [c["id"] for ph in d["phases"] for c in ph["criteria"] if c.get("unverified")], d["stale"])')" "([], [], [], None)"
out=$(facts); t_eq "DR-restore: ... and the run after that is NO_CHANGE" "${out%% *}" "NO_CHANGE"
t_eq "DR-restore: compare_keys (R6) unit: a NEW loss moves; a carried one still lost moves ('repairs pending'); a loss that left the set does not" "$(python3 -I - "$HOOKS" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
def cmp(judged, fresh):
    j = {"heads": {}, "watch_hashes": {}, "release": {}, "evidence_lost": judged}
    k = {"heads": {}, "watch_hashes": {}, "release": {}, "evidence_lost": fresh}
    r = K.compare_keys(j, k, {"commits": {"count": 0}, "answers": {"pending": []}, "key": k})
    return ("evidence_lost" in r["moved"], r["why"])
print(json.dumps([cmp([], ["a"]), cmp(["a"], ["a"]), cmp(["a", "b"], ["b"]), cmp(["a", "b"], []), cmp(["a"], ["a", "c"])]))
PY
)" '[[true, "completion evidence lost: a"], [true, "1 completion repairs pending"], [true, "1 completion repairs pending"], [false, ""], [true, "completion evidence lost: c; 1 completion repairs pending"]]'

t_eq "DR-restore: marks are cleared ONLY by an ok result (unit): lost keeps it, unknown or unvisited keeps it, ok clears it, an item no longer done clears it" "$(python3 -I - "$HOOKS" <<'PY'
import sys, json, copy
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
def state():
    return {"phases": [{"id": "P1", "criteria": [{"id": "P1.c1", "done": True, "ref": "file:a", "unverified": True}, {"id": "P1.c2", "done": True, "ref": "file:b", "unverified": True}]}],
            "parts": [{"id": "engine", "status": "done", "ref": "file:c", "unverified": True}, {"id": "later", "status": "in_progress", "ref": "file:d", "unverified": True}]}
def run(ev):
    T = state(); V.apply_evidence(T, dict({"checked": "partial", "n": 3, "done": 1, "lost": [], "unknown": [], "ok": []}, **ev)); return V.unverified_ids(T)
print(json.dumps([run({"lost": [{"id": "P1.c1", "ref": "file:a", "why": "file missing"}]}),   # still lost: kept; the others are unvisited: kept; the part no longer done: cleared
                  run({"unknown": ["P1.c1"]}),
                  run({"ok": [{"id": "P1.c1", "ref": "file:a"}, {"id": "engine", "ref": "file:c"}]}),
                  run({"ok": [{"id": "P1.c1", "ref": "file:OTHER"}]})]))
PY
)" '[["P1.c1", "P1.c2", "engine"], ["P1.c1", "P1.c2", "engine"], ["P1.c2"], ["P1.c1", "P1.c2", "engine"]]'

# ---- DR-unknown / DR-refresh: a ref that cannot be read is UNKNOWN (never lost, never marked); the view change is a refresh, not a judgement
if [ "$ISROOT" = 0 ]; then
mkrepo dru; printf 'ign/\n' >> "$R/.gitignore"; mkdir -p "$R/ign"; echo x > "$R/ign/u1.md"; echo x > "$R/ign/u2.md"; echo p > "$R/ign/p1.md"; (cd "$R" && git add -A && git commit -qm "ign setup"); begin
pub 'P["phases"][0]["criteria"]=[{"id":"P1.c1","text":"One","done":True,"ref":"file:ign/u1.md"},{"id":"P1.c2","text":"Two","done":True,"ref":"file:ign/u2.md"}]; [p for p in J["parts"] if p["id"]=="engine"][0]["ref"]="file:ign/p1.md"' full
t_pre "DR-unknown: setup" "$eo" "PM_EMBED_OK"
chmod 000 "$R/ign"; out=$(facts)
t_eq "DR-refresh: three refs cannot be read: no key moves, the view changes, so the answer is a mechanical refresh" "$out" "NEEDS_REFRESH evidence status changed"
t_eq "DR-unknown: ... partial, three unknown, nothing lost, no item marked, the key untouched" "$(S '(d["evidence"]["checked"], d["evidence"]["unknown"], d["evidence"]["lost"], [c["id"] for ph in d["phases"] for c in ph["criteria"] if c.get("unverified")], d["judged_key"]["evidence_lost"])')" "('partial', ['P1.c1', 'P1.c2', 'engine'], [], [], [])"
t_eq "DR-unknown: ... the assurance and line 2 of the brief say the check is incomplete" "$(S '[w for w in d["assurance"]["why"] if "evidence" in w]'):$(sed -n 2p "$PM/brief.txt" | grep -c 'evidence check incomplete')" "['evidence check incomplete']:1"
out=$(facts); t_eq "DR-unknown: the same unreadable world again is stable (the pass re-checks, the view is the same)" "${out%% *}" "NO_CHANGE"
chmod 755 "$R/ign"; out=$(facts)
t_eq "DR-unknown: readable again: the next refresh completes the check" "$out:$(S '(d["evidence"]["checked"], d["evidence"]["unknown"])')" "NEEDS_REFRESH evidence status changed:('complete', [])"
else echo "SKIP DR-unknown (running as root)"; fi

# ---- DR-publish-recheck: a check made at publication is part of the published state
drproj dr5 || true; bump; begin
rm "$R/ev/c1.md"          # the file vanishes while the judgement is being written
pub "$DRE" update
t_has "DR-publish-recheck: the embed says the map is behind and why" "$eo" "PM_EMBED_STALE completion evidence lost: P1.c1"
t_eq "DR-publish-recheck: ... the item is published unverified (done untouched), listed lost, with the recheck coverage stored" "$(S '([c for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P1.c1"][0], d["evidence"])')" "({'id': 'P1.c1', 'text': 'Weights load', 'done': True, 'ref': 'file:ev/c1.md:3', 'unverified': True}, {'checked': 'complete', 'n': 5, 'done': 5, 'lost': [{'id': 'P1.c1', 'ref': 'file:ev/c1.md:3', 'why': 'file missing'}], 'unknown': [], 'recheck': {'done': 5, 'n': 5}})"
t_eq "DR-publish-recheck: ... stale why, the judged key (the loss is carried), the assurance" "$(S '(d["stale"]["why"], d["judged_key"]["evidence_lost"], d["assurance"]["ok"], [w for w in d["assurance"]["why"] if "unverified" in w])')" "('completion evidence lost: P1.c1', ['P1.c1'], False, ['P1.c1 unverified'])"
t_has "DR-publish-recheck: ... and the brief shows both" "$(sed -n 2p "$PM/brief.txt")|$(grep '^evidence lost' "$PM/brief.txt")" "behind: completion evidence lost: P1.c1"
t_eq "DR-publish-recheck: the cache record holds the recheck's loss (a later pass cannot lose it to an earlier ok)" "$(evrec 'd["results"]["P1.c1|file:ev/c1.md:3"]["status"]')" "lost"
out=$(facts)
t_pre "DR-publish-recheck: the next run re-judges (the loss is carried; the file also left the working tree)" "$out" "NEEDS_JUDGEMENT working tree changed; 1 completion repairs pending inv "
# an incomplete recheck is part of the assurance, and the next refresh replaces it
drproj dr6 || true; bump; begin
PM_EMBED_EVIDENCE_DEADLINE=0 pub "$DRE" update
t_eq "DR-publish-recheck: nothing could be rechecked in time: recheck 0 of 5 stored" "$(S '(d["evidence"]["recheck"], d["evidence"]["lost"], d["stale"])')" "({'done': 0, 'n': 5}, [], None)"
t_eq "DR-publish-recheck: ... the assurance says so" "$(S '[w for w in d["assurance"]["why"] if "recheck" in w]')" "['publication recheck 0 of 5']"
out=$(facts)
t_eq "DR-publish-recheck: ... the next facts run replaces it by a pass of its own (a refresh, not a judgement)" "$out:$(S '"recheck" in d["evidence"]')" "NEEDS_REFRESH evidence status changed:False"
out=$(facts); t_eq "DR-publish-recheck: ... and then it is quiet" "${out%% *}" "NO_CHANGE"

# ---- DR-fit: judgement.fit (15.2): required when there is an intent and a baseline, evidence only from what the pack supplied
DRDEC='{"id":"D-010","q":"The work moved away from the focus: keep it?","options":[{"id":"A","label":"Keep the focus"},{"id":"B","label":"Revise the focus (then say the new one)"},{"id":"C","label":"Unclear, keep watching"}],"recommended":None,"default":"hold","hard_rule":None,"deadline":None,"ready":True,"about":"drift"}'
drdep()   { printf '%s' 'J["fit"]={"verdict":"departure","concern":"The new work is not the import","evidence":["'"$1"'"]'"${2:+,\"exclusion\":$2}"'}'; }   # EVIDENCE_REF [EXCLUSION]
drraise() { printf '%s' "$(drdep "$@"); J[\"decisions\"].append($DRDEC)"; }
drcarry() { printf '%s' "J[\"decisions\"].append($DRDEC)"; }
drdrift() { S 'json.dumps(d["intent"].get("drift"), sort_keys=True)'; }
mkrepo drf0; begin
rej "DR-fit: a first map (no baseline) must not carry fit" 'J["fit"]={"verdict":"unknown"}' "fit must be absent or null" full
drproj drf1 || true
drcommit work1; SHA1=$(drsha); bump; begin
t_eq "DR-fit: the pack the model reads carries what a departure may cite (commit items, dirty paths)" "$(get "$STAGE/pack.json" '([i["h"] for dd in d["commits"]["days"] for i in dd["items"]], d["dirty_paths"])')" "(['$SHA1'], ['PLAN.md'])"
rej "DR-fit: required when the pack carries an intent and a baseline" 'del J["fit"]' "fit is required"
rej "DR-fit: unknown verdict" 'J["fit"]={"verdict":"maybe"}' "fit.verdict must be one of consistent|departure|unknown"
rej "DR-fit: unknown keys" 'J["fit"]={"verdict":"unknown","score":3}' "fit has unknown keys: score"
rej "DR-fit: consistent carries no concern" 'J["fit"]={"verdict":"consistent","concern":"fine"}' "fit.concern belongs to a departure only"
rej "DR-fit: unknown carries no evidence" 'J["fit"]={"verdict":"unknown","evidence":["commit:'$SHA1'"]}' "fit.evidence belongs to a departure only"
rej "DR-fit: a departure needs a concern" 'J["fit"]={"verdict":"departure","evidence":["commit:'$SHA1'"]}' "fit.concern is required for a departure"
rej "DR-fit: a departure needs evidence" 'J["fit"]={"verdict":"departure","concern":"x"}' "fit.evidence is required for a departure"
rej "DR-fit: at most three evidence refs" 'J["fit"]={"verdict":"departure","concern":"x","evidence":["commit:'$SHA1'","file:PLAN.md","commit:'$SHA1'","file:PLAN.md"]}' "fit.evidence has 4 entries, allowed 1..3"
rej "DR-fit: concern over 160 bytes" 'J["fit"]={"verdict":"departure","concern":"x"*161,"evidence":["commit:'$SHA1'"]}' "fit.concern must be 1..160 bytes"
rej "DR-fit: a secret-shaped concern" 'J["fit"]={"verdict":"departure","concern":"deploy with AKIAABCDEFGHIJKLMNOP","evidence":["commit:'$SHA1'"]}' "judgement.fit.concern looks like it contains a secret"
rej "DR-fit: evidence from OUTSIDE the pack: a commit it did not list" 'J["fit"]={"verdict":"departure","concern":"x","evidence":["commit:1234567"]}' "fit.evidence[1]: commit 1234567 is not one of the commits the pack listed (fit evidence must be an observation the pack supplied)"
rej "DR-fit: evidence from outside the pack: a clean file" 'J["fit"]={"verdict":"departure","concern":"x","evidence":["file:README.md"]}' "file README.md is not a changed file the pack listed"
rej "DR-fit: evidence from outside the pack: a path that is not a file ref at all" 'J["fit"]={"verdict":"departure","concern":"x","evidence":["README.md"]}' "ref must start with commit: or file:"
rej "DR-fit: the same observation twice (a re-spelled ref is the same identity)" 'J["fit"]={"verdict":"departure","concern":"x","evidence":["file:PLAN.md","file:PLAN.md:5"]}' "fit.evidence[2] repeats an observation already listed"
rej "DR-fit: an exclusion index needs the owner's exclusions" 'J["fit"]={"verdict":"departure","concern":"x","evidence":["commit:'$SHA1'"],"exclusion":0}' "fit.exclusion 0 is not an index into the owner's exclusions (0)"
pub '' update; t_pre "DR-fit: unknown with no evidence is always legal" "$eo" "PM_EMBED_OK"
t_eq "DR-fit: ... state.fit for an unknown verdict" "$(S 'd["fit"]')" "{'verdict': 'unknown', 'concern': None, 'evidence': [], 'observations': [], 'exclusion': None, 'scope': {'shown': 1, 'total': 1}, 'against': 'proposed'}"
drcommit work2; SHA2=$(drsha); bump; begin
pub "$(drdep "commit:$SHA2")" update; t_pre "DR-fit: a departure citing a commit the pack listed publishes" "$eo" "PM_EMBED_OK"
OID2=$(cd "$R" && git rev-parse HEAD)
t_eq "DR-fit: ... state.fit: the refs as written, the observation identities from the staged snapshot, the scope shown, against the proposal" "$(S 'd["fit"]')" "{'verdict': 'departure', 'concern': 'The new work is not the import', 'evidence': ['commit:$SHA2'], 'observations': ['commit:.:$OID2'], 'exclusion': None, 'scope': {'shown': 1, 'total': 1}, 'against': 'proposed'}"
t_eq "DR-proposed-quiet: against a proposal only: no drift record" "$(drdrift)" "null"
t_has "DR-fit: brief line 5b" "$(cat "$PM/brief.txt")" "fit: The new work is not the import"
t_has "DR-fit: handoff line 9b" "$(cat "$PM/handoff.txt")" "Fit (against the map's proposal): The new work is not the import"
if [ "$HAVE_NODE" = 1 ]; then rbpage
  t_has "DR-page: the #since section says departure, against the proposal" "$(pj 'd["fit"][0][1]')" "fit: departure from the map's proposal · The new work is not the import"
fi
drcommit work3; bump; begin
rej "DR-proposed-quiet: no drift decision without a confirmed focus" "$(drraise "file:PLAN.md")" "there is no confirmed focus to drift from"
rej "DR-fit: a drift attention needs a departure" 'J["since"]={"changes":[],"attention":{"kind":"drift","text":"t","why":"w"},"not_checked":[]}' "since.attention.kind drift needs fit.verdict departure"
pub "$(drdep "file:PLAN.md"); "'J["since"]={"changes":[],"attention":{"kind":"drift","text":"The work left the focus","why":"A second look is cheap"},"not_checked":[]}' update
t_pre "DR-fit: ... a departure may set the attention to drift" "$eo" "PM_EMBED_OK"
t_eq "DR-fit: ... which the assurance reports; the brief shows attention and fit" "$(S '(d["since"]["attention"]["kind"], [w for w in d["assurance"]["why"] if "attention" in w])')|$(grep -c '^attention: The work left the focus' "$PM/brief.txt")$(grep -c '^fit:' "$PM/brief.txt")" "('drift', ['attention: drift'])|11"

# ---- DR-frozen-fp: the observation identity is the one frozen at staging
drproj drz || true
echo "first" >> "$R/docs/a.md"; begin
FP1=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$R/docs/a.md")
echo "second" >> "$R/docs/a.md"
pub "$(drdep "file:docs/a.md")" update; t_pre "DR-frozen-fp: setup: the file changed between staging and validation" "$eo" "PM_EMBED_OK"
t_eq "DR-frozen-fp: the identity is the staged one, not the one the file has now" "$(S 'd["fit"]["observations"]')" "['file:docs/a.md:$FP1']"

# ---- DR-streak: a second departure on distinct new work (or an exclusion) is what makes a drift decision eligible; the gate
drraise2() { printf '%s' "$(drdep "$@"); J[\"decisions\"].append(dict($DRDEC, id=\"D-011\"))"; }
drproj drs || true
fcset "$FC_O" "$FC_D"; out=$(facts); HA=$(fch "$FC_O" "$FC_D")
t_eq "DR-streak: setup: the owner confirmed the focus model-free" "$out" "NEEDS_REFRESH focus confirmed"
t_eq "DR-streak: ... a fresh drift record belongs to the accepted identity" "$(drdrift)" '{"acknowledged": null, "hash": "'$HA'", "heads": null, "revise_requested": false, "streak": 0}'
drcommit c1; SHA=$(drsha); begin
t_eq "DR-streak: the pack shows the staged drift record" "$(get "$STAGE/pack.json" 'd["drift"]')" "{'streak': 0, 'new_work': True, 'acknowledged': [], 'revise_requested': False, 'open': False}"
rej "DR-streak: the FIRST departure is not eligible for a decision" "$(drraise "commit:$SHA")" "it needs a second departure on distinct new work"
rej "DR-streak: a drift decision needs a departure" "J[\"fit\"]={\"verdict\":\"consistent\"}; J[\"decisions\"].append($DRDEC)" "fit.verdict is not departure"
pub "$(drdep "commit:$SHA")" update; t_pre "DR-streak: the first departure counts (against the accepted focus)" "$eo" "PM_EMBED_OK"
t_eq "DR-streak: ... streak 1 with the heads it saw; fit.against says accepted" "$(S '(d["intent"]["drift"]["streak"], d["intent"]["drift"]["heads"] == d["judged_key"]["heads"], d["fit"]["against"])')" "(1, True, 'accepted')"
bump; begin
t_eq "DR-streak: no new commits: the pack says there is no new work" "$(get "$STAGE/pack.json" '(d["drift"]["streak"], d["drift"]["new_work"])')" "(1, False)"
rej "DR-streak: ... so even a streak of 1 is not enough" "$(drraise "file:PLAN.md")" "it needs a second departure on distinct new work"
pub "$(drdep "file:PLAN.md")" update
t_eq "DR-streak: the same heads twice do not count again" "$(S '(d["intent"]["drift"]["streak"])')" "1"
drcommit c2; bump; begin; FPP=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$R/PLAN.md")
t_eq "DR-streak: new commits, streak 1: the pack shows an eligible state" "$(get "$STAGE/pack.json" '(d["drift"]["streak"], d["drift"]["new_work"], d["drift"]["open"])')" "(1, True, False)"
rej "DR-streak: options are exactly A / B / C" "$(drraise "file:PLAN.md"); J[\"decisions\"][-1][\"options\"]=J[\"decisions\"][-1][\"options\"][:2]" "a drift decision's options are exactly A Keep the focus"
rej "DR-streak: default is hold" "$(drraise "file:PLAN.md"); J[\"decisions\"][-1][\"default\"]=\"A\"" "a drift decision's default is hold"
rej "DR-streak: about has one value" "$(drraise "file:PLAN.md"); J[\"decisions\"][-1][\"about\"]=\"scope\"" 'about must be "drift" (the only value)'
rej "DR-streak: the closure predicate is the script's" "$(drraise "file:PLAN.md"); J[\"decisions\"][-1][\"resolves_when\"]=[{\"kind\":\"intent_changed\",\"hash\":\"$HA\"}]" "the closure predicate of a drift decision is bound by the script when it is raised"
rej "DR-streak: intent_hash and observations are the script's" "$(drraise "file:PLAN.md"); J[\"decisions\"][-1][\"intent_hash\"]=\"$HA\"" "intent_hash is owned by the script and must not be supplied"
rej "DR-streak: a model-written intent_changed predicate is refused like tid (on any new decision)" 'J["decisions"].append({"id":"D-020","q":"Is it done?","options":[{"id":"A","label":"yes"},{"id":"B","label":"no"}],"default":"hold","ready":True,"resolves_when":[{"kind":"intent_changed","hash":"abc"}]})' "resolves_when[1] kind intent_changed is bound by the script"
rej "DR-streak: only one new drift decision per judgement" "$(drraise "file:PLAN.md"); J[\"decisions\"].append(dict($DRDEC, id=\"D-011\"))" "only one new drift decision per judgement"
pub "$(drraise "file:PLAN.md")" update; t_pre "DR-streak: a second departure on new work raises the decision" "$eo" "PM_EMBED_OK"
t_eq "DR-streak: ... the script bound about, the identity, the observations and the predicate" "$(S '[{k: x.get(k) for k in ("about","intent_hash","observations","resolves_when","status","default")} for x in d["decisions"] if x["id"]=="D-010"][0]')" "{'about': 'drift', 'intent_hash': '$HA', 'observations': ['file:PLAN.md:$FPP'], 'resolves_when': [{'kind': 'intent_changed', 'hash': '$HA'}], 'status': 'open', 'default': 'hold'}"
t_eq "DR-streak: ... the departure counted (streak 2); the attention is the decision" "$(S '(d["intent"]["drift"]["streak"], d["since"]["attention"]["kind"], d["since"]["attention"]["id"])')" "(2, 'decision', 'D-010')"
if [ "$HAVE_NODE" = 1 ]; then rbpage; t_has "DR-page: the fit line names the confirmed focus" "$(pj 'd["fit"][0][1]')" "fit: departure from the confirmed focus"; fi
drcommit c3; bump; begin
t_eq "DR-carry: the pack shows the open drift decision (about kept, the script's fields kept out of the model's view)" "$(get "$STAGE/pack.json" '[{k: x.get(k) for k in ("about","intent_hash","observations","resolved")} for x in d["decisions"] if x["id"]=="D-010"][0]')|$(get "$STAGE/pack.json" 'd["drift"]["open"]')" "{'about': 'drift', 'intent_hash': None, 'observations': None, 'resolved': False}|True"
rej "DR-carry: a second open drift decision is refused" "$(drdep "file:PLAN.md"); J[\"decisions\"].append($DRDEC); J[\"decisions\"].append(dict($DRDEC, id=\"D-011\"))" "a drift decision is already open"
rej "DR-carry: dropping about from a carried decision is refused" "J[\"decisions\"].append(dict($DRDEC)); del J[\"decisions\"][-1][\"about\"]" "about is fixed when the decision is raised; repeat it unchanged"
rej "DR-carry: changing its predicate is refused" "J[\"decisions\"].append(dict($DRDEC, resolves_when=[{\"kind\":\"intent_changed\",\"hash\":\"zzz\"}]))" "resolves_when is fixed when the decision is raised"
rej "DR-carry: it cannot be closed while the focus is unchanged" "J[\"decisions\"].append(dict($DRDEC, overtaken={\"why\":\"no\"}))" "overtaken, but resolves_when does not hold yet (the confirmed focus is replaced by another)"
pub "J[\"fit\"]={\"verdict\":\"consistent\"}; J[\"decisions\"].append($DRDEC)" update
t_pre "DR-carry: after fit turned consistent the decision is carried unchanged (the gate is for new ids)" "$eo" "PM_EMBED_OK"
t_eq "DR-carry: ... still open, with the script's fields; consistent reset the streak" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-010"], [x["intent_hash"] for x in d["decisions"] if x["id"]=="D-010"], d["intent"]["drift"]["streak"], d["fit"]["verdict"])')" "(['open'], ['$HA'], 0, 'consistent')"
fcset "Other outcome" "Other done"; out=$(facts); HB=$(fch "Other outcome" "Other done")
t_pre "DR-carry: an F-set with new words: the intention changed" "$out" "NEEDS_JUDGEMENT focus set by owner"; INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "DR-carry: ... the staged drift record is reset to the new identity (Q6); the pack shows the decision resolved" "$(get "$STAGE/snapshot.json" 'd["intent"]["drift"]["hash"] == "'$HB'" and d["intent"]["drift"]["streak"] == 0'):$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-010"]')" "True:[True]"
rej "DR-streak: after the reset the first departure is not eligible (and the open decision is still there)" "$(drdep "file:PLAN.md"); J[\"decisions\"].append(dict($DRDEC, id=\"D-011\"))" "a drift decision is not allowed here"
pub "J[\"decisions\"].append(dict($DRDEC, overtaken={\"why\":\"The owner set a new focus\"}))" update
t_pre "DR-carry: the owner's new focus closes the question by events" "$eo" "PM_EMBED_OK"
t_eq "DR-carry: ... overtaken, evidence focus:changed; the drift record belongs to the new identity" "$(S '([(x["status"], x["overtaken_ref"]) for x in d["decisions"] if x["id"]=="D-010"], d["intent"]["drift"]["hash"] == "'$HB'", d["intent"]["drift"]["streak"])')" "([('overtaken', 'focus:changed')], True, 0)"

# ---- DR-exclusion: an owner exclusion named by the model makes a drift decision eligible at once
drproj dre || true
fcset "$FC_O" "$FC_D" '["no deploy"]'; begin; pub '' update
t_eq "DR-exclusion: setup: the focus carries an exclusion" "$(S 'd["intent"]["accepted"]["exclusions"]')" "['no deploy']"
drcommit e1; SHA=$(drsha); begin
rej "DR-exclusion: an index beyond the owner's exclusions" "$(drdep "commit:$SHA" 1)" "fit.exclusion 1 is not an index into the owner's exclusions (1)"
pub "$(drraise "commit:$SHA" 0)" update; t_pre "DR-exclusion: a departure naming exclusion 0 raises the decision at streak 0" "$eo" "PM_EMBED_OK"
t_eq "DR-exclusion: ... state.fit carries the index" "$(S '(d["fit"]["exclusion"], [x["status"] for x in d["decisions"] if x["id"]=="D-010"])')" "(0, ['open'])"

# L1 (Codex r4): the prompt's novelty rule ("the same commit or path counts as acknowledged, however spelled") applied to
# pack.drift.acknowledged must agree with the identity gate for every spelling fit validation accepts
ackrule() { python3 -I - "$HOOKS" "$STAGE" "$@" <<'PY'
import sys, json, os
sys.path.insert(0, sys.argv[1])
import pm_validate as VAL
snap = json.load(open(os.path.join(sys.argv[2], "snapshot.json")))
pack = json.load(open(os.path.join(sys.argv[2], "pack.json")))
acks = pack["drift"]["acknowledged"]
gate = set(snap["intent"]["drift"]["acknowledged"]["observations"])
def rule(ref):
    if ref.startswith("commit:"):
        sha = ref[7:]
        return any(a.startswith("commit:") and (a[7:].startswith(sha) or sha.startswith(a[7:])) for a in acks)
    rest = ref[5:]
    head, _, tail = rest.rpartition(":")
    if head and tail.isdigit():
        rest = head
    return any(a.startswith("file:") and os.path.normpath(a[5:]) == os.path.normpath(rest) for a in acks)
out = []
for ref in sys.argv[3:]:
    ident, prob = VAL.resolve_observation(ref, snap, pack)
    out.append([prob is None, rule(ref), ident in gate])
print(json.dumps(out))
PY
}
# ---- DR-ack: the owner's answers act on the drift record under the intent_hash guard; re-alert only on NEW material evidence
t_eq "DR-ack: reducer unit: A acknowledges the observations and resets the streak; B asks for a revision; C and hold change nothing" "$(python3 -I - "$HOOKS" <<'PY'
import sys, json, copy
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_common as C, pm_collect as K
def rec(h): return {"outcome": "o", "done_when": "d", "exclusions": [], "hash": h, "at": None, "line": 1}
def dec(ih="A"): return {"id": "D-010", "status": "open", "about": "drift", "intent_hash": ih, "observations": ["o1"], "options": [{"id": "A"}, {"id": "B"}, {"id": "C"}]}
def ans(a, line=1): return {"id": "D-010", "answer": a, "at": None, "by": "owner", "note": None, "line": line}
def fset(o, line=1): return dict(id="F-set", answer=o, note="d", at=None, by="owner", exclusions=[], line=line)
def run(pending, ih="A", streak=3, rev=False):
    d = C.new_drift("A"); d["streak"] = streak; d["revise_requested"] = rev
    it = {"accepted": rec("A"), "proposed": None, "target": None, "drift": d}
    K.apply_answers({"D-010": dec(ih)}, pending, it)
    return it["drift"]
out = []
d = run([ans("A")]); out.append((d["streak"], d["acknowledged"], d["revise_requested"]))
d = run([ans("B")]); out.append((d["streak"], d["acknowledged"], d["revise_requested"]))
d = run([ans("C")]); out.append((d["streak"], d["acknowledged"], d["revise_requested"]))
d = run([ans("hold")]); out.append((d["streak"], d["acknowledged"], d["revise_requested"]))
d = run([ans("A")], ih="Z"); out.append(("stale decision", d["streak"], d["acknowledged"]))
NEWH = C.intent_hash("New", "d", [])
d = run([fset("New", 1), ans("B", 2)]); out.append(("F-set new, old B", d["hash"] == NEWH, d["revise_requested"], d["streak"]))
d = run([ans("B", 1), fset("New", 2)]); out.append(("old B, F-set new", d["hash"] == NEWH, d["revise_requested"], d["streak"]))
same = dict(fset("x"), answer="o")
same_h = C.intent_hash("o", "d", [])
it = {"accepted": dict(rec(same_h)), "proposed": None, "target": None, "drift": dict(C.new_drift(same_h), revise_requested=True, streak=2)}
K.apply_answers({}, [dict(same, line=1)], it); out.append(("same F-set", it["drift"]["revise_requested"], it["drift"]["streak"], it["drift"]["hash"] == same_h))
print(json.dumps(out))
PY
)" '[[0, {"observations": ["o1"]}, false], [3, null, true], [3, null, false], [3, null, false], ["stale decision", 3, null], ["F-set new, old B", true, false, 0], ["old B, F-set new", true, false, 0], ["same F-set", false, 2, true]]'
drproj dra || true
fcset "$FC_O" "$FC_D" '["no deploy"]'; begin; pub '' update
echo "new" > "$R/ev/new.md"; drcommit a1; begin
FPN=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$R/ev/new.md")
pub "$(drraise "file:ev/new.md" 0)" update; t_pre "DR-ack: setup: the decision is raised on file evidence (exclusion 0)" "$eo" "PM_EMBED_OK"
t_eq "DR-ack: ... its observations are the file's identity" "$(S '[x["observations"] for x in d["decisions"] if x["id"]=="D-010"][0]')" "['file:ev/new.md:$FPN']"
printf '{"id":"D-010","answer":"A","at":"2026-10-11T10:00:00+03:00","by":"owner"}\n' >> "$PM/answers.jsonl"; begin
t_eq "DR-ack: the owner answered A: the staged drift record acknowledges exactly those observations" "$(get "$STAGE/snapshot.json" '(d["intent"]["drift"]["acknowledged"], d["intent"]["drift"]["streak"], [x["status"] for x in d["decisions"] if x["id"]=="D-010"])')" "({'observations': ['file:ev/new.md:$FPN']}, 0, ['answered'])"
t_eq "DR-ack (K1): the pack the model receives names the acknowledged ref in the string form it lists it (the file is unchanged); the commit-based new_work is not that signal" "$(get "$STAGE/pack.json" '(d["drift"]["acknowledged"], d["drift"]["new_work"], "ev/new.md" in d["dirty_paths"])')" "(['file:ev/new.md'], False, True)"
rej "DR-ack: the same observations do not re-raise it (even with an exclusion)" "$(drraise2 "file:ev/new.md" 0)" "the owner already acknowledged these observations"
rej "DR-ack: ... a re-spelled ref (with a line number) is the same identity" "$(drraise2 "file:ev/new.md:1" 0)" "the owner already acknowledged these observations"
rej "DR-ack (L1): ... a normalised path spelling (./) is the same identity" "$(drraise2 "file:./ev/new.md" 0)" "the owner already acknowledged these observations"
t_eq "DR-ack (L1): every accepted spelling of the acknowledged file (bare, with a line number, with ./) is acknowledged by the prompt rule AND by the identity gate" "$(ackrule "file:ev/new.md" "file:ev/new.md:1" "file:./ev/new.md")" "[[true, true, true], [true, true, true], [true, true, true]]"
t_true "DR-ack (L1): the agent prompt states the rule: evidence spelled as the pack lists it, and the same commit or path counts as acknowledged however spelled" "grep -q 'spelled exactly as the pack lists them (no line number, no \`./\`)' '$TD/../agents/project-map.md' && grep -q 'the same commit or path counts as acknowledged, however spelled' '$TD/../agents/project-map.md'"
echo "more" >> "$R/ev/new.md"; begin
FPN2=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$R/ev/new.md")
t_eq "DR-ack (K1): the same file changed again with NO new commits: new_work is false, yet it is NOT in pack.drift.acknowledged (a changed file is new evidence)" "$(get "$STAGE/pack.json" '(d["drift"]["acknowledged"], d["drift"]["new_work"], d["since"]["commits"])')" "([], False, 0)"
pub "$(drraise2 "file:ev/new.md" 0)" update
t_pre "DR-ack: a changed file at the same path is new material evidence: re-raised" "$eo" "PM_EMBED_OK"
t_eq "DR-ack: ... under a new id, with the new identity" "$(S '[(x["id"], x["observations"]) for x in d["decisions"] if x.get("about") == "drift" and x["status"] == "open"]')" "[('D-011', ['file:ev/new.md:$FPN2'])]"
printf '{"id":"D-011","answer":"B","at":"2026-10-11T10:00:00+03:00","by":"owner"}\n' >> "$PM/answers.jsonl"; begin; pub '' update
t_eq "DR-ack: B: a revision is requested (published), the brief says what to do" "$(S 'd["intent"]["drift"]["revise_requested"]')|$(grep '^focus:' "$PM/brief.txt")" "True|focus: revision requested: say the new one"
if [ "$HAVE_NODE" = 1 ]; then rbpage; t_has "DR-ack: ... the page says so under the focus" "$(pj 'd["since"]')" "revision requested: say the new focus"; fi
fcset "Other outcome" "Other done"; begin
t_eq "DR-ack: the next F-set clears the request and starts a new record (staged)" "$(get "$STAGE/snapshot.json" '(d["intent"]["drift"]["revise_requested"], d["intent"]["drift"]["hash"] == "'$(fch "Other outcome" "Other done")'", d["intent"]["drift"]["acknowledged"])')" "(False, True, None)"
pub '' update
t_eq "DR-ack: ... and it is published so: the brief is back to the focus" "$(S 'd["intent"]["drift"]["revise_requested"]')|$(grep '^focus:' "$PM/brief.txt")" "False|focus: Other outcome (confirmed)"

# ---- K1: the pack tells the model which refs are already acknowledged (commits relisted after a branch switch)
drproj drb || true
fcset "$FC_O" "$FC_D" '["no deploy"]'; begin; pub '' update
BASEC=$(cd "$R" && git rev-parse HEAD)
drcommit b1; SC=$(drsha); begin
pub "$(drraise "commit:$SC" 0)" update; t_pre "DR-ack (K1): setup: the question is raised on commit C" "$eo" "PM_EMBED_OK"
printf '{"id":"D-010","answer":"A","at":"2026-10-11T10:00:00+03:00","by":"owner"}\n' >> "$PM/answers.jsonl"
(cd "$R" && git checkout -q -b sib "$BASEC" && echo s > sib.txt && git add sib.txt && git commit -qm sib); begin; pub '' update
t_pre "DR-ack (K1): setup: a judgement on a sibling branch consumes the answer" "$eo" "PM_EMBED_OK"
(cd "$R" && git checkout -q main); drcommit b2; SD=$(drsha); begin
t_eq "DR-ack (K1): back on C's branch with a later unrelated commit D: C is listed AGAIN (history rewritten) and new_work is true, but the pack names C as acknowledged and not D" "$(get "$STAGE/pack.json" '(sorted(i["h"] for dd in d["commits"]["days"] for i in dd["items"] if i["h"] in ("'$SC'", "'$SD'")) == sorted(["'$SC'", "'$SD'"]), d["drift"]["acknowledged"], d["drift"]["new_work"], d["drift"]["streak"])')" "(True, ['commit:$SC'], True, 0)"
t_eq "DR-ack (L1): the commits: C by its listed short sha and by its full oid is acknowledged by the prompt rule AND by the gate; D is new to both" "$(ackrule "commit:$SC" "commit:$(cd "$R" && git rev-parse "$SC")" "commit:$SD")" "[[true, true, true], [true, true, true], [true, false, false]]"
rej "DR-ack (K1): citing only the acknowledged commit is refused although new_work is true" "J[\"fit\"]={\"verdict\":\"departure\",\"concern\":\"x\",\"evidence\":[\"commit:$SC\"],\"exclusion\":0}; J[\"decisions\"].append(dict($DRDEC, id=\"D-011\"))" "the owner already acknowledged these observations"
pub "J[\"fit\"]={\"verdict\":\"departure\",\"concern\":\"x\",\"evidence\":[\"commit:$SC\",\"commit:$SD\"],\"exclusion\":0}; J[\"decisions\"].append(dict($DRDEC, id=\"D-011\"))" update
t_pre "DR-ack (K1): ... citing the new commit D as well is accepted" "$eo" "PM_EMBED_OK"
t_eq "DR-ack (K1): acknowledged_refs unit: the string form of the pack, commits first, at most 6, a changed or unverified file is not listed" "$(python3 -I - "$HOOKS" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
oids = ["%07x" % (i + 1) + "0" * 33 for i in range(10)]
hs = [o[:7] for o in oids]
snap = {"commit_oids": {".|%s" % h: o for h, o in zip(hs, oids)}, "watch": [{"path": "w.md", "kind": "file"}], "prev_key": {"watch_hashes": {"w.md": "aaa"}}, "key": {"watch_hashes": {"w.md": "bbb"}},
        "file_fp": {"a.md": {"fp": "111111111111", "status": "verified"}, "b.md": {"fp": "222222222222", "status": "verified"}, "c.md": {"status": "unknown"}, "w.md": {"fp": "333333333333", "status": "verified"}},
        "intent": {"drift": {"acknowledged": {"observations": ["commit:.:" + o for o in oids] + ["file:a.md:111111111111", "file:b.md:OLDOLDOLDOLD", "file:c.md:111111111111", "file:w.md:333333333333"]}}}}
pack = {"commits": {"days": [{"items": [{"r": ".", "h": h} for h in hs]}]}, "dirty_paths": ["a.md", "b.md", "c.md", "other.md"], "watch": [{"path": "w.md"}]}
many = V.acknowledged_refs(snap, pack)
snap2 = json.loads(json.dumps(snap)); snap2["intent"]["drift"]["acknowledged"]["observations"] = ["file:a.md:111111111111", "file:b.md:OLDOLDOLDOLD", "file:c.md:111111111111", "file:w.md:333333333333"]
few = V.acknowledged_refs(snap2, pack)
pack3 = {"commits": {"days": [{"items": [{"r": ".", "h": hs[0]}]}]}, "dirty_paths": [], "watch": []}
snap3 = json.loads(json.dumps(snap)); snap3["intent"]["drift"]["acknowledged"] = None
print(json.dumps([len(many), many[:2] == ["commit:" + hs[0], "commit:" + hs[1]], few, V.acknowledged_refs(snap, pack3), V.acknowledged_refs(snap3, pack), V.acknowledged_refs(snap, None)]))
PY
)" '[6, true, ["file:a.md", "file:w.md"], ["commit:0000001"], [], []]'
t_eq "DR-ack (K1): the list is part of every size measurement: six long refs force a trim the pack would not otherwise make, and the pack stays inside 8192" "$(python3 -I - "$HOOKS" "$STAGE" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K, pm_validate as V
snap = json.load(open(sys.argv[2] + "/snapshot.json"))
snap["intent"]["drift"]["acknowledged"] = {"observations": ["commit:.:x"]}
def pack(L):
    s2 = json.loads(json.dumps(snap)); s2["dirty_paths"] = ["d/" + "x" * L + "%02d" % i for i in range(20)]
    return K.build_pack(s2, "inv-x")
L = next(L for L in range(10, 400, 5) if len(json.dumps(pack(L))) >= 7300)
base = pack(L)
real = V.acknowledged_refs
V.acknowledged_refs = lambda sn, p, limit=6: ["file:" + "y" * 300] * 6
big = pack(L)
V.acknowledged_refs = real
print(json.dumps([len(json.dumps(base)) <= 8192, len(base["dirty_paths"]), len(json.dumps(big)) <= 8192, len(big["dirty_paths"]) < len(base["dirty_paths"]), len(big["drift"]["acknowledged"])]))
PY
)" '[true, 20, true, true, 6]'

# the three channels that reduce owner lines (collection, late answers, --accept-answers): an old answer never marks a new intention
drproj drch || true
fcset "$FC_O" "$FC_D" '["no deploy"]'; begin; pub '' update
drcommit h1; SHA=$(drsha); begin; pub "$(drraise "commit:$SHA" 0)" update; t_pre "DR-ack: setup: an open drift decision about the first intention" "$eo" "PM_EMBED_OK"
HB=$(fch "Other outcome" "Other done" '[]')
Bl='{"id":"D-010","answer":"B","at":"2026-10-11T10:00:00+03:00","by":"owner"}'
Fl='{"id":"F-set","answer":"Other outcome","note":"Other done","at":"2026-10-11T10:00:00+03:00","by":"owner"}'
L1=$(head -n 1 "$PM/answers.jsonl")
drlines() { printf '%s\n' "$L1" > "$PM/answers.jsonl"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$PM/answers.jsonl"; done; }   # line 1 (applied) stays: only what follows it changes
drlines "$Bl"; begin
t_eq "DR-ack: collection, control: the answer about the CURRENT intention asks for a revision" "$(get "$STAGE/snapshot.json" '(d["intent"]["drift"]["revise_requested"])')" "True"
drlines "$Fl" "$Bl"; begin
t_eq "DR-ack: collection: F-set new, then the old B: the new intention is untouched" "$(get "$STAGE/snapshot.json" '(d["intent"]["drift"]["revise_requested"], d["intent"]["drift"]["hash"] == "'$HB'", d["intent"]["accepted"]["hash"] == "'$HB'")')" "(False, True, True)"
drlines "$Bl" "$Fl"; begin
t_eq "DR-ack: collection: the old B, then the F-set new: reset by the F-set" "$(get "$STAGE/snapshot.json" '(d["intent"]["drift"]["revise_requested"], d["intent"]["drift"]["hash"] == "'$HB'")')" "(False, True)"
t_eq "DR-ack: late answers (the reducer unit), both orders: the old B never marks the new intention; the control does" "$(python3 -I - "$HOOKS" "$PM" "$STAGE" "$HB" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
pm, stage, hb = sys.argv[2:5]
snap = json.load(open(stage + "/snapshot.json"))
snap["answers"] = dict(snap["answers"], total=0, applied=0, total_hash=K.prefix_hash([], 0))
B = '{"id":"D-010","answer":"B","at":"2026-10-11T10:00:00+03:00","by":"owner"}'.encode()
F = '{"id":"F-set","answer":"Other outcome","note":"Other done","at":"2026-10-11T10:00:00+03:00","by":"owner"}'.encode()
snap["intent"] = {k: v for k, v in snap["intent"].items()}
snap["intent"]["accepted"] = None
def late(lines):
    r = K.late_answers(pm, dict(snap, intent=json.loads(json.dumps(INTENT0))), ["D-010"], image=[(i + 1, l) for i, l in enumerate(lines)])
    d = r["intent"]["drift"]; return (d["revise_requested"], d["hash"] == hb)
# the staged intent for late answers is the one BEFORE the lines: take the published first intention
import os
prev = K.load_prev(pm)
INTENT0 = K.intent_of(prev["state"])
snap["decisions"] = prev["state"]["decisions"]
print(json.dumps([late([B]), late([F, B]), late([B, F])]))
PY
)" '[[true, false], [false, true], [false, true]]'
drlines "$Fl" "$Bl"; out=$(python3 "$HOOKS/project-map-facts.py" --accept-answers "$R"); begin
t_eq "DR-ack: --accept-answers replay (F-set new, old B): the new intention is untouched" "$(get "$STAGE/snapshot.json" '(d["intent"]["drift"]["revise_requested"], d["intent"]["drift"]["hash"] == "'$HB'", d["intent"]["accepted"]["hash"] == "'$HB'")')" "(False, True, True)"
drlines "$Bl" "$Fl"; out=$(python3 "$HOOKS/project-map-facts.py" --accept-answers "$R"); begin
t_eq "DR-ack: --accept-answers replay (old B, F-set new): reset by the F-set" "$(get "$STAGE/snapshot.json" '(d["intent"]["drift"]["revise_requested"], d["intent"]["drift"]["hash"] == "'$HB'")')" "(False, True)"
drlines "$Bl"; out=$(python3 "$HOOKS/project-map-facts.py" --accept-answers "$R"); begin
t_eq "DR-ack: --accept-answers replay, control (only the B about the current intention): it counts" "$(get "$STAGE/snapshot.json" 'd["intent"]["drift"]["revise_requested"]')" "True"

# ---- DR-carry (late): an F-set that arrives while a closure by events is judged resets the drift record; the question closes on the next judgement
drproj drl "$(ovraise "$RW_TP,$RW_SY")" || true
fcset "$FC_O" "$FC_D" '["no deploy"]'; begin; pub "$DRE" update
drcommit l1; begin; pub "$(drraise "commit:$(drsha)" 0); $DRE" update
HA=$(fch "$FC_O" "$FC_D" '["no deploy"]'); HB=$(fch "Other outcome" "Other done" '[]')
t_eq "DR-carry (late): setup: an open drift decision about the first intention" "$(S '[(x["status"], x["intent_hash"]) for x in d["decisions"] if x.get("about") == "drift"]')" "[('open', '$HA')]"
drcommit l2; ovpush drl; bump; begin
jud "$INVN" update "$(drdep "file:PLAN.md"); $(ovj "J[\"decisions\"].append($DRDEC); $DRE")"
fcset "Other outcome" "Other done"; printf '{"id":"D-002","answer":"hold","by":"owner"}\n' >> "$PM/answers.jsonl"; rm "$R/ev/c2.md"
eo=$(embed "$INVN")
t_has "DR-carry (late): the answer won over the closure by events" "$eo" "PM_EMBED_NOTE owner answer for D-002"
t_eq "DR-carry (late): the late F-set is the accepted record and RESET the drift record (no streak, no request, no acknowledgement)" "$(S '(d["intent"]["accepted"]["outcome"], d["intent"]["drift"]["hash"] == "'$HB'", d["intent"]["drift"]["streak"], d["intent"]["drift"]["revise_requested"], d["intent"]["drift"]["acknowledged"])')" "('Other outcome', True, 0, False, None)"
t_eq "DR-carry (late): ... the fit is published as judged (against the focus it was written against)" "$(S '(d["fit"]["verdict"], d["fit"]["against"])')" "('departure', 'accepted')"
t_eq "DR-carry (late): ... the raised decision stays open and about the first intention; the assurance says the focus changed" "$(S '([(x["status"], x["intent_hash"]) for x in d["decisions"] if x.get("about") == "drift"], [w for w in d["assurance"]["why"] if "focus" in w])')" "([('open', '$HA')], ['focus changed after the assessment'])"
t_eq "DR-carry (late): the publication recheck is in this path too: the file that vanished meanwhile is unverified, and the map is behind" "$(S '(d["stale"]["why"], [c["id"] for ph in d["phases"] for c in ph["criteria"] if c.get("unverified")])')" "('completion evidence lost: P1.c2', ['P1.c2'])"
out=$(facts); INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_pre "DR-carry (late): the next run re-judges" "$out" "NEEDS_JUDGEMENT "
t_eq "DR-carry (late): ... and the pack shows the old question resolved (the focus it was about is gone)" "$(get "$STAGE/pack.json" '[x["resolved"] for x in d["decisions"] if x["id"]=="D-010"]')" "[True]"
pub "J[\"decisions\"]=[x for x in J[\"decisions\"] if x[\"id\"]!=\"D-002\"]; J[\"decisions\"].append(dict($DRDEC, overtaken={\"why\":\"The owner set a new focus\"})); $DRE" update
t_pre "DR-carry (late): the next judgement closes the old question" "$eo" "PM_EMBED_OK"
t_eq "DR-carry (late): ... by events: focus:changed" "$(S '[(x["status"], x["overtaken_ref"]) for x in d["decisions"] if x.get("about") == "drift"]')" "[('overtaken', 'focus:changed')]"

# ---- the other publication paths keep the evidence honest: the prompt hook's mechanical refresh, a deferred closure
drproj drm2 || true
rm "$R/ev/c2.md"; (cd "$R" && git add -A && git commit -qm "drop c2")
eo=$(embed --mechanical --deadline 5); t_pre "DR-refresh: the hook's mechanical refresh (no staging) finds the loss" "$eo" "PM_EMBED_OK"
t_eq "DR-refresh: ... marks it, says the map is behind, and does NOT rebase the judged key (the loss still has to be judged)" "$(S '([c["id"] for ph in d["phases"] for c in ph["criteria"] if c.get("unverified")], d["stale"]["why"], d["judged_key"]["evidence_lost"], d["evidence"]["lost"][0]["id"])')" "(['P1.c2'], '1 new commits; completion evidence lost: P1.c2', [], 'P1.c2')"
out=$(facts); t_pre "DR-refresh: ... and facts re-judges" "$out" "NEEDS_JUDGEMENT 1 new commits; completion evidence lost: P1.c2 inv "
drproj drt "$(ovraise "$RW_TP,$RW_SY")" || true
ovpush drt; bump; begin
jud "$INVN" update "$(ovj "$DRE")"; printf '{"id":"D-002","answ' >> "$PM/answers.jsonl"; rm "$R/ev/c1.md"
eo=$(embed "$INVN")
t_has "DR-deferred: an uncommitted answer tail defers the closure by events" "$eo" "PM_EMBED_NOTE uncommitted answer tail; events closure of D-002 deferred"
t_eq "DR-deferred: ... and the evidence recheck of that very publication is in the state" "$(S '([x["status"] for x in d["decisions"] if x["id"]=="D-002"], [c["id"] for ph in d["phases"] for c in ph["criteria"] if c.get("unverified")], d["judged_key"]["evidence_lost"], d["evidence"]["recheck"])')" "(['open'], ['P1.c1'], ['P1.c1'], {'done': 5, 'n': 5})"

# ---- display: brief lines 5b / 6b / 11b, handoff 9b, drop orders
t_eq "DR-brief: the lines appear in the display order and go in the drop order: 12, 10, 8 (last first), 7, 6b, 5b, 5, 9, 11b, 11" "$(python3 -I - "$HOOKS" "$TD/../docs/demo-state.json" <<'PY'
import sys, json, copy
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_render as R
S = json.load(open(sys.argv[2]))
S["decisions"][0]["status"] = "overtaken"; S["decisions"][0].update(overtaken_why="done by hand", overtaken_ref="tag:v1")
S["since"] = {"from": {"generation": "g", "assessed_at": "2026-10-01T09:00:00+03:00"}, "commits": 3, "listed": 3, "dirty": 1, "hours": 5,
              "changes": [{"text": "change one is here", "state": "landed", "ref": "commit:abc1234"}, {"text": "change two is here", "state": "uncommitted", "ref": None},
                          {"text": "change three is here", "state": "uncommitted", "ref": None}],
              "attention": {"kind": "drift", "text": "attention text", "why": "attention why"}, "not_checked": []}
S["intent"] = {"accepted": {"outcome": "Ship it", "done_when": "It ships", "exclusions": [], "hash": "h", "at": "2026-10-01", "line": 1}, "proposed": None, "target": None}
S["fit"] = {"verdict": "departure", "concern": "fit concern text", "evidence": [], "observations": [], "exclusion": None, "scope": {"shown": 3, "total": 3}, "against": "accepted"}
S["evidence"] = {"checked": "complete", "n": 3, "done": 3, "unknown": [], "lost": [{"id": "P1.c1", "ref": "file:docs/one.md", "why": "file missing"}, {"id": "P1.c2", "ref": "file:docs/two.md", "why": "file missing"}, {"id": "engine", "ref": "file:docs/three.md:4", "why": "line past end"}]}
S["stale"] = {"judged_at": "x", "commits_since": 1, "why": "1 new commits"}
S["coverage"] = {"coverage": "partial", "covered": 1, "total": 2}
S["repos"][0]["release"] = {"line": "tagged v1 at HEAD"}
S["usage"] = {"totals": {"all": 123456, "claude": 100000, "codex": 23456}}
marks = [("tokens ", "12"), ("git: ", "10"), ("- change three", "8c"), ("- change two", "8b"), ("- change one", "8a"), ("since ", "7"), ("focus: ", "6b"), ("fit: ", "5b"),
         ("attention: ", "5"), ("D-001 overtaken", "9"), ("evidence lost: ", "11b"), ("coverage partial", "11c"), ("stale: ", "11")]
full = R.brief(S).splitlines()
present = lambda L: [m for p, m in marks if any(x.startswith(p) for x in L)]
order, seen = [], set(present(full))
pos = [m for p, m in marks if any(x.startswith(p) for x in full)]
disp = [next(i for i, x in enumerate(full) if x.startswith(p)) for p, m in marks if any(x.startswith(p) for x in full)]
for pad in range(0, 700, 5):
    T = copy.deepcopy(S); T["headline"]["text"] = "h" * (40 + pad)
    L = R.brief(T).splitlines()
    now = set(present(L))
    for m in [m for p, m in marks if m in seen and m not in now]:
        order.append(m); seen.discard(m)
    assert len(R.brief(T).encode()) <= 1000
    assert L[1].startswith("as of") and L[-1].startswith("generation")
i5, i5b, i6b = [next(i for i, x in enumerate(full) if x.startswith(p)) for p in ("attention: ", "fit: ", "focus: ")]
i6 = next(i for i, x in enumerate(full) if x.startswith("next: "))
print(json.dumps([order, [i5 < i5b < i6 < i6b], len(full)]))
PY
)" '[["12", "10", "8c", "8b", "8a", "7", "6b", "5b", "5", "9", "11b", "11c", "11"], [true], 18]'
t_eq "DR-brief: 6b shows a pending revision request instead of the outcome; 5b only for a departure" "$(python3 -I - "$HOOKS" "$TD/../docs/demo-state.json" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_render as R
S = json.load(open(sys.argv[2]))
S["intent"] = {"accepted": {"outcome": "Ship it", "done_when": "It ships", "exclusions": [], "hash": "h", "at": "2026-10-01", "line": 1}, "proposed": None, "target": None,
               "drift": {"hash": "h", "streak": 1, "heads": None, "acknowledged": None, "revise_requested": True}}
S["fit"] = {"verdict": "consistent", "concern": None, "evidence": [], "observations": [], "exclusion": None, "scope": {"shown": 1, "total": 1}, "against": "accepted"}
L = R.brief(S).splitlines()
print(json.dumps([[x for x in L if x.startswith("focus:")], [x for x in L if x.startswith("fit:")]]))
PY
)" '[["focus: revision requested: say the new one"], []]'
t_eq "DR-handoff: 9b follows 'Next' and goes after the since lines and before 'Where it stands' (12, 11 second first, 8 last first, 7, 9b, 6, 10, 9, 4)" "$(python3 -I - "$HOOKS" "$TD/../docs/demo-state.json" <<'PY'
import sys, json, copy
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_render as R
S = json.load(open(sys.argv[2]))
S["decisions"] = [dict(S["decisions"][0], id="D-%03d" % i, q="question %d" % i, status="open", ready=True) for i in range(1, 3)]
S["since"] = {"from": {"generation": "g", "assessed_at": "2026-10-01T09:00:00+03:00"}, "commits": 3, "listed": 3, "dirty": 1, "hours": 5,
              "changes": [{"text": "change %s is here" % w, "state": "landed", "ref": "commit:abc1234"} for w in ("one", "two", "three")],
              "attention": {"kind": "decision", "id": "D-001", "text": "t", "why": "w"}, "not_checked": []}
S["intent"] = {"accepted": {"outcome": "Ship the import", "done_when": "The import runs", "exclusions": ["no deploy"], "hash": "h", "at": "2026-10-01", "line": 1}, "proposed": None, "target": None}
S["fit"] = {"verdict": "departure", "concern": "The new work is not the import", "evidence": [], "observations": [], "exclusion": None, "scope": None, "against": "accepted"}
S["risks"] = [{"id": "R-1", "text": "first risk", "severity": "high"}, {"id": "R-2", "text": "second risk", "severity": "med"}]
S["repos"][0]["release"] = {"line": "tagged v1 at HEAD"}
marks = [("Evidence: ", "12"), ("Open risk: R-2", "11b"), ("Open risk: R-1", "11a"), ("- change three", "8c"), ("- change two", "8b"), ("- change one", "8a"),
         ("Since ", "7"), ("Fit: ", "9b"), ("Where it stands", "6"), ("Needs the owner", "10"), ("Next: ", "9"), ("Done when", "4")]
full = R.handoff(S).splitlines()
present = lambda L: {m for p, m in marks if any(x.startswith(p) for x in L)}
assert present(full) == {m for _p, m in marks}, present(full)
idx = {m: next(i for i, x in enumerate(full) if x.startswith(p)) for p, m in marks}
order, seen = [], present(full)
for cap in range(len(R.handoff(S).encode()), 100, -1):
    R.HANDOFF_MAX = cap
    L = R.handoff(S).splitlines()
    now = present(L)
    for m in [m for _p, m in marks if m in seen and m not in now]:
        order.append(m); seen.discard(m)
    assert all(x for x in L[:3]) and L[-1].startswith("Context only")
print(json.dumps([idx["9"] < idx["9b"] < idx["10"], idx["6"] < idx["7"] < idx["9"], order]))
PY
)" '[true, true, ["12", "11b", "11a", "8c", "8b", "8a", "7", "9b", "6", "10", "9", "4"]]'

# ---- DR-assurance / DR-fit page: the evidence clauses join the one predicate; the fit line says what the model saw
ax 'S["evidence"]["checked"]="partial"'; t_eq "DR-assurance: a partial evidence check is a reason" "$(axq '"evidence check incomplete" in d["assurance"]["why"]')" "True"
ax 'del S["evidence"]'; t_eq "DR-assurance: a state without the evidence view (before 3.6) is not certified either" "$(axq '"evidence check incomplete" in d["assurance"]["why"]')" "True"
ax 'S["evidence"]["recheck"]={"done":1,"n":3}'; t_eq "DR-assurance: an incomplete publication recheck says how far it got" "$(axq '[w for w in d["assurance"]["why"] if "recheck" in w]')" "['publication recheck 1 of 3']"
ax 'S["evidence"]["recheck"]={"done":3,"n":3}'; t_eq "DR-assurance: ... a complete one is no reason" "$(axq '[w for w in d["assurance"]["why"] if "recheck" in w]')" "[]"
ax 'S["phases"][0]["criteria"][0]["unverified"]=True; S["parts"][0]["unverified"]=True'; t_eq "DR-assurance: unverified items are named (the first, then how many more)" "$(axq '[w for w in d["assurance"]["why"] if "unverified" in w]')" "['P1.c1 unverified +1']"
if [ "$HAVE_NODE" = 1 ]; then
  rbpage '{"fit":{"verdict":"consistent","concern":null,"evidence":[],"observations":[],"exclusion":null,"scope":{"shown":12,"total":30},"against":"accepted"}}'
  t_eq "DR-fit: the page says 'consistent with the inspected work (12 of 30 commits shown)'" "$(pj 'd["fit"]')" "[['consistent', 'fit: consistent with the inspected work (12 of 30 commits shown)']]"
  rbpage '{"fit":{"verdict":"consistent","concern":null,"evidence":[],"observations":[],"exclusion":null,"scope":{"shown":30,"total":30},"against":"accepted"}}'
  t_eq "DR-fit: ... without the scope when everything was shown" "$(pj 'd["fit"]')" "[['consistent', 'fit: consistent with the inspected work']]"
  rbpage '{"fit":{"verdict":"departure","concern":"A <script>x</script> concern","evidence":["commit:abc1234"],"observations":[],"exclusion":null,"scope":{"shown":3,"total":9},"against":"accepted"}}'
  t_eq "DR-fit: a departure names the focus, the concern (as text, never markup) and the scope" "$(pj '(d["fit"], d["scripts"])')" "([['departure', 'fit: departure from the confirmed focus · A <script>x</script> concern (3 of 9 commits shown)']], 0)"
  rbpage '{"fit":{"verdict":"unknown","concern":null,"evidence":[],"observations":[],"exclusion":null,"scope":{"shown":1,"total":1},"against":"proposed"}}'
  t_eq "DR-fit: unknown is said as not judged" "$(pj 'd["fit"]')" "[['unknown', 'fit: not judged']]"
  rbpage '{"evidence":{"checked":"partial","n":60,"done":40,"lost":[],"unknown":[]}}'
  t_has "DR-page: a partial evidence check says how far it got" "$(pj 'd["progress"]')" "evidence check 40 of 60"
fi

# ======================================================================================================
# Codex round 1 on 3.6.0 (I1 .. I5)
# ======================================================================================================
# ---- I1 (DR-carry-mark): a judged publication keeps a mark the previous state carries until the ref verified OK
if [ "$ISROOT" = 0 ]; then
mkrepo dri1; printf 'ign/\n' >> "$R/.gitignore"; mkdir -p "$R/ign"; echo x > "$R/ign/u1.md"; echo x > "$R/ign/u2.md"; (cd "$R" && git add -A && git commit -qm "ign setup"); begin
pub 'P["phases"][0]["criteria"]=[{"id":"P1.c1","text":"One","done":True,"ref":"file:ign/u1.md"},{"id":"P1.c2","text":"Two","done":True,"ref":"file:ign/u2.md"}]' full
t_pre "DR-carry-mark: setup" "$eo" "PM_EMBED_OK"
rm "$R/ign/u1.md"; out=$(embed --mechanical --deadline 8)
t_eq "DR-carry-mark: setup: the refresh found the loss and marked the criterion" "$(S '[c for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P1.c1"][0].get("unverified")')" "True"
chmod 000 "$R/ign"; drcommit k1; begin
t_eq "DR-carry-mark: the world changed: the latest status is UNKNOWN (nothing lost, nothing ok) when the next assessment is staged" "$(get "$STAGE/snapshot.json" '(d["evidence"]["lost"], d["evidence"]["unknown"], [e["id"] for e in d["evidence"]["ok"]])')" "([], ['P1.c1', 'P1.c2'], ['engine', 'ground-truth'])"
pub '' update; t_pre "DR-carry-mark: an unrelated key movement; the unchanged criterion is legal (not a listed repair)" "$eo" "PM_EMBED_OK"
t_eq "DR-carry-mark: ... the judged publication keeps the mark (done untouched), says nothing is lost, and the assurance still names it" "$(S '([c.get("unverified") for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P1.c1"], [c["done"] for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P1.c1"], d["evidence"]["lost"], [w for w in d["assurance"]["why"] if "unverified" in w])')" "([True], [True], [], ['P1.c1 unverified'])"
chmod 755 "$R/ign"
# an UNVISITED ref: 56 criteria, the last ones are not reached by the first pass of a fresh record
mkrepo dri2; printf 'ign/\n' >> "$R/.gitignore"; mkdir -p "$R/ign"; for i in $(seq -w 1 56); do echo x > "$R/ign/r$i.md"; done; (cd "$R" && git add -A && git commit -qm "ign setup"); begin
DRI2='P["phases"]=[{"id":"P%d"%(i+1),"label":"Phase %d"%(i+1),"criteria":[{"id":"P%d.c%d"%(i+1,j+1),"text":"Criterion %d.%d"%(i+1,j+1),"done":True,"ref":"file:ign/r%02d.md"%(i*8+j+1)} for j in range(8)]} for i in range(7)]'
pub "$DRI2" full; t_pre "DR-carry-mark: setup (56 criteria)" "$eo" "PM_EMBED_OK"
rm "$R/ign/r56.md"; out=$(embed --mechanical --deadline 8); out=$(embed --mechanical --deadline 8)
t_eq "DR-carry-mark: setup: two passes reached P7.c8 and marked it" "$(S '[c.get("unverified") for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P7.c8"]')" "[True]"
python3 - "$PM/cache.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d.pop("evidence", None); json.dump(d, open(sys.argv[1], "w"))
PY
drcommit k2; begin
t_eq "DR-carry-mark: with a fresh record the first pass leaves P7.c8 UNVISITED: no loss, not ok" "$(get "$STAGE/snapshot.json" '(d["evidence"]["lost"], d["evidence"]["checked"], d["evidence"]["done"], "P7.c8" in [e["id"] for e in d["evidence"]["ok"]])')" "([], 'partial', 40, False)"
pub '' update
t_eq "DR-carry-mark: ... the publication keeps the mark of the unvisited ref" "$(S '([c.get("unverified") for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P7.c8"], [w for w in d["assurance"]["why"] if "unverified" in w])')" "([True], ['P7.c8 unverified'])"
else echo "SKIP DR-carry-mark (running as root)"; fi

# ---- I2 (DR-final-plan): a FULL run is validated against the FINAL plan (rebuilt plan + criteria_updates)
drproj drp1 || true
rm "$R/ev/c2.md"; (cd "$R" && git add -A && git commit -qm "drop c2"); begin; SHA=$(drsha)
rej "DR-final-plan: a rebuilt plan that keeps the listed loss done, with nothing in criteria_updates, is refused" "$(drcode "$SHA")" "P1.c2 completion evidence is lost" full
rej "DR-final-plan: ... and so is a criteria_updates entry with the old (missing) ref" "$(drcode "$SHA" 'J["criteria_updates"]=[{"id":"P1.c2","done":True,"ref":"file:ev/c2.md"}]')" "P1.c2" full
pub "$(drcode "$SHA" 'J["criteria_updates"]=[{"id":"P1.c2","done":True,"ref":"file:ev/c1.md:1"}]')" full
t_pre "DR-final-plan: criteria_updates may give the listed loss a NEW ref although plan.out.json still shows the old one" "$eo" "PM_EMBED_OK"
t_eq "DR-final-plan: ... the published criterion carries the new ref and no mark" "$(drcrit P1.c2)" "{'id': 'P1.c2', 'text': 'Engine builds', 'done': True, 'ref': 'file:ev/c1.md:1'}"
drproj drp2 || true
rm "$R/ev/c2.md"; (cd "$R" && git add -A && git commit -qm "drop c2"); begin; SHA=$(drsha)
pub "$(drcode "$SHA" 'J["criteria_updates"]=[{"id":"P1.c2","done":False}]')" full
t_pre "DR-final-plan: criteria_updates may reopen the listed loss" "$eo" "PM_EMBED_OK"
t_eq "DR-final-plan: ... reopened, nothing lost" "$(S '([c["done"] for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P1.c2"], d["evidence"]["lost"])')" "([False], [])"
drproj drp3 || true
bump; begin; SHA=$(drsha)
rej "DR-final-plan: a done criterion of the rebuilt plan with a missing ref that is NOT a known loss is still refused" "$(drcode "$SHA" 'P["phases"][0]["criteria"].append({"id":"P1.c4","text":"New","done":True,"ref":"file:ev/gone.md"})')" "criterion P1.c4: file ref ev/gone.md is not an existing regular file" full

# ---- I3 (DR-symlink): the referenced ENTRY must be a regular file; a link is not evidence
t_eq "DR-symlink: check_ref and ref_problem agree: regular ok; internal, dangling and escaping links are not evidence" "$(python3 -I - "$HOOKS" "$T" <<'PY'
import sys, os, json, shutil
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K, pm_validate as V
base = os.path.join(sys.argv[2], "symlink-root"); shutil.rmtree(base, ignore_errors=True)
root = os.path.join(base, "root"); os.makedirs(root); open(os.path.join(root, "real.md"), "w").write("1\n2\n3\n"); open(os.path.join(base, "outside.md"), "w").write("1\n2\n3\n")
os.symlink("real.md", os.path.join(root, "link.md")); os.symlink("nowhere.md", os.path.join(root, "dangle.md")); os.symlink("../outside.md", os.path.join(root, "esc.md"))
os.makedirs(os.path.join(root, "dir")); os.symlink("dir", os.path.join(root, "dirlink"))
out = []
for ref in ("file:real.md:2", "file:link.md:2", "file:dangle.md", "file:esc.md", "file:dirlink", "file:dir"):
    out.append([K.check_ref(root, [], ref)[0], V.ref_problem(root, [], ref) is None])
print(json.dumps(out))
PY
)" '[["ok", true], ["lost", false], ["lost", false], ["lost", false], ["lost", false], ["lost", false]]'
drproj drk || true
rm "$R/ev/c1.md"; ln -s c2.md "$R/ev/c1.md"; (cd "$R" && git add -A && git commit -qm "c1 is now a link"); begin
t_pre "DR-symlink: a completion file replaced by a link to another regular file is a loss" "$out" "NEEDS_JUDGEMENT 1 new commits; completion evidence lost: P1.c1 inv "
t_eq "DR-symlink: ... why: file missing (the entry is no longer the regular file the ref named)" "$(get "$STAGE/snapshot.json" '[(e["id"], e["why"]) for e in d["evidence"]["lost"]]')" "[('P1.c1', 'file missing')]"
rej "DR-symlink: and a link cannot be given back as the repair" 'J["criteria_updates"]=[{"id":"P1.c1","done":True,"ref":"file:ev/c1.md:3"}]' "criteria_updates P1.c1: file ref ev/c1.md is not an existing regular file"

# ---- I4 (DR-symlink-fp): a link has no usable fit identity, on either route
mkrepo drl4; echo base > "$R/target.md"; ln -s target.md "$R/link.md"; (cd "$R" && git add -A && git commit -qm "link"); begin; pub 'J["watch"]=["PLAN.md","link.md"]' full
echo more >> "$R/target.md"; begin
t_eq "DR-symlink-fp: a watched link (watch route only): unknown, while a watched regular file has its fingerprint" "$(get "$STAGE/snapshot.json" '(d["file_fp"]["link.md"], d["file_fp"].get("PLAN.md", {}).get("status", "unwatched-and-unmoved"))')" "({'status': 'unknown'}, 'verified')"
rm "$R/link.md"; ln -s PLAN.md "$R/link.md"; begin
t_eq "DR-symlink-fp: ... the same link on BOTH routes (watched and dirty): still unknown, one entry" "$(get "$STAGE/snapshot.json" '("link.md" in d["dirty_paths"], d["file_fp"]["link.md"])')" "(True, {'status': 'unknown'})"
t_eq "DR-symlink-fp: ... and resolve_observation refuses it as evidence" "$(python3 -I - "$HOOKS" "$STAGE" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_validate as V
snap = json.load(open(sys.argv[2] + "/snapshot.json")); pack = json.load(open(sys.argv[2] + "/pack.json"))
print(V.resolve_observation("file:link.md", snap, pack)[1][:60])
PY
)" "file link.md has no content identity (deleted, unreadable, a"

# ---- I5 (DR-repo-unreadable): an unreadable repository is unknown; only established absence is "repo moved"
if [ "$ISROOT" = 0 ]; then
t_eq "DR-repo-unreadable: check_ref: permission denied -> unknown; the known-repository union keeps it in view; removed -> repo moved; a failed or timed-out query -> unknown" "$(python3 -I - "$HOOKS" "$T" <<'PY'
import sys, os, json, shutil, subprocess
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import pm_collect as K
base = os.path.join(sys.argv[2], "repo-root"); os.system("chmod -R u+rwx '%s' 2>/dev/null" % base); shutil.rmtree(base, ignore_errors=True)
root = os.path.join(base, "root"); repo = os.path.join(root, "blocked", "repo"); os.makedirs(repo)
env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1")
for c in (["git", "init", "-q", "-b", "main"], ["git", "config", "user.email", "t@t"], ["git", "config", "user.name", "t"], ["git", "config", "commit.gpgsign", "false"]):
    subprocess.run(c, cwd=repo, env=env, check=True)
open(os.path.join(repo, "f"), "w").write("x\n")
subprocess.run(["git", "add", "-A"], cwd=repo, env=env, check=True); subprocess.run(["git", "commit", "-qm", "c"], cwd=repo, env=env, check=True)
sha = subprocess.run(["git", "rev-parse", "--short=7", "HEAD"], cwd=repo, env=env, capture_output=True, text=True).stdout.strip()
rows = [{"path": "blocked/repo", "vcs": "git"}]
ref = "commit:" + sha
out = [K.check_ref(root, rows, ref)[0]]                                          # healthy: ok
os.chmod(os.path.join(root, "blocked"), 0)
out.append(K.check_ref(root, rows, ref))                                          # EACCES on the way to the repository
state = {"repos": [{"path": ".", "vcs": "git"}, {"path": "blocked/repo", "vcs": "git"}]}
out.append([r["path"] for r in K.evidence_repos([{"path": ".", "vcs": "git"}], state)])    # collection dropped it: the pinned state still names it
out.append([r["path"] for r in K.evidence_repos([{"path": "blocked/repo", "vcs": "none"}], state)])   # seen as a plain folder: still probed
os.chmod(os.path.join(root, "blocked"), 0o755)
real = K.G.run
K.G.run = lambda *a, **k: (124, "")                                               # a timed-out git query
out.append(K.check_ref(root, rows, ref))
K.G.run = real
os.chmod(os.path.join(repo, ".git"), 0)                                           # a repository whose git cannot be read: the query fails (128) and git cannot name its toplevel
out.append(K.check_ref(root, rows, ref))
os.chmod(os.path.join(repo, ".git"), 0o755)
shutil.rmtree(os.path.join(root, "blocked"))                                      # genuinely removed
out.append(K.check_ref(root, rows, ref))
print(json.dumps(out))
PY
)" '["ok", ["unknown", ""], [".", "blocked/repo"], ["blocked/repo", ".", "blocked/repo"], ["unknown", ""], ["unknown", ""], ["lost", "repo moved"]]'
# through collection: a known nested repository that can no longer be entered
mkrepo drn; drfiles; printf 'repo2/\n' >> "$R/.gitignore"; mkdir -p "$R/repo2"; (cd "$R/repo2" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && echo n > n.txt && git add -A && git commit -qm nested); (cd "$R" && git add -A && git commit -qm "ignore repo2"); begin
NSHA=$(cd "$R/repo2" && git rev-parse --short=7 HEAD)
pub "$(drcode "$NSHA")" full
t_pre "DR-repo-unreadable: setup: a completion commit that lives in the nested repository" "$eo" "PM_EMBED_OK"
t_eq "DR-repo-unreadable: ... the nested repository is known to the state" "$(S '[(r["path"], r["vcs"]) for r in d["repos"]]')" "[('.', 'git'), ('repo2', 'git')]"
chmod 000 "$R/repo2"; out=$(facts)
t_not "DR-repo-unreadable: it cannot be entered any more: the verdict does not call the commit lost" "$out" "completion evidence lost"
t_eq "DR-repo-unreadable: ... the snapshot has it unknown, nothing lost, no repair queued" "$(get "$PM/inv-${out##* }/snapshot.json" '(d["evidence"]["lost"], "P1.c3" in d["evidence"]["unknown"])' 2>/dev/null || echo none)" "([], True)"
# J1: the unknown criterion is PUBLISHED by an UPDATE while the repository is still unreadable; the state must keep naming the repository
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
pub "$DRE" update; t_pre "DR-repo-unreadable: an UPDATE is published while the repository stays inaccessible (the unchanged criterion is legal)" "$eo" "PM_EMBED_OK"
t_eq "DR-repo-unreadable: ... the published state still names the repository as git (kept, marked inaccessible, no release facts); nothing lost" "$(S '([(r["path"], r["vcs"], r.get("inaccessible"), "release" in r) for r in d["repos"]], d["evidence"]["lost"], d["judged_key"]["evidence_lost"], d["evidence"]["unknown"])')" "([('.', 'git', None, True), ('repo2', 'git', True, False)], [], [], ['P1.c3'])"
out=$(facts)
t_eq "DR-repo-unreadable: pass 1 after the publication, permissions still denied: the ref stays unknown, no loss, nothing to repair" "${out%% *}:$(S 'd["evidence"]["lost"]'):$(evrec 'd["results"]["P1.c3|commit:'$NSHA'"]["status"]')" "NO_CHANGE:[]:unknown"
out=$(embed --mechanical --deadline 8)
t_eq "DR-repo-unreadable: pass 2 (a mechanical refresh): the repository is still in the state, the ref still unknown, still no loss" "$(S '([(r["path"], r["vcs"], r.get("inaccessible")) for r in d["repos"]], d["evidence"]["lost"], d["stale"])'):$(evrec 'd["results"]["P1.c3|commit:'$NSHA'"]["status"]')" "([('.', 'git', None), ('repo2', 'git', True)], [], None):unknown"
out=$(facts)
t_eq "DR-repo-unreadable: pass 3 (facts again): still unknown, never lost, never a repair" "${out%% *}:$(S 'd["evidence"]["lost"]'):$(evrec 'd["results"]["P1.c3|commit:'$NSHA'"]["status"]')" "NO_CHANGE:[]:unknown"
chmod 755 "$R/repo2"; out=$(facts)
t_eq "DR-repo-unreadable: permissions restored: the next pass verifies the commit (ok)" "$(evrec 'd["results"]["P1.c3|commit:'$NSHA'"]["status"]')" "ok"
out=$(embed --mechanical --deadline 8)
t_eq "DR-repo-unreadable: ... and a refresh reads the repository as git again: the kept marker is gone" "$(S '[(r["path"], r["vcs"], r.get("inaccessible")) for r in d["repos"]]')" "[('.', 'git', None), ('repo2', 'git', None)]"
# control: a repository that is genuinely removed is established absence: lost, repo moved (a loss to repair)
mkrepo drn2; drfiles; printf 'repo2/\n' >> "$R/.gitignore"; mkdir -p "$R/repo2"; (cd "$R/repo2" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && echo n > n.txt && git add -A && git commit -qm nested); (cd "$R" && git add -A && git commit -qm "ignore repo2"); begin
NSHA2=$(cd "$R/repo2" && git rev-parse --short=7 HEAD); pub "$(drcode "$NSHA2")" full
rm -rf "$R/repo2"; begin
t_has "DR-repo-unreadable: control: the repository is really gone -> the commit is a loss to repair" "$out" "completion evidence lost: P1.c3"
t_eq "DR-repo-unreadable: ... why: repo moved" "$(get "$STAGE/snapshot.json" '[(e["id"], e["why"]) for e in d["evidence"]["lost"]]')" "[('P1.c3', 'repo moved')]"
else echo "SKIP DR-repo-unreadable (running as root)"; fi

# ======================================================================================================
# 17. 3.6.1: the model reads the commits; a later decision never waits for an answer (FX-*)
# ======================================================================================================
# ---- FX-pack: changed files counted per folder (work first), usage detail never in the pack, commit subjects the last optional cut
mkrepo fxp; begin; pub "" full
mkdir -p "$R/.backups/old" "$R/work/a" "$R/src"
for i in $(seq 1 25); do echo b > "$R/.backups/old/backup-copy-$i.md"; done
for i in $(seq 1 12); do echo w > "$R/work/a/work-$i.md"; done
for i in $(seq 1 9); do echo s > "$R/src/s$i.py"; done
for i in 1 2 3 4; do (cd "$R" && echo "$i" >> docs/a.md && git add docs/a.md && git commit -qm "work step $i"); done
begin
t_pre "FX-pack: setup: 4 commits and 46 changed files -> a judgement" "$out" "NEEDS_JUDGEMENT"
t_eq "FX-pack: every changed file is seen: 20 listed one by one, the other 26 counted under their folder" "$(get "$STAGE/pack.json" '(d["seen"]["dirty"], d["seen"]["dirty_total"], len(d["dirty_paths"]), sum(r["n"] for r in d["dirty_dirs"]))')" "(46, 46, 20, 26)"
t_eq "FX-pack: work first: no file of a hidden folder is listed while work files are left; they are counted" "$(get "$STAGE/pack.json" '([p for p in d["dirty_paths"] if p.startswith(".")], [r for r in d["dirty_dirs"] if r["dir"]==".backups/"])')" "([], [{'dir': '.backups/', 'n': 25}])"
t_eq "FX-pack: all 4 commit subjects, nothing cut, the pack revision, no usage detail" "$(get "$STAGE/pack.json" '(d["seen"]["commits"], d["seen"]["commits_total"], d["trimmed"]["items"], d["seen"]["ledger_cut"], d["rev"], "by_model" in (d.get("usage") or {}), "jobs" in (d.get("usage") or {}))')" "(4, 4, 0, False, 2, False, False)"
t_eq "FX-pack: unit: a snapshot WITH usage detail (per model, per job): the pack keeps the totals, never the detail" "$(python3 -c '
import json, sys; sys.path.insert(0, sys.argv[1]); import pm_collect as K
snap = json.load(open(sys.argv[2]))
snap["usage"] = {"at": "2026-10-11T10:00:00+03:00", "approximate": False, "totals": {"all": 5, "jobs": 1},
                 "by_model": [{"model": "m", "total": 5, "jobs": 1}], "jobs": [{"label": "j", "model": "m", "in": 1, "out": 1, "cache": 3}]}
p = K.build_pack(snap, "inv-fxunit")
print(sorted(p["usage"]), p["trimmed"]["usage"])' "$HOOKS" "$STAGE/snapshot.json")" "['approximate', 'at', 'totals'] False"
pub "" update; t_pre "FX-pack: ... published" "$eo" "PM_EMBED_OK"
t_eq "FX-pack: ... the assurance names no omitted work (nothing was cut)" "$(S '[w for w in d["assurance"]["why"] if "map read" in w or "partly read" in w or "not read" in w]')" "[]"
python3 -c 'import sys
L = "\n".join("- line %d %s" % (i, "x" * 180) for i in range(12))
open(sys.argv[1], "w").write("## Goal\n%s\n## Now\n%s\n## Next action\n%s\n## Blockers\n%s\n" % (L, L, L, L))' "$R/thoughts/ledgers/demo-engine.md"
for i in 5 6 7 8; do (cd "$R" && echo "$i" >> docs/a.md && git add docs/a.md && git commit -qm "work step $i"); done
begin
t_eq "FX-pack: a 9 KB ledger: the listed files fold into folder counts (no cut), the ledger is cut, every commit subject stays" "$(get "$STAGE/pack.json" '(len(d["dirty_paths"]), d["seen"]["dirty"], d["seen"]["dirty_total"], d["seen"]["ledger_cut"], d["seen"]["commits"], d["seen"]["commits_total"], d["trimmed"]["items"], sorted(i["s"] for x in d["commits"]["days"] for i in x["items"]))')" "(0, 47, 47, True, 4, 4, 0, ['work step 5', 'work step 6', 'work step 7', 'work step 8'])"
t_true "FX-pack: ... pack <= 8192 bytes" "[ \$(wc -c < $STAGE/pack.json) -le 8192 ]"
t_eq "FX-pack: unit: hidden-folder rank and folder names" "$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_collect as K;print([K.dirty_rank(p) for p in ("a.md",".env","src/x.py",".b/x.md","src/__pycache__/x.pyc","src/.cache/y")], [K.dirty_dir(p) for p in ("a.md","src/x/y.py")], K.dirty_dirs(["a/1","b/1","a/2","c"], {"b/": 2}))' "$HOOKS")" "[0, 0, 0, 1, 1, 1] ['./', 'src/'] [{'dir': 'b/', 'n': 3}, {'dir': 'a/', 'n': 2}, {'dir': './', 'n': 1}]"

# ---- FX-rejudge: a judgement that read a cut pack of an older pack revision is redone ONCE; never for the current revision
mkrepo fxr; begin; pub "" full
lib mut "$PM/current/state.json" 'd["judged_seen"]=dict(d["judged_seen"], commits=0, commits_total=4); d.pop("judged_pack", None)'; lib resign "$PM/current"
out=$(facts); t_pre "FX-rejudge: the last judgement read 0 of 4 commits from a pack before 3.6.1 -> one judgement" "$out" "NEEDS_JUDGEMENT previous assessment read only part of the changes inv "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"; pub "" update; t_pre "FX-rejudge: ... published" "$eo" "PM_EMBED_OK"
t_eq "FX-rejudge: ... the new state records the pack revision the model read" "$(S 'd["judged_pack"]')" "2"
out=$(facts); t_not "FX-rejudge: ... and the next run does not judge again" "$out" "NEEDS_JUDGEMENT"
lib mut "$PM/current/state.json" 'd["judged_seen"]=dict(d["judged_seen"], commits=0, commits_total=4)'; lib resign "$PM/current"
out=$(facts); t_not "FX-rejudge: a cut read with the current revision is not redone (once per revision, bounded)" "$out" "NEEDS_JUDGEMENT"
lib mut "$PM/current/state.json" 'd["judged_seen"]=dict(d["judged_seen"], commits=0, commits_total=0, dirty=0, dirty_total=0, ledger_cut=False); d.pop("judged_pack", None)'; lib resign "$PM/current"
out=$(facts); t_not "FX-rejudge: an older revision that cut nothing is not redone" "$out" "NEEDS_JUDGEMENT"

# ---- FX-window: a commit leaves the window only once a judgement read every commit its snapshot listed (16.6)
mkrepo fxw; begin; pub "" full
t_eq "FX-window: a first map reads from its own heads" "$(S 'd["read"]["heads"] == d["judged_key"]["heads"] and d["read"]["generation"] == d["generation"]')" "True"
for i in 1 2 3; do (cd "$R" && echo "$i" >> docs/a.md && git add docs/a.md && git commit -qm "batch step $i"); done
G1=$(gen); begin
lib mut "$STAGE/pack.json" 'd["seen"]["commits"]=1'   # the pack this judgement reads showed 1 of the 3 listed commits
pub "" update; t_pre "FX-window: a judgement that read 1 of 3 listed commits publishes" "$eo" "PM_EMBED_OK"
t_eq "FX-window: ... the window start stays where it was (the heads and the generation before the batch)" "$(S '(d["read"]["heads"] != d["judged_key"]["heads"], d["read"]["generation"])')" "(True, '$G1')"
t_has "FX-window: ... and the assurance says what it did not read" "$(S 'd["assurance"]["why"]')" "map read 1 of 3 commits"
(cd "$R" && echo 4 >> docs/a.md && git add docs/a.md && git commit -qm "batch step 4"); begin
t_eq "FX-window: the next judgement's window holds the 3 unread commits and the new one, measured from the earlier point" "$(get "$STAGE/pack.json" '(d["commits"]["count"], sorted(i["s"] for x in d["commits"]["days"] for i in x["items"]), d["since"]["generation"], d["seen"]["commits"], d["seen"]["commits_total"])')" "(4, ['batch step 1', 'batch step 2', 'batch step 3', 'batch step 4'], '$G1', 4, 4)"
pub "" update; t_pre "FX-window: ... it reads all of them" "$eo" "PM_EMBED_OK"
t_eq "FX-window: ... so the window moves on to the heads it read" "$(S '(d["read"]["heads"] == d["judged_key"]["heads"], d["read"]["generation"] == d["generation"], [w for w in d["assurance"]["why"] if "map read" in w])')" "(True, True, [])"
(cd "$R" && echo 5 >> docs/a.md && git add docs/a.md && git commit -qm "batch step 5"); begin
t_eq "FX-window: ... and the next window is the ordinary one" "$(get "$STAGE/pack.json" '(d["commits"]["count"], [i["s"] for x in d["commits"]["days"] for i in x["items"]])')" "(1, ['batch step 5'])"
t_eq "FX-window: unit: read point: everything listed read -> the staged heads; fewer -> the window start; no previous assessment -> the staged heads" "$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import pm_validate as V
snap = {"commits": {"count": 60, "listed": 40}, "key": {"heads": {".": "bbbbbbbbbbbb"}}, "facts_at": "T", "window_heads": {".": "aaaaaaaaaaaa"},
        "since": {"generation": "000001-00000000", "assessed_at": "T0"}}
a = V.read_point(snap, {"commits": 40}, "000002-11111111")["heads"]; b = V.read_point(snap, {"commits": 39}, "g")["heads"]
c = V.read_point(snap, None, "g")["heads"]; snap["since"] = None; d = V.read_point(snap, {"commits": 0}, "g")["heads"]
print(a, b, c, d)' "$HOOKS")" "{'.': 'bbbbbbbbbbbb'} {'.': 'aaaaaaaaaaaa'} {'.': 'aaaaaaaaaaaa'} {'.': 'bbbbbbbbbbbb'}"
# J1: a repository discovered after the read point, and a folder that becomes a Git repository, keep their unread commits too
mkrepo fxn; begin; pub "" full
printf 'repo2/\n' >> "$R/.gitignore"; mkdir -p "$R/repo2"; (cd "$R/repo2" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && for i in 1 2 3; do echo $i > n$i.txt; git add -A; git commit -qm "nested $i"; done); (cd "$R" && git add -A && git commit -qm "ignore repo2")
begin
t_eq "FX-window new repo: setup: the new repository's 3 commits and the root's 1 are in the window" "$(get "$STAGE/pack.json" 'sorted(i["s"] for x in d["commits"]["days"] for i in x["items"])')" "['ignore repo2', 'nested 1', 'nested 2', 'nested 3']"
lib mut "$STAGE/pack.json" 'd["seen"]["commits"]=1'; pub "" update; t_pre "FX-window new repo: a judgement that read 1 of 4 publishes" "$eo" "PM_EMBED_OK"
t_eq "FX-window new repo: ... the held window names the new repository as starting at its history" "$(S 'repr(d["read"]["heads"].get("repo2"))')" "''"
(cd "$R" && echo r >> docs/a.md && git add docs/a.md && git commit -qm "root after"); begin
t_eq "FX-window new repo: the next window still holds the new repository's unread commits" "$(get "$STAGE/pack.json" 'sorted(i["s"] for x in d["commits"]["days"] for i in x["items"])')" "['ignore repo2', 'nested 1', 'nested 2', 'nested 3', 'root after']"
pub "" update; (cd "$R" && echo r >> docs/a.md && git add docs/a.md && git commit -qm "root later"); begin
t_eq "FX-window new repo: once read, they leave the window" "$(get "$STAGE/pack.json" 'sorted(i["s"] for x in d["commits"]["days"] for i in x["items"])')" "['root later']"
mkdir -p "$T/fxg"; R=$(cd "$T/fxg" && pwd -P); PM="$R/.project-map"; seq 1 300 > "$R/PLAN.md"; seq 1 200 > "$R/REVIEW-LOG.md"; echo r > "$R/README.md"; mkdir -p "$R/docs"; echo d > "$R/docs/a.md"
begin; pub "" full; t_pre "FX-window plain folder: setup: a map of a folder without Git" "$eo" "PM_EMBED_OK"
(cd "$R" && printf '.project-map/\n' > .gitignore && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && git add -A && git commit -qm "first git commit" && echo 2 >> docs/a.md && git commit -qam "second git commit")
begin; lib mut "$STAGE/pack.json" 'd["seen"]["commits"]=0'; pub "" update; t_pre "FX-window plain folder: it becomes a Git repository; a judgement reads 0 of its 2 commits" "$eo" "PM_EMBED_OK"
(cd "$R" && echo 3 >> docs/a.md && git commit -qam "third git commit"); begin
t_eq "FX-window plain folder: the next window still holds the 2 unread commits" "$(get "$STAGE/pack.json" 'sorted(i["s"] for x in d["commits"]["days"] for i in x["items"])')" "['first git commit', 'second git commit', 'third git commit']"
# a state from before 3.6.1 (no `read`) whose judgement read fewer commits than its snapshot listed: the re-judgement re-opens that batch
mkrepo fxl; begin; pub "" full
for i in 1 2 3; do (cd "$R" && echo "$i" >> docs/a.md && git add docs/a.md && git commit -qm "old batch $i"); done
G1=$(gen); begin; pub "" update; t_pre "FX-window legacy: setup: a judged batch of 3 commits" "$eo" "PM_EMBED_OK"
lib mut "$PM/current/state.json" 'd.pop("read", None); d.pop("judged_pack", None); d["judged_seen"]=dict(d["judged_seen"], commits=0)'; lib resign "$PM/current"
out=$(facts); t_pre "FX-window legacy: that judgement read 0 of 3 -> the one re-judgement" "$out" "NEEDS_JUDGEMENT previous assessment read only part of the changes inv "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FX-window legacy: ... its window is the unread batch again, measured from the generation it started from" "$(get "$STAGE/pack.json" '(d["commits"]["count"], sorted(i["s"] for x in d["commits"]["days"] for i in x["items"]), d["since"]["generation"])')" "(3, ['old batch 1', 'old batch 2', 'old batch 3'], '$G1')"
pub "" update; t_pre "FX-window legacy: ... published" "$eo" "PM_EMBED_OK"
t_eq "FX-window legacy: ... read everything: the window moves on, revision recorded" "$(S '(d["read"]["heads"] == d["judged_key"]["heads"], d["judged_pack"])')" "(True, 2)"
mkrepo fxl2; begin; pub "" full
for i in 1 2; do (cd "$R" && echo "$i" >> docs/a.md && git add docs/a.md && git commit -qm "gone batch $i"); done
G1=$(gen); begin; pub "" update
lib mut "$PM/current/state.json" 'd.pop("read", None); d.pop("judged_pack", None); d["judged_seen"]=dict(d["judged_seen"], commits=0)'; lib resign "$PM/current"
lib mut "$PM/gen-$G1/state.json" 'd["judged_at"]="2000-01-01T00:00:00+00:00"'   # still valid JSON: only the signature catches it
t_eq "FX-window legacy: the window never restarts from a start generation that does not verify (checked before any run cleans it up)" "$(python3 -c '
import sys, json; sys.path.insert(0, sys.argv[1]); import pm_collect as K
print(K.window_base(sys.argv[2], K.load_prev(sys.argv[2] + "/.project-map")))' "$HOOKS" "$R")" "(None, None)"
out=$(facts --no-stage); t_pre "FX-window legacy: ... and it is still the one re-judgement" "$out" "NEEDS_JUDGEMENT previous assessment read only part of the changes"
rm -rf "$PM/gen-$G1"
out=$(facts); t_pre "FX-window legacy: the generation it started from is gone: still the one re-judgement" "$out" "NEEDS_JUDGEMENT previous assessment read only part of the changes inv "
t_eq "FX-window legacy: ... with the ordinary window (nothing to restart from)" "$(get "$PM/inv-${out##* }/pack.json" '(d["commits"]["count"], d["since"]["generation"] != "'"$G1"'")')" "(0, True)"
# K1 (r3): legacy states with a null head (a plain root): the null is the history start, it never disables recovery for the map
mkdir -p "$T/fxk"; R=$(cd "$T/fxk" && pwd -P); PM="$R/.project-map"; seq 1 300 > "$R/PLAN.md"; seq 1 200 > "$R/REVIEW-LOG.md"; echo r > "$R/README.md"; mkdir -p "$R/docs" "$R/nested"; echo d > "$R/docs/a.md"
(cd "$R/nested" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && echo 0 > n.txt && git add -A && git commit -qm "nested start")
begin; pub "" full; t_eq "FX-window legacy plain root: setup: the root has a null head next to the nested repository's" "$(S 'sorted((r, h is None) for r, h in d["judged_key"]["heads"].items())')" "[('.', True), ('nested', False)]"
for i in 1 2 3; do (cd "$R/nested" && echo "$i" >> n.txt && git commit -qam "nested work $i"); done
G1=$(gen); begin; pub "" update
lib mut "$PM/current/state.json" 'd.pop("read", None); d.pop("judged_pack", None); d["judged_seen"]=dict(d["judged_seen"], commits=0)'; lib resign "$PM/current"
out=$(facts); t_pre "FX-window legacy plain root: the old cut judgement -> the one re-judgement" "$out" "NEEDS_JUDGEMENT previous assessment read only part of the changes inv "
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FX-window legacy plain root: ... the nested repository's 3 unread commits are back in the window" "$(get "$STAGE/pack.json" '(sorted(i["s"] for x in d["commits"]["days"] for i in x["items"]), d["since"]["generation"])')" "(['nested work 1', 'nested work 2', 'nested work 3'], '$G1')"
pub "" update; t_eq "FX-window legacy plain root: ... read, the window moves on" "$(S 'd["read"]["heads"]["nested"] == d["judged_key"]["heads"]["nested"] and d["read"]["generation"] == d["generation"]')" "True"
mkdir -p "$T/fxk2"; R=$(cd "$T/fxk2" && pwd -P); PM="$R/.project-map"; seq 1 300 > "$R/PLAN.md"; seq 1 200 > "$R/REVIEW-LOG.md"; echo r > "$R/README.md"; mkdir -p "$R/docs"; echo d > "$R/docs/a.md"
begin; pub "" full
(cd "$R" && printf '.project-map/\n' > .gitignore && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && git add -A && git commit -qm "first git commit" && echo 2 >> docs/a.md && git commit -qam "second git commit")
G1=$(gen); begin; pub "" update
lib mut "$PM/current/state.json" 'd.pop("read", None); d.pop("judged_pack", None); d["judged_seen"]=dict(d["judged_seen"], commits=0)'; lib resign "$PM/current"
out=$(facts); INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FX-window legacy plain-to-Git: the old cut judgement re-opens the 2 commits from the root's history" "$(get "$STAGE/pack.json" 'sorted(i["s"] for x in d["commits"]["days"] for i in x["items"])')" "['first git commit', 'second git commit']"
t_eq "FX-window unit: null and \"\" are one start; a read record equal to the judged heads up to that spelling is the ordinary window" "$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import pm_collect as K
print(K._heads_ok({".": None, "n": "aaaaaaa"}, {".": None, "n": "bbbbbbb"}), K._heads_ok({".": "", "n": "aaaaaaa"}, {".": None, "n": "aaaaaaa"}), K._heads_ok({".": 5}, {}))' "$HOOKS")" "True False False"
# L1 (r4): an invocation staged by 3.6.0 (no window_heads, a pack without rev) published by the current embed keeps the unread batch
fxold() { # NAME KEEP_PREV_KEY(1|0): a map, 3 commits staged the 3.6.0 way, a judgement that read none of them, published now
  mkrepo "$1"; begin; pub "" full
  for i in 1 2 3; do (cd "$R" && echo "$i" >> docs/a.md && git add docs/a.md && git commit -qm "staged old $i"); done
  G1=$(gen); begin
  lib mut "$STAGE/snapshot.json" 'd.pop("window_heads", None)'"$( [ "$2" = 0 ] && printf '; d["prev_key"]=None' )"
  lib mut "$STAGE/pack.json" 'd.pop("rev", None); d["seen"]["commits"]=0'
  pub "" update
}
fxold fxo1 1; t_pre "FX-window old staging: a 3.6.0 staging that read 0 of 3 publishes" "$eo" "PM_EMBED_OK"
t_eq "FX-window old staging: ... the read record starts where that window started (its staged judged heads), not empty" "$(S '(d["read"]["heads"] != {} and d["read"]["heads"] != d["judged_key"]["heads"], d["read"]["generation"], d["judged_pack"])')" "(True, '$G1', 1)"
out=$(facts); INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FX-window old staging: ... the one re-judgement re-opens the 3 unread commits" "$(printf '%s' "${out%% inv *}")|$(get "$STAGE/pack.json" 'sorted(i["s"] for x in d["commits"]["days"] for i in x["items"])')" "NEEDS_JUDGEMENT previous assessment read only part of the changes|['staged old 1', 'staged old 2', 'staged old 3']"
pub "" update; t_eq "FX-window old staging: ... read, the window moves on" "$(S '(d["read"]["heads"] == d["judged_key"]["heads"], d["judged_pack"])')" "(True, 2)"
fxold fxo2 0; t_pre "FX-window old staging without prev_key: publishes" "$eo" "PM_EMBED_OK"
t_eq "FX-window old staging without prev_key: ... no read record is written (no recoverable start)" "$(S '"read" in d')" "False"
out=$(facts); INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
t_eq "FX-window old staging without prev_key: ... the legacy restart (since.from.generation) re-opens the 3 commits" "$(get "$STAGE/pack.json" '(sorted(i["s"] for x in d["commits"]["days"] for i in x["items"]), d["since"]["generation"])')" "(['staged old 1', 'staged old 2', 'staged old 3'], '$G1')"
# I2: a partial hash pass must not postpone the one re-judgement forever
mkdir -p "$T/fxc"; R=$(cd "$T/fxc" && pwd -P); PM="$R/.project-map"; seq 1 300 > "$R/PLAN.md"; seq 1 200 > "$R/REVIEW-LOG.md"; echo r > "$R/README.md"; mkdir -p "$R/docs"
python3 - "$R/docs" <<'PY'
import sys
for i in range(60): open("%s/d%03d.md" % (sys.argv[1], i), "w").write("doc %d\n" % i * 20)
PY
begin; pub "" full
lib mut "$PM/current/state.json" 'd.pop("judged_pack", None); d["judged_seen"]=dict(d["judged_seen"], ledger_cut=True)'; lib resign "$PM/current"
rm -f "$PM/cache.json"; out=$(PM_FACTS_SLOW=0.02 facts --budget 1)
t_pre "FX-rejudge-partial: an old cut judgement and a partial hash pass -> the re-judgement, not another refresh" "$out" "NEEDS_JUDGEMENT previous assessment read only part of the changes"

# ---- FX-page: a ready:false decision is a LATER decision, never "waits for your answer"; the plan table numbers phases like the list
if [ "$HAVE_NODE" = 1 ]; then
  FXD1='{"id":"D-001","q":"Open the PR?","options":[{"id":"A","label":"Open"},{"id":"B","label":"Hold"}],"recommended":"A","default":"hold","hard_rule":"upstream_post","deadline":null,"ready":false,"status":"open"}'
  FXD2='{"id":"D-002","q":"Pick a name?","options":[{"id":"A","label":"Alpha"},{"id":"B","label":"Beta"}],"recommended":"A","default":"A","hard_rule":null,"deadline":null,"ready":true,"status":"open"}'
  rbpage '{"decisions":['"$FXD1"','"$FXD2"']}'
  t_eq "FX-page: the ready decision is a card under the current phase; the ready:false one only under Later decisions, not asked yet" "$(pj 'sorted(d["cards"])')" "[['D-001', True, 'Not asked yet · will need your explicit answer'], ['D-002', False, 'Default A']]"
  t_eq "FX-page: ... the disclosure says how many, right after the Handoff (which stays first, 3.5)" "$(pj 'd["disclosures"][:2]')" "['Handoff', 'Later decisions (1, not asked yet)']"
  t_eq "FX-page: ... and only the ready one needs the owner" "$(pj '(d["pill"], d["count"])')" "('Needs you', '1')"
  rbpage '{"decisions":['"$FXD1"']}'
  t_eq "FX-page: only a ready:false decision: no card under the phase, nothing waits for the owner" "$(pj '(sorted(d["cards"]), d["count"] in ("Nothing", "None found"), "Waits for your answer" in json.dumps(d))')" "([['D-001', True, 'Not asked yet · will need your explicit answer']], True, False)"
  t_eq "FX-page: the plan table names a phase by its position in the phase list (01, 02, ...), never by its id" "$(pj 'sorted(set(x[1] for x in d["planPhase"]))')" "$(S 'sorted("%02d" % (i + 1) for i, p in enumerate(d["phases"]) if p.get("criteria"))')"
fi

# ======================================================================================================
# 18. 3.6.2: the checklist is judged every run; evidence is the checked-out history (FX2-*), INTERFACES section 17
# ======================================================================================================
crit_of() { S '[(c["id"], c["done"], c.get("retired")) for ph in d["phases"] for c in ph["criteria"] if c["id"]=="'"$1"'"][0]'; }
# ---- FX2-checklist (17.1): every judgement sees the open checklist; applied updates are not re-sent
mkrepo fx2c; begin; pub "" full
(cd "$R" && echo 1 >> docs/a.md && git commit -qam "step one"); begin
t_eq "FX2-checklist: the pack lists the active open criteria, current phase first, full text" "$(get "$STAGE/pack.json" '([c["id"] for c in d["criteria"]][:2], all(len(c["text"]) > 0 for c in d["criteria"]), d["seen"]["criteria_cut"])')" "(['P2.c1', 'P2.c2'], True, 0)"
pub 'J["criteria_updates"]=[{"id":"P2.c1","done":True,"ref":"file:PLAN.md:12"}]' update; t_pre "FX2-checklist: an update closes P2.c1" "$eo" "PM_EMBED_OK"
(cd "$R" && echo 2 >> docs/a.md && git commit -qam "step two"); begin
t_eq "FX2-checklist: the next staging re-sends no applied update, and the closed item left the list" "$(get "$STAGE/judgement.in.json" 'd["criteria_updates"]')|$(get "$STAGE/pack.json" '"P2.c1" in [c["id"] for c in d["criteria"]]')" "[]|False"
mkrepo fx2m; begin
pub 'P["phases"]=[{"id":"P%d"%p,"label":"Phase %d"%p,"criteria":[{"id":"P%d.c%d"%(p,c),"text":"Criterion %d of phase %d, with a condition that matters at the very end"%(c,p),"done":False} for c in range(1,9)]} for p in range(1,8)]; J["current_phase"]="P3"' full
(cd "$R" && echo 1 >> docs/a.md && git commit -qam "more"); begin
t_eq "FX2-checklist: 56 open items: the pack lists 30 (the current phase first), the other 26 are counted as not shown" "$(get "$STAGE/pack.json" '(len(d["criteria"]), d["criteria"][0]["id"], d["seen"]["criteria_cut"], d["criteria"][0]["text"].endswith("at the very end"))')" "(30, 'P3.c1', 26, True)"
pub "" update; t_has "FX2-checklist: ... and the assurance says so" "$(S 'd["assurance"]["why"]')" "26 checklist items not shown"
t_eq "FX2-checklist: unit: a 3.6.1 staged pack (no criteria_cut) is still a valid seen record; a stray key is not" "$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_collect as K
o={k:0 for k in K.SEEN_KEYS};o["ledger_cut"]=False
print(K.valid_seen(o), K.valid_seen(dict(o,criteria_cut=2)), K.valid_seen(dict(o,other=1)))' "$HOOKS")" "True True False"

# ---- FX2-retire (17.2): an item that no longer applies is retired, visibly, never counted, never revived by an UPDATE
mkrepo fx2r; begin; pub "" full
(cd "$R" && echo 1 >> docs/a.md && git commit -qam "scope change"); begin
rej "FX2-retire: a done criterion is never retired" 'J["criteria_updates"]=[{"id":"P1.c1","retired":True,"why":"no longer needed"}]' "a shipped criterion is never retired"
rej "FX2-retire: at most 3 per judgement" 'J["criteria_updates"]=[{"id":"P2.c%d"%i,"retired":True,"why":"scope changed"} for i in (1,2,3,4)]' "at most 3 per judgement"
rej "FX2-retire: retired must be true" 'J["criteria_updates"]=[{"id":"P2.c1","retired":False,"why":"x"}]' "retired must be true"
rej "FX2-retire: a why over 100 bytes" 'J["criteria_updates"]=[{"id":"P2.c1","retired":True,"why":"w"*101}]' "why"
pub 'J["criteria_updates"]=[{"id":"P2.c2","retired":True,"why":"the reset dropped the edits it names"}]' update; t_pre "FX2-retire: retiring an open item publishes" "$eo" "PM_EMBED_OK"
t_eq "FX2-retire: ... kept in its phase, not done, with the reason and time" "$(S '[(c["done"], c["retired"]["why"], bool(c["retired"].get("at"))) for ph in d["phases"] for c in ph["criteria"] if c["id"]=="P2.c2"][0]')" "(False, 'the reset dropped the edits it names', True)"
t_eq "FX2-retire: ... and counted nowhere (phase total shrinks, retired count shown)" "$(S '[(p["total"], p.get("retired")) for p in d["phases"] if p["id"]=="P2"][0]')" "($(get "$STAGE/plan.json" 'len([c for ph in d["phases"] if ph["id"]=="P2" for c in ph["criteria"]]) - 1'), 1)"
t_has "FX2-retire: ... the change log names it with its text" "$(S '[c["text"] for c in d["changes"] if c["id"]=="P2.c2"]')" "retired (no longer applies: the reset dropped the edits it names)"
(cd "$R" && echo 2 >> docs/a.md && git commit -qam "later"); begin
t_eq "FX2-retire: a retired item is not in the pack's checklist" "$(get "$STAGE/pack.json" '"P2.c2" in [c["id"] for c in d["criteria"]]')" "False"
rej "FX2-retire: an UPDATE cannot close (revive) a retired item" 'J["criteria_updates"]=[{"id":"P2.c2","done":True,"ref":"file:PLAN.md:3"}]' "only a FULL rebuild can bring it back"
rej "FX2-retire: nor retire it twice" 'J["criteria_updates"]=[{"id":"P2.c2","retired":True,"why":"again"}]' "already retired"
if [ "$HAVE_NODE" = 1 ]; then rbpage
  t_eq "FX2-retire: page: progress counts active items and says how many are retired; the row says it no longer applies" "$(pj '(d["progress"].endswith("active · 1 retired"), [c[1] for c in d["criteria"] if c[0]=="P2.c2"][0].endswith("no longer applies · the reset dropped the edits it names"))')" "(True, True)"
  t_has "FX2-retire: page: Plan vs shipped says Retired" "$(pj 'd["bodies"]["Plan vs shipped"]')" "Retired · the reset dropped the edits it names"
fi
# FULL: a retirement is carried unchanged, never invented; listing it without the record revives it (logged)
begin
rej "FX2-retire: a FULL plan may not invent a retirement" "$(printf '%s' 'import json as j; P["phases"]=j.load(open(os.path.join(os.environ["STAGE"],"plan.json")))["phases"]; P["phases"][1]["criteria"][0]["retired"]={"why":"made up"}')" "a retirement can only be carried unchanged" full
pub 'import json as j; P["phases"]=j.load(open(os.path.join(os.environ["STAGE"],"plan.json")))["phases"]' full; t_pre "FX2-retire: a FULL run that carries the plan unchanged keeps it retired" "$eo" "PM_EMBED_OK"
t_eq "FX2-retire: ... still retired" "$(crit_of P2.c2 | cut -c1-20)" "('P2.c2', False, {'w"
(cd "$R" && echo 3 >> docs/a.md && git commit -qam "rebuild"); begin; pub 'import json as j; P["phases"]=j.load(open(os.path.join(os.environ["STAGE"],"plan.json")))["phases"]; [c.pop("retired") for ph in P["phases"] for c in ph["criteria"] if c["id"]=="P2.c2"]' full
t_eq "FX2-retire: a FULL run that drops the record revives it, and the change log says so" "$(crit_of P2.c2)|$(S '[c["text"][:8] for c in d["changes"] if c["id"]=="P2.c2"]')" "('P2.c2', False, None)|['revived:']"
# a phase whose items are all retired no longer applies and never blocks
mkrepo fx2d; begin; pub 'J["current_phase"]="P1"; P["phases"][0]["criteria"]=[{"id":"P1.c1","text":"Edits committed","done":False}]' full
(cd "$R" && echo 1 >> docs/a.md && git commit -qam "x"); begin
pub 'J["current_phase"]="P1"; J["criteria_updates"]=[{"id":"P1.c1","retired":True,"why":"the edits were dropped upstream"}]' update
t_eq "FX2-retire: the only item of P1 retired: P1 no longer applies, the current phase moves on" "$(S '([(p["id"], p["state"], p["total"]) for p in d["phases"]][:2], d["focus"]["phase"])')" "([('P1', 'dropped', 0), ('P2', 'current', $(S 'len([c for p in d["phases"] if p["id"]=="P2" for c in p["criteria"]])'))], 'P2')"

# ---- FX2-reach (17.3): a commit that left the checked-out history is not evidence, even if its object survives
mkrepo fx2h; drfiles; (cd "$R" && echo s > side.txt && git add -A && git commit -qm "the edits"); X=$(cd "$R" && git rev-parse --short=7 HEAD)
begin; pub "$(drcode "$X")" full; t_pre "FX2-reach: setup: P1.c3 cites the commit on HEAD" "$eo" "PM_EMBED_OK"
t_eq "FX2-reach: ... bound to the root repository with its full id" "$(S '[(b["repo"], len(b["oid"])) for k, b in d["evidence_bind"].items() if k.startswith("P1.c3")]')" "[('.', 40)]"
(cd "$R" && git branch -q backup && git reset -q --hard HEAD~1); out=$(facts)
t_has "FX2-reach: reset away (a backup branch still holds the object): a loss" "$out" "completion evidence lost: P1.c3"
t_eq "FX2-reach: ... why: commit not in history" "$(get "$PM/inv-${out##* }/snapshot.json" '[(e["id"], e["why"]) for e in d["evidence"]["lost"]]')" "[('P1.c3', 'commit not in history')]"
INV=${out##* }; INVN=inv-$INV; STAGE="$PM/$INVN"
rej "FX2-reach: a new ref to a commit outside HEAD's history is refused" 'J["criteria_updates"]=[{"id":"P2.c1","done":True,"ref":"commit:'"$X"'"}]' "not in the checked-out history"
t_eq "FX2-reach: unit: object_info: missing is git's own answer; a failed query is unknown, never missing" "$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_git as G
print(G.object_info(sys.argv[2], "deadbee"), G.object_info(sys.argv[3], "deadbee"))' "$HOOKS" "$R" "$T")" "('missing', None) ('unknown', None)"
# an unbound ref (a map published before 3.6.2 carries no binding) is checked in every known repository, HEAD-only too
mkrepo fx2u; drfiles; (cd "$R" && echo s > side.txt && git add -A && git commit -qm "the edits"); X=$(cd "$R" && git rev-parse --short=7 HEAD)
begin; pub "$(drcode "$X")" full
lib mut "$PM/current/state.json" 'd.pop("evidence_bind", None)'; lib resign "$PM/current"
(cd "$R" && git reset -q --hard HEAD~1); out=$(facts)
t_eq "FX2-reach: an unbound ref whose commit left HEAD's history: lost, commit not in history" "$(get "$PM/inv-${out##* }/snapshot.json" '[(e["id"], e["why"]) for e in d["evidence"]["lost"]]')" "[('P1.c3', 'commit not in history')]"
# a nested clone holding the same commit cannot vouch for the root's claim once the root dropped it (binding)
mkrepo fx2b; drfiles; (cd "$R" && echo s > side.txt && git add -A && git commit -qm "the edits"); X=$(cd "$R" && git rev-parse --short=7 HEAD)
(cd "$R" && printf 'clone2/\n' >> .gitignore && git add .gitignore && git commit -qm ignore && git clone -q "$R" clone2)
begin; pub "$(drcode "$X")" full; t_pre "FX2-reach: setup: a nested clone also holds the commit" "$eo" "PM_EMBED_OK"
t_eq "FX2-reach: ... the new ref is bound to the root (the repository it was accepted in)" "$(S '[b["repo"] for k, b in d["evidence_bind"].items() if k.startswith("P1.c3")]')" "['.']"
(cd "$R" && git reset -q --hard HEAD~2); out=$(facts)
t_has "FX2-reach: the root drops it; the clone still has it: still a loss" "$out" "completion evidence lost: P1.c3"

# I1 (impl r1): a completion commit behind a shallow boundary is unknown, never lost
mkrepo fx2sh; drfiles; (cd "$R" && echo s > side.txt && git add -A && git commit -qm "cited work"); X=$(cd "$R" && git rev-parse --short=7 HEAD)
begin; pub "$(drcode "$X")" full
(cd "$R" && for i in 1 2; do echo $i >> docs/a.md; git commit -qam "later $i"; done && git rev-parse HEAD~1 > .git/shallow); out=$(facts)
t_not "FX2-reach shallow: the cited commit sits behind the shallow boundary: not a loss" "$out" "completion evidence lost"
t_eq "FX2-reach shallow: ... it is unknown (the check is incomplete)" "$(get "$PM/inv-${out##* }/snapshot.json" '("P1.c3" in [i for i in d["evidence"]["unknown"]], d["evidence"]["lost"])' 2>/dev/null || get "$PM/inv-${out##* }/snapshot.json" '(any("P1.c3" in str(x) for x in d["evidence"]["unknown"]), d["evidence"]["lost"])')" "(True, [])"
t_eq "FX2-reach shallow: unit: commit_reach in a shallow clone answers unknown" "$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_git as G;print(G.commit_reach(sys.argv[2], sys.argv[3])[0])' "$HOOKS" "$R" "$X")" "unknown"
rm -f "$R/.git/shallow"
# I2 (impl r1): a bound claim whose repository cannot be read is not re-verified through another clone at publication
if [ "$ISROOT" = 0 ]; then
mkrepo fx2v; drfiles; printf 'repo2/\nrepo3/\n' >> "$R/.gitignore"; mkdir -p "$R/repo2"; (cd "$R/repo2" && git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false && echo n > n.txt && git add -A && git commit -qm nested); (cd "$R" && git clone -q repo2 repo3 && git add -A && git commit -qm "ignore nested")
N=$(cd "$R/repo2" && git rev-parse --short=7 HEAD)
NPART='[p for p in J["parts"] if p["id"]=="engine"][0].update(status="done", ref="commit:'"$N"'")'
begin; pub "$(drcode "$N")
$NPART" full; t_pre "FX2-bind: setup: the commit of repo2 (also in its clone repo3) is cited" "$eo" "PM_EMBED_OK"
t_eq "FX2-bind: ... bound to repo2 (the first repository in order whose history has it)" "$(S '[b["repo"] for k, b in d["evidence_bind"].items() if k.startswith("P1.c3")]')" "['repo2']"
(cd "$R" && echo 1 >> docs/a.md && git commit -qam x); chmod 000 "$R/repo2"; begin
pub "$NPART" update; chmod 755 "$R/repo2"
t_pre "FX2-bind: repo2 unreadable: the carried claim publishes (unknown is not an error)" "$eo" "PM_EMBED_OK"
t_eq "FX2-bind: ... but it is not verified through repo3: the part stays unknown and the check incomplete" "$(S '("engine" in d["evidence"]["unknown"], d["evidence"]["checked"])')" "(True, 'partial')"
(cd "$R" && echo 2 >> docs/a.md && git commit -qam y2); begin
t_eq "FX2-bind: J2 setup: repo2 readable again: the staged check finds the part ok" "$(get "$STAGE/snapshot.json" '"engine" in [e["id"] for e in d["evidence"]["ok"]]')" "True"
chmod 000 "$R/repo2"; PM_EMBED_EVIDENCE_DEADLINE=0.001 pub "$NPART" update; chmod 755 "$R/repo2"
t_eq "FX2-bind: J2: repo2 unreadable at publication and no recheck reached it: the publication's unknown outranks the staged ok" "$(S '"engine" in d["evidence"]["unknown"]')" "True"
t_eq "FX2-bind: K1: ... and that observation is in the evidence cache (an older ok cannot come back before its own next check)" "$(evrec 'd["results"]["engine|commit:'"$N"'"]["status"]')" "unknown"
fi
(cd "$R" 2>/dev/null; true)
mkrepo fx2r2; drfiles; (cd "$R" && echo s > side.txt && git add -A && git commit -qm "the edits"); X=$(cd "$R" && git rev-parse --short=7 HEAD)
(cd "$R" && printf 'clone2/\n' >> .gitignore && git add .gitignore && git commit -qm ignore && git clone -q "$R" clone2)
begin; pub "$(drcode "$X")" full; (cd "$R" && git reset -q --hard HEAD~2); begin
rej "FX2-bind: after the root dropped it, re-asserting the claim is refused although the clone still has the commit" 'J["criteria_updates"]=[u for u in J.get("criteria_updates",[]) if u["id"]!="P1.c3"]+[{"id":"P1.c3","done":True,"ref":"commit:'"$X"'"}]' "not in the checked-out history of ., where it was accepted"

# ---- FX2-rewrite (17.4): the new work after a rewrite is exactly P..HEAD; rewritten and unknown are said, never guessed
mkrepo fx2w; for i in 1 2 3 4 5 6 7; do (cd "$R" && echo $i >> docs/a.md && git commit -qam "old $i"); done
(cd "$R" && echo x >> docs/a.md && git commit -qam "local only"); begin; pub "" full
(cd "$R" && git reset -q --hard HEAD~1 && for i in 1 2; do echo n$i >> docs/b.md; git add -A; git commit -qm "upstream $i"; done); begin
t_eq "FX2-rewrite: reset + 2 new commits: 2 commits, not the whole history; rewritten said" "$(get "$STAGE/pack.json" '(d["since"]["commits"], sorted(i["s"] for x in d["commits"]["days"] for i in x["items"]), d["since"].get("rewritten"))')" "(2, ['upstream 1', 'upstream 2'], True)"
pub "" update; t_has "FX2-rewrite: ... the brief counts the 2 new commits" "$(cat "$PM/brief.txt")" ": 2 commits · 0 uncommitted"
t_has "FX2-rewrite: ... and history rewritten" "$(cat "$PM/brief.txt")" "history rewritten"
(cd "$R" && git reset -q --hard HEAD~2); begin
t_eq "FX2-rewrite: a reset backwards: 0 new commits, rewritten" "$(get "$STAGE/pack.json" '(d["since"]["commits"], d["since"].get("rewritten"))')" "(0, True)"
pub "" update
mkrepo fx2g; (cd "$R" && git checkout -q -b a && echo a > a.txt && git add -A && git commit -qm "side a" && git checkout -q main && git checkout -q -b b && echo b > b.txt && git add -A && git commit -qm "side b" && git checkout -q main && git merge -q --no-edit a b -m "merge one")
begin; pub "" full
(cd "$R" && git reset -q --hard HEAD~1 && git merge -q --no-edit a b -m "merge two" && echo c >> docs/a.md && git commit -qam "after merge"); begin
t_eq "FX2-rewrite: merges re-done over the same side branches: only the new merge and the new commit, side commits not re-counted" "$(get "$STAGE/pack.json" '(d["since"]["commits"], sorted(i["s"] for x in d["commits"]["days"] for i in x["items"]))')" "(2, ['after merge', 'merge two'])"
pub "" update
(cd "$R" && git reset -q --hard HEAD~1 && echo e >> docs/a.md && git commit -qam "shallow other" && git rev-parse HEAD~1 > .git/shallow)
begin
t_eq "FX2-rewrite: a shallow clone: not called rewritten; the count is marked unknown" "$(get "$STAGE/pack.json" '(d["since"].get("rewritten"), d["since"].get("count_unknown"))')" "(None, True)"
rm -f "$R/.git/shallow"; pub "" update
(cd "$R" && echo f >> docs/a.md && git commit -qam "kept" && git reset -q --hard HEAD~1 && git reflog expire --expire=now --all && git gc -q --prune=now)
lib mut "$PM/current/state.json" 'd["judged_key"]["heads"]["."]="0123456789ab"; d["read"]["heads"]["."]="0123456789ab"'; lib resign "$PM/current"; begin
t_eq "FX2-rewrite: the previous head is gone from this clone: the latest commits are a sample and the count is unknown" "$(get "$STAGE/pack.json" '(d["since"].get("count_unknown"), d["since"].get("rewritten"))')" "(True, None)"
pub "" update; t_has "FX2-rewrite: ... the brief says count unknown" "$(cat "$PM/brief.txt")" "count unknown"
t_eq "FX2-rewrite: ... the state says why (missing)" "$(S 'd["since"].get("count_why")')" "missing"
t_has "FX2-rewrite: ... and the assurance" "$(S 'd["assurance"]["why"]')" "new-work count unknown"

mkrepo fx2sx; (cd "$R" && for i in 1 2 3; do echo $i >> docs/a.md; git commit -qam "c$i"; done); begin; pub "" full
(cd "$R" && git rev-parse HEAD~2 > .git/shallow && echo n >> docs/a.md && git commit -qam "new on shallow"); begin
t_eq "FX2-rewrite: any shallow clone, even with the assessed head in HEAD's history (a merge may hide a side chain): count unknown, shallow" "$(get "$STAGE/pack.json" '(d["since"].get("count_unknown"), d["since"].get("count_why"), d["since"].get("rewritten"))')" "(True, 'shallow', None)"
rm -f "$R/.git/shallow"
if [ "$HAVE_NODE" = 1 ]; then
  rbpage '{"since":{"from":{"generation":"000001-aaaaaaaa","assessed_at":"2026-10-11T10:00:00+03:00"},"commits":20,"listed":20,"dirty":0,"hours":1,"changes":[],"attention":{"kind":"continue","text":"Work goes on","why":"Nothing blocks it"},"not_checked":[],"count_unknown":true,"count_why":"shallow"}}'
  t_has "FX2-rewrite: page: count unknown says why (a shallow clone)" "$(pj 'd["since"][1]')" "count unknown (a shallow clone: the history before its boundary is not here; these are the latest commits)"
fi
# I4 (impl r1): the checklist's current phase is the EFFECTIVE one, after the requested phase completed
mkrepo fx2p; begin; pub 'J["current_phase"]="P1"; P["phases"][0]["criteria"]=[{"id":"P1.c1","text":"Weights load","done":False}]' full
(cd "$R" && echo 1 >> docs/a.md && git commit -qam x); begin
pub 'J["current_phase"]="P1"; J["criteria_updates"]=[{"id":"P1.c1","done":True,"ref":"file:PLAN.md:10"}]' update
(cd "$R" && echo 2 >> docs/a.md && git commit -qam y); begin
t_eq "FX2-checklist: the requested phase completed: the pack orders and trims by the effective current phase" "$(get "$STAGE/snapshot.json" 'd["criteria_phase"]')|$(get "$STAGE/pack.json" 'd["criteria"][0]["id"].split(".")[0]')" "P2|P2"
# I5 (impl r1): a retirement survives a busy update (more than 8 other changes) in the change log and the history
pub 'J["headline"]["text"]="A very different headline"; J["next_step"]["title"]="Another next step"; J["eta"]=None; J["risks"]=[{"id":"R-1","text":"Another risk","severity":"low"}]
for p in J["parts"]:
    p["line"]="changed line"
J["criteria_updates"]=[{"id":"P2.c3","retired":True,"why":"scope changed upstream"}]' update
t_eq "FX2-retire: a busy update: the retirement is in the change log and in the history" "$(S '(any(c["id"]=="P2.c3" and c["text"].startswith("retired") for c in d["changes"]), any(c["id"]=="P2.c3" for c in d["history"][-1]["changed"]), len(d["changes"]))')" "(True, True, 8)"

# ---- FX2-exclude (17.5): .project-map/ ignored through the local exclude file; the project's files are never written
mkrepo fx2x; begin; pub "" full
t_eq "FX2-exclude: after the first map: an anchored line in .git/info/exclude, no .gitignore, a clean tree" "$(grep -c '^/.project-map/$' "$R/.git/info/exclude")|$([ -e "$R/.gitignore" ] && echo gi || echo none)|$(cd "$R" && git status --porcelain | wc -l | tr -d ' ')" "1|none|0"
(cd "$R" && echo 1 >> docs/a.md && git commit -qam "x"); begin; pub "" update
t_eq "FX2-exclude: ... added once, not on every run" "$(grep -c '.project-map/' "$R/.git/info/exclude")" "1"
mkrepo fx2y; (cd "$R" && printf '.project-map/\n' > .gitignore && git add .gitignore && git commit -qm gi); begin; pub "" full
t_eq "FX2-exclude: an existing .gitignore rule already ignores it: nothing appended" "$(grep -c 'project-map' "$R/.git/info/exclude")" "0"
mkrepo fx2s; mkdir -p "$R/pkg/app"; cp -R "$R/PLAN.md" "$R/REVIEW-LOG.md" "$R/README.md" "$R/docs" "$R/pkg/app/"; (cd "$R" && git add -A && git commit -qm pkg); R0=$R; R="$R/pkg/app"; PM="$R/.project-map"
begin; pub "" full; t_pre "FX2-exclude: a sub-folder map publishes" "$eo" "PM_EMBED_OK"
t_eq "FX2-exclude: a sub-folder map: the line is anchored at that folder" "$(grep -c '^/pkg/app/.project-map/$' "$R0/.git/info/exclude")" "1"
mkrepo fx2l; mkdir -p "$T/fx2l-outside"; rm -rf "$R/.git/info"; ln -s "$T/fx2l-outside" "$R/.git/info"; begin; pub "" full
t_eq "FX2-exclude: info/ is a link: nothing written through it; published with a note" "$(ls "$T/fx2l-outside" | wc -l | tr -d ' ')|$(printf '%s' "$eo" | grep -c 'PM_EMBED_NOTE .project-map/ is not ignored by git')" "0|1"
t_eq "FX2-exclude: unit: the pattern is anchored and escaped" "$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import pm_git as G;print(G._exclude_pattern("", ".project-map"), G._exclude_pattern("a*b/c", ".project-map"))' "$HOOKS")" '/.project-map/ /a\*b/c/.project-map/'

t_eq "FX2-exclude: unit: a failed ignore check is reported, never silent; no time left defers" "$(python3 -c '
import sys, time; sys.path.insert(0, sys.argv[1]); import pm_git as G
real = G._fixed
G._fixed = lambda root, args, t: (128, "") if args[0] == "check-ignore" else real(root, args, t)
a = G.ensure_local_exclude(sys.argv[2])
G._fixed = lambda root, args, t: (124, "") if args[0] == "ls-files" else real(root, args, t)
b = G.ensure_local_exclude(sys.argv[2])
G._fixed = real
c = G.ensure_local_exclude(sys.argv[2], deadline=time.monotonic() - 1)
print(a[0], b[0], c[0])' "$HOOKS" "$R")" "not_ignored not_ignored deferred"
XH=$(cd "$R" && git rev-parse --short=7 HEAD)
mkdir -p "$T/fx2bad"; printf 'gitdir: /nonexistent/x\n' > "$T/fx2bad/.git"; mkdir -p "$T/fx2plain/sub"
t_eq "FX2-exclude: unit (J3): a broken .git is reported, a plain folder is skipped; (J4) no git call after the deadline" "$(python3 -c '
import sys, time; sys.path.insert(0, sys.argv[1]); import pm_git as G
a = G.ensure_local_exclude(sys.argv[2])[0]; b = G.ensure_local_exclude(sys.argv[3])[0]
G.object_info = lambda *x, **k: (_ for _ in ()).throw(RuntimeError("called"))
c = G.commit_reach(sys.argv[2], "abcdef1", deadline=time.monotonic() - 1)
print(a, b, c)' "$HOOKS" "$T/fx2bad" "$T/fx2plain/sub")" "not_ignored skip ('unknown', None)"
t_eq "FX2-bind: unit: a legacy ref binds when one repository confirms it, not after the deadline, not when two do; a new ref binds root-first" "$(python3 -c '
import sys, time; sys.path.insert(0, sys.argv[1]); import pm_validate as V
r, x = sys.argv[2], "commit:" + sys.argv[3]
one = [{"path": ".", "vcs": "git"}]; two = one + [{"path": "../" + r.rsplit("/", 1)[1], "vcs": "git"}]
a = len(V.bind_evidence(r, one, [("P1.c3", x)], {}, [("P1.c3", x)]))
b = len(V.bind_evidence(r, one, [("P1.c3", x)], {}, [("P1.c3", x)], None, time.monotonic() - 1))
c = len(V.bind_evidence(r, [one[0], one[0]], [("P1.c3", x)], {}, [("P1.c3", x)]))
d = list(V.bind_evidence(r, [one[0], one[0]], [("P1.c3", x)], {}, []).values())[0]["repo"]
print(a, b, c, d)' "$HOOKS" "$R" "$XH")" "1 0 0 ."

# ---- FX2-blocked (17.6): a stuck part may wait on an open decision, never on a closed one
mkrepo fx2k; begin; pub "" full; (cd "$R" && echo 1 >> docs/a.md && git commit -qam x); begin
STUCK='for p in J["parts"]:
    if p["status"]=="stuck": p["blocked_by"]="'
pub "$STUCK"'D-001"' update; t_pre "FX2-blocked: blocked_by an open decision publishes" "$eo" "PM_EMBED_OK"
(cd "$R" && echo 2 >> docs/a.md && git commit -qam y); begin
rej "FX2-blocked: blocked_by an unknown id is refused" "$STUCK"'D-009"' "blocked_by must name another part id or an open decision id"
rej "FX2-blocked: blocked_by a decision this judgement closes is refused" "$STUCK"'D-001"
J["decisions"][0]["overtaken"]={"why":"done by hand"}' "blocked_by must name another part id or an open decision id"

fi   # PM_FC_ONLY=1

echo; echo "total $((pass+fail)) pass $pass fail $fail"; [ "$fail" = 0 ]
