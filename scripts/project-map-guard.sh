#!/bin/bash
# project-map-guard.sh (3.2) - PreToolUse hook (+ `--spawn-result ok|fail` for PostToolUse / PostToolUseFailure,
# `--subagent start|stop` for SubagentStart / SubagentStop: background launches are claimed later by the agent).
# Contract: docs/INTERFACES-3.2.md sections 3, 4. Exit 0 = allow (silent), exit 2 = deny (reason on stderr).
# Fails CLOSED on oversized or unparsable input. Bash 3.2 compatible. Linear in input size: one bounded
# stdin read, one jq pass, case/parameter expansion/grep only (no per-character loops).
#
# Modes: no agent_id = main (allowed; records only for the trusted commands and Agent-spawn registration);
#        agent_type ending ":project-map" = agent (bound to ONE invocation, strict grammar);
#        any other subagent = other (exit 0, never trusted).
export LC_ALL=C
umask 077

HOOKS_DIR=$(cd "$(dirname "$0")" && pwd -P)
PLUGIN="${CLAUDE_PLUGIN_ROOT:-$(dirname "$HOOKS_DIR")}"
DATA="${CLAUDE_PLUGIN_DATA:-}"
MEM_DIR="$HOME/.claude/agent-memory/project-map"
LOG="${PM_GUARD_LOG:-$MEM_DIR/guard.log}"
SELF="$HOOKS_DIR/$(basename "$0")"
SPAWN_RESULT=""; SUBAGENT=""
[ "${1:-}" = "--spawn-result" ] && SPAWN_RESULT="${2:-}"
[ "${1:-}" = "--subagent" ] && SUBAGENT="${2:-}"

MODE="-"; TOOL="-"; SUMMARY=""

deny() {
  echo "project-map guard: $1" >&2
  { mkdir -p "$(dirname "$LOG")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$MODE" "$TOOL" "$1" "$(printf %s "$SUMMARY" | head -c 200 | tr '\n\t' '  ')" >> "$LOG"; } 2>/dev/null
  exit 2
}
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ------------------------------------------------------------ envelope (section 3)
# The input is spooled to a temp file and parsed by jq from there (linear, no size cap in main mode).
# Agent mode fails closed above 8 MB. Unparsable input: exit 0 unless it carries agent identity or names a
# ":project-map" agent (then fail closed).
if [ -n "${PM_LOCKED:-}" ] && [ -n "${PM_IN_FILE:-}" ] && [ -f "$PM_IN_FILE" ]; then
  INF="$PM_IN_FILE"
else
  INF=$(mktemp "${TMPDIR:-/tmp}/pmguard.XXXXXX") || deny "cannot spool the hook input"
  cat > "$INF"
fi
unset PM_IN_FILE
trap 'rm -f "$INF"' EXIT
if [ -n "${PM_GUARD_TRACE:-}" ]; then { cat "$INF"; echo; } >> "$PM_GUARD_TRACE" 2>/dev/null; fi
unparsable() {
  if grep -Eq 'agent_id|agent_type|:project-map' "$INF" 2>/dev/null; then deny "hook input too large or unreadable"; fi
  exit 0
}
command -v jq >/dev/null 2>&1 || unparsable

# one jq pass; every value comes back @sh-quoted, so eval only ever sees assignments
EV=$(jq -r '
  def s: if type=="string" then . elif .==null then "" else tojson end;
  if type!="object" then error("not an object") else . end
  | if ([.. | strings | select(contains("\u0000"))] | length) > 0 then error("nul") else . end
  | (.agent_type|s|endswith(":project-map")) as $ag
  | (.tool_input // {}) as $t
  | if ($t|type)!="object" then error("tool_input") else . end
  | ($t.command|s) as $cmd
  | (($t.prompt // "" | s)[0:4096] | split("\n")) as $pl
  | [ "AIDK=\(if has("agent_id") then (if (.agent_id|type)=="string" and (.agent_id|length)>0 then "ok" else "bad" end) else "absent" end|@sh)",
      "SID=\(.session_id|s|@sh)", "AID=\(.agent_id|s|@sh)", "ATYPE=\(.agent_type|s|@sh)",
      "TOOL=\(.tool_name|s|@sh)", "CWD=\(.cwd|s|@sh)", "TUID=\(.tool_use_id|s|@sh)",
      "CMD=\(if $ag or ($cmd|contains("project-map-facts.py")) then $cmd else "" end|@sh)",
      "FP=\(if $ag then $t.file_path|s else "" end|@sh)", "CONTENT=\(if $ag then $t.content|s else "" end|@sh)",
      "OLDS=\(if $ag then $t.old_string|s else "" end|@sh)", "NEWS=\(if $ag then $t.new_string|s else "" end|@sh)", "RALL=\($t.replace_all // false|s|@sh)",
      "SUBT=\($t.subagent_type|s|@sh)", "RBG=\($t.run_in_background // false|s|@sh)",
      "RESUMEN=\([$t|keys[]|select(test("resume|continue";"i"))]|length|tostring|@sh)",
      "TRSTAT=\((.tool_response // {}) | (if type=="string" then (try fromjson catch {}) else . end) | (if type=="object" then (.status|s) else "" end)|@sh)",
      "TRAID=\((.tool_response // {}) | (if type=="string" then (try fromjson catch {}) else . end) | (if type=="object" then (.agentId|s) else "" end)|@sh)",
      "PL1=\($pl[0] // ""|@sh)", "PL2=\($pl[1] // ""|@sh)", "PL3=\($pl[2] // ""|@sh)" ] | join("\n")' < "$INF" 2>/dev/null) \
  || unparsable
[ -n "$EV" ] || unparsable
eval "$EV"
[ -n "$TOOL" ] || [ -n "$SUBAGENT" ] || unparsable
case "$TRAID" in *[!A-Za-z0-9_-]*) TRAID="";; esac

[ "$AIDK" != bad ] || deny "malformed agent identity"
if [ "$AIDK" = absent ]; then
  case "$ATYPE" in *:project-map) deny "agent identity missing";; esac
  MODE=main
else case "$ATYPE" in *:project-map) MODE=agent;; *) MODE=other;; esac; fi
SUMMARY="${CMD:-$FP}"
if [ "$MODE" = agent ]; then
  [ "$(wc -c < "$INF")" -le 8388608 ] || deny "hook input too large or unreadable"
fi

SIDOK=""; case "$SID" in ''|*[!A-Za-z0-9_-]*) ;; *) SIDOK=1;; esac
AIDOK=""; case "$AID" in ''|*[!A-Za-z0-9_-]*) ;; *) AIDOK=1;; esac
SB=""; [ -n "$SIDOK" ] && [ -n "$DATA" ] && SB="$DATA/bind/$SID"

[ "$MODE" != other ] || exit 0

# agent mode: an over-long Bash command is denied before anything else (section 3)
if [ "$MODE" = agent ] && [ "$TOOL" = Bash ] && [ ${#CMD} -gt 2048 ]; then deny "command longer than 2048 bytes"; fi

# ------------------------------------------------------------ helpers
# Take DATA/bind/.lock (fcntl.flock, 2 s) and restart this script holding it. No-op once locked.
need_lock() {
  [ -z "${PM_LOCKED:-}" ] || return 0
  [ -n "$DATA" ] || deny "no plugin data directory"
  mkdir -p "$DATA/bind" 2>/dev/null || deny "cannot create bind directory"
  PM_LOCKED=1 PM_IN_FILE="$INF" exec python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
end = time.time() + 2.0
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); break
    except OSError:
        if time.time() > end:
            sys.stderr.write("project-map guard: binding lock busy\n")
            try: os.unlink(os.environ.get("PM_IN_FILE", ""))
            except OSError: pass
            sys.exit(2)
        time.sleep(0.01)
os.set_inheritable(fd, True)
os.execv(sys.argv[2], sys.argv[2:])
' "$DATA/bind/.lock" "$BASH" "$SELF" "$@"
  deny "cannot take the binding lock"
}

# RP = canonical path (symlinks resolved; absent tail kept; '..' only allowed in the existing part)
rp() {
  local p="$1" rest cur base d t n=0
  case "$p" in /*) ;; *) return 1;; esac
  while :; do
    n=$((n+1)); [ $n -le 60 ] || return 1
    while :; do case "$p" in *//*) p=${p//\/\//\/};; *) break;; esac; done
    [ "$p" = / ] || p=${p%/}
    [ -n "$p" ] || p=/
    cur=$p; rest=""
    while [ ! -e "$cur" ] && [ ! -L "$cur" ]; do
      base=${cur##*/}
      case "$base" in ''|.|..) return 1;; esac
      rest="/$base$rest"; cur=${cur%/*}; [ -n "$cur" ] || cur=/
    done
    if [ -L "$cur" ]; then
      t=$(readlink "$cur") || return 1
      case "$t" in
        /*) p="$t$rest";;
        *) d=${cur%/*}; p="$d/$t$rest";;
      esac
      continue
    fi
    if [ -d "$cur" ]; then
      d=$(cd -P "$cur" 2>/dev/null && pwd -P) || return 1
      [ "$d" = / ] && d=""
      RP="$d$rest"
    else
      d=${cur%/*}; [ -n "$d" ] || d=/
      d=$(cd -P "$d" 2>/dev/null && pwd -P) || return 1
      [ "$d" = / ] && d=""
      RP="$d/${cur##*/}$rest"
    fi
    [ -n "$RP" ] || RP=/
    return 0
  done
}

root_ok() { # a resolved path: any folder inside $HOME except $HOME itself, hidden top-level folders and ~/Library
  case "$1" in /private/tmp/claude-*/*/scratchpad/?*) return 0;; esac
  local h="" lp="" lh=""
  case "$HOME" in /?*) h=$(cd -P "$HOME" 2>/dev/null && pwd -P) || h="";; esac
  case "$h" in /?*) ;; *) h="";; esac
  if [ -n "$h" ]; then
    case "$1" in "$h"/?*)
      # exclusions compared case-insensitively: macOS volumes accept ~/library for ~/Library
      lp=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
      lh=$(printf '%s' "$h" | LC_ALL=C tr '[:upper:]' '[:lower:]')
      case "$lp" in "$lh"/.*|"$lh"/library|"$lh"/library/*) ;; *) return 0;; esac;;
    esac
  fi
  [ -n "${TMPDIR:-}" ] && case "$1" in "${TMPDIR%/}"/claude-*/?*) return 0;; esac
  return 1
}

SECRE='(^|/)\.env([.][^/]*)?(/|$)|\.env$|(^|/)\.envrc$|(^|/)(secrets|credentials|\.kube|\.docker|\.ssh|\.aws|\.gnupg|\.git)(/|$)|\.tfstate$|(^|/)\.pgpass$|(^|/)service-account[^/]*\.json$|(^|/)\.config/gh(/|$)|[^/]*(credential|secret|token|password)[^/]*$|\.(pem|key|p12|pfx)$|(^|/)id_(rsa|ed25519)[^/]*$|_history$|(^|/)\.(netrc|npmrc|pypirc|claude\.json)$|(^|/)settings[^/]*\.json$|(^|/)ssh_host_[^/]*$|(^|/)known_hosts$'
secret_path() { printf '%s\n' "$@" | grep -Eiq "$SECRE"; }

nlink() {
  if [ "$(uname)" = Darwin ]; then stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}

# ------------------------------------------------------------ main mode
release_marker() { # root inv : tell embed/facts the invocation is free
  case "$2" in inv-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) return 0;; esac
  case "$1" in /*) : > "$1/.project-map/$2/released" 2>/dev/null;; esac
  return 0
}
retire_file() { # file : pending -> removed, <agent>.json -> terminal; marker written
  local r i o
  r=$(jq -r '.root // empty' "$1" 2>/dev/null); i=$(jq -r '.inv // empty' "$1" 2>/dev/null)
  case "$1" in
    "$SB/pending")
      # a stamped owner that never claimed becomes terminal too, so a late first call cannot take a newer job
      o=$(jq -r '.agent_id // empty' "$1" 2>/dev/null)
      case "$o" in ''|*[!A-Za-z0-9_-]*) ;; *) [ -e "$SB/$o.json" ] || [ -e "$SB/$o.done.json" ] || cp "$1" "$SB/$o.done.json" 2>/dev/null;; esac
      rm -f "$1" ;;
    *.json) mv "$1" "${1%.json}.done.json" 2>/dev/null ;;
  esac
  release_marker "$r" "$i"
}
stamp_pending() { # agent id : only this agent may claim the pending invocation (background launch)
  local t="$SB/.stamp.$$"
  if jq -c --arg a "$1" '. + {agent_id:$a}' "$SB/pending" > "$t" 2>/dev/null; then mv -f "$t" "$SB/pending" 2>/dev/null; fi
  rm -f "$t"
}
pending_owner() { jq -r '.agent_id // empty' "$SB/pending" 2>/dev/null; }

spawn_result() {
  [ -n "$SB" ] && [ -n "$TUID" ] && [ "$TOOL" = Agent ] && [ -z "$AID" ] || exit 0
  case "$SPAWN_RESULT" in ok|fail) ;; *) exit 0;; esac
  [ -d "$SB" ] || exit 0
  need_lock "$@"
  local f hit owner
  hit=$(jq -r --arg t "$TUID" 'select(.tool_use_id==$t) | input_filename' "$SB/pending" "$SB"/*.json 2>/dev/null)
  if [ "$SPAWN_RESULT" = ok ] && [ "$TRSTAT" = async_launched ]; then
    # Background launch (Claude Code 2.1.29x spawns subagents this way): the agent has not run yet.
    # Keep the pending record, remember which agent may claim it; SubagentStop retires it later.
    for f in $hit; do
      case "$f" in
        "$SB/pending")
          owner=$(pending_owner)
          if [ -z "$owner" ]; then [ -z "$TRAID" ] || stamp_pending "$TRAID"
          elif [ -n "$TRAID" ] && [ "$owner" != "$TRAID" ]; then retire_file "$f"; fi ;;
        *.done.json|*/roots.jsonl) ;;
        *.json) [ "$(basename "$f" .json)" = "${TRAID:-$(basename "$f" .json)}" ] || retire_file "$f" ;;
      esac
    done
    exit 0
  fi
  for f in $hit; do
    case "$f" in *.done.json|*/roots.jsonl) continue;; esac
    retire_file "$f"
  done
  exit 0
}

subagent_event() { # SubagentStart / SubagentStop for a ":project-map" agent (input: session_id, agent_id, agent_type)
  [ "$MODE" = agent ] && [ -n "$SB" ] && [ -n "$AIDOK" ] || exit 0
  case "$SUBAGENT" in start|stop) ;; *) exit 0;; esac
  [ -d "$SB" ] || exit 0
  need_lock "$@"
  local owner
  if [ "$SUBAGENT" = start ]; then
    [ -e "$SB/$AID.done.json" ] && exit 0   # a terminal agent never gets a new job
    if [ -f "$SB/pending" ] && [ -z "$(pending_owner)" ]; then stamp_pending "$AID"; fi
    exit 0
  fi
  [ ! -f "$SB/$AID.json" ] || retire_file "$SB/$AID.json"
  if [ -f "$SB/pending" ]; then owner=$(pending_owner); [ "$owner" != "$AID" ] || retire_file "$SB/pending"; fi
  exit 0
}

if [ -n "$SPAWN_RESULT" ]; then spawn_result "$@"; fi
if [ -n "$SUBAGENT" ]; then subagent_event "$@"; fi

# trusted main-session Bash commands (section 4.2a): the facts invocation is searched anywhere in the command
# text; only literal absolute paths count (a path given through a variable is never registered).
# Fills MK[] (reg|close) and MR[] (path) in parallel.
MK=(); MR=()
main_trusted() {
  local pl line esc rest seen=" "
  case "$CMD" in *project-map-facts.py*) ;; *) return 0;; esac
  for pl in "$PLUGIN" "$RPLUGIN_MAIN"; do
    [ -n "$pl" ] || continue
    case "$seen" in *" $pl "*) continue;; esac; seen="$seen$pl "
    esc=$(printf %s "$pl" | sed 's/[][\.^$*+?(){}|\/]/\\&/g')
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rest=${line#*project-map-facts.py }
      case "$rest" in *\$) continue;; esac
      case "$rest" in
        "--close-session "*) MK[${#MK[@]}]=close; MR[${#MR[@]}]=${rest#--close-session };;
        /*) MK[${#MK[@]}]=reg; MR[${#MR[@]}]=$rest;;
      esac
    done <<EOF_M
$(printf '%s\n' "$CMD" | grep -oE "python3 $esc/scripts/project-map-facts\\.py (--close-session )?/[^ \"'\$;&|<>]+[\$]?")
EOF_M
  done
  return 0
}
RPLUGIN_MAIN=""; if [ "$MODE" = main ] && [ "$TOOL" = Bash ]; then rp "$PLUGIN" && RPLUGIN_MAIN="$RP"; fi

if [ "$MODE" = main ]; then
  if [ "$TOOL" = Bash ]; then
    main_trusted
    [ ${#MK[@]} -gt 0 ] || exit 0
    [ -n "$SB" ] || exit 0
    need_lock
    mkdir -p "$SB" 2>/dev/null || exit 0
    i=0
    while [ $i -lt ${#MK[@]} ]; do
      if [ "${MK[$i]}" = close ]; then
        ( set -C; iso > "$SB/closed" ) 2>/dev/null
      elif rp "${MR[$i]}"; then
        case "$RP" in *[!A-Za-z0-9_./-]*) ;; *)
          if [ -d "$RP" ] && root_ok "$RP"; then
            jq -nc --arg r "$RP" --arg a "$(iso)" '{root:$r,at:$a}' >> "$SB/roots.jsonl" 2>/dev/null
          fi;;
        esac
      fi
      i=$((i+1))
    done
    exit 0
  fi
  if [ "$TOOL" = Agent ]; then
    case "$SUBT" in *:project-map) ;; *) exit 0;; esac
    SUMMARY="spawn $PL1 $PL2 $PL3"
    case "$PL1" in "ROOT: /"*) R=${PL1#ROOT: };; *) deny "spawn: line 1 must be 'ROOT: <absolute path>'";; esac
    case "$R" in *' '*) deny "spawn: ROOT must not contain spaces";; esac
    case "$PL2" in "INV: "*) I=${PL2#INV: };; *) deny "spawn: line 2 must be 'INV: inv-<id>'";; esac
    case "$I" in inv-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) deny "spawn: bad INV id";; esac
    case "$PL3" in "RUN: UPDATE") RUNM=UPDATE;; "RUN: FULL") RUNM=FULL;; *) deny "spawn: line 3 must be 'RUN: UPDATE' or 'RUN: FULL'";; esac
    [ "$RBG" = false ] || deny "spawn: run_in_background is not allowed (foreground only)"
    [ "$RESUMEN" = 0 ] || deny "spawn: resume/continue is not allowed"
    [ -n "$TUID" ] || deny "spawn: tool_use_id missing"
    [ -n "$SIDOK" ] || deny "spawn: no usable session id"
    [ -n "$DATA" ] || deny "spawn: no plugin data directory"
    need_lock
    mkdir -p "$SB" 2>/dev/null || deny "spawn: cannot create session binding directory"
    [ ! -e "$SB/closed" ] || deny "spawn: session closed, start a new Claude Code session"
    rp "$R" || deny "spawn: ROOT does not resolve"
    RR="$RP"
    [ -f "$SB/roots.jsonl" ] && jq -r '.root // empty' "$SB/roots.jsonl" 2>/dev/null | grep -Fxq -- "$RR" \
      || deny "spawn: ROOT was not registered in this session. Run the facts command by itself as one plain command with the literal absolute path: python3 $PLUGIN/scripts/project-map-facts.py $R  then spawn again"
    INVF="$RR/.project-map/$I/invocation.json"
    rp "$RR/.project-map" && [ "$RP" = "$RR/.project-map" ] || deny "spawn: .project-map is not a plain directory"
    [ -f "$INVF" ] || deny "spawn: invocation.json missing"
    IR=$(jq -r '.root // empty' "$INVF" 2>/dev/null)
    ok=""; [ "$IR" = "$RR" ] && ok=1; if [ -z "$ok" ] && [ -n "$IR" ] && rp "$IR" && [ "$RP" = "$RR" ]; then ok=1; fi
    [ -n "$ok" ] || deny "spawn: invocation.json root differs"
    # a pending record that no agent claimed within 10 minutes is an orphan (background agent lost): released
    if [ -f "$SB/pending" ] && [ -n "$(find "$SB" -maxdepth 1 -name pending -mmin +10 2>/dev/null)" ]; then retire_file "$SB/pending"; fi
    [ ! -e "$SB/pending" ] || deny "spawn: one map agent at a time (a pending invocation exists)"
    TMPP="$SB/.pending.$$"
    jq -nc --arg r "$RR" --arg i "$I" --arg m "$RUNM" --arg t "$TUID" --arg a "$(iso)" \
      '{root:$r,inv:$i,mode:$m,tool_use_id:$t,at:$a}' > "$TMPP" 2>/dev/null || deny "spawn: cannot write pending record"
    ln "$TMPP" "$SB/pending" 2>/dev/null || { rm -f "$TMPP"; deny "spawn: pending record already exists"; }
    rm -f "$TMPP"
    exit 0
  fi
  exit 0
fi

# ------------------------------------------------------------ agent mode
[ -n "$SIDOK" ] || deny "agent: no usable session id"
[ -n "$AIDOK" ] || deny "agent: no usable agent id"
[ -n "$SB" ] || deny "agent: no plugin data directory"
BROOT=""; BINV=""; BMODE=""
load_binding() { # $1 file
  local o
  o=$(jq -r '[.root // "", .inv // "", .mode // ""] | join("\n")' "$1" 2>/dev/null) || return 1
  BROOT=$(printf '%s\n' "$o" | sed -n 1p); BINV=$(printf '%s\n' "$o" | sed -n 2p); BMODE=$(printf '%s\n' "$o" | sed -n 3p)
  case "$BROOT" in /*) ;; *) return 1;; esac
  case "$BINV" in inv-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) return 1;; esac
  case "$BMODE" in UPDATE|FULL) ;; *) return 1;; esac
}
if [ -e "$SB/$AID.done.json" ]; then deny "agent finished: this invocation is over"; fi
if [ -f "$SB/$AID.json" ] && load_binding "$SB/$AID.json"; then :
else
  need_lock "$@"
  if [ -e "$SB/$AID.done.json" ]; then deny "agent finished: this invocation is over"; fi
  if [ -f "$SB/$AID.json" ]; then
    load_binding "$SB/$AID.json" || deny "agent: unreadable binding"
  else
    [ ! -e "$SB/closed" ] || deny "agent: session closed, no claim possible"
    [ -f "$SB/pending" ] || deny "agent: no pending invocation, nothing to claim"
    load_binding "$SB/pending" || deny "agent: unreadable pending record"
    PO=$(pending_owner); [ -z "$PO" ] || [ "$PO" = "$AID" ] || deny "agent: the pending invocation belongs to another agent"
    mv "$SB/pending" "$SB/$AID.json" 2>/dev/null || deny "agent: claim failed"
    : > "$BROOT/.project-map/$BINV/claimed" 2>/dev/null
  fi
fi
STAGE="$BROOT/.project-map/$BINV"
rp "$BROOT" || deny "agent: bound root does not resolve"
RROOT="$RP"
rp "$STAGE" && [ "$RP" = "$RROOT/.project-map/$BINV" ] || deny "agent: staging directory is missing or not a plain directory"
RSTAGE="$RP"
MEMR="$MEM_DIR"; rp "$MEM_DIR" && MEMR="$RP"
RPLUGIN=""; rp "$PLUGIN" && RPLUGIN="$RP"
RDATA=""; if [ -n "$DATA" ]; then RDATA="$DATA"; rp "$DATA" && RDATA="$RP"; fi

in_scope() { # $1 = realpath
  local l
  case "$1" in "$RROOT"|"$RROOT"/*) return 0;; esac
  [ -n "$RPLUGIN" ] && case "$1" in "$RPLUGIN"|"$RPLUGIN"/*) return 0;; esac
  case "$1" in "$MEMR"|"$MEMR"/*) return 0;; esac
  l=$(jq -r '.ledger.path // empty' "$RSTAGE/snapshot.json" 2>/dev/null)
  case "$l" in /*) rp "$l" && [ "$RP" = "$1" ] && return 0;; esac
  return 1
}
# chk_path <operand> : canonicalise, secret-filter requested + resolved path, require scope. Sets CP (real path).
chk_path() {
  local a="$1" ab
  [ -n "$a" ] || deny "empty path operand"
  case "$a" in -*) deny "flag not allowed here: $a";; esac
  case "$a" in
    /*) ab=$a;;
    *) [ -n "$CWD" ] || deny "relative path without cwd: $a"; ab="$CWD/$a";;
  esac
  rp "$ab" || deny "path does not resolve: $a"
  CP="$RP"
  secret_path "$ab" "$CP" && deny "secret-looking path: $a"
  case "$CP" in /dev|/dev/*) deny "device path: $a";; esac
  # private plugin files: compared on lowercased resolved paths, because a case-insensitive volume (macOS default)
  # serves ~/.claude/agent-memory/project-map/Usage/... as the same file while the resolved spelling keeps the caller's case
  LCP=$(printf '%s' "$CP" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  if [ -n "$RDATA" ]; then
    LRD=$(printf '%s' "$RDATA" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    case "$LCP" in "$LRD"|"$LRD"/*) deny "plugin data is not readable by the map agent";; esac
  fi
  LMEM=$(printf '%s' "$MEMR" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "$LCP" in
    "$LMEM"/key) deny "the signing key is not readable by the map agent";;
    "$LMEM"/usage|"$LMEM"/usage/*|"$LMEM"/published|"$LMEM"/published/*)
      deny "the plugin's private usage cache and publish records are not readable by the map agent";;
  esac
  in_scope "$CP" || deny "path outside root, plugin, agent memory and ledger: $a"
}
is_file_op() { chk_path "$1"; [ -d "$CP" ] && deny "directory operand not allowed: $1"; return 0; }
num() { case "$1" in ''|*[!0-9]*) return 1;; esac; }

case "$TOOL" in
Grep|Glob) deny "$TOOL is not available to the map agent";;

# ---------------------------------------------------------- Read
Read)
  SUMMARY="Read $FP"
  case "$FP" in /*) ;; *) deny "Read: absolute path required";; esac
  chk_path "$FP"
  exit 0 ;;

# ---------------------------------------------------------- Write / Edit
Write|Edit)
  SUMMARY="$TOOL $FP"
  case "$FP" in /*) ;; *) deny "$TOOL: absolute path required";; esac
  case "$FP" in */) deny "$TOOL: file path ends with a slash";; esac
  BN=${FP##*/}; PAR=${FP%/*}; [ -n "$PAR" ] || PAR=/
  rp "$PAR" || deny "$TOOL: parent directory does not resolve"
  RPAR="$RP"
  KIND=""
  if [ "$RPAR" = "$RSTAGE" ]; then
    case "$BN" in
      judgement.out.json) KIND=out;;
      plan.out.json) [ "$BMODE" = FULL ] || deny "$TOOL: plan.out.json is FULL-only"; KIND=out;;
    esac
  elif [ "$RPAR" = "$MEMR" ]; then
    case "$BN" in
      .*|*[!A-Za-z0-9_.-]*) deny "$TOOL: odd memory file name";;
      *.md) KIND=out;;
    esac
  elif [ "$RPAR" = "$RROOT" ] && [ "$BN" = .gitignore ]; then
    KIND=gi
  fi
  [ -n "$KIND" ] || deny "$TOOL: target not allowed (judgement.out.json, plan.out.json (FULL), agent memory *.md, root .gitignore append): $FP"
  if [ -L "$FP" ]; then deny "$TOOL: target is a symlink"; fi
  if [ -e "$FP" ]; then
    [ -f "$FP" ] || deny "$TOOL: target is not a regular file"
    [ "$(nlink "$FP")" = 1 ] || deny "$TOOL: target has more than one hard link"
  fi
  [ "$KIND" = gi ] || exit 0
  # .gitignore: previous content plus exactly one line ".project-map/"
  WANT=".project-map/"
  OLD=""; if [ -e "$FP" ]; then OLD=$(cat "$FP"; printf x); OLD=${OLD%x}; fi
  gi_ok() { # $1 = candidate new content
    [ "$1" = "$OLD$WANT"$'\n' ] && { [ -z "$OLD" ] || case "$OLD" in *$'\n') true;; *) false;; esac; } && return 0
    [ -n "$OLD" ] && case "$OLD" in *$'\n') false;; *) true;; esac && [ "$1" = "$OLD"$'\n'"$WANT"$'\n' ] && return 0
    return 1
  }
  if [ "$TOOL" = Write ]; then
    gi_ok "$CONTENT" || deny ".gitignore: Write may only append the single line $WANT to the existing content"
    exit 0
  fi
  [ -e "$FP" ] || deny ".gitignore: Edit on a missing file"
  [ "$RALL" = false ] || deny ".gitignore: replace_all not allowed"
  if [ -z "$OLDS" ]; then
    [ -z "$OLD" ] || deny ".gitignore: empty old_string on a non-empty file"
    NEWF="$NEWS"
  else
    case "$OLD" in *"$OLDS"*) NEWF="${OLD%%"$OLDS"*}$NEWS${OLD#*"$OLDS"}";; *) deny ".gitignore: old_string not found";; esac
  fi
  gi_ok "$NEWF" || deny ".gitignore: Edit may only append the single line $WANT"
  exit 0 ;;

# ---------------------------------------------------------- Bash
Bash)
  C="$CMD"
  [ -n "$C" ] || deny "empty command"
  if [ "$BMODE" = FULL ]; then
    CH='"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars'
    URL="file://$BROOT/.project-map/index.html"
    [ "$C" = "$CH --window-size=1440,900 --screenshot=$STAGE/shot-desktop.png $URL" ] && exit 0
    [ "$C" = "$CH --window-size=390,844 --screenshot=$STAGE/shot-mobile.png $URL" ] && exit 0
  fi
  case "$C" in *[]\;\&\`\$\(\)\{\}\<\>\!\*\?\[\~\\=#]*) deny "shell metacharacter not allowed";; esac
  case "$C" in *[[:cntrl:]]*) deny "control character or newline not allowed";; esac
  case "$C" in
    *\"*|*\'*)
      printf '%s\n' "$C" | grep -Eq "\"[^\"]*[ |][^\"]*\"|'[^']*[ |][^']*'" && deny "quoted space or pipe not allowed"
      q=${C//[^\"]/}; [ $(( ${#q} % 2 )) -eq 0 ] || deny "unbalanced quote"
      q=${C//[^\']/}; [ $(( ${#q} % 2 )) -eq 0 ] || deny "unbalanced quote"
      C=${C//\"/}; C=${C//\'/} ;;
  esac
  q=${C//[^|]/}; [ ${#q} -le 1 ] || deny "at most one pipe"
  FIRST="$C"; SECOND=""
  if [ ${#q} -eq 1 ]; then
    FIRST=${C%%|*}; SECOND=${C#*|}
    case "$FIRST" in *[!\ ]*) ;; *) deny "empty command before the pipe";; esac
    case "$SECOND" in *[!\ ]*) ;; *) deny "empty pipe consumer";; esac
  fi
  set -f; set -- $FIRST; set +f
  [ $# -gt 0 ] || deny "empty command"
  verb="$1"; shift
  case "$verb" in
    python3|bash)
      s="$1"; r="${2:-}"; [ $# -ge 2 ] || deny "$verb: script and ROOT required"
      sok=""
      for pl in "$PLUGIN" "$RPLUGIN"; do [ -n "$pl" ] || continue
        case "$verb:$s" in
          "python3:$pl/scripts/project-map-facts.py") sok=facts;;
          "python3:$pl/scripts/project-map-usage.py") sok=usage;;
          "bash:$pl/scripts/project-map-embed.sh") sok=embed;;
          "bash:$pl/scripts/pm-git.sh") sok=git;;
        esac
      done
      [ -n "$sok" ] || deny "$verb: only the plugin facts, usage, embed and pm-git scripts are allowed"
      rok=""; [ "$r" = "$BROOT" ] && rok=1
      if [ -z "$rok" ]; then case "$r" in /*) rp "$r" && [ "$RP" = "$BROOT" -o "$RP" = "$RROOT" ] && rok=1;; esac; fi
      if [ -z "$rok" ] && [ "$sok" = git ]; then
        # nested repo: <bound root>/<path>, path listed in the script-owned snapshot repos[].path
        for np in $(jq -r '.repos[]?.path // empty' "$RSTAGE/snapshot.json" 2>/dev/null); do
          case "$np" in .|/*|*..*|*[!A-Za-z0-9_./-]*) continue;; esac
          if [ "$r" = "$BROOT/$np" ] || [ "$r" = "$RROOT/$np" ]; then
            rp "$r" && case "$RP" in "$RROOT"/?*) rok=1;; esac
            break
          fi
        done
      fi
      [ -n "$rok" ] || deny "$sok: ROOT must be the bound root"
      shift 2
      case "$sok" in
        facts|usage) [ $# -eq 0 ] || deny "$sok: no extra arguments allowed";;
        embed) [ $# -eq 1 ] && [ "$1" = "$BINV" ] || deny "embed: second argument must be the bound invocation $BINV";;
        git)
          [ $# -ge 1 ] || deny "pm-git: subcommand required"
          sub="$1"; shift
          case "$sub" in status|log|rev-parse|branch|ls-files|tag) ;; *) deny "pm-git: subcommand not allowed: $sub";; esac
          case "$sub" in
            status|rev-parse|branch|tag) [ $# -eq 0 ] || deny "pm-git $sub: no arguments allowed";;
            log)
              if [ $# -gt 0 ]; then
                [ $# -eq 2 ] && [ "$1" = -n ] && num "$2" && [ "$2" -le 60 ] || deny "pm-git log: only -n N (N <= 60)"
              fi ;;
            ls-files)
              if [ $# -gt 0 ]; then
                [ $# -eq 1 ] || deny "pm-git ls-files: at most one relative path"
                case "$1" in ''|-*|/*|*[!A-Za-z0-9_./-]*) deny "pm-git ls-files: bad path";; esac
                case "/$1/" in */../*) deny "pm-git ls-files: '..' not allowed";; esac
              fi ;;
          esac ;;
      esac ;;
    ls)
      case "${1:-}" in -la|-l|-a) shift;; esac
      [ $# -eq 1 ] || deny "ls: exactly one path (flags -la|-l|-a only)"
      chk_path "$1" ;;
    cat) [ $# -eq 1 ] || deny "cat: exactly one path"; is_file_op "$1" ;;
    head|tail)
      if [ "${1:-}" = -n ]; then
        num "${2:-}" || { [ "$verb" = tail ] && case "${2:-}" in +[0-9]*) num "${2#+}";; *) false;; esac; } || deny "$verb: bad -n value"
        shift 2
      fi
      [ $# -eq 1 ] || deny "$verb: [-n N] <path> only"
      is_file_op "$1" ;;
    wc)
      case "${1:-}" in -l|-c) shift;; esac
      [ $# -eq 1 ] || deny "wc: [-l|-c] <path> only"
      is_file_op "$1" ;;
    stat)
      [ $# -eq 3 ] && [ "$1" = -f ] && [ "$2" = %z ] || deny "stat: only stat -f %z <path>"
      chk_path "$3" ;;
    find)
      [ $# -ge 1 ] || deny "find: path required"
      fpath="$1"; shift
      chk_path "$fpath"
      sd=""; st=""; sn=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -maxdepth) [ -z "$sd" ] && num "${2:-}" || deny "find: bad -maxdepth"; sd=1; shift 2;;
          -type) [ -z "$st" ] && { [ "${2:-}" = f ] || [ "${2:-}" = d ]; } || deny "find: bad -type"; st=1; shift 2;;
          -name) [ -z "$sn" ] && case "${2:-}" in ''|*[!A-Za-z0-9_.-]*) false;; *) true;; esac || deny "find: bad -name literal"; sn=1; shift 2;;
          *) deny "find: argument not allowed: $1";;
        esac
      done ;;
    date)
      [ $# -le 1 ] || deny "date: no operands after the format"
      [ $# -eq 0 ] || case "$1" in +*) ;; *) deny "date: only +FORMAT";; esac ;;
    gh)
      case "${1:-} ${2:-}" in "issue list"|"pr list") shift 2;; *) deny "gh: only 'issue list' and 'pr list'";; esac
      while [ $# -gt 0 ]; do
        case "$1" in
          -L) num "${2:-}" || deny "gh: bad -L"; shift 2;;
          --state) case "${2:-}" in open|closed|all|merged) shift 2;; *) deny "gh: bad --state";; esac;;
          *) deny "gh: flag not allowed: $1";;
        esac
      done ;;
    *) deny "Bash verb not allowed: $verb";;
  esac

  # optional single pipe consumer (stdin only, no file operands)
  if [ -n "$SECOND" ]; then
    set -f; set -- $SECOND; set +f
    [ $# -gt 0 ] || deny "empty pipe consumer"
    cv="$1"; shift
    case "$cv" in
      head|tail)
        if [ $# -gt 0 ]; then
          [ "$1" = -n ] || deny "pipe $cv: only -n N"
          { num "${2:-}" || { [ "$cv" = tail ] && case "${2:-}" in +[0-9]*) num "${2#+}";; *) false;; esac; }; } || deny "pipe $cv: bad -n value"
          [ $# -eq 2 ] || deny "pipe $cv: no file operands"
        fi ;;
      wc) [ $# -le 1 ] || deny "pipe wc: one flag only"
          [ $# -eq 0 ] || case "$1" in -l|-c|-w) ;; *) deny "pipe wc: flag not allowed";; esac ;;
      sort)
        for a in "$@"; do case "$a" in -r|-n|-u) ;; *) deny "pipe sort: flag/operand not allowed: $a";; esac; done ;;
      grep)
        np=0
        for a in "$@"; do
          case "$a" in
            -i|-n|-c|-E|-F) ;;
            -*) deny "pipe grep: flag not allowed: $a";;
            *) [ $np -eq 0 ] || deny "pipe grep: exactly one pattern"; np=1;;
          esac
        done
        [ $np -eq 1 ] || deny "pipe grep: pattern required" ;;
      *) deny "pipe consumer not allowed: $cv";;
    esac
  fi
  exit 0 ;;
esac
deny "tool not covered by this guard: $TOOL"
