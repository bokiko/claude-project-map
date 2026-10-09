#!/bin/bash
# test_guard.sh - project-map 3.2 guard suite (docs/INTERFACES-3.2.md sections 3, 4, 9).
# Usage: GUARD=<path> bash tests/test_guard.sh      (default GUARD: ../scripts/project-map-guard.sh)
# Run it under both `bash` and `/bin/bash`: the guard is executed by the same interpreter that runs this file.
# Needs jq and python3. Fixtures live under a Claude scratchpad path so the root rule accepts them.

HERE=$(cd "$(dirname "$0")" && pwd)
GUARD="${GUARD:-$HERE/../scripts/project-map-guard.sh}"
[ -f "$GUARD" ] || { echo "no guard at $GUARD"; exit 1; }
TB="/private/tmp/claude-$(id -u)/pmguard-test.$$/scratchpad"; mkdir -p "$TB"
TMP=$(mktemp -d "$TB/t.XXXXXX"); TMP=$(cd -P "$TMP" && pwd -P)
export PM_GUARD_LOG="$TMP/guard.log"
export HOME="$TMP/home"
export CLAUDE_PLUGIN_ROOT="$TMP/plugin"
export CLAUDE_PLUGIN_DATA="$TMP/data"
unset PM_GUARD_TRACE PM_LOCKED PM_IN
PLUGIN="$CLAUDE_PLUGIN_ROOT"; PLG="$PLUGIN/scripts"; DATA="$CLAUDE_PLUGIN_DATA"
MEM="$HOME/.claude/agent-memory/project-map"
mkdir -p "$MEM" "$PLG" "$DATA" "$HOME/.ssh" "$TMP/ledgers"
for f in project-map-facts.py project-map-usage.py project-map-embed.sh pm-git.sh; do : > "$PLG/$f"; done
printf 'x\n' > "$HOME/.claude.json"; printf 'x\n' > "$HOME/.zsh_history"; printf 'k\n' > "$HOME/.ssh/id_ed25519"
printf 'note\n' > "$MEM/feedback_x.md"

PROJ="$TMP/proj"; OTHER="$TMP/other"; OUT="$TMP/outside"; EVIL="$TMP/evil"
mkdir -p "$PROJ/sub" "$PROJ/.project-map" "$OTHER/.project-map" "$OUT" "$EVIL"
printf 'node_modules\n' > "$PROJ/.gitignore"
printf 'readme\n' > "$PROJ/README.md"; printf 'plan\n' > "$PROJ/PLAN.md"
printf 'dist\n' > "$OTHER/.gitignore"; printf 'other\n' > "$OTHER/README.md"
printf 'x\n' > "$PROJ/sub/.gitignore"; printf 'out\n' > "$OUT/data.txt"
printf 'S=1\n' > "$PROJ/.env"; mkdir -p "$PROJ/.git"; printf '[core]\n' > "$PROJ/.git/config"
ln -s "$PROJ/.env" "$PROJ/link-env"; ln -s "$OUT/data.txt" "$PROJ/link-out"; ln -s "$PROJ/README.md" "$PROJ/link-ok"
ln -s "$OUT/nothing" "$PROJ/link-dangling"; ln -s "$OUT" "$PROJ/dir-out"; ln -s "$OUT" "$EVIL/.project-map"
ln -s "$HOME/.ssh/id_ed25519" "$PROJ/link-ssh"
LEDGER="$TMP/ledgers/CONTINUITY_demo.md"; printf 'ledger\n' > "$LEDGER"; printf 'other ledger\n' > "$TMP/ledgers/CONTINUITY_other.md"

# ---------------------------------------------------------------- fixture helpers
CNT=0
nid() { printf 'inv-%08x' $(( (RANDOM * 32768 + RANDOM) * 2 % 4294967296 )); }   # fresh invocation id (no state: used in subshells)
nsid() { printf 'sess-%d-%d%d' $$ $RANDOM $RANDOM; }
mkinv() { # root inv [ledger]  -> invocation dir with the script-owned files
  local root="$1" inv="$2" led="${3:-$LEDGER}" d="$1/.project-map/$2"
  mkdir -p "$d"
  jq -nc --arg r "$root" --arg i "$inv" '{id:$i,created_at:"2026-10-08T00:00:00Z",base:null,root:$r,session_id:null}' > "$d/invocation.json"
  jq -nc --arg l "$led" '{ledger:{path:$l}}' > "$d/snapshot.json"
  printf '{}' > "$d/pack.json"; printf '{}' > "$d/judgement.in.json"
}
bindf() { # sid aid root inv mode  -> claimed binding
  mkdir -p "$DATA/bind/$1"
  jq -nc --arg r "$2" --arg i "$4" --arg m "$5" '{root:$r,inv:$i,mode:$m,tool_use_id:"tu-fix",at:"x"}' > "$DATA/bind/$1/$2.json" 2>/dev/null
}
bindj() { # sid aid root inv mode tuid
  mkdir -p "$DATA/bind/$1"
  jq -nc --arg r "$3" --arg i "$4" --arg m "$5" --arg t "${6:-tu-fix}" '{root:$r,inv:$i,mode:$m,tool_use_id:$t,at:"x"}' > "$DATA/bind/$1/$2.json"
}
pendj() { # sid root inv mode tuid
  mkdir -p "$DATA/bind/$1"
  jq -nc --arg r "$2" --arg i "$3" --arg m "$4" --arg t "$5" '{root:$r,inv:$i,mode:$m,tool_use_id:$t,at:"x"}' > "$DATA/bind/$1/pending"
}

SA=$(nsid); AA=agentA1; INVA=$(nid); mkinv "$PROJ" "$INVA"; bindj "$SA" "$AA" "$PROJ" "$INVA" UPDATE
SF=$(nsid); AF=agentF1; INVF=$(nid); mkinv "$PROJ" "$INVF"; bindj "$SF" "$AF" "$PROJ" "$INVF" FULL
STA="$PROJ/.project-map/$INVA"; STF="$PROJ/.project-map/$INVF"
CHROME='"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"'
CHD="$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=$STF/shot-desktop.png file://$PROJ/.project-map/index.html"
CHM="$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=390,844 --screenshot=$STF/shot-mobile.png file://$PROJ/.project-map/index.html"

pass=0; fail=0
note() { # name want got
  if [ "$3" = "$2" ]; then pass=$((pass+1)); printf 'PASS  %-6s %s\n' "$2" "$1"
  else fail=$((fail+1)); printf 'FAIL  want %-5s got %-9s %s\n' "$2" "$3" "$1"; fi
}
rcname() { case "$1" in 0) echo allow;; 2) echo block;; *) echo "error($1)";; esac; }
run() { # name want json [guard args...]
  local name="$1" want="$2" json="$3" rc; shift 3
  printf '%s' "$json" | "$BASH" "$GUARD" "$@" >/dev/null 2>&1; rc=$?
  note "$name" "$want" "$(rcname $rc)"
}
rc_of() { printf '%s' "$1" | "$BASH" "$GUARD" "${@:2}" >/dev/null 2>&1; echo $?; }
chk() { note "$1" "$2" "$3"; }                      # arbitrary assertion: name want got
yes_no() { if eval "$2"; then echo yes; else echo no; fi; }

mkin() { # sid aid atype tool cwd tool_input_json [tuid]
  jq -nc --arg s "$1" --arg a "$2" --arg at "$3" --arg t "$4" --arg c "$5" --argjson ti "$6" --arg u "${7:-}" \
    '{session_id:$s,tool_name:$t,cwd:$c,tool_input:$ti} + (if $a!="" then {agent_id:$a,agent_type:$at} else {} end) + (if $u!="" then {tool_use_id:$u} else {} end)'
}
AT=project-map:project-map
# bound UPDATE agent (A) and bound FULL agent (F)
bash_t()  { run "Bash: $2" "$1" "$(mkin "$SA" "$AA" $AT Bash "$PROJ" "$(jq -nc --arg c "$2" '{command:$c}')")"; }
fbash_t() { run "FULL Bash: $2" "$1" "$(mkin "$SF" "$AF" $AT Bash "$PROJ" "$(jq -nc --arg c "$2" '{command:$c}')")"; }
write_t() { run "Write: $2" "$1" "$(mkin "$SA" "$AA" $AT Write "$PROJ" "$(jq -nc --arg p "$2" --arg c "$3" '{file_path:$p,content:$c}')")"; }
fwrite_t(){ run "FULL Write: $2" "$1" "$(mkin "$SF" "$AF" $AT Write "$PROJ" "$(jq -nc --arg p "$2" --arg c "$3" '{file_path:$p,content:$c}')")"; }
edit_t()  { run "Edit: $2" "$1" "$(mkin "$SA" "$AA" $AT Edit "$PROJ" "$(jq -nc --arg p "$2" --arg o "$3" --arg n "$4" '{file_path:$p,old_string:$o,new_string:$n}')")"; }
read_t()  { run "Read: $2" "$1" "$(mkin "$SA" "$AA" $AT Read "$PROJ" "$(jq -nc --arg p "$2" '{file_path:$p}')")"; }
tool_t()  { run "$2 (agent)" "$1" "$(mkin "$SA" "$AA" $AT "$2" "$PROJ" "$3")"; }
main_t()  { run "main $2: $3" "$1" "$(mkin "$(nsid)" "" "" "$2" "$PROJ" "$4")"; }

# ================================================================= allowed agent Bash
echo "== allowed Bash (bound UPDATE agent) =="
bash_t allow "python3 $PLG/project-map-facts.py $PROJ"
bash_t allow "bash $PLG/project-map-embed.sh $PROJ $INVA"
bash_t allow "python3 $PLG/project-map-usage.py $PROJ"
bash_t allow "bash $PLG/pm-git.sh $PROJ status"
bash_t allow "bash $PLG/pm-git.sh $PROJ log"
bash_t allow "bash $PLG/pm-git.sh $PROJ log -n 20"
bash_t allow "bash $PLG/pm-git.sh $PROJ rev-parse"
bash_t allow "bash $PLG/pm-git.sh $PROJ branch"
bash_t allow "bash $PLG/pm-git.sh $PROJ tag"
bash_t allow "bash $PLG/pm-git.sh $PROJ ls-files"
bash_t allow "bash $PLG/pm-git.sh $PROJ ls-files sub/x.py"
bash_t allow "ls -la $PROJ"
bash_t allow "ls -l $PROJ"
bash_t allow "ls -a $PROJ/sub"
bash_t allow "ls $PROJ"
bash_t allow 'ls .'
bash_t allow 'cat README.md'
bash_t allow "cat $PROJ/PLAN.md"
bash_t allow "cat $PLG/project-map-facts.py"
bash_t allow "cat $MEM/feedback_x.md"
bash_t allow "cat $LEDGER"
bash_t allow "cat $STA/pack.json"
bash_t allow 'head README.md'
bash_t allow 'head -n 5 README.md'
bash_t allow 'tail -n 5 README.md'
bash_t allow 'tail README.md'
bash_t allow 'wc README.md'
bash_t allow 'wc -l README.md'
bash_t allow 'wc -c README.md'
bash_t allow 'stat -f %z README.md'
bash_t allow "find $PROJ"
bash_t allow "find $PROJ -maxdepth 2"
bash_t allow "find $PROJ -maxdepth 2 -type f"
bash_t allow "find $PROJ -type d"
bash_t allow "find $PROJ -maxdepth 2 -type f -name PLAN.md"
bash_t allow "find $PROJ -name notes.md"
bash_t allow 'date'
bash_t allow 'date +%Y-%m-%dT%H:%M:%S%z'
bash_t allow 'date +%F'
bash_t allow 'gh issue list'
bash_t allow 'gh issue list -L 30'
bash_t allow 'gh issue list -L 30 --state open'
bash_t allow 'gh pr list --state all'
bash_t allow 'gh pr list -L 5 --state closed'
bash_t allow 'cat README.md | head -n 5'
bash_t allow 'cat README.md | tail -n 5'
bash_t allow 'cat README.md | tail -n +3'
bash_t allow 'cat README.md | head'
bash_t allow 'cat README.md | wc -l'
bash_t allow 'cat README.md | wc -c'
bash_t allow 'cat README.md | wc -w'
bash_t allow 'cat README.md | grep foo'
bash_t allow 'cat README.md | grep -i foo'
bash_t allow 'cat README.md | grep -n foo'
bash_t allow 'cat README.md | grep -c foo'
bash_t allow 'cat README.md | grep -E foo'
bash_t allow 'cat README.md | grep -F foo'
bash_t allow 'cat README.md | grep -i -n foo'
bash_t allow 'cat README.md | sort'
bash_t allow 'cat README.md | sort -r'
bash_t allow 'cat README.md | sort -n'
bash_t allow 'cat README.md | sort -u'
bash_t allow "ls -la $PROJ | head -n 3"
bash_t allow "bash $PLG/pm-git.sh $PROJ log -n 20 | head -n 5"
bash_t allow 'cat README.md|wc -l'
bash_t allow 'cat "README.md"'
bash_t allow "cat '$PROJ/PLAN.md'"
bash_t allow 'cat README.md | grep "foo"'
bash_t allow "ls -la $PROJ/link-ok"
bash_t allow "cat $PROJ/link-ok"

# ================================================================= blocked agent Bash
echo "== blocked Bash: raw git (G-git-raw) =="
for g in 'git status' 'git log' 'git log --oneline -n 5' 'git diff --stat HEAD' 'git show HEAD' 'git show HEAD --stat' 'git branch --list' 'git branch -a' \
         'git tag -l' 'git rev-parse HEAD' 'git rev-list --count HEAD' 'git ls-files' 'git check-ignore -q .project-map' "git -C $PROJ log" "git -C $PROJ/sub log -n 3" \
         'git config user.name x' 'git -c core.pager=evil log' 'git push origin master' 'git commit -am x' 'git checkout -- .' 'git remote -v' 'git cat-file -p HEAD' \
         'git log --output=/tmp/x' 'git diff --ext-diff' 'git blame README.md' 'git describe' 'git shortlog -sn' 'git branch newbranch' 'git tag v9' 'git branch -D x'; do
  bash_t block "$g"
done

echo "== blocked Bash: pm-git / trusted scripts =="
bash_t block "bash $PLG/pm-git.sh $PROJ show HEAD"
bash_t block "bash $PLG/pm-git.sh $PROJ config user.name"
bash_t block "bash $PLG/pm-git.sh $PROJ push"
bash_t block "bash $PLG/pm-git.sh $PROJ remote"
bash_t block "bash $PLG/pm-git.sh $PROJ"
bash_t block "bash $PLG/pm-git.sh $PROJ log -c core.pager=x"
bash_t block "bash $PLG/pm-git.sh $PROJ log --output=/tmp/x"
bash_t block "bash $PLG/pm-git.sh $PROJ ls-files /etc/passwd"
bash_t block "bash $PLG/pm-git.sh $PROJ ls-files ../x"
bash_t block "bash $PLG/pm-git.sh $OTHER status"
bash_t block "bash $PLG/pm-git.sh /etc status"
bash_t block "bash $PROJ/pm-git.sh $PROJ status"
bash_t block "bash $PLG/pm-git.sh status"
bash_t block "python3 $PLG/pm-git.sh $PROJ status"
bash_t block "python3 $PLG/project-map-facts.py $PROJ --json"
bash_t block "python3 $PLG/project-map-facts.py $PROJ --max-commits 50"
bash_t block "python3 $PLG/project-map-facts.py $PROJ --close-session"
bash_t block "python3 $PLG/project-map-facts.py --close-session $PROJ"
bash_t block "python3 $PLG/project-map-facts.py --accept-answers $PROJ"
bash_t block "python3 $PLG/project-map-facts.py $OTHER"
bash_t block "python3 $PLG/project-map-facts.py /etc"
bash_t block "python3 $PLG/project-map-facts.py $HOME"
bash_t block "python3 $PLG/project-map-facts.py"
bash_t block "python3 $PROJ/project-map-facts.py $PROJ"
bash_t block "python3 $PLG/project-map-facts.py $PROJ > /tmp/facts.out"
bash_t block "python3 $PLG/project-map-facts.py $PROJ --json > $PROJ/.project-map/state.json"
bash_t block "bash $PLG/project-map-embed.sh $PROJ"
bash_t block "bash $PLG/project-map-embed.sh $PROJ inv-ffffffff"
bash_t block "bash $PLG/project-map-embed.sh $PROJ $INVF"
bash_t block "bash $PLG/project-map-embed.sh $PROJ $INVA extra"
bash_t block "bash $PLG/project-map-embed.sh $OTHER $INVA"
bash_t block "bash $PLG/project-map-embed.sh $PROJ/../../etc $INVA"
bash_t block "bash $PLG/project-map-embed.sh $HOME $INVA"
bash_t block "bash $PLG/project-map-embed.sh /tmp $INVA"
bash_t block "bash $PLG/project-map-embed.sh $PROJ --evil"
bash_t block "python3 $PLG/project-map-usage.py $PROJ --since 2026-10-05T00:00:00+03:00"
bash_t block "python3 $PLG/project-map-usage.py $PROJ --evil"
bash_t block "python3 $PLG/project-map-usage.py /etc"
bash_t block "python3 $PLG/project-map-usage.py $HOME"
bash_t block "python3 $PLG/project-map-usage.py $OTHER"
bash_t block 'python3 evil.py'
bash_t block 'bash evil.sh'
bash_t block 'python3 -c print(1)'
bash_t block 'bash -c ls'
bash_t block 'sh -c ls'

echo "== blocked Bash: grammar =="
bash_t block 'ls; touch x'
bash_t block 'cat a && touch b'
bash_t block 'ls || rm -r y'
bash_t block 'ls | sh'
bash_t block 'ls | tee out.txt'
bash_t block 'echo `rm -rf y`'
bash_t block 'ls $(rm -r y)'
bash_t block 'ls
rm x'
bash_t block 'ls	-la'
bash_t block 'cat README.md | head -n 5 | tail -n 1'
bash_t block 'cat README.md |'
bash_t block '| cat README.md'
bash_t block 'cat README.md & ls'
bash_t block 'cat README.md > f'
bash_t block 'cat < README.md'
bash_t block 'cat README.md >> f'
bash_t block 'cat (README.md)'
bash_t block 'cat {README.md,PLAN.md}'
bash_t block 'cat README.md !'
bash_t block 'cat README.m?'
bash_t block 'cat READ[M]E.md'
bash_t block 'cat *'
bash_t block 'cat *.md'
bash_t block 'cat ~/README.md'
bash_t block 'cat ~'
bash_t block 'cat $HOME/README.md'
bash_t block 'cat ${HOME}/x'
bash_t block 'cat "$HOME/x"'
bash_t block 'cat READ\ME.md'
bash_t block "cat 'README.md PLAN.md'"
bash_t block 'cat "README.md | head"'
bash_t block 'cat "README.md'
bash_t block "cat README.md'"
bash_t block 'cat "a" | "b"'
bash_t block 'ls -R'
bash_t block "ls -R $PROJ"
bash_t block "ls -laR $PROJ"
bash_t block 'ls'
bash_t block "ls $PROJ $PROJ/sub"
bash_t block 'cat'
bash_t block 'cat README.md PLAN.md'
bash_t block 'head -n x README.md'
bash_t block 'head -n README.md'
bash_t block 'head -c 5 README.md'
bash_t block 'head -5 README.md'
bash_t block 'tail -f README.md'
bash_t block 'tail -F README.md'
bash_t block 'tail -n 5x README.md'
bash_t block 'tail -n +x README.md'
bash_t block 'wc -L README.md'
bash_t block 'wc -w README.md'
bash_t block 'wc README.md PLAN.md'
bash_t block 'stat README.md'
bash_t block 'stat -f %N README.md'
bash_t block 'stat -f %z'
bash_t block 'stat -x README.md'
bash_t block "find $PROJ -delete"
bash_t block "find $PROJ -exec cat {} +"
bash_t block "find $PROJ -ok rm {} ;"
bash_t block "find $PROJ -fprint /tmp/x"
bash_t block "find $PROJ -fprintf /tmp/x %p"
bash_t block "find $PROJ -fls /tmp/x"
bash_t block "find $PROJ -newer state.json"
bash_t block "find $PROJ -maxdepth x"
bash_t block "find $PROJ -maxdepth 2 -maxdepth 3"
bash_t block "find $PROJ -type l"
bash_t block "find $PROJ -name *.md"
bash_t block "find $PROJ -name a/b"
bash_t block "find $PROJ -name"
bash_t block 'find'
bash_t block "find $HOME/.ssh -type f"
bash_t block 'find ~/.ssh'
bash_t block 'date -s 2026-01-01'
bash_t block 'date 1007120026'
bash_t block 'date +%F 1007120026'
bash_t block 'date -u'
bash_t block 'date +%F +%T'
bash_t block 'gh issue list -R other/repo'
bash_t block 'gh issue list --repo other/repo'
bash_t block 'gh issue list --hostname evil.example'
bash_t block 'gh issue list --search x'
bash_t block 'gh issue list --json number'
bash_t block 'gh issue list -L x'
bash_t block 'gh issue list --state bogus'
bash_t block 'gh issue list --web'
bash_t block 'gh issue view 1'
bash_t block 'gh issue create'
bash_t block 'gh pr list -R other/repo'
bash_t block 'gh pr view 1'
bash_t block 'gh pr merge 1'
bash_t block 'gh api /user'
bash_t block 'gh auth token'
bash_t block 'gh'
bash_t block 'rm x'
bash_t block 'touch x'
bash_t block 'mkdir x'
bash_t block 'cp README.md x'
bash_t block 'mv README.md x'
bash_t block 'curl http://example.com'
bash_t block 'echo hi'
bash_t block 'env'
bash_t block 'printenv'
bash_t block 'pwd'
bash_t block 'which python3'
bash_t block 'grep foo README.md'
bash_t block 'grep -n foo README.md'
bash_t block 'grep -r . .'
bash_t block "grep -R foo $HOME/projects/x"
bash_t block 'grep --recursive foo .'
bash_t block 'grep -e foo -e bar README.md'
bash_t block 'sed -n 1p README.md'
bash_t block 'awk 1 README.md'
bash_t block 'xargs ls'
bash_t block 'tee out'
bash_t block 'sort -o f g'
bash_t block 'uniq README.md'
bash_t block 'cut -d, -f1 README.md'
bash_t block 'tr a b'
bash_t block "cd $PROJ"
bash_t block "cd $PROJ && ls"
bash_t block 'cd ..'
bash_t block 'source x'
bash_t block '. x'
bash_t block 'export A=1'
bash_t block 'A=1 ls'
bash_t block 'time ls'
bash_t block '/bin/ls .'
bash_t block './ls .'
bash_t block 'command ls .'
bash_t block 'eval ls'

echo "== blocked Bash: pipe consumers =="
bash_t block 'cat README.md | uniq /dev/stdin out.txt'
bash_t block 'cat README.md | uniq in out'
bash_t block 'cat README.md | head README.md'
bash_t block 'cat README.md | head -n 3 other.txt'
bash_t block 'cat README.md | head -c 5'
bash_t block 'cat README.md | head --lines=3'
bash_t block 'cat README.md | head -n x'
bash_t block 'cat README.md | head -n'
bash_t block 'cat README.md | head -q'
bash_t block 'cat README.md | tail -n 3 other.txt'
bash_t block 'cat README.md | tail -f'
bash_t block 'cat README.md | tail --follow'
bash_t block 'cat README.md | tail -n 3x'
bash_t block 'cat README.md | wc -l other.txt'
bash_t block 'cat README.md | wc --lines'
bash_t block 'cat README.md | wc -L'
bash_t block 'cat README.md | wc -l -c'
bash_t block 'cat README.md | sort other.txt'
bash_t block 'cat README.md | sort --out=/tmp/x'
bash_t block 'cat README.md | sort --o=/tmp/x'
bash_t block 'cat README.md | sort --output=/tmp/x'
bash_t block 'cat README.md | sort -o /tmp/x'
bash_t block 'cat README.md | sort -o out.txt'
bash_t block 'cat README.md | sort -k 2'
bash_t block 'cat README.md | sort -t ,'
bash_t block 'cat README.md | sort -rn'
bash_t block 'cat README.md | sort --reverse'
bash_t block 'cat README.md | sort --compress-program=sh'
bash_t block 'cat README.md | grep foo bar.txt'
bash_t block 'cat README.md | grep a b'
bash_t block 'cat README.md | grep'
bash_t block 'cat README.md | grep -i'
bash_t block 'cat README.md | grep -r foo'
bash_t block 'cat README.md | grep -f patterns.txt'
bash_t block 'cat README.md | grep --file=p'
bash_t block 'cat README.md | grep -m 3 foo'
bash_t block 'cat README.md | grep -v foo'
bash_t block 'cat README.md | cut -d, -f1'
bash_t block 'cat README.md | tr a b'
bash_t block 'cat README.md | sh'
bash_t block 'cat README.md | bash'
bash_t block 'cat README.md | xargs rm'
bash_t block 'cat README.md | tee x'
bash_t block 'cat README.md | cat'
bash_t block 'cat README.md | awk 1'
bash_t block 'cat README.md | sed p'
bash_t block 'grep "a | tee out" README.md'
bash_t block "cat 'a | b'"
bash_t block 'cat README.md | grep "a|b"'

echo "== blocked Bash: metacharacters inside quotes =="
bash_t block 'cat "x; touch y"'
bash_t block 'cat "a > out"'
bash_t block 'cat "a < b"'
bash_t block 'cat "a & b"'
bash_t block 'cat "$(touch y)"'
bash_t block 'cat "`touch y`"'
bash_t block "cat 'x; y'"
bash_t block 'cat "~/.ssh/id_rsa"'
bash_t block 'cat "READ*.md"'
bash_t block 'cat "READ?E.md"'
bash_t block 'cat "READ[M]E.md"'

echo "== blocked Bash: scope and secrets (G-read-scope) =="
bash_t block 'cat ~/.ssh/id_ed25519'
bash_t block "cat $HOME/.ssh/id_ed25519"
bash_t block "cat $HOME/.claude.json"
bash_t block "cat $HOME/.zsh_history"
bash_t block 'cat /etc/passwd'
bash_t block 'cat /etc/hosts'
bash_t block 'cat /dev/zero'
bash_t block 'cat /dev/stdin'
bash_t block 'head -n 1 /dev/random'
bash_t block 'tail -n 1 /dev/urandom'
bash_t block 'cat ../other/README.md'
bash_t block "cat $OTHER/README.md"
bash_t block "cat $OUT/data.txt"
bash_t block "cat $PROJ/../other/README.md"
bash_t block "ls $OTHER"
bash_t block "ls $HOME"
bash_t block 'ls /'
bash_t block 'ls /etc'
bash_t block "ls $HOME/.ssh"
bash_t block "find $HOME -maxdepth 1"
bash_t block "find $OTHER -type f"
bash_t block "wc -l $OTHER/README.md"
bash_t block "stat -f %z $OTHER/README.md"
bash_t block "stat -f %z $HOME/.claude.json"
bash_t block "head -n 3 $OUT/data.txt"
bash_t block "tail -n 3 $HOME/.zsh_history"
bash_t block "cat $PROJ/.env"
bash_t block 'cat .env'
bash_t block 'cat .env.local'
bash_t block 'cat .ENV'
bash_t block "cat $PROJ/.git/config"
bash_t block 'cat .git/config'
bash_t block 'cat .git/HEAD'
bash_t block "ls $PROJ/.git"
bash_t block "find $PROJ/.git -type f"
bash_t block 'cat credentials.md'
bash_t block 'cat my-credentials.txt'
bash_t block 'cat secrets.yaml'
bash_t block 'cat api_token.txt'
bash_t block 'cat password.txt'
bash_t block 'cat server.pem'
bash_t block 'cat server.key'
bash_t block 'cat cert.p12'
bash_t block 'cat cert.pfx'
bash_t block 'cat id_rsa'
bash_t block 'cat id_rsa.pub'
bash_t block 'cat id_ed25519'
bash_t block 'cat .zsh_history'
bash_t block 'cat .bash_history'
bash_t block 'cat .netrc'
bash_t block 'cat .npmrc'
bash_t block 'cat .pypirc'
bash_t block 'cat .claude.json'
bash_t block 'cat settings.json'
bash_t block 'cat settings.local.json'
bash_t block 'cat ssh_host_rsa_key'
bash_t block 'cat known_hosts'
bash_t block 'cat .ssh/config'
bash_t block 'cat .aws/credentials'
bash_t block 'cat .gnupg/pubring.kbx'
bash_t block 'cat .config/gh/hosts.yml'
bash_t block "cat $LEDGER.bak"
bash_t block "cat $TMP/ledgers/CONTINUITY_other.md"
bash_t block "ls $TMP/ledgers"
bash_t block "cat $HOME/.claude/projects/-Users-demo/memory/credentials.md"
bash_t block "cat $HOME/.claude/CLAUDE.md"
bash_t block "cat $MEM/../../settings.json"
bash_t block "cat $PROJ/sub/../../other/README.md"

echo "== blocked Bash: symlinks (G-symlink) =="
bash_t block "cat $PROJ/link-env"
bash_t block 'cat link-env'
bash_t block "cat $PROJ/link-out"
bash_t block "cat $PROJ/link-ssh"
bash_t block "cat $PROJ/link-dangling"
bash_t block "cat $PROJ/dir-out/data.txt"
bash_t block "ls $PROJ/dir-out"
bash_t block "head -n 1 $PROJ/link-env"
bash_t block "wc -l $PROJ/link-out"
bash_t block "stat -f %z $PROJ/link-ssh"
bash_t block "find $PROJ/dir-out -type f"
bash_t block "cat $PROJ/dir-out/../README.md"

echo "== blocked Bash: directories as file operands =="
bash_t block "cat $PROJ"
bash_t block "cat $PROJ/sub"
bash_t block 'cat .'
bash_t block 'cat sub'
bash_t block "head -n 3 $PROJ"
bash_t block "tail -n 3 $PROJ/sub"
bash_t block "wc -l $PROJ"
bash_t block "cat $PLG"

echo "== Chrome (FULL only) =="
bash_t block "$CHD"
bash_t block "$CHM"
fbash_t allow "$CHD"
fbash_t allow "$CHM"
fbash_t block "$CHD; ls"
fbash_t block "$CHD --remote-debugging-port=9222"
fbash_t block "$CHD --user-data-dir=/tmp/p"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=$STF/shot-mobile.png file://$PROJ/.project-map/index.html"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=390,844 --screenshot=$STF/shot-desktop.png file://$PROJ/.project-map/index.html"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=/tmp/shot.png file://$PROJ/.project-map/index.html"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=$STA/shot-desktop.png file://$PROJ/.project-map/index.html"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=$STF/shot-desktop.png file://$PROJ/.project-map/mobile.html"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=$STF/shot-desktop.png file://$OTHER/.project-map/index.html"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=$STF/shot-desktop.png https://example.com"
fbash_t block "$CHROME --headless=new --window-size=1440,900 --screenshot=$STF/shot-desktop.png file://$PROJ/.project-map/index.html"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=500,2400 --screenshot=$STF/shot-desktop.png file://$PROJ/.project-map/index.html"
fbash_t block "$CHROME --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=$STF/shot-desktop.png file://$PROJ/.project-map/index.html "
fbash_t allow "python3 $PLG/project-map-facts.py $PROJ"
fbash_t allow "bash $PLG/project-map-embed.sh $PROJ $INVF"
fbash_t block "bash $PLG/project-map-embed.sh $PROJ $INVA"

# ================================================================= Write / Edit
echo "== Write/Edit =="
write_t allow "$STA/judgement.out.json" '{}'
edit_t  allow "$STA/judgement.out.json" 'a' 'b'
write_t block "$STA/plan.out.json" '{}'                        # FULL-only target
fwrite_t allow "$STF/judgement.out.json" '{}'
fwrite_t allow "$STF/plan.out.json" '{}'
write_t allow "$MEM/MEMORY.md" '# mem'
write_t allow "$MEM/feedback_x.md" 'x'
write_t allow "$MEM/new-note.md" 'x'
write_t allow "$PROJ/.gitignore" $'node_modules\n.project-map/\n'
edit_t  allow "$PROJ/.gitignore" 'node_modules' $'node_modules\n.project-map/'
edit_t  allow "$PROJ/.gitignore" $'node_modules\n' $'node_modules\n.project-map/\n'
write_t block "$STA/judgement.json" '{}'                        # old path
write_t block "$STA/pack.json" '{}'
write_t block "$STA/snapshot.json" '{}'
write_t block "$STA/invocation.json" '{}'
write_t block "$STA/judgement.in.json" '{}'
write_t block "$STA/claimed" 'x'
write_t block "$STA/released" 'x'
write_t block "$STA/sub/judgement.out.json" '{}'
write_t block "$STA/judgement.out.json/" '{}'
write_t block "$STF/judgement.out.json" '{}'                    # another invocation's staging dir
write_t block "$PROJ/.project-map/judgement.out.json" '{}'
write_t block "$PROJ/.project-map/judgement.json" '{}'
write_t block "$PROJ/.project-map/state.json" '{}'
write_t block "$PROJ/.project-map/index.html" '<html></html>'
write_t block "$PROJ/.project-map/answers.jsonl" '{}'
write_t block "$PROJ/.project-map/.lock" 'x'
write_t block "$PROJ/.project-map/current/index.html" 'x'
write_t block "$PROJ/.project-map/gen-000001-aaaaaaaa/judgement.out.json" '{}'
edit_t  block "$PROJ/.project-map/state.json" 'a' 'b'
edit_t  block "$PROJ/.project-map/index.html" 'a' 'b'
write_t block ".project-map/$INVA/judgement.out.json" '{}'     # relative
write_t block "judgement.out.json" '{}'
write_t allow "$STA/../$INVA/judgement.out.json" '{}'
write_t block "$STA/../../.project-map/$INVA/judgement.out.json/x" '{}'
write_t block "$OTHER/.project-map/$INVA/judgement.out.json" '{}'   # cross-project
write_t block "$EVIL/.project-map/$INVA/judgement.out.json" '{}'
write_t block "$HOME/.project-map/$INVA/judgement.out.json" '{}'
write_t block "/etc/hosts" 'x'
write_t block "$MEM/pm.sh" 'x'
write_t block "$MEM/template.html" 'x'
write_t block "$MEM/guard.log" 'x'
write_t block "$MEM/.hidden.md" 'x'
write_t block "$MEM/sub/x.md" 'x'
write_t block "$MEM/../x.md" 'x'
write_t block "$MEM/a b.md" 'x'
write_t block "$HOME/.claude/agents/project-map.md" 'x'
write_t block "$PLG/project-map-guard.sh" '#!/bin/bash'
write_t block "$PLG/project-map-facts.py" 'x'
write_t block "$HOME/.claude/settings.json" '{}'
write_t block "$PROJ/README.md" 'x'
write_t block "$PROJ/sub/.gitignore" $'x\n.project-map/\n'
write_t block "$OTHER/.gitignore" $'dist\n.project-map/\n'
write_t block "$HOME/.gitignore" $'.project-map/\n'
write_t block "$PROJ/.gitignore" '*'
write_t block "$PROJ/.gitignore" $'.project-map/\n'                       # drops the previous content
write_t block "$PROJ/.gitignore" $'node_modules\n.project-map/'            # no trailing newline
write_t block "$PROJ/.gitignore" $'node_modules\n.project-map/\nsecret_dir/\n'
write_t block "$PROJ/.gitignore" $'node_modules\n.project-map/\n.project-map/\n'
write_t block "$PROJ/.gitignore" $'.project-map/\nnode_modules\n'
edit_t  block "$PROJ/.gitignore" 'node_modules' '# wiped'
edit_t  block "$PROJ/.gitignore" 'node_modules' $'node_modules\n.project-map/\n/etc/passwd'
edit_t  block "$PROJ/.gitignore" 'xyz' $'xyz\n.project-map/'
edit_t  block "$PROJ/.gitignore" '' $'.project-map/\n'                     # non-empty file, empty old_string
edit_t  block "$PROJ/missing/.gitignore" '' $'.project-map/\n'
write_t block "$PROJ/link-env" 'x'
write_t block "$PROJ/link-ok" 'x'
write_t block "$PROJ/link-dangling" 'x'
write_t block "$PROJ/dir-out/judgement.out.json" '{}'
run "Edit .gitignore replace_all" block "$(mkin "$SA" "$AA" $AT Edit "$PROJ" "$(jq -nc --arg p "$PROJ/.gitignore" '{file_path:$p,old_string:"node_modules",new_string:"node_modules\n.project-map/",replace_all:true}')")"
run "Write relative path" block "$(mkin "$SA" "$AA" $AT Write "$PROJ" '{"file_path":"x.md","content":"x"}')"
run "Write without file_path" block "$(mkin "$SA" "$AA" $AT Write "$PROJ" '{"content":"x"}')"

echo "== Write/Edit: file type rules =="
# hard link, symlink and non-regular targets
HL="$STA/judgement.out.json"
rm -f "$HL" "$TMP/hardlink-copy"; printf '{}' > "$HL"
write_t allow "$HL" '{"a":1}'
ln "$HL" "$TMP/hardlink-copy"
write_t block "$HL" '{"a":2}'                                  # nlink == 2
edit_t  block "$HL" 'a' 'b'
rm -f "$TMP/hardlink-copy"
write_t allow "$HL" '{"a":3}'
rm -f "$HL"; ln -s "$OUT/data.txt" "$HL"
write_t block "$HL" '{"a":4}'                                  # symlink target
rm -f "$HL"; mkdir "$HL"
write_t block "$HL" '{"a":5}'                                  # directory target
rmdir "$HL"
PL="$STF/plan.out.json"; rm -f "$PL"; ln -s "$OUT/data.txt" "$PL"
fwrite_t block "$PL" '{}'
rm -f "$PL"; printf '{}' > "$PL"; ln "$PL" "$TMP/plan-hl"
fwrite_t block "$PL" '{}'
rm -f "$PL" "$TMP/plan-hl"
fwrite_t allow "$PL" '{}'
rm -f "$MEM/linked.md"; ln -s "$OUT/data.txt" "$MEM/linked.md"
write_t block "$MEM/linked.md" 'x'
rm -f "$MEM/linked.md"
GI="$PROJ/.gitignore"; cp "$GI" "$TMP/gi.keep"; ln "$GI" "$TMP/gi-hl"
write_t block "$GI" $'node_modules\n.project-map/\n'
rm -f "$TMP/gi-hl"
write_t allow "$GI" $'node_modules\n.project-map/\n'
printf 'no-newline' > "$GI"
write_t allow "$GI" $'no-newline\n.project-map/\n'
write_t block "$GI" $'no-newline.project-map/\n'
: > "$GI"
write_t allow "$GI" $'.project-map/\n'
edit_t  allow "$GI" '' $'.project-map/\n'
rm -f "$GI"
write_t allow "$GI" $'.project-map/\n'                          # absent file may be created
cp "$TMP/gi.keep" "$GI"

# ================================================================= Read
echo "== Read (G-read-scope, G-symlink) =="
read_t allow "$PROJ/README.md"
read_t allow "$PROJ/sub/.gitignore"
read_t allow "$PROJ/link-ok"
read_t allow "$PLG/project-map-facts.py"
read_t allow "$MEM/feedback_x.md"
read_t allow "$LEDGER"
read_t allow "$STA/pack.json"
read_t allow "$STA/snapshot.json"
read_t allow "$PROJ/not-yet.md"
read_t block "$TMP/ledgers/CONTINUITY_other.md"
read_t block "$HOME/.claude.json"
read_t block "$HOME/.zsh_history"
read_t block "/etc/passwd"
read_t block "/etc/hosts"
read_t block "/dev/zero"
read_t block "$HOME/.ssh/id_ed25519"
read_t block "$HOME/.ssh/config"
read_t block "$HOME/.claude/projects/-Users-demo/memory/credentials.md"
read_t block "$HOME/.claude/settings.json"
read_t block "$HOME/.claude/CLAUDE.md"
read_t block "$OTHER/README.md"
read_t block "$OUT/data.txt"
read_t block "$PROJ/.env"
read_t block "$PROJ/.env.production"
read_t block "$PROJ/.git/config"
read_t block "$PROJ/link-env"
read_t block "$PROJ/link-out"
read_t block "$PROJ/link-ssh"
read_t block "$PROJ/link-dangling"
read_t block "$PROJ/dir-out/data.txt"
read_t block "$PROJ/../other/README.md"
read_t block "$PROJ/sub/../../other/README.md"
read_t block "README.md"
read_t block "~/.ssh/id_ed25519"
read_t block "$PROJ/notes/secret.txt"
read_t block "$PROJ/notes/api-token.md"
read_t block "$PROJ/server.pem"
read_t block "$PROJ/id_rsa"
read_t block "$PROJ/settings.json"
read_t block "$PROJ/.netrc"
read_t block "$MEM/../../.claude.json"
run "Read without file_path" block "$(mkin "$SA" "$AA" $AT Read "$PROJ" '{}')"

# ================================================================= Grep / Glob / other tools
echo "== Grep/Glob and other tools (G-grep) =="
tool_t block Grep '{"pattern":"TODO","path":"/tmp"}'
tool_t block Grep '{"pattern":"TODO"}'
tool_t block Grep '{"pattern":"x","path":"README.md"}'
tool_t block Glob '{"pattern":"**/*.md"}'
tool_t block Glob '{"pattern":"*","path":"/"}'
tool_t block Agent '{"subagent_type":"general-purpose","prompt":"x"}'
tool_t block Task '{"prompt":"x"}'
tool_t block WebFetch '{"url":"http://example.com"}'
tool_t block NotebookEdit '{"notebook_path":"x"}'
tool_t block mcp__x__y '{}'
main_t allow Grep grep '{"pattern":"TODO"}'
main_t allow Glob glob '{"pattern":"*.md"}'
main_t allow Read read '{"file_path":"/etc/passwd"}'
main_t allow Write write '{"file_path":"/tmp/x","content":"x"}'
main_t allow Bash rm '{"command":"rm -rf /"}'
main_t allow Bash git '{"command":"git status"}'
main_t allow WebFetch web '{"url":"http://example.com"}'

# ================================================================= modes
echo "== modes =="
S0=$(nsid)
run "main (no agent_id): everything allowed" allow "$(mkin "$S0" "" "" Bash "$PROJ" '{"command":"rm -rf /"}')"
run "main: Write anywhere allowed" allow "$(mkin "$S0" "" "" Write "$PROJ" '{"file_path":"/etc/x","content":"x"}')"
run "agent_type :project-map without agent_id is not main mode" block "$(jq -nc --arg s "$S0" '{session_id:$s,agent_type:"project-map:project-map",tool_name:"Bash",tool_input:{command:"rm -rf /"}}')"
run "other subagent: allowed" allow "$(mkin "$S0" other1 other Bash "$PROJ" '{"command":"rm -rf /"}')"
run "other subagent (project-mapper): allowed" allow "$(mkin "$S0" other1 project-mapper Bash "$PROJ" '{"command":"rm -rf /"}')"
run "other subagent (bare project-map): allowed" allow "$(mkin "$S0" other1 project-map Bash "$PROJ" '{"command":"rm -rf /"}')"
run "other subagent: Write anywhere allowed" allow "$(mkin "$S0" other1 other Write "$PROJ" '{"file_path":"/etc/x","content":"x"}')"
run "other subagent never claims a pending record" allow "$(mkin "$S0" other1 other Read "$PROJ" '{"file_path":"/etc/passwd"}')"
run "agent_type x:project-map enforced" block "$(mkin "$S0" ag9 x:project-map Bash "$PROJ" '{"command":"ls ."}')"
run "agent_type plugin:project-map:project-map enforced (no binding)" block "$(mkin "$S0" ag9 plugin:project-map:project-map Bash "$PROJ" '{"command":"rm -rf /"}')"
run "agent without session_id denied" block "$(jq -nc '{agent_id:"ag1",agent_type:"project-map:project-map",tool_name:"Read",tool_input:{file_path:"/x"}}')"
run "agent with unsafe session_id denied" block "$(mkin "../x" ag1 $AT Read "$PROJ" '{"file_path":"/x"}')"
run "agent with unsafe agent_id denied" block "$(mkin "$SA" "../x" $AT Read "$PROJ" '{"file_path":"/x"}')"
run "agent without tool_name" block "$(jq -nc --arg s "$SA" '{session_id:$s,agent_id:"agentA1",agent_type:"project-map:project-map",tool_input:{}}')"
CLAUDE_PLUGIN_DATA="" run "agent without plugin data dir" block "$(mkin "$SA" "$AA" $AT Read "$PROJ" "$(jq -nc --arg p "$PROJ/README.md" '{file_path:$p}')")"

# ================================================================= envelope
for v in '""' null true false 0 7 '{}' '[]' '{"x":1}' '["a"]'; do
  run "malformed agent_id $v selects no main mode" block "$(jq -nc --argjson v "$v" --arg s "$S0" '{session_id:$s,agent_id:$v,agent_type:"x",tool_name:"Bash",tool_input:{command:"rm -rf /"}}')"
done
run "malformed agent_id with project-map type" block "$(jq -nc --arg s "$S0" '{session_id:$s,agent_id:null,agent_type:"project-map:project-map",tool_name:"Read",tool_input:{file_path:"/etc/passwd"}}')"
run "malformed agent_id on an Agent spawn" block "$(jq -nc --arg s "$S0" '{session_id:$s,agent_id:"",tool_name:"Agent",tool_input:{subagent_type:"project-map:project-map",prompt:"x"}}')"
run "malformed agent_id in spawn-result mode" block "$(jq -nc --arg s "$S0" '{session_id:$s,agent_id:"",tool_name:"Agent",tool_use_id:"t"}')" --spawn-result ok
run "non-empty agent_id, other type: other mode" allow "$(jq -nc --arg s "$S0" '{session_id:$s,agent_id:"a1",agent_type:"Explore",tool_name:"Bash",tool_input:{command:"rm -rf /"}}')"
run "non-empty agent_id, missing agent_type: other mode" allow "$(jq -nc --arg s "$S0" '{session_id:$s,agent_id:"a1",tool_name:"Bash",tool_input:{command:"ls"}}')"
echo "== envelope (G-pad, G-envelope) =="
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
PAD=$(head -c 40000 /dev/zero | tr '\0' ' ')
PADCMD=$(jq -nc --arg c "cat ~/.ssh/id_ed25519$PAD" '{command:$c}')
t0=$(now_ms)
run "G-pad: 40 KB padded cat ~/.ssh/id_ed25519" block "$(mkin "$SA" "$AA" $AT Bash "$PROJ" "$PADCMD")"
t1=$(now_ms); PADMS=$((t1-t0))
chk "G-pad: denied in under 1000 ms (took ${PADMS} ms)" yes "$(yes_no x "[ $PADMS -lt 1000 ]")"
PAD2=$(head -c 3000 /dev/zero | tr '\0' ' ')
run "agent Bash command of 2049 bytes" block "$(mkin "$SA" "$AA" $AT Bash "$PROJ" "$(jq -nc --arg c "ls $PROJ$(head -c 2100 /dev/zero | tr '\0' '/')" '{command:$c}')")"
run "agent Bash 3000 bytes of padding after a valid command" block "$(mkin "$SA" "$AA" $AT Bash "$PROJ" "$(jq -nc --arg c "cat README.md$PAD2" '{command:$c}')")"
LONGOK=$(printf 'cat %s' "$PROJ/README.md")
run "agent Bash short valid command" allow "$(mkin "$SA" "$AA" $AT Bash "$PROJ" "$(jq -nc --arg c "$LONGOK" '{command:$c}')")"
BIG=$(head -c 70000 /dev/zero | tr '\0' 'a')
run "70 KB input, main Read: allowed (main never denies for size)" allow "$(mkin "$(nsid)" "" "" Read "$PROJ" "$(jq -nc --arg c "$BIG" '{file_path:"/x",pad:$c}')")"
run "70 KB input, main Bash: allowed" allow "$(mkin "$(nsid)" "" "" Bash "$PROJ" "$(jq -nc --arg c "$BIG" '{command:"ls",pad:$c}')")"
run "70 KB input, other subagent: allowed" allow "$(mkin "$(nsid)" o1 other Bash "$PROJ" "$(jq -nc --arg c "$BIG" '{command:"ls",pad:$c}')")"
run "70 KB input, bound agent Read: allowed (only Bash has the 2 KB limit)" allow "$(mkin "$SA" "$AA" $AT Read "$PROJ" "$(jq -nc --arg c "$BIG" --arg p "$PROJ/README.md" '{file_path:$p,pad:$c}')")"
run "70 KB input, non-map Agent spawn: allowed" allow "$(mkin "$(nsid)" "" "" Agent "$PROJ" "$(jq -nc --arg c "$BIG" '{subagent_type:"general-purpose",prompt:$c}')" tu-big)"
run "70 KB main Write: allowed" allow "$(mkin "$(nsid)" "" "" Write "$PROJ" "$(jq -nc --arg c "$BIG" '{file_path:"/tmp/x",content:$c}')")"
run "70 KB main Edit: allowed" allow "$(mkin "$(nsid)" "" "" Edit "$PROJ" "$(jq -nc --arg c "$BIG" '{file_path:"/tmp/x",old_string:"a",new_string:$c}')")"
run "70 KB main Bash: allowed" allow "$(mkin "$(nsid)" "" "" Bash "$PROJ" "$(jq -nc --arg c "echo $BIG" '{command:$c}')")"
python3 -c "import sys;sys.stdout.write('{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x\",\"pad\":\"' + 'a'*9000000 + '\"}}')" > "$TMP/huge.json"
chk "9 MB main input is allowed (main never denies for size)" allow "$(rcname "$("$BASH" "$GUARD" < "$TMP/huge.json" >/dev/null 2>&1; echo $?)")"
python3 -c "import sys;sys.stdout.write('{\"session_id\":\"$SA\",\"agent_id\":\"agentA1\",\"agent_type\":\"project-map:project-map\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$PROJ/README.md\",\"pad\":\"' + 'a'*9000000 + '\"}}')" > "$TMP/hugeagent.json"
chk "9 MB agent input fails closed" block "$(rcname "$("$BASH" "$GUARD" < "$TMP/hugeagent.json" >/dev/null 2>&1; echo $?)")"
python3 -c "import sys;sys.stdout.write('{\"session_id\":\"s1\",\"tool_name\":\"Agent\",\"tool_use_id\":\"t\",\"tool_input\":{\"subagent_type\":\"project-map:project-map\",\"prompt\":\"ROOT: /x\\\\nINV: inv-00000000\\\\nRUN: UPDATE\\\\n' + 'a'*9000000 + '\"}}')" > "$TMP/hugespawn.json"
chk "9 MB main spawn of a map agent is parsed, not size-denied (denied by a real rule: unregistered root)" block "$(rcname "$("$BASH" "$GUARD" < "$TMP/hugespawn.json" >/dev/null 2>&1; echo $?)")"
python3 -c "import sys;sys.stdout.write('{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x\",\"pad\":\"' + 'a'*3000000 + '\"}}')" > "$TMP/big3.json"
chk "3 MB main input is accepted" allow "$(rcname "$("$BASH" "$GUARD" < "$TMP/big3.json" >/dev/null 2>&1; echo $?)")"
# exactly at the limit: 64 KB of valid JSON is accepted
OKJ=$(jq -nc --arg c "$(head -c 60000 /dev/zero | tr '\0' 'a')" '{tool_name:"Read",tool_input:{file_path:"/x",pad:$c}}')
run "60 KB input, main Read" allow "$OKJ"
run "empty input (main): allowed" allow ""
run "not json (main): allowed" allow "this is not json"
run "truncated json (main): allowed" allow '{"tool_name":"Bash","tool_input":{"command":"ls'
run "json array (main): allowed" allow '[]'
run "json string (main): allowed" allow '"x"'
run "json null (main): allowed" allow 'null'
run "empty object (no tool, main): allowed" allow '{}'
run "tool_input not an object (main): allowed" allow '{"tool_name":"Bash","tool_input":"ls"}'
run "input with NUL escape in a string (main): allowed" allow '{"tool_name":"Bash","tool_input":{"command":"ls\u0000"}}'
run "unparsable input without identity: allowed" allow "garbage"
run "spawn-result mode unparsable input without identity: allowed" allow "garbage" --spawn-result ok
run "unparsable input naming an agent_id: fail closed" block '{"agent_id":"a1","tool_name":"Bash","tool_input":{"command":"ls'
run "unparsable input naming agent_type: fail closed" block '{"agent_type":"x","tool_name"'
run "unparsable Agent spawn of :project-map: fail closed" block '{"tool_name":"Agent","tool_input":{"subagent_type":"project-map:project-map","prompt":"ROOT: /x'
run "array naming :project-map: fail closed" block '["project-map:project-map"]'
run "agent input with tool_input not an object: fail closed" block '{"agent_id":"a1","agent_type":"project-map:project-map","tool_name":"Bash","tool_input":"ls"}'
run "other-mode input with tool_name missing: fail closed" block '{"agent_id":"a1","agent_type":"Explore"}'

# ================================================================= bind: registration (4.2a)
echo "== main-mode records: root binding (4.2a) =="
S=$(nsid); R1="$TMP/projects/reg1"; mkdir -p "$R1/.project-map"
M() { printf '%s' "$(mkin "$S" "" "" Bash "$PROJ" "$(jq -nc --arg c "$1" '{command:$c}')")"; }
run "facts ROOT in main: allowed" allow "$(M "python3 $PLG/project-map-facts.py $R1")"
chk "facts ROOT registers the root" yes "$(yes_no x "jq -r .root '$DATA/bind/$S/roots.jsonl' 2>/dev/null | grep -Fxq '$R1'")"
chk "roots.jsonl entry has an 'at' time" yes "$(yes_no x "jq -e '.at|length>5' '$DATA/bind/$S/roots.jsonl' >/dev/null 2>&1")"
run "facts ROOT --json in main: allowed" allow "$(M "python3 $PLG/project-map-facts.py $R1 --json")"
chk "second facts call appends (2 lines)" 2 "$(wc -l < "$DATA/bind/$S/roots.jsonl" | tr -d ' ')"
R2="$TMP/projects/reg2"; mkdir -p "$R2"; ln -s "$R2" "$TMP/projects/reg2-link"
run "facts via symlink root" allow "$(M "python3 $PLG/project-map-facts.py $TMP/projects/reg2-link")"
chk "symlink root is stored as realpath" yes "$(yes_no x "jq -r .root '$DATA/bind/$S/roots.jsonl' | grep -Fxq '$R2'")"
run "facts with --budget: allowed, no record" allow "$(M "python3 $PLG/project-map-facts.py --budget")"
run "facts --accept-answers: allowed, no record" allow "$(M "python3 $PLG/project-map-facts.py --accept-answers $R1")"
chk "still 3 roots" 3 "$(wc -l < "$DATA/bind/$S/roots.jsonl" | tr -d ' ')"
S2=$(nsid)
run "root outside allowed locations: allowed, no record" allow "$(mkin "$S2" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py /etc" '{command:$c}')")"
chk "no record for /etc" no "$(yes_no x "[ -e '$DATA/bind/$S2/roots.jsonl' ]")"
run "facts \$HOME/projects itself: allowed, no record" allow "$(mkin "$S2" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py $HOME/projects" '{command:$c}')")"
chk "no record for the projects directory itself" no "$(yes_no x "[ -e '$DATA/bind/$S2/roots.jsonl' ]")"
run "facts from another plugin dir: no record" allow "$(mkin "$S2" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PROJ/project-map-facts.py $R1" '{command:$c}')")"
run "a different command: no record" allow "$(mkin "$S2" "" "" Bash "$PROJ" "$(jq -nc --arg c "ls $R1" '{command:$c}')")"
chk "none of those registered anything" no "$(yes_no x "[ -e '$DATA/bind/$S2/roots.jsonl' ]")"
run "main facts without session_id: allowed, writes nothing" allow "$(jq -nc --arg c "python3 $PLG/project-map-facts.py $R1" '{tool_name:"Bash",tool_input:{command:$c}}')"
chk "no stray bind directory without session id" no "$(yes_no x "[ -d '$DATA/bind/' ] && ls '$DATA/bind' | grep -q '^$'")"
echo "== main-mode records: facts anywhere in the command =="
S5=$(nsid); RA="$TMP/projects/chain-a"; RB="$TMP/projects/chain-b"; mkdir -p "$RA" "$RB"
mc() { run "$2" "$1" "$(mkin "$3" "" "" Bash "$PROJ" "$(jq -nc --arg c "$4" '{command:$c}')")"; }
nroots() { if [ -f "$DATA/bind/$1/roots.jsonl" ]; then wc -l < "$DATA/bind/$1/roots.jsonl" | tr -d ' '; else echo 0; fi; }
mc allow "facts inside an && chain with a literal path" "$S5" "cd /tmp && python3 $PLG/project-map-facts.py $RA --json && echo done"
chk "chained literal path registered" yes "$(yes_no x "jq -r .root '$DATA/bind/$S5/roots.jsonl' | grep -Fxq '$RA'")"
S6=$(nsid)
mc allow "facts with a quoted shell variable" "$S6" "ROOT=$RA; python3 $PLG/project-map-facts.py \"\$ROOT\""
mc allow "facts with an unquoted shell variable" "$S6" "python3 $PLG/project-map-facts.py \$ROOT"
mc allow "facts with \$PWD" "$S6" "python3 $PLG/project-map-facts.py \$PWD"
chk "variable paths are not registered" 0 "$(nroots "$S6")"
S7=$(nsid)
mc allow "two literal roots in one command" "$S7" "python3 $PLG/project-map-facts.py $RA; python3 $PLG/project-map-facts.py $RB"
chk "both roots registered" 2 "$(nroots "$S7")"
chk "first of the two" yes "$(yes_no x "jq -r .root '$DATA/bind/$S7/roots.jsonl' | grep -Fxq '$RA'")"
chk "second of the two" yes "$(yes_no x "jq -r .root '$DATA/bind/$S7/roots.jsonl' | grep -Fxq '$RB'")"
S8=$(nsid)
mc allow "facts followed by a pipe" "$S8" "python3 $PLG/project-map-facts.py $RA | head -n 5"
chk "pipe-terminated path registered" 1 "$(nroots "$S8")"
mc allow "facts with a trailing extra word" "$S8" "python3 $PLG/project-map-facts.py $RB x"
chk "extra word does not stop registration" 2 "$(nroots "$S8")"
S9=$(nsid)
mc allow "close-session inside a chain" "$S9" "echo x && python3 $PLG/project-map-facts.py --close-session $RA"
chk "chained close-session closes" yes "$(yes_no x "[ -s '$DATA/bind/$S9/closed' ]")"
S10=$(nsid)
mc allow "close-session with a variable" "$S10" "python3 $PLG/project-map-facts.py --close-session \$ROOT"
chk "variable close-session does nothing" no "$(yes_no x "[ -e '$DATA/bind/$S10/closed' ]")"
mc allow "relative path is not registered" "$S10" "python3 $PLG/project-map-facts.py ./rel"
chk "nothing registered for relative path" 0 "$(nroots "$S10")"
echo "== main-mode records: close-session =="
S3=$(nsid)
run "close-session in main: allowed" allow "$(mkin "$S3" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py --close-session $R1" '{command:$c}')")"
chk "closed marker created" yes "$(yes_no x "[ -s '$DATA/bind/$S3/closed' ]")"
run "close-session is idempotent" allow "$(mkin "$S3" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py --close-session $R1" '{command:$c}')")"
S4=$(nsid)
run "close-session without ROOT: no record" allow "$(mkin "$S4" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py --close-session" '{command:$c}')")"
chk "no closed marker without ROOT" no "$(yes_no x "[ -e '$DATA/bind/$S4/closed' ]")"
run "close-session by an agent is not a main command" block "$(mkin "$SA" "$AA" $AT Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py --close-session $PROJ" '{command:$c}')")"

# ================================================================= bind: spawn (4.2b)
echo "== Agent spawn registration (4.2b, G-bind-*) =="
spawn() { # sid root inv run tuid [extra-json-for-tool_input]
  local p x="${6:-}"; [ -n "$x" ] || x='{}'
  p=$(printf 'ROOT: %s\nINV: %s\nRUN: %s\nMore text follows.' "$2" "$3" "$4")
  mkin "$1" "" "" Agent "$PROJ" "$(jq -nc --arg p "$p" --argjson x "$x" '{subagent_type:"project-map:project-map",prompt:$p} + $x')" "$5"
}
reg() { # sid root  -> register root through main facts call
  printf '%s' "$(mkin "$1" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py $2" '{command:$c}')")" | "$BASH" "$GUARD" >/dev/null 2>&1
}
newcase() { # sets SX RX IX with a registered root + invocation
  CNT=$((CNT+1)); SX=$(nsid); RX="$TMP/projects/p$CNT"; mkdir -p "$RX/.project-map"; IX=$(nid); mkinv "$RX" "$IX"; reg "$SX" "$RX"
}
newcase
run "spawn UPDATE accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1)"
chk "pending record created" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
chk "pending mode UPDATE" UPDATE "$(jq -r .mode "$DATA/bind/$SX/pending")"
chk "pending carries tool_use_id" tu-1 "$(jq -r .tool_use_id "$DATA/bind/$SX/pending")"
chk "pending carries root" "$RX" "$(jq -r .root "$DATA/bind/$SX/pending")"
chk "pending carries inv" "$IX" "$(jq -r .inv "$DATA/bind/$SX/pending")"
chk "no temp files left behind" 0 "$(ls -a "$DATA/bind/$SX" | grep -c '^\.pending\.')"
run "second concurrent spawn denied (one map agent at a time)" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-2)"
chk "pending untouched by the denied spawn" tu-1 "$(jq -r .tool_use_id "$DATA/bind/$SX/pending")"
newcase
run "spawn FULL accepted" allow "$(spawn "$SX" "$RX" "$IX" FULL tu-1)"
chk "pending mode FULL" FULL "$(jq -r .mode "$DATA/bind/$SX/pending")"
run "FULL mode carried into the active binding on claim" allow "$(mkin "$SX" agentX1 $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
chk "binding mode FULL" FULL "$(jq -r .mode "$DATA/bind/$SX/agentX1.json")"
chk "claimed marker written in STAGE" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/claimed' ]")"
chk "pending consumed by the claim" no "$(yes_no x "[ -e '$DATA/bind/$SX/pending' ]")"
run "FULL agent may write plan.out.json" allow "$(mkin "$SX" agentX1 $AT Write "$PROJ" "$(jq -nc --arg p "$RX/.project-map/$IX/plan.out.json" '{file_path:$p,content:"{}"}')")"
newcase
run "spawn of a non-map agent type: allowed, no record" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{"subagent_type":"general-purpose","prompt":"anything"}' tu-g)"
chk "no pending for other agent types" no "$(yes_no x "[ -e '$DATA/bind/$SX/pending' ]")"
run "spawn of a bare 'project-map' type: not governed" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{"subagent_type":"project-map","prompt":"x"}' tu-g)"
newcase
run "spawn with unregistered ROOT" block "$(spawn "$SX" "$TMP/projects/never" "$IX" UPDATE tu-1)"
mkdir -p "$TMP/projects/unreg/.project-map"; mkinv "$TMP/projects/unreg" "$IX"
run "spawn with ROOT not registered in this session" block "$(spawn "$SX" "$TMP/projects/unreg" "$IX" UPDATE tu-1)"
MSG=$(printf '%s' "$(spawn "$SX" "$TMP/projects/never" "$IX" UPDATE tu-1)" | "$BASH" "$GUARD" 2>&1 >/dev/null)
chk "unregistered-root deny message is the exact guidance" "project-map guard: spawn: ROOT was not registered in this session. Run the facts command by itself as one plain command with the literal absolute path: python3 $PLG/project-map-facts.py $TMP/projects/never  then spawn again" "$MSG"
run "spawn with missing invocation.json" block "$(spawn "$SX" "$RX" inv-deadbeef UPDATE tu-1)"
mkinv "$RX" inv-0badc0de; jq -c '.root="/somewhere/else"' "$RX/.project-map/inv-0badc0de/invocation.json" > "$TMP/inv.tmp" && mv "$TMP/inv.tmp" "$RX/.project-map/inv-0badc0de/invocation.json"
run "spawn with invocation.json root differing" block "$(spawn "$SX" "$RX" inv-0badc0de UPDATE tu-1)"
run "spawn with RUN missing" block "$(mkin "$SX" "" "" Agent "$PROJ" "$(jq -nc --arg p "ROOT: $RX
INV: $IX
hello" '{subagent_type:"project-map:project-map",prompt:$p}')" tu-1)"
run "spawn with RUN invalid" block "$(spawn "$SX" "$RX" "$IX" REBUILD tu-1)"
run "spawn with RUN lowercase" block "$(spawn "$SX" "$RX" "$IX" update tu-1)"
run "spawn with ROOT on line 2" block "$(mkin "$SX" "" "" Agent "$PROJ" "$(jq -nc --arg p "INV: $IX
ROOT: $RX
RUN: UPDATE" '{subagent_type:"project-map:project-map",prompt:$p}')" tu-1)"
run "spawn with space in ROOT" block "$(spawn "$SX" "$RX x" "$IX" UPDATE tu-1)"
run "spawn with bad INV id" block "$(spawn "$SX" "$RX" inv-XYZ UPDATE tu-1)"
run "spawn with INV traversal" block "$(spawn "$SX" "$RX" "inv-../../x" UPDATE tu-1)"
run "spawn with empty prompt" block "$(mkin "$SX" "" "" Agent "$PROJ" '{"subagent_type":"project-map:project-map","prompt":""}' tu-1)"
run "spawn without prompt" block "$(mkin "$SX" "" "" Agent "$PROJ" '{"subagent_type":"project-map:project-map"}' tu-1)"
chk "none of the denied spawns left a pending record" no "$(yes_no x "[ -e '$DATA/bind/$SX/pending' ]")"
run "spawn with a symlinked .project-map" block "$(spawn "$SX" "$EVIL" "$IX" UPDATE tu-1)"
echo "== G-spawn-bg =="
newcase
run "G-spawn-bg: run_in_background true" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1 '{"run_in_background":true}')"
run "G-spawn-bg: run_in_background \"true\"" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1 '{"run_in_background":"true"}')"
run "G-spawn-bg: resume field" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1 '{"resume":"agent-123"}')"
run "G-spawn-bg: continue field" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1 '{"continue":true}')"
run "G-spawn-bg: resumeFrom field" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1 '{"resumeFrom":"x"}')"
run "G-spawn-bg: Continue_agent field" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1 '{"Continue_agent":"x"}')"
run "G-spawn-bg: no RUN line" block "$(mkin "$SX" "" "" Agent "$PROJ" "$(jq -nc --arg p "ROOT: $RX
INV: $IX
" '{subagent_type:"project-map:project-map",prompt:$p}')" tu-1)"
chk "G-spawn-bg: nothing pending after the denials" no "$(yes_no x "[ -e '$DATA/bind/$SX/pending' ]")"
run "G-spawn-bg: run_in_background false is fine" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1 '{"run_in_background":false}')"
echo "== closed session =="
newcase
run "close the session" allow "$(mkin "$SX" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py --close-session $RX" '{command:$c}')")"
run "spawn after close-session denied" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1)"
echo "== G-bind-sessions =="
newcase; SY=$(nsid)
run "session X spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-1)"
run "session Y cannot spawn X's root (unregistered there)" block "$(spawn "$SY" "$RX" "$IX" UPDATE tu-2)"
run "session Y agent cannot claim X's pending" block "$(mkin "$SY" agentY1 $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
chk "X's pending is untouched by Y's agent" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
run "session Y closure does not close X" allow "$(mkin "$SY" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py --close-session $RX" '{command:$c}')")"
run "X's agent can still claim after Y closed" allow "$(mkin "$SX" agentX1 $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
chk "X agent bound to X's root" "$RX" "$(jq -r .root "$DATA/bind/$SX/agentX1.json")"
run "Y agent with X's agent_id has no binding" block "$(mkin "$SY" agentX1 $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
SZ=$(nsid)
run "a fresh session Z registers the root itself and then spawns" allow "$(reg "$SZ" "$RX"; spawn "$SZ" "$RX" "$IX" UPDATE tu-3)"
run "Y was closed: even after registering it cannot spawn" block "$(reg "$SY" "$RX"; spawn "$SY" "$RX" "$IX" UPDATE tu-4)"
echo "== G-bind-claim =="
newcase
pendj "$SX" "$RX" "$IX" UPDATE tu-1
run "unseen agent claims pending; first op on its root allowed" allow "$(mkin "$SX" agentC1 $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
chk "binding file written" yes "$(yes_no x "[ -f '$DATA/bind/$SX/agentC1.json' ]")"
chk "pending gone" no "$(yes_no x "[ -e '$DATA/bind/$SX/pending' ]")"
run "second unseen agent: no pending, denied" block "$(mkin "$SX" agentC2 $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
run "first agent continues" allow "$(mkin "$SX" agentC1 $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
newcase
pendj "$SX" "$RX" "$IX" UPDATE tu-1
run "G-bind-cross: first op targets another project (denied)" block "$(mkin "$SX" agentC1 $AT Read "$PROJ" "$(jq -nc --arg p "$PROJ/README.md" '{file_path:$p}')")"
chk "G-bind-cross: but the claim itself happened (bound to its spawn root)" "$RX" "$(jq -r .root "$DATA/bind/$SX/agentC1.json" 2>/dev/null)"
run "G-bind-cross: Bash facts on another ROOT denied" block "$(mkin "$SX" agentC1 $AT Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py $PROJ" '{command:$c}')")"
run "G-bind-cross: Write into another root's staging denied" block "$(mkin "$SX" agentC1 $AT Write "$PROJ" "$(jq -nc --arg p "$PROJ/.project-map/$INVA/judgement.out.json" '{file_path:$p,content:"{}"}')")"
run "G-bind-cross: Write .gitignore of another root denied" block "$(mkin "$SX" agentC1 $AT Write "$PROJ" "$(jq -nc --arg p "$PROJ/.gitignore" '{file_path:$p,content:"node_modules\n.project-map/\n"}')")"
run "G-bind-cross: its own staging is writable" allow "$(mkin "$SX" agentC1 $AT Write "$PROJ" "$(jq -nc --arg p "$RX/.project-map/$IX/judgement.out.json" '{file_path:$p,content:"{}"}')")"
newcase
run "G-bind-none: no pending, Read denied" block "$(mkin "$SX" agentN1 $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
run "G-bind-none: no pending, Bash denied" block "$(mkin "$SX" agentN1 $AT Bash "$PROJ" '{"command":"date"}')"
run "G-bind-none: no pending, Write denied" block "$(mkin "$SX" agentN1 $AT Write "$PROJ" "$(jq -nc --arg p "$RX/.project-map/$IX/judgement.out.json" '{file_path:$p,content:"{}"}')")"
run "G-bind-none: no pending, Edit denied" block "$(mkin "$SX" agentN1 $AT Edit "$PROJ" "$(jq -nc --arg p "$RX/.project-map/$IX/judgement.out.json" '{file_path:$p,old_string:"a",new_string:"b"}')")"
run "G-bind-none: no pending, Grep denied" block "$(mkin "$SX" agentN1 $AT Grep "$PROJ" '{"pattern":"x"}')"
chk "G-bind-none: denied agent left no binding" no "$(yes_no x "[ -e '$DATA/bind/$SX/agentN1.json' ]")"
echo "== G-bind-fail (spawn result, 4.2c) =="
newcase
run "spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-A)"
run "PostToolUseFailure with a NON-matching tool_use_id" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{"subagent_type":"project-map:project-map"}' tu-OTHER)" --spawn-result fail
chk "pending still there after a non-matching failure" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
run "PostToolUse (ok) with a non-matching id" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{"subagent_type":"project-map:project-map"}' tu-OTHER)" --spawn-result ok
chk "pending still there after a non-matching ok" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
run "second spawn still denied" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-B)"
run "PostToolUseFailure with the matching id" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{"subagent_type":"project-map:project-map"}' tu-A)" --spawn-result fail
chk "pending removed by the matching failure" no "$(yes_no x "[ -e '$DATA/bind/$SX/pending' ]")"
chk "released marker written" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"
run "retry spawn after the failure accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-C)"
chk "new pending has the new id" tu-C "$(jq -r .tool_use_id "$DATA/bind/$SX/pending")"
run "spawn-result for a tool other than Agent ignored" allow "$(mkin "$SX" "" "" Bash "$PROJ" '{"command":"ls"}' tu-C)" --spawn-result fail
chk "pending untouched by a Bash spawn-result" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
run "spawn-result with a bad mode argument ignored" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{}' tu-C)" --spawn-result bogus
chk "pending untouched by a bad mode" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
run "spawn-result without tool_use_id ignored" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{}')" --spawn-result fail
chk "pending untouched without tool_use_id" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
run "spawn-result from another session ignored" allow "$(mkin "$(nsid)" "" "" Agent "$PROJ" '{}' tu-C)" --spawn-result fail
chk "pending untouched by another session" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
run "spawn-result with an agent_id (a subagent's own Agent call) ignored" allow "$(mkin "$SX" agentZ $AT Agent "$PROJ" '{}' tu-C)" --spawn-result fail
chk "pending untouched by a subagent call" yes "$(yes_no x "[ -f '$DATA/bind/$SX/pending' ]")"
echo "== G-bind-terminal =="
newcase
SB1="$DATA/bind/$SX"
run "A spawned" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-A)"
run "A claims" allow "$(mkin "$SX" agentA $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
chk "binding keeps the tool_use_id" tu-A "$(jq -r .tool_use_id "$SB1/agentA.json")"
run "A completes (PostToolUse ok, matching id)" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{}' tu-A)" --spawn-result ok
chk "binding renamed to terminal" yes "$(yes_no x "[ -f '$SB1/agentA.done.json' ] && [ ! -e '$SB1/agentA.json' ]")"
chk "released marker written" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"
IXB=$(nid); mkinv "$RX" "$IXB"
run "B spawned (pending exists)" allow "$(spawn "$SX" "$RX" "$IXB" UPDATE tu-B)"
run "A calls again after completion: denied" block "$(mkin "$SX" agentA $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
run "A Bash after completion: denied" block "$(mkin "$SX" agentA $AT Bash "$PROJ" '{"command":"date"}')"
run "A Write after completion: denied" block "$(mkin "$SX" agentA $AT Write "$PROJ" "$(jq -nc --arg p "$RX/.project-map/$IX/judgement.out.json" '{file_path:$p,content:"{}"}')")"
chk "B's pending record unchanged" tu-B "$(jq -r .tool_use_id "$SB1/pending")"
run "B claims afterwards" allow "$(mkin "$SX" agentB $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
chk "B bound to its own invocation" "$IXB" "$(jq -r .inv "$SB1/agentB.json")"
run "a repeated spawn-result for A is harmless" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{}' tu-A)" --spawn-result fail
chk "A stays terminal" yes "$(yes_no x "[ -f '$SB1/agentA.done.json' ]")"
echo "== terminal on failure of a claimed agent =="
newcase
pendj "$SX" "$RX" "$IX" UPDATE tu-A
run "claim" allow "$(mkin "$SX" agentA $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
run "failure of the claimed spawn" allow "$(mkin "$SX" "" "" Agent "$PROJ" '{}' tu-A)" --spawn-result fail
chk "terminal after failure" yes "$(yes_no x "[ -f '$DATA/bind/$SX/agentA.done.json' ]")"
run "agent denied after failure" block "$(mkin "$SX" agentA $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
run "a new spawn is possible after the terminal binding" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-N)"
echo "== G-spawn-async =="
sub() { # sid aid atype mode(start|stop)  -> run the SubagentStart/Stop hook
  local j; j=$(jq -nc --arg s "$1" --arg a "$2" --arg t "$3" '{session_id:$s,agent_id:$a,agent_type:$t}')
  printf '%s' "$j" | "$BASH" "$GUARD" --subagent "$4" >/dev/null 2>&1; echo $?
}
asyncres() { # sid tuid agentId(or empty) [obj]  -> PostToolUse input for a background launch
  local resp
  if [ -n "$3" ]; then resp=$(jq -nc --arg a "$3" '{isAsync:true,status:"async_launched",agentId:$a,description:"x"}')
  else resp='{"isAsync":true,"status":"async_launched"}'; fi
  if [ "${4:-}" = obj ]; then
    jq -nc --argjson r "$resp" --arg s "$1" --arg u "$2" '{session_id:$s,tool_name:"Agent",cwd:"/",tool_input:{subagent_type:"project-map:project-map"},tool_use_id:$u,tool_response:$r}'
  else
    jq -nc --arg r "$resp" --arg s "$1" --arg u "$2" '{session_id:$s,tool_name:"Agent",cwd:"/",tool_input:{subagent_type:"project-map:project-map"},tool_use_id:$u,tool_response:$r}'
  fi
}
rdf() { mkin "$1" "$2" $AT Read "$PROJ" "$(jq -nc --arg p "$3" '{file_path:$p}')"; }   # sid aid path
snap() { (cd "$1" 2>/dev/null && find . -type f -exec cksum {} + 2>/dev/null | sort | cksum); }

newcase; SB2="$DATA/bind/$SX"; PK="$RX/.project-map/$IX/pack.json"
run "G-spawn-async 1: spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-bg1)"
chk "G-spawn-async 1: SubagentStart agBG exits 0" 0 "$(sub "$SX" agBG $AT start)"
chk "G-spawn-async 1: pending gains agent_id agBG" agBG "$(jq -r .agent_id "$SB2/pending")"
chk "G-spawn-async 1: pending keeps its tool_use_id" tu-bg1 "$(jq -r .tool_use_id "$SB2/pending")"
run "G-spawn-async 2: PostToolUse async (string response), matching id" allow "$(asyncres "$SX" tu-bg1 agBG)" --spawn-result ok
chk "G-spawn-async 2: pending still exists" yes "$(yes_no x "[ -f '$SB2/pending' ]")"
chk "G-spawn-async 2: no released marker" no "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"
chk "G-spawn-async 2: owner unchanged" agBG "$(jq -r .agent_id "$SB2/pending")"
run "G-spawn-async 3: PostToolUse async (object response), matching id" allow "$(asyncres "$SX" tu-bg1 agBG obj)" --spawn-result ok
chk "G-spawn-async 3: pending still exists" yes "$(yes_no x "[ -f '$SB2/pending' ]")"
chk "G-spawn-async 3: no released marker" no "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"
SNAP=$(snap "$SB2")
run "G-spawn-async 4: another :project-map agent's first Read is denied" block "$(rdf "$SX" agOther "$PK")"
MSG=$(rdf "$SX" agOther "$PK" | "$BASH" "$GUARD" 2>&1 >/dev/null)
chk "G-spawn-async 4: message says it belongs to another agent" yes "$(yes_no x "case '$MSG' in *'belongs to another agent'*) true;; *) false;; esac")"
chk "G-spawn-async 4: pending untouched" "$SNAP" "$(snap "$SB2")"
chk "G-spawn-async 4: no binding for the other agent" no "$(yes_no x "[ -e '$SB2/agOther.json' ]")"
run "G-spawn-async 5: agBG's first Read is allowed" allow "$(rdf "$SX" agBG "$PK")"
chk "G-spawn-async 5: agBG.json exists" yes "$(yes_no x "[ -f '$SB2/agBG.json' ]")"
chk "G-spawn-async 5: pending gone" no "$(yes_no x "[ -e '$SB2/pending' ]")"
chk "G-spawn-async 5: claimed marker exists" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/claimed' ]")"
chk "G-spawn-async 6: SubagentStop agBG exits 0" 0 "$(sub "$SX" agBG $AT stop)"
chk "G-spawn-async 6: agBG.done.json exists" yes "$(yes_no x "[ -f '$SB2/agBG.done.json' ]")"
chk "G-spawn-async 6: agBG.json gone" no "$(yes_no x "[ -e '$SB2/agBG.json' ]")"
chk "G-spawn-async 6: released marker exists" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"
run "G-spawn-async 6: a further Read by agBG is denied" block "$(rdf "$SX" agBG "$PK")"
MSG=$(rdf "$SX" agBG "$PK" | "$BASH" "$GUARD" 2>&1 >/dev/null)
chk "G-spawn-async 6: message says agent finished" yes "$(yes_no x "case '$MSG' in *'agent finished'*) true;; *) false;; esac")"

newcase; SB2="$DATA/bind/$SX"
run "G-spawn-async 7: spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-bg7)"
chk "G-spawn-async 7: SubagentStart agX" 0 "$(sub "$SX" agX $AT start)"
run "G-spawn-async 7: PostToolUse async agX" allow "$(asyncres "$SX" tu-bg7 agX)" --spawn-result ok
chk "G-spawn-async 7: pending kept until stop" yes "$(yes_no x "[ -f '$SB2/pending' ]")"
chk "G-spawn-async 7: SubagentStop agX (never claimed)" 0 "$(sub "$SX" agX $AT stop)"
chk "G-spawn-async 7: pending removed" no "$(yes_no x "[ -e '$SB2/pending' ]")"
chk "G-spawn-async 7: released marker written" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"
chk "G-spawn-async 7: stamped-but-unclaimed owner left agX.done.json" yes "$(yes_no x "[ -f '$SB2/agX.done.json' ]")"

newcase; SB2="$DATA/bind/$SX"
run "G-spawn-async 8: spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-bg8)"
chk "G-spawn-async 8: SubagentStart stamps agA" 0 "$(sub "$SX" agA $AT start)"
run "G-spawn-async 8: PostToolUse async names agB, a mismatch fails safe" allow "$(asyncres "$SX" tu-bg8 agB)" --spawn-result ok
chk "G-spawn-async 8: mismatch retires the pending record" no "$(yes_no x "[ -e '$SB2/pending' ]")"
chk "G-spawn-async 8: released marker written" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"

newcase; SB2="$DATA/bind/$SX"
run "G-spawn-async 9: spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-bg9)"
run "G-spawn-async 9: PostToolUse async without agentId" allow "$(asyncres "$SX" tu-bg9 "")" --spawn-result ok
chk "G-spawn-async 9: pending kept" yes "$(yes_no x "[ -f '$SB2/pending' ]")"
chk "G-spawn-async 9: pending still unstamped" "" "$(jq -r '.agent_id // empty' "$SB2/pending")"
chk "G-spawn-async 9: no released marker" no "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"
run "G-spawn-async 9: any :project-map agent may claim (3.2.0 behaviour)" allow "$(rdf "$SX" agAny "$RX/.project-map/$IX/pack.json")"
chk "G-spawn-async 9: binding written" yes "$(yes_no x "[ -f '$SB2/agAny.json' ]")"

newcase; SB2="$DATA/bind/$SX"
run "G-spawn-async 10: spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-bg10)"
SNAP=$(snap "$SB2")
chk "G-spawn-async 10: SubagentStart for a non-map agent exits 0" 0 "$(sub "$SX" agGP general-purpose start)"
chk "G-spawn-async 10: SubagentStop for a non-map agent exits 0" 0 "$(sub "$SX" agGP general-purpose stop)"
chk "G-spawn-async 10: nothing changed for the non-map agent" "$SNAP" "$(snap "$SB2")"
chk "G-spawn-async 10: SubagentStop with agent_id containing / exits 0" 0 "$(sub "$SX" "ag/../x" $AT stop)"
chk "G-spawn-async 10: SubagentStart with agent_id containing / exits 0" 0 "$(sub "$SX" "ag/../x" $AT start)"
chk "G-spawn-async 10: nothing changed for the malformed id" "$SNAP" "$(snap "$SB2")"
chk "G-spawn-async 10: --subagent bogus exits 0" 0 "$(sub "$SX" agBG $AT bogus)"
chk "G-spawn-async 10: nothing changed for bogus" "$SNAP" "$(snap "$SB2")"

newcase; SB2="$DATA/bind/$SX"
run "G-spawn-async 11: spawn 1 accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-s1)"
run "G-spawn-async 11: spawn 2 denied (one map agent at a time)" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-s2)"
touch -t 202601010000 "$SB2/pending"
run "G-spawn-async 11: spawn 3 accepted once the pending is stale" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-s3)"
chk "G-spawn-async 11: pending carries spawn 3's tool_use_id" tu-s3 "$(jq -r .tool_use_id "$SB2/pending")"
chk "G-spawn-async 11: released marker written for the retired one" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"

newcase; SB2="$DATA/bind/$SX"
run "G-spawn-async 12: foreground spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-fg)"
run "G-spawn-async 12: PostToolUse with plain text response" allow "$(jq -nc --arg s "$SX" '{session_id:$s,tool_name:"Agent",cwd:"/",tool_input:{},tool_use_id:"tu-fg",tool_response:"DONE gen 1"}')" --spawn-result ok
chk "G-spawn-async 12: pending removed" no "$(yes_no x "[ -e '$SB2/pending' ]")"
chk "G-spawn-async 12: released marker written" yes "$(yes_no x "[ -e '$RX/.project-map/$IX/released' ]")"

newcase; SB2="$DATA/bind/$SX"
run "G-spawn-async 13: spawn accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-big)"
chk "G-spawn-async 13: SubagentStart stamps agBig" 0 "$(sub "$SX" agBig $AT start)"
SNAP=$(snap "$SB2")
head -c 9000000 /dev/zero | tr '\0' a > "$TMP/pad.txt"
jq -nc --arg s "$SX" --rawfile p "$TMP/pad.txt" '{session_id:$s,agent_id:"agBig",agent_type:"project-map:project-map",pad:$p}' > "$TMP/big.json"
"$BASH" "$GUARD" --subagent stop < "$TMP/big.json" >/dev/null 2>&1; RCBIG=$?
chk "G-spawn-async 13: SubagentStop over 8 MB fails closed" block "$(rcname $RCBIG)"
chk "G-spawn-async 13: nothing changed" "$SNAP" "$(snap "$SB2")"
rm -f "$TMP/pad.txt" "$TMP/big.json"

newcase; SB2="$DATA/bind/$SX"; PK="$RX/.project-map/$IX/pack.json"
run "G-spawn-async 14: spawn A accepted" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-A)"
chk "G-spawn-async 14: SubagentStart agA stamps pending" 0 "$(sub "$SX" agA $AT start)"
chk "G-spawn-async 14: pending stamped agA" agA "$(jq -r .agent_id "$SB2/pending")"
touch -t 202601010000 "$SB2/pending"
run "G-spawn-async 14: spawn B accepted over the expired stamped pending" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-B)"
chk "G-spawn-async 14: agA.done.json exists (expired owner is terminal)" yes "$(yes_no x "[ -f '$SB2/agA.done.json' ]")"
chk "G-spawn-async 14: pending carries tu-B" tu-B "$(jq -r .tool_use_id "$SB2/pending")"
chk "G-spawn-async 14: pending has no agent_id" "" "$(jq -r '.agent_id // empty' "$SB2/pending")"
run "G-spawn-async 14: agA's first Read is denied" block "$(rdf "$SX" agA "$PK")"
MSG=$(rdf "$SX" agA "$PK" | "$BASH" "$GUARD" 2>&1 >/dev/null)
chk "G-spawn-async 14: message says agent finished, not another agent" yes "$(yes_no x "case '$MSG' in *'agent finished'*) true;; *) false;; esac")"
chk "G-spawn-async 14: SubagentStart agA again exits 0" 0 "$(sub "$SX" agA $AT start)"
chk "G-spawn-async 14: pending still unstamped (terminal agent gets no job)" "" "$(jq -r '.agent_id // empty' "$SB2/pending")"
chk "G-spawn-async 14: SubagentStart agB" 0 "$(sub "$SX" agB $AT start)"
chk "G-spawn-async 14: pending stamped agB" agB "$(jq -r .agent_id "$SB2/pending")"
run "G-spawn-async 14: agB's first Read allowed" allow "$(rdf "$SX" agB "$PK")"
chk "G-spawn-async 14: agB.json exists" yes "$(yes_no x "[ -f '$SB2/agB.json' ]")"

echo "== G-bind-close (uncertain termination) =="
newcase
run "A spawned, leaving PENDING" allow "$(spawn "$SX" "$RX" "$IX" UPDATE tu-A)"
run "main closes the session" allow "$(mkin "$SX" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py --close-session $RX" '{command:$c}')")"
run "main tries to spawn B: denied" block "$(spawn "$SX" "$RX" "$IX" UPDATE tu-B)"
run "A's delayed first touch: denied" block "$(mkin "$SX" agentA $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
chk "no binding was created" no "$(yes_no x "[ -e '$DATA/bind/$SX/agentA.json' ]")"
newcase
bindj "$SX" agentK "$RX" "$IX" UPDATE tu-K
run "already-claimed agent keeps working after close-session" allow "$(printf '%s' "$(mkin "$SX" "" "" Bash "$PROJ" "$(jq -nc --arg c "python3 $PLG/project-map-facts.py --close-session $RX" '{command:$c}')")" | "$BASH" "$GUARD" >/dev/null 2>&1; mkin "$SX" agentK $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')")"
echo "== G-bind-oversized =="
newcase
pendj "$SX" "$RX" "$IX" UPDATE tu-A
IXB=$(nid); mkinv "$RX" "$IXB"
PADP=$(head -c 70000 /dev/zero | tr '\0' 'x')
OV="$(mkin "$SX" "" "" Agent "$PROJ" "$(jq -nc --arg p "ROOT: $RX
INV: $IXB
RUN: UPDATE
$PADP" '{subagent_type:"project-map:project-map",prompt:$p}')" tu-B)"
run "G-bind-oversized: A pending, 70 KB padded spawn of B denied" block "$OV"
OVMSG=$(printf '%s' "$OV" | "$BASH" "$GUARD" 2>&1 >/dev/null)
chk "G-bind-oversized: the deny reason is the one-at-a-time rule, not size" yes "$(yes_no x "case \"\$OVMSG\" in *'one map agent at a time'*) true;; *) false;; esac")"
chk "G-bind-oversized: and it does not mention size" no "$(yes_no x "case \"\$OVMSG\" in *large*|*size*) true;; *) false;; esac")"
OV2="$(mkin "$SX" "" "" Agent "$PROJ" "$(jq -nc --arg p "ROOT: $RX
INV: $IXB
$PADP" '{subagent_type:"project-map:project-map",prompt:$p}')" tu-B)"
OVMSG2=$(printf '%s' "$OV2" | "$BASH" "$GUARD" 2>&1 >/dev/null)
chk "G-bind-oversized: padded spawn with the RUN header missing is denied for RUN" yes "$(yes_no x "case \"\$OVMSG2\" in *RUN*) true;; *) false;; esac")"
chk "G-bind-oversized: A's pending record intact" tu-A "$(jq -r .tool_use_id "$DATA/bind/$SX/pending")"
newcase
run "G-bind-oversized: a 70 KB padded spawn registers normally" allow "$(mkin "$SX" "" "" Agent "$PROJ" "$(jq -nc --arg p "ROOT: $RX
INV: $IX
RUN: FULL
$PADP" '{subagent_type:"project-map:project-map",prompt:$p}')" tu-B)"
chk "G-bind-oversized: pending written with the right fields" "$IX FULL tu-B" "$(jq -r '[.inv,.mode,.tool_use_id]|join(" ")' "$DATA/bind/$SX/pending")"
echo "== concurrent claims =="
newcase
pendj "$SX" "$RX" "$IX" UPDATE tu-A
JIN() { mkin "$SX" "$1" $AT Read "$PROJ" "$(jq -nc --arg p "$RX/README.md" '{file_path:$p}')"; }
for n in 1 2 3 4 5 6; do ( printf '%s' "$(JIN agentP$n)" | "$BASH" "$GUARD" >/dev/null 2>&1; echo $? > "$TMP/par.$n" ) & done; wait
OKS=$(cat "$TMP"/par.[1-6] | grep -c '^0$'); chk "six agents race for one pending: exactly one wins" 1 "$OKS"
chk "exactly one binding file" 1 "$(ls "$DATA/bind/$SX" | grep -c '^agentP')"
newcase
for n in 1 2 3 4 5 6; do ( printf '%s' "$(spawn "$SX" "$RX" "$IX" UPDATE tu-$n)" | "$BASH" "$GUARD" >/dev/null 2>&1; echo $? > "$TMP/spar.$n" ) & done; wait
OKS=$(cat "$TMP"/spar.[1-6] | grep -c '^0$'); chk "six concurrent spawns: exactly one accepted" 1 "$OKS"

# ================================================================= misc contract lines
echo "== misc =="
run "other subagent never writes records" allow "$(mkin "$(nsid)" o9 other Agent "$PROJ" "$(jq -nc --arg p "ROOT: $PROJ
INV: $INVA
RUN: UPDATE" '{subagent_type:"project-map:project-map",prompt:$p}')" tu-o)"
PM_GUARD_TRACE="$TMP/trace.log" run "trace mode allows normally" allow "$(mkin "$SA" "$AA" $AT Read "$PROJ" "$(jq -nc --arg p "$PROJ/README.md" '{file_path:$p}')")"
chk "trace keeps the full input" yes "$(yes_no x "grep -q agentA1 '$TMP/trace.log'")"
: > "$PM_GUARD_LOG"
bash_t block 'cat ~/.ssh/id_ed25519'
chk "deny is logged with the reason" yes "$(yes_no x "grep -q 'metacharacter' '$PM_GUARD_LOG'")"
chk "log line has 5 tab-separated fields" 5 "$(head -n 1 "$PM_GUARD_LOG" | awk -F'\t' '{print NF}')"
chk "log carries the mode" agent "$(head -n 1 "$PM_GUARD_LOG" | cut -f2)"
chk "log carries the tool" Bash "$(head -n 1 "$PM_GUARD_LOG" | cut -f3)"
chk "log operand cut at 200 chars" yes "$(yes_no x "[ $(head -n 1 "$PM_GUARD_LOG" | cut -f5 | wc -c) -le 202 ]")"
OUTMSG=$(printf '%s' "$(mkin "$SA" "$AA" $AT Bash "$PROJ" '{"command":"rm x"}')" | "$BASH" "$GUARD" 2>&1 >/dev/null)
chk "deny prints the reason on stderr" yes "$(yes_no x "[ -n \"$OUTMSG\" ]")"
OUTOK=$(printf '%s' "$(mkin "$SA" "$AA" $AT Bash "$PROJ" '{"command":"date"}')" | "$BASH" "$GUARD" 2>&1)
chk "allow prints nothing" "" "$OUTOK"
chk "guard file is bash-3.2 syntax clean" yes "$(yes_no x "/bin/bash -n '$GUARD'")"
chk "no declare -A / mapfile / \${var,,} in guard" no "$(yes_no x "grep -Eq 'declare -A|mapfile|readarray|\\$\\{[A-Za-z_]+(,,|\\^\\^)' '$GUARD'")"

# ================================================================= hardening round
echo "== metacharacters = and # (agent), spawn tool_use_id, trailing \$, secret names =="
bash_t block 'ls =ls'
bash_t block 'cat =ls'
bash_t block 'cat README.md #comment'
bash_t block 'cat README.md # x'
bash_t block 'date +%F=x'
bash_t block 'find . -name=x'
bash_t block 'gh issue list --state=open'
bash_t block 'stat -f %z=x README.md'
fbash_t block "$CHD #"
fbash_t block "$CHD =x"
newcase
run "spawn without tool_use_id denied" block "$(spawn "$SX" "$RX" "$IX" UPDATE "")"
chk "no pending without tool_use_id" no "$(yes_no x "[ -e '$DATA/bind/$SX/pending' ]")"
S11=$(nsid)
mc allow "path followed by a variable continuation" "$S11" "python3 $PLG/project-map-facts.py $RA\$X"
mc allow "path then slash then variable" "$S11" "python3 $PLG/project-map-facts.py $RA/\$X"
chk "variable continuation is not registered" 0 "$(nroots "$S11")"
mc allow "close-session path with variable continuation" "$S11" "python3 $PLG/project-map-facts.py --close-session $RA\$X"
chk "close with continuation does nothing" no "$(yes_no x "[ -e '$DATA/bind/$S11/closed' ]")"
mc allow "plain literal after those still registers" "$S11" "python3 $PLG/project-map-facts.py $RA"
chk "registered once" 1 "$(nroots "$S11")"
for f in secrets/x.txt credentials/x.txt .kube/config .docker/config.json .gnupg/x .envrc app.env prod.ENV terraform.tfstate x.tfstate .pgpass service-account.json service-account-prod.json Service-Account-X.json key.pfx; do
  mkdir -p "$PROJ/$(dirname "$f")"; printf 'z\n' > "$PROJ/$f" 2>/dev/null
  read_t block "$PROJ/$f"
  bash_t block "cat $PROJ/$f"
done
read_t allow "$PROJ/README.md"
read_t allow "$PROJ/notes/envelope.md"

echo "== plugin data and key are unreadable for agents =="
read_t block "$DATA/bind/$SA/agentA1.json"
read_t block "$DATA/bind/.lock"
read_t block "$DATA/anything"
bash_t block "cat $DATA/bind/$SA/agentA1.json"
bash_t block "ls $DATA/bind"
bash_t block "find $DATA -type f"
bash_t block "wc -c $DATA/bind/.lock"
printf 'sekrit\n' > "$MEM/key"; printf 'n\n' > "$MEM/key-notes.md"
read_t block "$MEM/key"
bash_t block "cat $MEM/key"
bash_t block "head -n 1 $MEM/key"
read_t allow "$MEM/key-notes.md"
read_t allow "$MEM/feedback_x.md"
write_t block "$MEM/key" 'x'
echo "== pm-git on nested repos from the snapshot =="
mkdir -p "$PROJ/nested-lib" "$PROJ/other-nested"
jq -nc --arg l "$LEDGER" '{ledger:{path:$l},repos:[{path:"."},{path:"nested-lib"}]}' > "$STA/snapshot.json"
bash_t allow "bash $PLG/pm-git.sh $PROJ/nested-lib log -n 20"
bash_t allow "bash $PLG/pm-git.sh $PROJ/nested-lib status"
bash_t allow "bash $PLG/pm-git.sh $PROJ status"
bash_t block "bash $PLG/pm-git.sh $PROJ/other-nested log"
bash_t block "bash $PLG/pm-git.sh $PROJ/nested-lib/sub log"
bash_t block "bash $PLG/pm-git.sh $PROJ/nested-lib/../other-nested log"
bash_t block "bash $PLG/pm-git.sh $PROJ/sub/../nested-lib log"
bash_t allow "bash $PLG/pm-git.sh $PROJ/. log"   # realpath equals the bound root
bash_t block "python3 $PLG/project-map-facts.py $PROJ/nested-lib"
bash_t block "bash $PLG/project-map-embed.sh $PROJ/nested-lib $INVA"
rm -rf "$PROJ/nested-lib"; ln -s "$OUT" "$PROJ/nested-lib"
bash_t block "bash $PLG/pm-git.sh $PROJ/nested-lib log"
rm -f "$PROJ/nested-lib"; ln -s "$PROJ/sub" "$PROJ/nested-lib"
bash_t allow "bash $PLG/pm-git.sh $PROJ/nested-lib log"
rm -f "$PROJ/nested-lib"
jq -nc --arg l "$LEDGER" '{ledger:{path:$l},repos:[{path:"."},{path:"../escape"},{path:"/etc"},{path:"a/../b"}]}' > "$STA/snapshot.json"
mkdir -p "$TMP/escape"
bash_t block "bash $PLG/pm-git.sh $PROJ/../escape log"
bash_t block "bash $PLG/pm-git.sh /etc log"
bash_t block "bash $PLG/pm-git.sh $PROJ/a/../b log"
jq -nc --arg l "$LEDGER" '{ledger:{path:$l}}' > "$STA/snapshot.json"
bash_t block "bash $PLG/pm-git.sh $PROJ/nested-lib log"

# ================================================================= timing
echo "== timing =="
timeit() { local a b; a=$(now_ms); printf '%s' "$1" | "$BASH" "$GUARD" >/dev/null 2>&1; b=$(now_ms); echo $((b-a)); }
T_MAIN=$(timeit "$(mkin "$(nsid)" "" "" Read "$PROJ" '{"file_path":"/x"}')")
T_BASH=$(timeit "$(mkin "$SA" "$AA" $AT Bash "$PROJ" '{"command":"cat README.md | head -n 5"}')")
T_READ=$(timeit "$(mkin "$SA" "$AA" $AT Read "$PROJ" "$(jq -nc --arg p "$PROJ/README.md" '{file_path:$p}')")")
echo "  main Read ${T_MAIN} ms, agent Bash ${T_BASH} ms, agent Read ${T_READ} ms, G-pad ${PADMS} ms"
chk "main Read under 150 ms" yes "$(yes_no x "[ $T_MAIN -lt 150 ]")"
chk "agent Bash with pipe under 300 ms" yes "$(yes_no x "[ $T_BASH -lt 300 ]")"
chk "agent Read under 300 ms" yes "$(yes_no x "[ $T_READ -lt 300 ]")"

echo
echo "guard: $GUARD   shell: $BASH ${BASH_VERSION}"
echo "total $((pass+fail)) pass $pass fail $fail"
rm -rf "$TB/.." 2>/dev/null
[ $fail -eq 0 ]
