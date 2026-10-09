# project-map 3.2: interfaces

Fixed contracts for release 3.2. Code follows this document; a change here needs a Codex review
before implementation. Plan: `docs/PLAN-v3.2.md` (Codex AGREE, round 6, 2026-10-08).

Verified prerequisites (headless probe, 2026-10-08): a subagent's hook input carries the parent
`session_id`, its own `agent_id` and `agent_type`; a main-session hook input has no `agent_id`;
the Agent-tool PreToolUse input carries `tool_input.prompt`, `tool_input.subagent_type` and
`tool_use_id`; PostToolUse / PostToolUseFailure repeat that `tool_use_id`; hook processes receive
`CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA`. A timed-out PreToolUse command hook does not block
(documented), so the guard is linear-time and fast.

Notation: `PLUGIN` = `${CLAUDE_PLUGIN_ROOT}`, `DATA` = `${CLAUDE_PLUGIN_DATA}`, `PM` =
`<ROOT>/.project-map`. "realpath" = `os.path.realpath` (symlinks resolved, no trailing slash).

## 1. Files under `PM/`

```
PM/
  current -> gen-000012-9f3a2c1d/     publication pointer: ONE symlink, switched by atomic rename
  index.html  -> current/index.html   stable paths for people and browsers (symlinks into current/)
  mobile.html -> current/mobile.html
  brief.txt   -> current/brief.txt
  state.json  -> current/state.json
  gen-<seq6>-<id8>/                   PUBLISHED generation, immutable after publish
    manifest.json   {"generation":"<seq>-<id>","base":"<seq>-<id>"|null,"files":{name:{size,sha256}}}
    state.json      merged view (schema project-map-4), has "generation"
    index.html, mobile.html   <meta name="pm-generation" content="<seq>-<id>">
    brief.txt       last line: `generation <seq>-<id>`
    snapshot.json   complete script-owned record (no cap), has "generation"
    pack.json       bounded model view (<= 8 KB), has "generation"
    plan.json       phases + criteria (schema project-map-plan-1), has "generation"
    judgement.json  the ACCEPTED judgement (next invocation copies it as judgement.in.json)
    invocation/     copy of the staging dir that produced this generation (audit trail), or absent
                    for a mechanical re-render
    legacy/         (migration generation only) the 3.x files, copied, never moved
  inv-<id8>/                          STAGING for one invocation; never `current`; see 1.2
    invocation.json {"id","created_at","base":"<seq>-<id>"|null,"root","session_id"|null}
    snapshot.json, pack.json, plan.json (carried forward), judgement.in.json (frozen input)
    judgement.out.json, plan.out.json   agent output (written by the agent, section 4.3)
    claimed         written by the guard on claim (empty file); released  written on spawn result
  cache.json      script-owned mutable: watch_cache (6.1), acknowledged plugin hashes (5.2)
  answers.jsonl   append-only owner answers (6.7)
  .lock           publish lock (4.4)
```

1.1 **Ids.** `seq` = zero-padded decimal, previous published seq + 1, allocated under the publish
lock. `id` = 8 hex chars from `secrets.token_hex(4)` (collision-resistant, not time-derived).
Staging ids are allocated exclusively with `os.mkdir` (EEXIST → draw again).

1.2 **Staging lifecycle.** facts (without `--no-stage`) creates `inv-<id>/` for every verdict
that may spawn (`NEEDS_JUDGEMENT`, `NEEDS_FULL`), with `base` = the current generation (`null` when `current` is
absent: bootstrap or migration). Map agents are always spawned in the foreground (no
`run_in_background`, never resumed). A staging dir is *active* while a pending record or a
non-terminal agent binding references its id (§4). Publication COPIES the staging dir into
`gen-*/invocation/` and keeps STAGE in place: FULL screenshots after a successful publish still
read STAGE, and Edit+embed retries apply only after a FAILED publication (`PM_EMBED_ERROR`).
After a successful publication the invocation's `base` is no longer `current`, so any further
embed of that invocation returns SUPERSEDED; corrections need a fresh invocation (rerun
`/project-map`). STAGE becomes inactive when its binding turns *terminal* (§4.2c) or its
pending record is deleted; inactive staging is swept by the next facts run under the publish
lock (also any `inv-*` with no reference at all that is older than 24 h, covering crashes before
registration).

1.3 **Publish (embed).** Under the publish lock: resolve `current` once; require
`invocation.base == current` (string compare of the generation name; both `null` only on
bootstrap/migration) else print `SUPERSEDED base <b> current <c>` and exit 4 without writing;
allocate seq; write all files into `gen-<seq>-<id>.tmp/`; write `manifest.json` last; fsync the
files and the directory; rename `.tmp` → final name; create symlink `current.tmp` → final name;
`rename(current.tmp, current)` (atomic replace); then install each of the four stable symlinks
by atomic replacement (`<name>.tmp` → `rename` over whatever is there, a legacy regular file
included). A generation is *complete* iff `manifest.json` exists and every listed file matches
its size. Dirs without a complete manifest are swept by facts under the lock. Crash semantics: a
crash before the pointer rename leaves the previous complete generation current; a crash after it
leaves the NEW complete generation current. facts repairs the four stable symlinks (missing or
pointing elsewhere than `current/<name>`) under the lock before it may return `NO_CHANGE`
(tests E-crash-links, E-migrate-links).

1.3b **Signed generations.** A per-user random key lives at `DATA/key` (0600; fallback
`~/.claude/agent-memory/project-map/key`; both unreadable to the agent). Embed records every
publish in `DATA/published/<sha256(realpath root)>` = `{root, generation, at}`. When the key is
missing (first run after upgrade, or a lost key) the current generation is ADOPTED and re-signed
only if that record exists for the root and names the current generation; otherwise it is
unverified (→ `NEEDS_FULL no verified generation`). Embed also writes `cache.json.ack_hashes` at
every publish. `manifest.json` carries `hmac` =
HMAC-SHA256(key, canonical JSON of `files` + `generation` + `base`). A generation is *verified*
when every listed file matches its size and sha256 and the hmac matches. Unverified generations
are never `complete`: facts never returns `NO_CHANGE` on one (it re-renders from the last
verified generation → `NEEDS_REFRESH`, or `NEEDS_FULL` when none), and the session hook injects
only `project-map: map unverified; run /project-map` (§5.1). `pm_common.verify_generation(dir)`
is the one check used by scripts and hooks.

1.4 **Pinned reads.** Every reader (facts, embed, hooks, usage) resolves `current` ONCE with
`os.readlink`, then opens all files inside that directory name; it never re-reads `current`
mid-operation. Readers verify the `generation` field / meta / trailer agrees across the files
they use; disagreement → `NEEDS_REFRESH generation mismatch`.

1.5 **Legacy (3.x) detection and migration.** No `current` and a regular `PM/state.json` →
`NEEDS_FULL migrate`. facts creates a staging dir with `base: null`, `judgement.in.json` = the
legacy `judgement.json` (so ids, ledger, frozen decisions carry over) and `plan.json` derived from
the legacy milestone list. The migration generation keeps copies of the legacy files under
`legacy/`; the legacy top-level files are replaced by the stable symlinks through the atomic
replacement above (never deleted first), so no stable path is ever missing.

1.6 `.gitignore`: first map only, one appended line `.project-map/`.

1.7 **Pruning.** In facts' sweep, under the publish lock: keep the newest 10 complete
generations, the one `current` points to, and any generation named as `base` by an active
staging dir; older complete generations (with their `invocation/` copies) are deleted.

## 2. Verdicts (one stdout line; first token is the verdict; last token `inv <id>` when a staging dir was created)

| Verdict | Exit | Meaning | Skill action |
|---|---|---|---|
| `NO_CHANGE <note>` | 0 | key unchanged, coverage complete, generation consistent | print brief, stop |
| `NEEDS_REFRESH <why>` | 0 | mechanical re-render was needed and succeeded (generation mismatch, template/embed moved, usage moved, map > 1 h, coverage partial k/n) | print brief, stop |
| `NEEDS_JUDGEMENT <why> inv <id>` | 0 | key moved (git key, watch, ledger, answers, deadlines); may be preceded by one mechanical re-render so the published brief carries the stale stamp | spawn UPDATE (sonnet) |
| (`--no-stage`) | | same verdicts, mechanical re-render included, but no staging dir and no `inv <id>` suffix; used by the SessionStart hook | |
| `NEEDS_FULL <why> inv <id>` | 0 | first map, migrate, invalid or schema-mismatched state | state the cost, spawn FULL (opus) |
| `REFRESH_FAILED <why>` | 3 | mechanical re-render failed; previous generation still current | report the line; never print a brief as fresh |
| `ERROR <why>` | 2 | git collection failure, unreadable root, unsupported location, missing prerequisite, answers rewritten | report the line, stop |

Partial coverage never spawns: while `coverage: partial`, facts returns `NEEDS_REFRESH coverage
partial k/n` (and continues hashing, 2 s budget per run beyond the base work) unless the git
key moved, in which case it returns `NEEDS_JUDGEMENT` as usual. `NO_CHANGE` requires complete
coverage.

Embed prints `PM_EMBED_OK gen <seq>-<id> <bytes>` (exit 0), `SUPERSEDED ...` (exit 4) or
`PM_EMBED_ERROR <why>` (exit 1; nothing replaced).

2.1 **Mechanical embed** (`embed.sh ROOT --mechanical [--deadline S]`): no invocation argument.
It pins `current` once, takes `judgement.json`, `plan.json` and the assessment time from that
generation unchanged, collects only mechanical inputs (status signature, usage, template/embed
hashes, answers lifecycle), then publishes a new generation with `base` = the pinned generation
under the same base check (SUPERSEDED exit 4 if `current` moved meanwhile). `--deadline S` is a
TOTAL wall budget covering ROOT discovery, git calls and rendering, checked between steps and
immediately before the pointer switch (a single stalled step cannot be interrupted); on expiry it
prints `PM_EMBED_ERROR deadline` (exit 1) with nothing replaced. The prompt hook calls it with
`--deadline 3.5`; facts calls it with `--deadline 8` for `NEEDS_REFRESH`.

## 3. Hooks (`hooks/hooks.json`, exec form, scripts under `PLUGIN/scripts/`)

| Event | Matcher | Command | Timeout | Role |
|---|---|---|---|---|
| PreToolUse | `Agent\|Read\|Grep\|Glob\|Edit\|Write\|Bash` | `project-map-guard.sh` | 30 s | §4 |
| PostToolUse | `Agent` | `project-map-guard.sh --spawn-result ok` | 10 s | §4.2c |
| PostToolUseFailure | `Agent` | `project-map-guard.sh --spawn-result fail` | 10 s | §4.2c |
| SessionStart | `startup\|resume\|clear\|compact` | `project-map-session.sh` | 20 s | §5.1 |
| UserPromptSubmit | (none) | `project-map-prompt.sh` | 5 s | §5.2 |

Guard envelope: the guard reads ALL of stdin and parses it with jq (linear). Main mode never
denies for size or for unparsable input, with one exception: an Agent spawn whose
`subagent_type` ends with `:project-map` must be fully parsed and registered, else it is denied.
Agent mode fails closed on input over 8 MB or unparsable input, and denies a Bash `command` over
2 KB before any other check. Agent-spawn registration parses prompt lines 1-3 from the full
input, so a padded spawn is registered normally (tests G-pad < 1 s; G-bind-oversized: a 70 KB
spawn registers, a 70 KB main-session Write is allowed). In agent mode a Bash `command` over 2 KB is denied before any other
check. Write/Edit contents are not size-limited by the guard (embed enforces the 6 KB / 64 KB
limits on judgement.out / plan.out). Regression: a 40 KB padded command is denied in < 1 s.

## 4. Guard modes and binding (`DATA/bind/`)

4.1 **Mode.** No `agent_id` field and no `agent_type` ending `:project-map` → **main mode**
(an input with that `agent_type` but no `agent_id` is denied: "agent identity missing"). `agent_type` ends with `:project-map` →
**agent mode**. Any other subagent → **other mode**: exit 0, never trusted, never writes
records. Main mode allows every tool call except the Agent spawn denials in 4.2b; it writes
records only for the three exact trusted commands below. Missing `session_id` → agent mode
denies everything; main mode writes nothing.

4.2 **Main-mode records.** `SESSION_BIND = DATA/bind/<session_id>/`. Root registration appends
`SESSION_BIND/roots.jsonl`; closure creates `SESSION_BIND/closed`; the pending record is
`SESSION_BIND/pending`; active and terminal bindings are `SESSION_BIND/<agent_id>.json` and
`SESSION_BIND/<agent_id>.done.json`. All transitions use `flock` on `DATA/bind/.lock` (create
dir and file if missing). Files are never overwritten in place: appends, `O_EXCL` creates and
renames only. Sessions are isolated: nothing under one `SESSION_BIND` is read for another.
- (a) **root binding.** The Bash command text contains
  `python3 PLUGIN/scripts/project-map-facts.py <ROOT>` where ROOT is a LITERAL absolute path
  (regex `python3 <PLUGIN>/scripts/project-map-facts\.py (/[^ "'$;&|<>]+)`, matched anywhere in
  the command; a path passed through a shell variable, or a match immediately followed by `$`,
  is never registered): append
  `{"root": realpath(ROOT), "at": iso}` to `SESSION_BIND/roots.jsonl` for every match. The skill
  still runs the facts command by itself as one plain command; the deny message for an
  unregistered root tells the model to do exactly that and spawn again.
  `python3 PLUGIN/scripts/project-map-facts.py --close-session <ROOT>`: create
  `SESSION_BIND/closed` (contents: iso time). `--accept-answers <ROOT>` and
  `--budget` are also recognised as trusted (no record).
- (b) **pending invocation.** Agent tool, `tool_input.subagent_type` ends with `:project-map`;
  a missing or empty `tool_use_id` denies the spawn.
  Parse lines 1-3 of `tool_input.prompt`: `ROOT: <path>`, `INV: inv-<id8>`, `RUN: UPDATE|FULL`.
  Deny the spawn (exit 2, reason printed) if any of: `SESSION_BIND/closed` exists; ROOT not in the session's
  roots; `realpath(ROOT)/.project-map/inv-<id>/invocation.json` missing or its `root` differs;
  `SESSION_BIND/pending` exists and is younger than 10 minutes (an older one is an orphan of a lost background
  agent: it is removed, `inv-<id>/released` written, and the spawn proceeds); `RUN` missing or not `UPDATE`/`FULL`;
  `tool_input.run_in_background` is true;
  `tool_input.resume` (or any resume/continue field) is present. Otherwise create `SESSION_BIND/pending` with
  `O_EXCL`, contents `{"root","inv","mode":"UPDATE"|"FULL","tool_use_id","at"}`, written to a
  temp name and renamed so a partial file is never visible; `mode` is carried into the active and
  terminal bindings (FULL-only targets in 4.3 check `mode`).
- (c) **spawn result.** Look up `tool_use_id` in `SESSION_BIND/pending` AND in every
  `SESSION_BIND/<agent_id>.json` (claimed bindings keep the `tool_use_id`). Match in pending
  (agent never made a tool call): delete `SESSION_BIND/pending`, write `inv-<id>/released`.
  Match in a claimed binding (`ok` or `fail`): mark the binding *terminal* (rename to
  `SESSION_BIND/<agent_id>.done.json`), write `inv-<id>/released`. A terminal binding denies every further
  call from that `agent_id` and no longer keeps STAGE active. Non-matching ids: no action.
  **Background launch (3.2.1).** Claude Code 2.1.29x launches every subagent in the background: PostToolUse
  fires at launch with `tool_response` = `{"isAsync":true,"status":"async_launched","agentId":...}` (a JSON
  string or object), before the agent has made any call. When `ok` carries `status == "async_launched"`:
  a matching pending record is **kept** and stamped `agent_id = agentId` (if it is unstamped; if it is stamped
  for a different id the record is retired as above, fail safe); a matching claimed binding for a different
  `agent_id` is made terminal; nothing else happens. The job is retired by (d) instead.
- (d) **subagent events.** `SubagentStart` and `SubagentStop` (input: `session_id`, `agent_id`, `agent_type`,
  no `tool_name`) call the guard with `--subagent start|stop`; any other `agent_type` than `*:project-map`,
  a malformed `agent_id` or an unknown argument → exit 0 with no change. Under the binding lock: *start* stamps
  an unstamped pending record with this `agent_id` (SubagentStart precedes PostToolUse); *stop* makes
  `<agent_id>.json` terminal (as in (c)) and removes a pending record stamped for this `agent_id`, writing
  `inv-<id>/released` in both cases. Claim (4.3 step 3) additionally denies when the pending record is
  stamped for another `agent_id` ("belongs to another agent"). Whenever a *stamped* pending record is retired
  without having been claimed (expiry, launch-id mismatch, stop), its owner becomes terminal
  (`<owner>.done.json` is written from the record) so a late first call of that agent cannot take a newer job;
  *start* never stamps for a terminal `agent_id`. Hook output is never used to block these events.

4.3 **Agent mode.** All paths below are under `SESSION_BIND` (§4.2). Under the binding lock, in
this order: (1) if `<agent_id>.done.json` exists → deny ("agent finished"), without inspecting or
claiming the pending record; (2) else if `<agent_id>.json` exists → load `{root, inv, mode}` (the
authority); (3) else (unseen agent): deny if `closed` exists or `pending` is missing; otherwise
rename `pending` → `<agent_id>.json` and write `inv-<id>/claimed`. Bindings are never
overwritten. After claiming, every check below uses `root`, `inv` and `mode`; `STAGE` =
`root/.project-map/inv-<id>`. Test G-bind-terminal: A completes (terminal), B's spawn leaves a
pending record, A calls again → denied and B's pending record is unchanged.

- **Bash grammar.** `command` = one simple command, optionally followed by at most one `|` and one
  pipe consumer. No `; & \` ` $ ( ) { } < > ! * ? [ ~` anywhere, no quotes around a
  metacharacter, no newline. Words are split on single spaces. Allowed simple commands:
  - `python3 PLUGIN/scripts/project-map-facts.py ROOT`, `bash PLUGIN/scripts/project-map-embed.sh ROOT inv-<id>`,
    `python3 PLUGIN/scripts/project-map-usage.py ROOT`, `bash PLUGIN/scripts/pm-git.sh ROOT <sub> [flags]` (§7.2),
    where ROOT must equal the bound root textually or after realpath;
  - `ls [-la|-l|-a] <path>`, `cat <path>`, `head [-n N] <path>`, `tail [-n N] <path>`,
    `wc [-l|-c] <path>`, `stat -f %z <path>`, `find <path> [-maxdepth N] [-type f|d] [-name <literal>]`,
    `date [+%FORMAT]` (no operands after the format), `gh issue list [-L N] [--state s]`,
    `gh pr list [-L N] [--state s]` (never `-R/--repo/--hostname/--search/--json`);
  - FULL only (`binding.mode == "FULL"`), exact strings: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=STAGE/shot-desktop.png file://ROOT/.project-map/index.html`
    and the same with `--window-size=390,844 --screenshot=STAGE/shot-mobile.png`.
  - Pipe consumers: `head [-n N]`, `tail [-n N]`, `wc [-l|-c|-w]`, `grep [-i|-n|-c|-E|-F] <pattern>`
    (pattern has no metacharacters, no `-r/-R/--include`), `sort [-r|-n|-u]`. No file operands.
  - `<path>` operands: realpath must be under one of: `root`, `PLUGIN`,
    `~/.claude/agent-memory/project-map/`, or equal the ledger path recorded in
    `STAGE/snapshot.json` (`ledger.path`, script-owned). `/dev/*`, `.git/` components, and
    anything matching the secret patterns are denied. `ls -R`, `tail -f`, `cat` of a directory
    are denied.
- **Secret patterns** (applied to the requested path, its basename and the realpath, case-folded):
  basename `.env`, `.envrc`, `*.env` or starting with `.env.`; path component `.ssh`, `.aws`,
  `.gnupg`, `.kube`, `.docker`, `.config/gh`, `.git`, `secrets`, `credentials`; basename matching
  `*credential*`, `*secret*`, `*token*`, `*password*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`,
  `*.tfstate`, `.pgpass`, `service-account*.json`, `id_rsa*`, `id_ed25519*`, `*_history`,
  `.netrc`, `.npmrc`, `.pypirc`, `.claude.json`, `settings*.json`, `ssh_host_*`, `known_hosts`.
  Metacharacters additionally denied in agent Bash: `=` (outside the exact Chrome strings) and `#`.
- **Read**: `file_path` realpath'd and checked like `<path>` above; symlinks resolved first.
- **Grep, Glob**: denied in agent mode (and absent from the agent's tool list).
- **Write / Edit**: allowed targets exactly `STAGE/judgement.out.json`, `STAGE/plan.out.json`
  (FULL-only targets require `binding.mode == "FULL"`),
  `~/.claude/agent-memory/project-map/*.md` (no subdirectories), and `root/.gitignore` with
  content exactly the previous content plus `.project-map/\n` (Edit: `old_string` empty or the
  current tail, `new_string` adds that one line). Target rules: parent directory realpath equals
  the expected directory; a new target may be absent; an existing target must be a regular file,
  not a symlink, `nlink == 1`.

4.4 **Locks.** `fcntl.flock(LOCK_EX | LOCK_NB)` on `PM/.lock` for publish (embed) and for sweeping
(facts); a busy lock → embed `PM_EMBED_ERROR another embed is running`, facts skips the sweep.
`DATA/bind/.lock` (blocking, 2 s timeout) for every binding transition. No age-based stealing.

4.5 **Logging.** Denies → `~/.claude/agent-memory/project-map/guard.log`: time, mode, tool,
reason, first 200 chars of the operand. `PM_GUARD_TRACE=<file>` keeps the full input.

## 5. Session hooks

5.0 **ROOT for hooks** = `git -C <cwd> rev-parse --show-toplevel` (through §7.1, 3 s timeout),
else cwd; if that equals `$HOME` → cwd; if cwd equals `$HOME` → no ROOT, exit 0 silently.

5.1 **SessionStart** (`project-map-session.sh`). If `PM/` has neither `current` nor a legacy
`state.json` → exit 0 silently. Else run `facts.py ROOT --budget 10 --no-stage` (total wall budget 10 s;
git calls inside get 5 s each). Injected `additionalContext` by verdict:
- `NO_CHANGE` / `NEEDS_REFRESH`: the brief, then `map: ROOT/.project-map/index.html · /project-map re-judges`;
- `NEEDS_JUDGEMENT` / `NEEDS_FULL`: the brief (its line 2 shows `assessment <time> · N commits
  since`), then `map is behind: <why>; run /project-map` (migration: `map needs migration to 3.2:
  run /project-map`);
- `REFRESH_FAILED` / `ERROR`: `project-map: <verdict line>; run /project-map`.
Invalid or missing brief → one line `project-map: brief unreadable; run /project-map`. Output
`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}`. No model
call; about 300 context tokens.

5.2 **UserPromptSubmit** (`project-map-prompt.sh`). ROOT as 5.0; if `PM/current` is missing →
exit 0. Compute `shasum` of `PLUGIN/scripts/project-map-template.html` and `project-map-embed.py`
(< 50 ms). If both equal `cache.json.ack_hashes` → exit 0 silently. Else run
`embed.sh ROOT --mechanical --deadline 3.5` directly (never facts, so no spawn regardless
of the key; ROOT discovery is inside the deadline): on `PM_EMBED_OK` write the new hashes to
`cache.json.ack_hashes` and inject `project-map: map re-rendered after a plugin update`; on
SUPERSEDED, deadline or any other failure inject `project-map: <output line>` and do NOT
acknowledge the hashes (retry on a later prompt, at most once per 10 min via
`cache.json.ack_attempt_at`).

## 6. Schemas (R = required, O = optional; strings are UTF-8, limits in bytes)

6.1 `snapshot.json` (script-owned; cap: none):
`schema:"project-map-snapshot-1"` R; `generation` R (staging: the invocation id, published: the gen name);
`base` R (gen name|null); `root` R; `facts_at` R iso; `repos[]` R `{path, vcs:"git"|"none", head|null,
branch|null, head_at|null, rewritten:bool, commits:int}`; `commits` R `{count, listed, flagged,
days[{day, n, items[{r, h, s<=60, f}]}]}`; `status` R `{hash, dirty:int, coverage:"complete"|"partial",
covered:int, total:int, git_error:string|null}`; `watch[]` R `{path, kind:"file"|"dir", hash, n}`;
`ledger` R (`{path, name, goal, now, next, blockers, hash}`|null); `answers` R `{total, applied,
applied_hash, pending[], bad[]}`; `decisions[]` R (script lifecycle view); `usage` R; `key` R;
`prev_key` R; `template_hash`, `embed_hash` R.
`cache.json` (mutable): `{watch_cache:{abs_path:{dev, ino, size, mtime_ns, ctime_ns, sha256}},
ack_hashes:{template, embed}, ack_attempt_at, coverage_cursor}`. Directory hash = sha256 over
the sorted list of `(relative path, file sha256)` for every regular file under the directory,
including untracked and ignored files, excluding `.git` directories and `.project-map`.

6.2 `pack.json` (model-facing, <= 8192 bytes): snapshot fields where EVERY unbounded field is
trimmed in this order until it fits, each with an explicit marker in `trimmed`:
`commits.days[].items` (keep flagged first), `watch` (paths only, hash dropped), `ledger`
(each of goal/now/next/blockers cut to 200 bytes), `answers.pending[]` (notes cut to 120 bytes,
then entries dropped), `decisions[]` (q cut to 140, options labels to 60), `usage.by_model`.
`trimmed` = `{items:N, watch:N, ledger:bool, answers:N, decisions:N, usage:bool}`. Keys
replaced by `key_digest`/`prev_key_digest`; no cache. Complete data stays in `snapshot.json`.

6.3 `plan.json` / `plan.out.json` (`schema:"project-map-plan-1"`): `generation` R; `origin` R
`"proposed"|"owner"`; `phases[]` R, 1..7 items: `{id R ^P[1-9]$ unique, label R <=60, criteria[]
R 0..8: {id R ^P[1-9]\.c[1-8]$ unique, text R <=80, done R bool, ref O "file:<rel>[:line]"|"commit:<sha7+>"|null}}`.
`done:true` requires a `ref` that resolves (§6.4 rules). Phase `state` is DERIVED by embed:
`done` iff every criterion done (and >= 1 criterion); `current` = `judgement.current_phase` if
not done, else the first non-done phase; `next` = the phase after current; `later` = the rest;
phases before current that are not done are `current`-blocking and listed in the headline note.

6.4 `judgement.out.json` (model-owned; target 3072, hard 6144 bytes):
`generation` R (= invocation id); `project` R `{name R <=40, tagline O <=80, goal R <=160,
ledger O path|null}`; `run` R `{type:"UPDATE"|"FULL", model}`; `watch[]` O (<= 40 unique entries,
relative paths; never `.`, `..`, absolute, a `.project-map` or `.git` component, `.env*` or any
secret-pattern name); `repos[]` O; `headline` R `{text <=180, tone:"ok"|"watch"|"blocked"|"stale"}`;
`parts[]` R 1..12 `{id ^[a-z][a-z0-9-]{1,23}$ unique, label <=40, status:"done"|"in_progress"|"stuck"|"unknown",
line <=100, ref (required when status=done), blocked_by O part id (required when stuck)}`;
`current_phase` R phase id; `criteria_updates[]` O `{id, done, ref}` (any phase);
`eta` O `{low R int>=0, high R int>=low, unit:"days"|"weeks", basis R <=80, confidence:"low"|"med"|"high"}`|null;
`next_step` R `{title <=80, why <=160, actor:"claude"|"codex"|"owner"|"external", unblocks[] part ids}`;
`decisions[]` O <= 6 `{id ^D-\d{3}$, q <=140, options[] 2..5 {id ^[A-E]$ unique, label <=60},
recommended option id|null, default option id|"hold", hard_rule string|null, deadline iso|null,
ready bool}`; `loops[]` O; `risks[]` O <= 4 `{id, text <=120, severity:"low"|"med"|"high"}`;
`template_feedback[]` O <= 5 `{where <=40, text <=160}`; `loops[]` O <= 4 `{id ^L-\d{2}$ unique,
kind:"review"|"retry"|"wait", rounds int>=0, failed int>=0, note <=100}` (a loop warns only when
`failed > 0`). Rules enforced by embed: unknown keys anywhere → reject; all ids unique within
their list; `decisions[].id` unique and never a retired id; `criteria_updates[].id` must exist in
the carried `plan.json` (or in `plan.out.json` on FULL) and a criterion id must belong to its
containing phase (`P2.c3` only under `P2`); `file:` line numbers are positive integers;
`hard_rule` non-null or `ready:false` → `default` must be `"hold"`; decision freezing: a
decision whose script lifecycle status is `answered` or `defaulted` is FROZEN (model text
ignored, script copy kept); `open` and `overdue` decisions are editable by the model (an
`overdue` hard-rule decision stays `hold`); `answer`/`answered_by`/`status` on decisions are
script-owned (model-supplied values rejected); numbers must be finite
(`parse_constant` rejects NaN/Infinity; dump with `allow_nan=False`); every model string is free
of C0 control characters, U+0085, U+2028/U+2029, zero-width characters (U+200B-U+200F, U+FEFF)
and bidi overrides (U+202A-U+202E, U+2066-U+2069); every string in
judgement.out.json and plan.out.json is scanned for secret-looking tokens (AWS `AKIA|ASIA` ids,
`sk-…`, `sk_live_`/`sk_test_`, `AIza…`, `github_pat_`, `gh[opsu]_`, `glpat-`, `npm_`, `hf_`,
`xox[abprs]-`, JWTs, `-----BEGIN … PRIVATE KEY`, `Bearer …`, `password=`, credentialed URLs), rejected with the field path; `commit:` refs must resolve
(`cat-file -e`) in a known repo; `file:` refs must be regular files under ROOT, not under
`.project-map/`, with `line <= line count` when given; retired ids may not be reused.

6.5 `state.json` (`schema:"project-map-4"`): `generation` R; `base` R; `generation_files[]` R;
`identity` R `{name, folder (~-shortened realpath), branch, head, snapshot_at, generation}`;
`phases[]` R (plan + updates + derived state, with `done/total` per phase); `headline` R;
`focus` R `{phase, done, total, next_step}`; `decisions[]`; `parts[]`; `changes[]`; `risks[]`;
`history[]` (<= 10); `usage`; `stale` (`{judged_at, commits_since, why}`|null); `coverage`;
`template_hash`; `embed_hash`.

6.6 `brief.txt` (<= 1000 bytes including the final newline; lines added in this priority until
the cap, never cut mid-line): 1 `<name> · <~/folder> · phase <k>/<n> <label> · <tone>`;
2 `assessment <iso minute> · current` or `· <N> commits since`; 3 headline; 4.. one line per
needs-you decision (`D-004 needs you: <q> (default <d>, by <deadline>)`), then `+N more decisions`;
next step; stale/coverage note; `tokens ...` (dropped first); last line `generation <seq>-<id>`.

6.7 `answers.jsonl`: one object per line `{"id":"D-004","answer":"A"|"hold","at":iso,"by":"owner","note": O string <= 16384}`;
closed key set, `by` must be `owner`, other lines count as `bad`.
`applied_hash` = sha256 of the first `applied` lines as bytes. If the stored prefix hash does not
match the file → `ERROR answers rewritten` with the recovery line `run: python3
PLUGIN/scripts/project-map-facts.py --accept-answers ROOT` (main session only, §4.2a): it replays
the whole file from scratch against the current decisions and re-baselines the hash.

## 7. Git

7.1 **Core** (`scripts/pm_git.py`, used by facts, embed, hooks and pm-git.sh): argv =
`git -C <repo> --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null
-c core.pager=cat -c diff.external= -c core.sshCommand=false <sub> <args>`; env =
`GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_EXTERNAL_DIFF=
GIT_PAGER=cat`, all `GIT_*` from the caller removed; timeout per call (default 20 s; hooks 5 s);
bytes decoded `errors="replace"`. Result: `(rc, out)`; `rc != 0` is a *collection failure*
(`git_error`) except where a non-zero exit is the documented answer (`cat-file -e`,
`merge-base --is-ancestor`), which is *missing evidence*. Internal grammar:
- `status --porcelain=v1 -z --untracked-files=all`
- `log --format=%x1e%H%x1f%ct%x1f%s -n <N<=200> [--since=<iso>] [-- <relpath>...]`
- `ls-files -s -z [-- <relpath>...]`, `rev-parse [--show-toplevel|--abbrev-ref HEAD|HEAD|<sha>^{commit}]`
- `rev-list --count <A>..<B>`, `merge-base --is-ancestor <A> <B>`, `cat-file -e|-t <sha>`
- `diff --stat --no-ext-diff --no-textconv <A> <B> [-- <relpath>...]`, `branch --show-current`, `tag --list`
  where `<A>`, `<B>`, `<sha>` match `^[0-9a-f]{7,40}$` or `HEAD`, relpaths contain no `..`.

7.2 **Agent wrapper** (`scripts/pm-git.sh ROOT <sub> [flags]`, exec's the core with the agent
grammar; ROOT is the bound root or `<bound root>/<path>` for a `path` listed in the script-owned
`STAGE/snapshot.json` `repos[]`, realpath under the bound root): `status` → `status --porcelain=v1`; `log [-n N]` (N <= 60, default 20) → the fixed
format `%h %ad %s` with `--date=short`; `rev-parse` → `rev-parse HEAD`; `branch` → `branch
--list`; `ls-files [relpath]`; `tag` → `tag --list`. Any other word, flag or environment override
→ exit 2 with `pm-git: not allowed`.

## 8. Skill flow (`/project-map [ROOT]`)

0. Preflight (main session, no spawn yet): ROOT = argument else `rev-parse --show-toplevel`
   else cwd; realpath; not `$HOME`; under `~/projects`, `~/Desktop`, `~/thoughts` or a Claude
   scratchpad (`/private/tmp/claude-*/` or `$TMPDIR/claude-*`); no spaces, `[`, `]`; `python3 >= 3.9`,
   `jq`, `git` present (non-git ROOT allowed, said so); `PM/` creatable or writable; Chrome optional.
   One sentence on failure, stop.
1. `python3 PLUGIN/scripts/project-map-facts.py ROOT` → verdict (§2); binds ROOT (§4.2a) and,
   for spawning verdicts, creates `inv-<id>`.
2. Spawn only on `NEEDS_JUDGEMENT` (sonnet) / `NEEDS_FULL` (opus; say "one Opus run, about
   $0.5" first). Prompt lines 1-3 exactly: `ROOT: <ROOT>`, `INV: inv-<id>`, `RUN: UPDATE|FULL`.
   Unknown agent type → "run /reload-plugins". Spawn denied → print the guard's reason.
3. Agent budget: Read `STAGE/pack.json`, Read `STAGE/judgement.in.json` (FULL: + `plan.json`),
   Write `judgement.out.json` (FULL: + `plan.out.json`), `embed.sh ROOT inv-<id>` = 4 (FULL 5);
   plus two Edit + embed retries → 8 max (FULL: 30, `maxTurns` 32).
4. Replies: `DONE gen <seq>-<id>` → print `PM/current/brief.txt`; `DONE (stale)` → say the repo
   moved during judgement; `SUPERSEDED` → rerun step 1 once; `PARTIAL <deny text>` → report;
   `NEED_FULL` → FULL branch. The agent never reads or prints the brief.
5. `ASK:` lines → one question each (recommended first, default and deadline, hard rule "waits
   until you answer"); answers appended to `answers.jsonl`; rerun from step 1.
6. Recovery lines the skill may print: `--close-session ROOT` (uncertain agent termination; then
   "start a new Claude Code session"), `--accept-answers ROOT` (§6.7).

## 9. Test map (every audit reproduction is a named case; suites: `tests/test_guard.sh`, `tests/test_embed.sh`, `tests/test_hooks.sh`)

| Source | Case id | Expectation |
|---|---|---|
| Sec 1 | G-pad | 40 KB padded `cat ~/.ssh/id_ed25519` denied in < 1 s |
| Sec 2, Codex S1/S2 | G-git-raw, E-git-helpers | raw `git` denied; a repo with fsmonitor, textconv, external diff, pager and hook helpers configured: no helper executes through pm-git or the core; `show` absent |
| Sec 3/4/5 | G-read-scope, G-symlink, G-grep | Reads of `~/.claude.json`, `.zsh_history`, `/etc/passwd` denied; symlink to `.env` denied; Grep/Glob denied; `cat .git/config` denied |
| Sec 6, Codex S3 | G-bind-* | cross-project write denied; A's first op on bound B denied; second concurrent spawn denied; failed spawn (matching id) then retry ok; non-matching failure id leaves pending; close-session then spawn denied and delayed claim denied; hard-link target denied; no pending → all denied |
| Cor 1, Codex C3 | E-watch-40, E-watch-41, E-watch-long | 40 watch entries with long paths publish and the next facts prints a verdict; 41 entries rejected at validation; 125 watched paths rejected with the message |
| Codex C3 (answers) | E-answer-12k | `answers.jsonl` entry with a 12 KB `note` (schema-valid optional field, <= 16 KB, stored verbatim in snapshot): facts verdict printed, embed completes, note cut to 120 bytes in the pack with `trimmed.answers` set |
| Cor 2, plan D2 | F-coverage, F-ctime | non-git folder over the budget → `NEEDS_REFRESH coverage partial`, no spawn, completes next run; same-size edit with restored mtime on a watched file flips the key |
| Cor 3 | E-brief-6 | 6 decisions → <= 1000 bytes, no mid-line cut, `+N more` |
| Cor 4, Codex C11 | F-answers-rewritten | edited prefix → ERROR; `--accept-answers` recovers |
| Cor 5/6 | F-log-n, F-log-at | 60 commits → count <= 40; `@@` subject intact |
| Cor 7 | F-ledger-name | basename match wins over mtime |
| Cor 8-13, Codex C5/C6/C7/C9 | E-types | eta missing/NaN, `ready:"false"`, option without id, `file:.`, `file:README.md:999999`, `commit:HEAD` rejected; state `[]` → `NEEDS_FULL invalid state` |
| Cor 12 | F-refacts | second facts run between judgement and embed does not force a re-judge |
| Codex C1 | E-crash-* | kill at each boundary (tmp dir, manifest, rename, symlink): `current` complete, mixed generation never observed |
| Codex C2 | E-lock-live | live holder → second embed fails; dead holder → proceeds |
| Codex C4 | F-git-broken | broken index → ERROR |
| Codex C8 | F-refresh-failed | failed re-render → REFRESH_FAILED exit 3 |
| Plan D10 | E-superseded | A on base 5, B publishes 6, answer recorded, A → SUPERSEDED, 6 and the answer stay |
| Codex D1 | S-preflight-* | unsupported location, `$HOME`, space in path, missing jq → one sentence, no spawn |
| Plan A1/A3 | H-session, H-prompt | `claude -p`: brief injected, no model call; template change → one re-render line, acknowledged only after PM_EMBED_OK |
| 1.5 | E-migrate | legacy 3.x map → NEEDS_FULL migrate; ids, ledger, frozen decisions kept; legacy files removed only after the switch |
| 1.2 | F-sweep, E-stage-retain | abandoned staging swept; active staging kept; after a successful FULL publish the screenshots still read STAGE and a post-success embed retry returns SUPERSEDED; after a failed publish an Edit+embed retry publishes; a terminal binding denies further calls and frees STAGE |
| 4.3 | G-bind-terminal | terminal A calls again while B is pending → denied, B's pending untouched |
| 4.2 | G-bind-sessions | a second session's agent cannot claim or read the first session's pending/roots/closed; closure in one session does not close another |
| 4.2b | G-spawn-bg | spawn with run_in_background, a resume field, or no RUN line → denied |
| 4.2c/d | G-spawn-async | background launch: PostToolUse `async_launched` keeps the pending record stamped for the launched agent; another agent cannot claim it; SubagentStop retires the claimed binding or the unclaimed record; stamped/launched id mismatch retires it; a pending record older than 10 min no longer blocks a spawn; the foreground path (text `tool_response`) still releases at once |
| 3 | G-bind-oversized | A pending, 70 KB padded spawn of B → denied (fail closed), B cannot claim A |
| 2.1 | H-prompt-deadline | mechanical embed over its 3.5 s deadline → `PM_EMBED_ERROR deadline`, hashes not acknowledged |
