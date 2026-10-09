#!/bin/bash
# tests/test_git.sh: pm_git.py core + pm-git.sh wrapper (INTERFACES-3.2 section 7).
# Scratch repo has CONFIGURED HELPERS (fsmonitor, diff.external, textconv, pager, hooks)
# that write marker files; no pm_git route may ever create one. bash 3.2 compatible.

HERE=$(cd "$(dirname "$0")" && pwd -P)
SCRIPTS=$(cd "$HERE/../scripts" && pwd -P)
W=/private/tmp/claude-501/-Users-demo/pmgit-test/scratchpad/w1
R=$W/repo
M=$W/markers
H=$W/helpers
WRAP=$SCRIPTS/pm-git.sh
DRV=$W/drv.py
PASS=0
FAIL=0

for v in $(env | grep '^GIT_' | cut -d= -f1); do unset "$v"; done

pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
# check NAME CMD...: pass when CMD succeeds
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass; else fail "$n"; fi; }
no_markers() { [ -z "$(ls -A "$M")" ]; }
# assert_clean NAME: no helper marker exists; report which one fired otherwise
assert_clean() {
  if no_markers; then pass; else fail "$1 (helper executed: $(ls "$M" | tr '\n' ' '))"; rm -f "$M"/*; fi
}

rm -rf "$W"
mkdir -p "$M" "$H" "$W/hooks"

# ---- scratch repo (built BEFORE helpers are configured) ----------------------------
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q "$R"
printf '*.txt diff=secret\n' > "$R/.gitattributes"
printf 'one\n' > "$R/a.txt"
printf 'SECRET=1\n' > "$R/.env"
g add -A && g commit -q -m "first commit"
printf 'two\n' > "$R/a.txt"
g commit -q -am 'subject with @@ and %x1f inside'
g rm -q .env && g commit -q -m "remove env"
printf 'three\n' > "$R/a.txt"          # dirty tracked file
printf 'x\n' > "$R/untracked.txt"
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

# helpers: each writes a marker named after itself
mk() { printf '#!/bin/sh\necho x >> "%s/%s"\n%s\n' "$M" "$1" "$2" > "$H/$1.sh"; chmod +x "$H/$1.sh"; }
mk fsmonitor "printf 't\\0'"
mk extdiff ":"
mk textconv 'cat "$1"'
mk pager "cat"
mk ssh ":"
for hk in pre-commit post-checkout; do
  printf '#!/bin/sh\necho x >> "%s/hook-%s"\n' "$M" "$hk" > "$W/hooks/$hk"; chmod +x "$W/hooks/$hk"
done
git -C "$R" config core.fsmonitor "$H/fsmonitor.sh"
git -C "$R" config diff.external "$H/extdiff.sh"
git -C "$R" config diff.secret.textconv "$H/textconv.sh"
git -C "$R" config core.pager "$H/pager.sh"
git -C "$R" config core.sshCommand "$H/ssh.sh"
git -C "$R" config core.hooksPath "$W/hooks"

# driver: pm_git.run via argv; prints "rc cf" then output; exit 99 on GitArgError
cat > "$DRV" <<'PYEOF'
import os, sys
sys.path.insert(0, sys.argv[1])
import pm_git
repo, sub, args = sys.argv[2], sys.argv[3], sys.argv[4:]
try:
    rc, out = pm_git.run(repo, sub, *args, timeout=float(os.environ.get("DRV_TIMEOUT", "20")))
except pm_git.GitArgError as e:
    sys.stderr.write("GitArgError: %s\n" % e)
    sys.exit(99)
sys.stdout.write("%d %d\n%s" % (rc, int(pm_git.collection_failure(sub, rc)), out))
PYEOF

# core REPO SUB ARGS...: runs the core, sets CRC (git rc / 99), CCF, COUT
core() {
  local raw
  raw=$(python3 -I "$DRV" "$SCRIPTS" "$@" 2>/dev/null | tr -d '\000'; exit ${PIPESTATUS[0]}); CRC=$?
  if [ $CRC -eq 99 ]; then CCF=""; COUT=""; return; fi
  raw="$raw
"
  CRC=${raw%% *}; raw=${raw#* }; CCF=${raw%%$'\n'*}; COUT=${raw#*$'\n'}; COUT=${COUT%$'\n'}
}
# ok_core NAME EXPECT_RC REPO SUB ARGS...: succeeds with rc, no helper fires
ok_core() {
  local n=$1 want=$2; shift 2
  core "$@"
  if [ "$CRC" = "$want" ]; then pass; else fail "$n (rc $CRC, want $want)"; fi
  assert_clean "$n"
}
# rej_core NAME REPO SUB ARGS...: GitArgError, nothing executed
rej_core() {
  local n=$1; shift
  core "$@"
  if [ "$CRC" = 99 ]; then pass; else fail "$n (not rejected, rc $CRC)"; fi
  assert_clean "$n"
}

H0=$(git -C "$R" rev-parse HEAD)
H1=$(git -C "$R" rev-parse HEAD~1)
H2=$(git -C "$R" rev-parse HEAD~2)
F1=%x1e%H%x1f%ct%x1f%s
LF="--format=$F1"

# ---- 0. positive controls: helpers DO fire when git runs unguarded -----------------
cp -R "$R" "$W/ctl"
git -C "$W/ctl" status >/dev/null 2>&1
check "control fsmonitor fires" test -e "$M/fsmonitor"; rm -f "$M"/*
git -C "$W/ctl" diff >/dev/null 2>&1
check "control diff.external fires" test -e "$M/extdiff"; rm -f "$M"/*
git -C "$W/ctl" diff --no-ext-diff >/dev/null 2>&1
check "control textconv fires" test -e "$M/textconv"; rm -f "$M"/*
script -q /dev/null git -C "$W/ctl" log -n 1 </dev/null 2>&1 | cat >/dev/null   # pager needs a tty
check "control pager fires" test -e "$M/pager"; rm -f "$M"/*
git -C "$W/ctl" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c >/dev/null 2>&1
check "control pre-commit hook fires" test -e "$M/hook-pre-commit"; rm -f "$M"/*
git -C "$W/ctl" checkout -q -b nb >/dev/null 2>&1
check "control post-checkout hook fires" test -e "$M/hook-post-checkout"; rm -f "$M"/*
rm -rf "$W/ctl"

# ---- 1. internal calls (7.1): run, rc 0, no marker ----------------------------------
ok_core "int status" 0 "$R" status --porcelain=v1 -z --untracked-files=all
ok_core "int log" 0 "$R" log "$LF" -n 5
ok_core "int log since+path" 0 "$R" log "$LF" -n 200 --since=2000-01-01T00:00:00 -- a.txt
ok_core "int log agent format" 0 "$R" log "--format=%h %ad %s" --date=short -n 3
ok_core "int ls-files -s -z" 0 "$R" ls-files -s -z
ok_core "int ls-files -s -z path" 0 "$R" ls-files -s -z -- a.txt
ok_core "int ls-files path" 0 "$R" ls-files -- a.txt
ok_core "int rev-parse toplevel" 0 "$R" rev-parse --show-toplevel
ok_core "int rev-parse abbrev" 0 "$R" rev-parse --abbrev-ref HEAD
ok_core "int rev-parse HEAD" 0 "$R" rev-parse HEAD
ok_core "int rev-parse sha^{commit}" 0 "$R" rev-parse "$H1^{commit}"
ok_core "int rev-list count" 0 "$R" rev-list --count "$H2..$H0"
[ "$COUT" = "2" ] && pass || fail "int rev-list count value ($COUT)"
ok_core "int merge-base ancestor yes" 0 "$R" merge-base --is-ancestor "$H2" "$H0"
ok_core "int merge-base ancestor no" 1 "$R" merge-base --is-ancestor "$H0" "$H2"
[ "$CCF" = 0 ] && pass || fail "merge-base rc1 is not a collection failure"
ok_core "int cat-file -e" 0 "$R" cat-file -e "$H1"
ok_core "int cat-file -t" 0 "$R" cat-file -t "$H1"
[ "$COUT" = "commit" ] && pass || fail "cat-file -t value ($COUT)"
ok_core "int diff --stat" 0 "$R" diff --stat --no-ext-diff --no-textconv "$H2" "$H1"
ok_core "int diff --stat path" 0 "$R" diff --stat --no-ext-diff --no-textconv "$H2" "$H1" -- a.txt
ok_core "int branch --show-current" 0 "$R" branch --show-current
ok_core "int tag --list" 0 "$R" tag --list
ok_core "int HEAD revisions" 0 "$R" diff --stat --no-ext-diff --no-textconv HEAD HEAD

# ---- 2. internal rejections ---------------------------------------------------------
rej_core "rej sub show" "$R" show "$H0"
rej_core "rej sub remote" "$R" remote
rej_core "rej sub config" "$R" config --list
rej_core "rej sub checkout" "$R" checkout "$H0"
rej_core "rej status extra flag" "$R" status --porcelain=v1 -z
rej_core "rej log -p" "$R" log "$LF" -n 5 -p
rej_core "rej log no -n" "$R" log "$LF"
rej_core "rej log -n 201" "$R" log "$LF" -n 201
rej_core "rej log -n 0" "$R" log "$LF" -n 0
rej_core "rej log bad format" "$R" log --format=%H -n 5
rej_core "rej log bad since" "$R" log "$LF" -n 5 "--since=--output=/tmp/x"
rej_core "rej log path dotdot" "$R" log "$LF" -n 5 -- ../x
rej_core "rej log path dash" "$R" log "$LF" -n 5 -- -x
rej_core "rej log path abs" "$R" log "$LF" -n 5 -- /etc/passwd
rej_core "rej log empty --" "$R" log "$LF" -n 5 --
rej_core "rej ls-files -o" "$R" ls-files -o
rej_core "rej ls-files nested dotdot" "$R" ls-files -- a/../../b
rej_core "rej rev-parse --git-dir" "$R" rev-parse --git-dir
rej_core "rej rev-parse bad rev" "$R" rev-parse "HEAD~1^{commit}"
rej_core "rej rev-list non-sha" "$R" rev-list --count "master..HEAD"
rej_core "rej rev-list triple dot" "$R" rev-list --count "$H2...$H0"
rej_core "rej merge-base bad sha" "$R" merge-base --is-ancestor abc "$H0"
rej_core "rej cat-file -p" "$R" cat-file -p "$H0"
rej_core "rej cat-file newline sha" "$R" cat-file -e "$H0
"
rej_core "rej diff without no-ext" "$R" diff --stat "$H2" "$H1"
rej_core "rej diff --ext-diff" "$R" diff --stat --ext-diff --no-textconv "$H2" "$H1"
rej_core "rej diff -p" "$R" diff -p --no-ext-diff --no-textconv "$H2" "$H1"
rej_core "rej branch -a" "$R" branch -a
rej_core "rej tag -d" "$R" tag -d x
rej_core "rej -c as sub" "$R" -c core.fsmonitor=x status
rej_core "rej --git-dir as sub" "$R" --git-dir=/tmp status

# ---- 3. env stripping ---------------------------------------------------------------
EV=$(GIT_EXTERNAL_DIFF=/x/y GIT_DIR=/nonexistent GIT_PAGER=evil GIT_CONFIG_COUNT=1 \
     python3 -I -c "
import sys; sys.path.insert(0, '$SCRIPTS'); import pm_git
e = pm_git.env_for_git()
print(sorted(k for k in e if k.startswith('GIT_')))
print(e['GIT_EXTERNAL_DIFF'] == '' and e['GIT_PAGER'] == 'cat' and e['GIT_CONFIG_GLOBAL'] == '/dev/null' and e['GIT_CONFIG_NOSYSTEM'] == '1' and e['GIT_TERMINAL_PROMPT'] == '0')
")
[ "$(echo "$EV" | tail -1)" = "True" ] && pass || fail "env_for_git pinned values"
[ "$(echo "$EV" | head -1)" = "['GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_EXTERNAL_DIFF', 'GIT_PAGER', 'GIT_TERMINAL_PROMPT']" ] \
  && pass || fail "env_for_git leaks caller GIT_* ($(echo "$EV" | head -1))"
# bogus GIT_DIR would break git if it leaked; an injected fsmonitor via GIT_CONFIG_* would fire
OUT=$(GIT_DIR=/nonexistent GIT_EXTERNAL_DIFF="$H/extdiff.sh" GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="$H/fsmonitor.sh" \
      python3 -I "$DRV" "$SCRIPTS" "$R" status --porcelain=v1 -z --untracked-files=all 2>/dev/null | tr -d '\000')
[ "${OUT%% *}" = "0" ] && pass || fail "run() ignores caller GIT_DIR (got: ${OUT%% *})"
assert_clean "run() with GIT_EXTERNAL_DIFF/GIT_CONFIG_* in os.environ"
check "argv_prefix shape" python3 -I -c "
import sys; sys.path.insert(0, '$SCRIPTS'); import pm_git
a = pm_git.argv_prefix('/r')
assert a[:4] == ['git', '-C', '/r', '--no-optional-locks'], a
assert a[4:] == ['-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-c','core.pager=cat','-c','diff.external=','-c','core.sshCommand=false'], a
"
check "toplevel of repo" python3 -I -c "
import sys, os; sys.path.insert(0, '$SCRIPTS'); import pm_git
assert os.path.realpath(pm_git.toplevel('$R/')) == os.path.realpath('$R')
assert pm_git.toplevel('$W/markers') is None
assert pm_git.toplevel('/nonexistent-dir-xyz') is None
"
assert_clean "toplevel"

# ---- 4. log format survives @@ and %x1f ---------------------------------------------
core "$R" log "$LF" -n 5
echo "$COUT" | python3 -I -c "
import sys
recs = [r for r in sys.stdin.read().split('\x1e') if r.strip()]
assert len(recs) == 3, recs
subs = [r.rstrip('\n').split('\x1f')[2] for r in recs]
assert all(len(r.rstrip('\n').split('\x1f')) == 3 for r in recs)
assert 'subject with @@ and %x1f inside' in subs, subs
" && pass || fail "@@ and %x1f subject survives log format"

# ---- 5. failure semantics -----------------------------------------------------------
cp -R "$R" "$W/broken"
head -c 20 "$R/.git/index" > "$W/broken/.git/index"
core "$W/broken" status --porcelain=v1 -z --untracked-files=all
[ "$CRC" != 0 ] && [ "$CRC" != 99 ] && pass || fail "broken index rc != 0 (rc $CRC)"
[ "$CCF" = 1 ] && pass || fail "broken index collection_failure True ($CCF)"
rm -rf "$W/broken"
assert_clean "broken index"
MISSING=0000000000000000000000000000000000000001
core "$R" cat-file -e "$MISSING"
[ "$CRC" = 1 ] && pass || fail "cat-file -e missing sha rc 1 (rc $CRC)"
[ "$CCF" = 0 ] && pass || fail "cat-file -e missing sha collection_failure False ($CCF)"
core /nonexistent-repo-dir status --porcelain=v1
[ "$CCF" = 1 ] && pass || fail "not-a-repo is a collection failure ($CRC/$CCF)"
DRV_TIMEOUT=0.0001 core "$R" status --porcelain=v1 -z --untracked-files=all
[ "$CRC" = 124 ] && [ "$CCF" = 1 ] && [ -z "$COUT" ] && pass || fail "timeout rc 124 + collection failure (rc $CRC)"
check "collection_failure table" python3 -I -c "
import sys; sys.path.insert(0, '$SCRIPTS'); import pm_git as p
c = p.collection_failure
assert not c('status', 0) and c('status', 1) and c('status', 128) and c('status', 124)
assert not c('cat-file', 1) and c('cat-file', 128) and not c('merge-base', 1) and c('merge-base', 2)
"

# ---- 6. agent wrapper (7.2): accepted -----------------------------------------------
agent_ok() { # NAME ARGS...: exit 0, output regex in AREGEX (optional), no marker
  local n=$1; shift
  AOUT=$("$WRAP" "$R" "$@" 2>/dev/null); local rc=$?
  if [ $rc -eq 0 ]; then pass; else fail "agent $n (rc $rc)"; fi
  assert_clean "agent $n"
}
agent_ok "status" status
echo "$AOUT" | grep -q 'a.txt' && pass || fail "agent status shows dirty file"
agent_ok "log" log
echo "$AOUT" | grep -Eq '^[0-9a-f]{7,} [0-9]{4}-[0-9]{2}-[0-9]{2} first commit$' && pass || fail "agent log format"
echo "$AOUT" | grep -Fq 'subject with @@ and %x1f inside' && pass || fail "agent log subject literal"
[ "$(echo "$AOUT" | wc -l | tr -d ' ')" = 3 ] && pass || fail "agent log default lists all 3 commits"
agent_ok "log -n 1" log -n 1
[ "$(echo "$AOUT" | wc -l | tr -d ' ')" = 1 ] && pass || fail "agent log -n 1 line count"
agent_ok "log -n 60" log -n 60
agent_ok "rev-parse" rev-parse
[ "$AOUT" = "$H0" ] && pass || fail "agent rev-parse prints HEAD"
agent_ok "branch" branch
echo "$AOUT" | grep -Eq 'master|main' && pass || fail "agent branch lists branch"
agent_ok "ls-files" ls-files
echo "$AOUT" | grep -q '^a.txt$' && pass || fail "agent ls-files lists a.txt"
echo "$AOUT" | grep -q '^\.env$' && fail "agent ls-files lists removed .env" || pass
agent_ok "ls-files relpath" ls-files a.txt
[ "$AOUT" = "a.txt" ] && pass || fail "agent ls-files a.txt output"
agent_ok "tag" tag
# symlinked wrapper (file symlink and directory symlink)
ln -s "$WRAP" "$W/pm-git-link.sh"
ln -s "$SCRIPTS" "$W/scripts-link"
"$W/pm-git-link.sh" "$R" rev-parse >/dev/null 2>&1 && pass || fail "wrapper via file symlink"
"$W/scripts-link/pm-git.sh" "$R" rev-parse >/dev/null 2>&1 && pass || fail "wrapper via dir symlink"
# hostile caller environment is neutralised by the core
GIT_DIR=/nonexistent GIT_EXTERNAL_DIFF="$H/extdiff.sh" GIT_PAGER="$H/pager.sh" "$WRAP" "$R" status >/dev/null 2>&1 \
  && pass || fail "agent call with hostile GIT_* env still works"
assert_clean "agent call with hostile GIT_* env"

# ---- 7. agent wrapper: rejected with exit 2 -----------------------------------------
agent_rej() { # NAME ROOT ARGS...
  local n=$1; shift
  local err; err=$("$WRAP" "$@" 2>&1 >/dev/null); local rc=$?
  if [ $rc -eq 2 ] && [ "$err" = "pm-git: not allowed" ]; then pass; else fail "agent rej $n (rc $rc, err '$err')"; fi
  assert_clean "agent rej $n"
}
agent_rej "show HEAD:.env" "$R" show HEAD:.env
agent_rej "diff" "$R" diff
agent_rej "remote" "$R" remote
agent_rej "log -p" "$R" log -p
agent_rej "log -n 61" "$R" log -n 61
agent_rej "log -n 0" "$R" log -n 0
agent_rej "log -n abc" "$R" log -n abc
agent_rej "log -n 5 extra" "$R" log -n 5 --stat
agent_rej "log -n12345" "$R" log -n 12345
agent_rej "-c" "$R" -c core.fsmonitor=x status
agent_rej "--git-dir" "$R" --git-dir=/tmp status
agent_rej "status -s" "$R" status -s
agent_rej "status --porcelain=v1 -z" "$R" status --porcelain=v1 -z
agent_rej "rev-parse --git-dir" "$R" rev-parse --git-dir
agent_rej "branch -a" "$R" branch -a
agent_rej "tag -d" "$R" tag -d x
agent_rej "ls-files ../x" "$R" ls-files ../x
agent_rej "ls-files /abs" "$R" ls-files /etc/passwd
agent_rej "ls-files -o" "$R" ls-files -o
agent_rej "ls-files two paths" "$R" ls-files a.txt b.txt
agent_rej "config" "$R" config --list
agent_rej "checkout" "$R" checkout HEAD
agent_rej "relative ROOT" relative/path status
agent_rej "missing ROOT" /nonexistent-root-xyz status
agent_rej "ROOT with space" "$R x" status
agent_rej "ROOT only" "$R"
agent_rej "no args"
# the core itself (python --agent path, bypassing the shell checks) also refuses
python3 -I "$SCRIPTS/pm_git.py" --agent "$R" show HEAD >/dev/null 2>&1; [ $? -eq 2 ] && pass || fail "python --agent rejects show"
python3 -I "$SCRIPTS/pm_git.py" --agent "$R" log -n 61 >/dev/null 2>&1; [ $? -eq 2 ] && pass || fail "python --agent rejects log -n 61"
python3 -I "$SCRIPTS/pm_git.py" "$R" status >/dev/null 2>&1; [ $? -eq 2 ] && pass || fail "python without --agent rejected"
assert_clean "python --agent rejections"

echo "total $((PASS + FAIL)) pass $PASS fail $FAIL"
[ "$FAIL" -eq 0 ]
