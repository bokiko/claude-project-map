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
    judgement.json  the ACCEPTED judgement (next invocation stages it as judgement.in.json, minus decisions retired since: 12.8)
    invocation/     copy of the staging dir that produced this generation (audit trail), or absent
                    for a mechanical re-render
    legacy/         (migration generation only) the 3.x files, copied, never moved
  inv-<id8>/                          STAGING for one invocation; never `current`; see 1.2
    invocation.json {"id","created_at","base":"<seq>-<id>"|null,"root","session_id"|null}
    snapshot.json, pack.json, plan.json (carried forward), judgement.in.json (frozen input)
    judgement.out.json, plan.out.json   agent output (written by the agent, section 4.3)
    claimed         written by the guard on claim (empty file); released  written on spawn result
  cache.json      script-owned mutable: watch_cache (6.1), acknowledged plugin hashes (5.2)
  (no usage files here: the usage scan's cache is private and lives outside the project, 11.1; a legacy usage-cache.json / usage-last.json
   found here is deleted by facts and by the usage script)
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

1.3b **Signed generations.** A per-user random key lives at `~/.claude/agent-memory/project-map/key` (0600; the guard denies the agent
any read of it). 3.3.0: this is the ONLY location; it no longer depends on `CLAUDE_PLUGIN_DATA`, which hooks get
and the skill's Bash calls do not (two keys made hooks reject every map). **Legacy recovery** (authenticated, narrow): a generation
that fails verification with the canonical key is re-checked with the pre-3.3.0 key `$CLAUDE_PLUGIN_DATA/key` only when that
variable is set, the file exists and its directory differs from the canonical one; if that key authenticates the manifest HMAC and
every listed file matches its size and sha256, the manifest is re-signed with the canonical key (an existing canonical key is never
replaced; a missing one is created), and the adoption-record lookup also falls back to `$CLAUDE_PLUGIN_DATA/published/`. An unsigned
or wrongly signed map, a tampered file, or no legacy key means no recovery. Recovery therefore happens the first time a hook
(which has DATA) sees the map; a skill run before that sees the old map as unverified. Embed records every
publish in `<key dir>/published/<sha256(realpath root)>` = `{root, generation, at}`. When the key is
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

Embed prints `PM_EMBED_OK gen <seq>-<id> <bytes>` (exit 0; optionally followed by a `PM_EMBED_STALE <why>` line and, 3.3.0, by
`PM_EMBED_NOTE <text>` lines, section 12.5), `SUPERSEDED ...` (exit 4) or `PM_EMBED_ERROR <why>` (exit 1; nothing replaced).

2.1 **Mechanical embed** (`embed.sh ROOT --mechanical [--deadline S]`): no invocation argument.
It pins `current` once, takes `judgement.json`, `plan.json` and the assessment time from that
generation unchanged, collects only mechanical inputs (status signature, usage, template/embed
hashes, answers lifecycle), then publishes a new generation with `base` = the pinned generation
under the same base check (SUPERSEDED exit 4 if `current` moved meanwhile). It also drops the pinned generation's closed decisions
(answered, defaulted, overtaken) and tombstones their ids: a closed decision is shown for one published generation (section 12.8). `--deadline S` is a
TOTAL wall budget covering ROOT discovery, git calls and rendering, checked between steps and
immediately before the pointer switch (a single stalled step cannot be interrupted); on expiry it
prints `PM_EMBED_ERROR deadline` (exit 1) with nothing replaced. The prompt hook calls it with
`--deadline 3.5`; facts calls it with `--deadline 8` for `NEEDS_REFRESH`.
Usage never decides whether the refresh succeeds (11.3): it gets what is left of the deadline minus a render margin, and a
timeout keeps the previous numbers.

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
then entries dropped), `decisions[]` (q cut to 140, options labels to 60; open decisions with a `resolves_when` carry the script's `resolved: true|false`,
12.3), `usage.by_model`.
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
ready bool, resolves_when O (3.3.0, only when the decision is raised: 1-3 closure predicates, section 12.1),
overtaken O `{why <=120, ref O}` (section 12.2)}`; `loops[]` O; `risks[]` O <= 4 `{id, text <=120, severity:"low"|"med"|"high"}`;
`template_feedback[]` O <= 5 `{where <=40, text <=160}`; `loops[]` O <= 4 `{id ^L-\d{2}$ unique,
kind:"review"|"retry"|"wait", rounds int>=0, failed int>=0, note <=100}` (a loop warns only when
`failed > 0`). Rules enforced by embed: unknown keys anywhere → reject; all ids unique within
their list; `decisions[].id` unique and never a retired id; `criteria_updates[].id` must exist in
the carried `plan.json` (or in `plan.out.json` on FULL) and a criterion id must belong to its
containing phase (`P2.c3` only under `P2`); `file:` line numbers are positive integers;
`hard_rule` non-null or `ready:false` → `default` must be `"hold"`; decision freezing: a
decision whose script lifecycle status is `answered` or `defaulted` is FROZEN (model text
ignored, script copy kept); `open` and `overdue` decisions are editable by the model (an
`overdue` hard-rule decision stays `hold`); `answer`/`answered_by`/`status` (and 3.3.0:
`closed_by`/`closed_at`/`overtaken_why`/`overtaken_ref`) on decisions are
script-owned (model-supplied values rejected); a decision whose script status is `overtaken`
is frozen the same way (section 12.4: it lives for one generation and cannot be reopened under
its id; `resolves_when` is script-owned once raised, 12.1; retired decision ids are tombstoned for good, 12.7); an open or overdue decision in the staged snapshot may not be omitted from
`decisions[]` (3.3.0, section 12); numbers must be finite
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
`history[]` (<= 10); `usage` (the usage collector's `snapshot_for_state`; `stale: true` when the numbers are the previous ones, `at` is then
the time they were measured, 11.3); `stale` (`{judged_at, commits_since, why}`|null); `coverage`;
`template_hash`; `embed_hash`; `retired_ids[]` (the last 200 retired part and decision ids); 3.3.0 `retired_decisions` (the
permanent decision tombstones, a compact range string, section 12.7).

6.6 `brief.txt` (<= 1000 bytes including the final newline; lines added in this priority until
the cap, never cut mid-line): 1 `<name> · <~/folder> · phase <k>/<n> <label> · <tone>`;
2 `assessment <iso minute> · current` or `· <N> commits since`; 3 headline; 4.. one line per
needs-you decision (`D-004 needs you: <q> (default <d>, by <deadline>)`), then `+N more decisions`;
next step; (3.3.0) one `D-001 overtaken by events: <why> (<ref>)` line per decision closed by events in this generation, placed
with the decisions block, ranked just below the next step, never counted as needs-you; stale/coverage note; `tokens ...` (dropped first); last line `generation <seq>-<id>`.

6.7 `answers.jsonl`: one object per line `{"id":"D-004","answer":"A"|"hold","at":iso,"by":"owner","note": O string <= 16384}`;
closed key set, `by` must be `owner`, other lines count as `bad`.
`applied_hash` = sha256 of the first `applied` lines as bytes. If the stored prefix hash does not
match the file → `ERROR answers rewritten` with the recovery line `run: python3
PLUGIN/scripts/project-map-facts.py --accept-answers ROOT` (main session only, §4.2a): it replays
the whole file from scratch against the current decisions and re-baselines the hash.
Only COMPLETE lines (terminated by `\n`) are read, counted, hashed and applied, by facts and by embed alike: an unterminated tail is a
record the owner's tool is still appending. It stays pending (not applied, not `bad`, not in `answers_count`, and never inside
`applied_hash`), and once its newline arrives it is an ordinary append, never "answers rewritten". A missing file is empty; a file that
cannot be read is an error (`ERROR answers.jsonl cannot be read ...` / `PM_EMBED_ERROR ...`), never an empty file.
When the file ends in non-blank bytes without a newline, the facts verdict line carries the warning
`(warning: answers.jsonl has an uncommitted last line)` (just before `inv <id>`); the bytes themselves stay unread. A closure by events
published while such a tail exists is deferred (12.5).

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
- 3.3.0 release-fact tuples (exact argv only, script-internal; see section 10): `rev-parse --verify --end-of-options HEAD^{commit}`,
  `rev-parse --verify --end-of-options <literal ref>^{commit}` (the branch's configured upstream, `refs/remotes/...` or `refs/heads/...`
  with the same ref-grammar checks, no arbitrary revision), `rev-parse --is-shallow-repository`, `symbolic-ref --quiet HEAD`,
  four `for-each-ref` forms (head tags, five recent tags, branch upstream metadata, existence/type of ONE literal ref),
  `rev-list --left-right --count <oid>...<oid>`. The head-tag listing is streamed (`pm_git.stream_lines`), not buffered.

7.2 **Agent wrapper** (`scripts/pm-git.sh ROOT <sub> [flags]`, exec's the core with the agent
grammar; ROOT is the bound root or `<bound root>/<path>` for a `path` listed in the script-owned
`STAGE/snapshot.json` `repos[]`, realpath under the bound root): `status` → `status --porcelain=v1`; `log [-n N]` (N <= 60, default 20) → the fixed
format `%h %ad %s` with `--date=short`; `rev-parse` → `rev-parse HEAD`; `branch` → `branch
--list`; `ls-files [relpath]`; `tag` → `tag --list`. Any other word, flag or environment override
→ exit 2 with `pm-git: not allowed`.

## 8. Skill flow (`/project-map [ROOT]`)

0. Preflight (main session, no spawn yet): ROOT = argument else `rev-parse --show-toplevel`
   else cwd; realpath; not `$HOME`; inside `$HOME` but not a hidden top-level folder or `~/Library` (3.2.3), or a Claude
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
| 11 | U-* (`tests/test_usage.sh`) | incremental totals equal a full rescan after appends, repeated ids, new/deleted/truncated/rewritten files, an unterminated last line, attribution changes, subagent inheritance and cache damage; a warm run reads 0 bytes; a budgeted run returns the previous totals as `partial` and resumes; U330-1 (private location, counters-only output, legacy files swept), U330-2 (middle edits, fixed totals), U330-3 (a gated concurrent rewrite is never cached), U330-4 (cap: completed files evicted first, unfinished never, budgeted runs finish), U330-5 (planted symlink / 0644 temp file), U330-6 (the last chunk cannot overrun the budget), U330-R2-2 (resumable prefix verification converges over budgeted runs, rewrites still found), U330-R2-3 (folded bucket and cursor: 20 files, forced whole-file eviction, ~3 files per run, exact 220), U330-R3-1..3 (foreign transcripts fold with zero rows and converge; rename-over with restored mtime re-read; key collision re-reads), U330-R4-1..2 (in-place rewrite with restored mtime detected via ctime; cache pressure reported) |
| 11.3 | U33-mech, U33-mech35, U33-resume, U33-crash, U33-facts, U33-none | a slow or failing usage scan never fails a mechanical refresh (1.2 s and 3.5 s deadlines) or a facts verdict; the previous numbers are kept with `stale` and their original as-of time, shown as "usage as of" in brief and page; the scan completes over several budgeted runs; U330-1 (embed/facts: no transcript-derived text in state, pack, page or brief; legacy files swept) |

## 10. 3.3.0: the map sees tags and pushes (release facts)

Problem: after a release was committed, tagged and pushed, the map still said "next: tag and push", because the facts never
carried tags or branch sync. Everything below is local evidence only: no fetch, no ls-remote, no `gh`, no network, no assumption
about tag naming, remote name, default branch or SemVer. SHA-1 object ids only (40 lowercase hex); other object formats give no
release facts.

10.1 **Collection** (`pm_collect.collect_release`, once per Git toplevel per run). Per repository row, `repos[].release`:
`{shared, head_oid, head_tags[{name,kind}], head_tags_total, recent_tags[{name,kind,at}], sync{branch_ref, upstream_ref,
upstream_kind: remote|local, state, ahead, behind}, shallow, key, line}`; `inconsistent: true` when HEAD, the branch or its upstream kept moving during the read (see 10.8).
Display safety: every tag, branch and upstream name in `release`, `repos[].branch` and the key goes through `pm_common.display_safe`
(control, bidi, zero-width and line-separator characters become visible `\uXXXX` escapes; a name matching the secret detectors becomes
`[redacted]`; ordinary Unicode and a literal `%` stay). The key uses `ref_ident` (the display form plus a hash of the raw name when it
differs), so two hostile names never collide and none reaches pack, brief, state or HTML raw.
- `head_oid`: pinned full repository HEAD (`null` on an unborn branch, and `null` when HEAD could not be verified, see 10.8). It is
  re-read after the other refs; a move means one re-read (two at most). If the re-reads are exhausted, `sync.state = unknown`; the tag
  set is kept only when the last HEAD read verified the pinned oid unchanged, otherwise `head_oid`, `head_tags` and `head_tags_total`
  are `null` and tag coverage is unknown (never "no tags").
- `head_tags`: ordinary tags that point at the pinned HEAD (`for-each-ref --points-at`); `kind` is `lightweight` or `annotated`
  (`*objectname` peeled). Tags of non-commit objects and nested tag-of-tag objects are not head tags (the nested case is not covered). The listing is streamed
and the COMPLETE set is counted and hashed (`head_tags_total`, key); only `head_tags` (display) is capped at 20. Past 20000 rows
(or `PM_MAX_TAG_ROWS`) the read stops: `head_tags_partial: true`, `key.partial: true`, the count is a lower bound and the release
line says "tag list incomplete" (a partial key never yields a bare "complete" claim; see 10.2 for what it does to change detection).
  `recent_tags`: the five newest by creatordate with refname as tie-break; display only (a lightweight tag's date is its target's).
- `sync.state`: `aligned | ahead | behind | diverged | no_upstream | missing_upstream | detached | unborn | unknown`. `ahead`/`behind`
  come from one `rev-list --left-right --count <HEAD oid>...<upstream commit oid>` and are `null` when not computed, never an
  invented 0. `no_upstream` = no configured upstream; `missing_upstream` = configured, and a literal existence query
  (`for-each-ref` on that exact ref) shows the ref genuinely absent; `unborn` = HEAD attached to a branch whose ref genuinely does not
  exist. A rev-parse failure alone (rc 1/128) is never evidence: an upstream ref that exists but is not a commit (a tree), a ref to
  an absent object, or an unreadable query give `unknown` with null counts. The configured upstream is pinned as the LITERAL ref from
  the branch metadata and that ref is what gets resolved; symbolic HEAD, the upstream config and the upstream oid are re-read at the end
  and a mismatch (even between two branches at the same commit) means a re-read, then `unknown`/`inconsistent`. The re-read keeps query
  success separate from absence: only a successful query documents "absent" (detached `symbolic-ref` rc 1, no upstream configured,
  and, for a failed `rev-parse` of HEAD or of the upstream ref, an exact `for-each-ref` existence/type query that succeeds with no row).
  Round 3: that rc 1/128 of the FINAL `rev-parse` is not evidence either. It goes through the same existence/type query as the first
  read, and the answer is part of the pin (`absent | commit | other | broken`): `broken` is the query itself failing with rc 1/128 (a
  ref to a missing object), `other` a ref that exists but is not a commit, a timeout is `error` = unverified and never equals an
  earlier answer. A transition such as absent -> tree, absent -> missing object or unborn -> broken branch ref during the final read is
  therefore a mismatch (re-read, then coherent `unknown`, or `unknown`/`inconsistent` if it keeps flipping), never `missing_upstream`
  or `unborn`; a stable malformed ref is a coherent `unknown` (not inconsistent). A timeout or error on any final read (HEAD, symbolic
  HEAD, upstream metadata, upstream oid, existence query) is "unverified", handled like a move: re-read at most twice, then
  `unknown`/`inconsistent` -- never a silent `no_upstream`, `detached` or `missing_upstream`.
  A timeout, an unreadable ref or a failed count gives `unknown`; a failing tag listing is a collection failure (`git_error`).
  Shallow repositories set `shallow: true` (counts may be incomplete).
- Sub-folder ROOT of a larger repository: the toplevel's facts, `shared: true`, line prefixed `shared repo:`. A nested standalone
  repository (own `.git`) has its own facts.
- `line`: the one script-owned sentence, at most 200 bytes, e.g. `tagged v3.2.3 at HEAD · in sync with origin/main (local tracking
  state)`, `no tag at HEAD · 3 commits ahead of origin/main`, `no tag at HEAD · no upstream`. It never says "released" or "pushed".

10.2 **Change key.** `key.release = {repo path: {tags: sha12 of the sorted head-tag (name, tag oid, commit) tuples, n, upstream, state,
ahead}}`. Not in the key: `behind`, `recent_tags`, timestamps, remote URLs. In a shared repository `ahead` counts only as `> 0`.
`compare_keys`: a judged key without `release` (any map judged before 3.3.0) is `moved` ("tags and branch sync not yet judged") and
stays so until one judgement stores the new key (exactly one re-judgement); otherwise a different entry gives "tags changed" and/or
"branch sync changed", also when `commits_since` is 0. `release` is a GIT key (NEEDS_JUDGEMENT even under partial coverage).
Partial tag sets (round 2): the entry includes `n` and `partial`, so a change of prefix digest, count, sync or coverage (complete ->
partial, partial -> complete) is a move ("tag list too large to verify", "tag count or coverage changed"). An UNCHANGED partial entry
(equal to the judged one) is NOT a move: `compare_keys` returns it in `incomplete: [paths]` (script-owned coverage warning, independent
of `moved`), `facts` does not call the model, and the lifecycle is facts -> UPDATE -> one `NEEDS_REFRESH stale cleared` -> `NO_CHANGE`
forever. `NO_CHANGE` for such a map reads `nothing moved (tag list incomplete: too many tags at HEAD to verify)`, the release line in
brief, state and page keeps "tag list incomplete". Tags beyond the retained prefix stay unobservable by design; the warning says so.
`state.schema` stays `project-map-4`: `repos[].release` and `judged_key.release` are additive.

10.3 **Display facts vs judgement.** A change in anything the page shows but the key ignores (behind count, recent tags, HEAD oid
of a non-shared repo) gives `NEEDS_REFRESH release facts changed`: one mechanical render that updates `state.repos[].release` and
leaves `judged_key`, `judged_at` and `stale` untouched, so the next run is `NO_CHANGE` (no loop). For a shared repository only
`release.key` is compared, so a parent-only commit stays invisible.

10.4 **Pack and brief.** Pack: `repos[].release_line` is reserved ahead of the optional details; the trim order starts with
`release.recent_tags`, drops the rest of `release` before any repo is cut, and the line survives to the last step. Brief: one
`git: <line>` line after the headline, ranked below decisions and the next step and above stale/coverage/tokens (dropped, whole,
when it does not fit in 1000 bytes). Page: `#release-line` under the folder line and a "Tags and sync (local git)" snapshot row,
both through `textContent`.

10.5 **Publish recheck.** `light_stale` (embed, normal mode) re-collects release facts next to HEAD; if the key entry moved while
the judgement was being written the map is published with `stale = {why: "tags changed" | "branch sync changed" | "N new commits"
(joined with " and ")}` and `PM_EMBED_STALE`; the next run re-judges. A PARTIAL recheck (`key.partial` now) independently adds
"tag list too large to verify (unverified)" whatever else is equal, and a changed count or coverage (complete -> partial included)
adds "tag count or coverage changed (unverified)". Round 3: ANY inconsistent recheck (`inconsistent: true`, 10.8) independently adds
"tags and branch sync kept changing during the re-check (unverified)", also when its key equals the judged key, so an unverifiable
world is never published as current. In a sub-folder ROOT, `repos[].head` is the last PATH-SCOPED commit, so the
activity check uses the same path-scoped log (a parent-only commit is not activity) while the shared release key is compared
separately. The scoped check runs for every scoped git row, also when the judged scoped head is null (an empty package): empty scoped
history that now has commits is "N new commits" (stale); a shared repository without HEAD is skipped. A recheck that cannot be completed (collector failure, timeout, tag-list failure, or release facts that existed and are now
unavailable) is never "no change": the map is published flagged stale with "... could not be re-verified (unverified)" /
"... unavailable on re-check (unverified)", and the next run re-verifies (clears the flag with `NEEDS_REFRESH` if nothing moved, else
`NEEDS_JUDGEMENT`). An exhausted `--deadline` during the recheck is the ordinary `PM_EMBED_ERROR deadline` (nothing replaced).

10.6 **Agent.** `pm-git.sh` and the agent grammar are unchanged (the new tuples are refused there). The agent prompt gets one rule: use
`release_line`, drop "tag"/"push" steps the facts show done locally, keep remote publication, deployment and review unknown unless
evidenced.

10.7 **Signing-key recovery record (round 2).** `pm_common._legacy_recover` re-signs a legacy-authenticated manifest with the canonical
key, which changes the manifest bytes. After the re-signing it writes the canonical publish record
(`published/<sha256 of the root>`) of the OWNING root (`<root>/.project-map/gen-<id>`) with the final manifest hash, so a later loss of
the canonical key can still adopt the generation (`adoptable`). Never written for an unauthenticated map; a record that names a
different (newer) generation is left alone.

10.8 **Exhausted re-reads (round 3).** When HEAD, the branch or the upstream still differ after two re-reads, the result is
`inconsistent: true`, `sync` unknown with null counts, and `key.unverified: true`. Tag coverage is then UNKNOWN, never "no tag at
HEAD": if the last HEAD read verifies that HEAD still resolves to the pinned oid (only the branch or its upstream moved), the tag set
read for that oid stays (it is an independently verified fact); otherwise `head_oid`, `head_tags` and `head_tags_total` are `null`,
`key.tags` is `"unknown"`, and the line reads `tags unknown · sync unknown`. An UNCHANGED inconsistent entry is not a move
(`compare_keys` returns it in `unverified: [paths]`, independent of `moved`): `facts` returns `NEEDS_REFRESH stale cleared` once and
then `NO_CHANGE nothing moved (tags and branch sync unverified: refs kept moving during the read)`, no paid judgement; a changed entry
(race started or ended) re-judges as usual.

## 11. 3.3.0: usage collection is incremental and never fails a refresh

Problem (measured): `project-map-usage.py` walked and parsed every transcript under `~/.claude/projects` and `~/.codex/sessions`
on each collection (1.1 GB, 4-7 s for a heavy user). The prompt hook refreshes with `--deadline 3.5`, so for such a user every
refresh ended in `PM_EMBED_ERROR deadline`, usage was never stored, and the next refresh tried again; the skill's facts step paid
the full scan on every judgement. The release/tag collection (0.19 s) was not the cause.

11.1 **Incremental scan, private cache.** Transcripts hold conversation text and other projects' paths, and the map agent can read
everything under `PM/`, so NOTHING of the cache lives there. The cache is in the plugin's private directory
`~/.claude/agent-memory/project-map/usage/` (`pm_common.usage_private_dir()`, next to the signing key; mode 0700, must be a real directory
owned by the user, else the scan runs without a cache). The guard denies the map agent any read of `<memdir>/usage` and `<memdir>/usage/*`.
Two files per root, named by `sha256(realpath ROOT)`, each written by the usage script only, mode 0600:
- `<sha256>-cache.json`: `{key:{schema, root, since, claude dir, codex dir}, seq, files:{<transcript path>: entry}}`; a different key
  (another root, `--since`, schema) discards the whole cache. Written only when something changed. Atomic: `tempfile.mkstemp` in the same
  directory (random name, O_EXCL), `fchmod 0600`, write, fsync, `os.replace`; a pre-existing symlink or file at any predictable name is
  never followed or reused. Temp files of killed runs older than an hour are removed.
- `<sha256>-last.json`: the last COMPLETE result (key: root, since, max-jobs), small, rewritten on every complete scan so its as-of
  time is current even when nothing else changed.
- Entry: `sz`, `mt` (st_size, st_mtime_ns at the last visit); `off` (bytes committed = flag-scanned, always at a line boundary); `ph`
  (fingerprint of the committed prefix `[0, off)`: a chained sha256 over full 1 MB blocks, `cd = sha256(cd + sha256(block))`, plus a plain sha256 of the trailing partial block; extended chunk by chunk); `vf` (`{sn: [dev, ino, size, mtime_ns], vp, vd}`: the prefix verified so far, a block boundary and the chain digest there, valid only for that exact snapshot); `fl` (attribution evidence: cwd hit, any cwd, mention count,
  first-user-message `ROOT:` marker); `po`/`pk`/`st` (parse offset, parse kind `cwd`|`all`, resumable parse state: Claude `{cwd, title, seen:
  message id -> last usage row}`, Codex counters per turn; no Codex user text is kept); `md`, `jb`, `cnt`, `apx` (attribution mode and the
  finished job rows, valid when `ok`); `u` (1 while the transcript is unfinished: flags or parse behind); `sn` (the run sequence that last saw
  it, for least-recently-seen eviction).
- A transcript whose size and mtime_ns are unchanged is skipped (no read). One that grew has its whole old prefix fingerprinted (streamed)
  and compared with `ph`; the verification is RESUMABLE: every finished block saves `vf`, a run that runs out of budget leaves it, and the
  next run (same snapshot) continues at `vp`; a different snapshot starts over from byte 0, so progress made on one version of a file is
  never combined with bytes of another (U330-R2-2). Only the new bytes are parsed, the flags and parse state continue from the stored values. Anything
  else is re-read from byte 0: shorter than the committed prefix, SAME size with another mtime, the prefix hash differs, the cache entry
  does not fit the code, the attribution kind changed `cwd`<->`all`, the parse state was evicted. Deleted files drop out. A last line
  without newline is read tentatively on every scan (it counts like a full scan would count it) and is never committed; a half-written
  record fails to parse and is ignored until it is complete.
- Concurrent writers: the file's `(dev, ino, size, mtime_ns)` is taken before reading and compared after the read and parse. If it
  changed, the file's result is discarded for this run (the previous entry is kept, `scan.unstable` counts it, the run is `partial`),
  unless it is the same file that only grew and its committed prefix still hashes to `ph` (a live session being appended to). The hash
  and the offsets are computed from the bytes that were parsed, and the stored size/mtime are the ones taken BEFORE the read, so a rewrite
  that slips through is seen as a change on the next visit; bytes other than those parsed are never sealed.
- Exactness: totals are those of a full scan (`--cache none`); every file goes through the same code whether new or resumed, and a
  repeated message id keeps the last record. Rewrites are detected for any change in the committed prefix (not sampled), at the cost of
  reading the old prefix once per grown file.
- Cap: the serialized cache is at most ~24 MB (`PM_USAGE_CACHE_CAP` for tests). Over it, completed files lose their parse state, then
  are evicted whole, least recently seen first (`sn`). An evicted completed file (`u = 0`, nothing left to parse) is FOLDED, not forgotten:
  top-level `folded` maps `sha256(path)[:24]` to `{h: the rest of the digest, z: size, m: mtime_ns, i: [device, inode, ctime_ns], f: flags, k, d: mode, c, a, s, j: job rows (empty for a transcript excluded from the root)}`; the aggregate of a root
  is folded + live entries. A folded file whose `h`, size, mtime and identity are all unchanged is reused without being opened; any other state is read again
  from byte 0 (the record has no prefix fingerprint or parse state); a mode change (subagent inheritance) re-reads it too. Only when the
  folded bucket itself does not fit are its least recently seen records dropped. Top-level `cur` is the scan cursor `{c, x}` (Claude, Codex:
  `[phase, path]` where the last budgeted run stopped; phase 0 session, 1 subagent): the next run starts there, continues with the keys after
  it and wraps; a complete run clears it (U330-R2-3). An entry with `u = 1` (a transcript still being scanned) is NEVER evicted. When the
  unfinished entries alone exceed the cap, nothing is written (the previous file stays), `scan.cache_partial` is true and the answer of the
  run is unaffected. A cache file larger than the cap is ignored on load.
- Subagents: their cwd evidence is their own; inheritance needs the parent session's cwd hit (sessions are visited before subagents) or
  the `ROOT:` marker, and is re-evaluated on every scan, so a parent that becomes a hit later flips its subagents.
- **Output allowlist.** stdout, `<sha256>-last.json` and everything callers copy (snapshot, pack, state, page, brief) carry only: per-model
  totals; per-job rows `{id, source, kind, label, model, family, attribution, msgs, first_at, last_at, in, out, cache_read, cache_write,
  total}`; counts (`files_scanned`, `jobs_attributed`, `approximate_files` as a number). `label` is the Claude session's ai-title only for a
  main session with `attribution == "cwd"` (it ran in the root itself); otherwise `Claude session <id8>` (a subagent: its session's id8) or
  `Codex session <id8>`. User messages, transcript paths, other projects' cwds, subagent descriptions and agent types are never output.
  Strings pass `pm_common.display_safe`. The snapshot carries `allow: 2`; a stored usage without that stamp (3.3.0 development builds)
  loses its job list when it is reused (`pm_collect.clean_usage`).
- **Legacy.** 3.3.0 development builds kept `PM/usage-cache.json` and `PM/usage-last.json`. Facts (`sweep`) and the usage script delete
  them, and `.usage-*.tmp.*`, when found (never through a symlinked `.project-map`).

11.2 **Budget.** `--budget S` bounds the whole run (the scan stops at `max(0.8 S, S - 0.3)` to save and print). Deadline checks cover
the cache load (a file over the cap is not read), directory enumeration, every chunk read (also inside one huge line), the end of the
scan (a result is never certified complete past the deadline: the last chunk is followed by a check) and aggregation (past `S` the
result is not complete). Progress is saved at chunk (8 MB) boundaries, so a scan too big for one run finishes over several. On
running out, the output is the previous complete result (`<sha256>-last.json`) with `partial: true`, `as_of` (its `generated_at`) and `snapshot_for_state.partial: true`, its `at` still the
time of that complete scan; with no previous result `snapshot_for_state` is `null`. Without `--budget` the scan always completes.
Output additions: `partial`, `as_of`, `scan {bytes_read, files, skipped, incremental, full, reparsed, unstable, cache: off|cold|warm,
cache_partial, elapsed_s}`. Live entries carry `di: [device, inode, ctime_ns]` and the verification snapshot `vf.sn` is `[device, inode, size, mtime_ns, ctime_ns]`; a mismatch of any field is a change (a metadata-only touch costs one re-read). `scan.cache_pressure` (bool) and `scan.evicted_records` (int) say whether compact records were dropped to meet the cap this run; convergence of budgeted runs is conditional on the cap holding all compact records plus the active state (about 370 bytes per attributed transcript, 200 per excluded one), an unbounded scan always completes. Cache schema `project-map-usage-cache-5`. Test hooks: `PM_USAGE_SLOW=<seconds>` sleeps after every chunk; `PM_USAGE_CACHE_CAP=<bytes>`; `PM_USAGE_CHUNK=<bytes>`; `PM_USAGE_BLOCK=<bytes>` (prefix fingerprint block); `PM_USAGE_PKEY_LEN=<n>` (folded key length, 1 forces collisions);
`PM_USAGE_GATE=<dir>` stops after the first chunk read (writes `<dir>/reached`, waits up to 20 s for `<dir>/go`) so a test can rewrite the file
at a known point.

11.3 **Callers (`pm_collect.collect_usage(root, timeout, prev)`; never raises).** A complete scan returns the fresh snapshot (no marker).
A partial scan, a timeout, a crash, garbage output or `timeout < 0.5 s` (no scan is started) return the newest previous numbers (the
script's last complete result or `prev`, the state's usage) with `stale: true` and their original as-of time in `at`; with none, `None`
(the state keeps what it had). `PM_USAGE_SKIP=1` returns `None`.
- **D7 (replaces the 1 h rule on the map's age).** Mechanical embed collects usage when the state has none or its OWN as-of time (`usage.at`)
  is over an hour old, so a refresh that kept stale numbers retries on the next one. The timeout is evaluated after the git and hashing
  work: `deadline - now - max(0.7 s, 20% of the deadline)`; the script gets that minus 0.35 s as `--budget`. A skipped, partial or failed
  scan keeps `state.usage` (marked stale) and the refresh publishes as usual. Fresh numbers are never rescanned within the hour.
- Facts (staging for a judgement) gives the scan at most 10 s (`USAGE_CAP`), within `--budget`; out of time keeps the previous numbers
  with the marker in the staged snapshot, so the judged publish does not lose them. Facts never returns `ERROR` because of usage.
- Display: brief tail `tokens … (claude …, codex …) · usage as of YYYY-MM-DD HH:MM` and the page's Usage disclosure, when `usage.stale`.


## 12. 3.3.0: decisions overtaken by events

Problem (seen live): the map raised "Tag v1.0.0 and push main now, or wait?" (`hard_rule: push`, default `hold`). The owner then tagged
and pushed by hand. The next UPDATE's facts showed `tagged v1.0.0 at HEAD · in sync with origin/main` and the headline said so, but the
decision stayed "needs you" - and a decision the model merely omitted vanished silently (the old `withdrawn` status was never set by
anything). The only options were to nag forever or to forget silently. Design rule: the script owns the lifecycle and the evidence, the
model only judges. A closure is therefore decided by a predicate that was bound to the decision when it was RAISED, evaluated by the
script; the model's words never retire a question by themselves.

12.1 **Closure predicate, bound at raise time.** A decision may carry `resolves_when: [pred, ...]` (1-3 predicates, ALL must hold),
accepted only on a decision the snapshot does not have yet (the raise). It is stored with the decision and is script-owned from then on:
a later judgement may repeat it unchanged or omit it, but adding or changing it is a `PM_EMBED_ERROR` ("resolves_when is fixed when the
decision is raised"). Predicates (closed key sets; unknown keys rejected):
- `{"kind":"tag_at_head","repo":<path>,"name":<tag name|null>}`: some tag (`name` null) or that tag is among the repository's `release.head_tags`. Evidence `tag:<name>`.
  **Tag identity.** `release.head_tags[]` entries carry `tid`, the first 16 hex characters of the sha256 of the RAW ref name (the display
  `name` is `display_safe` output: secret-shaped names become `[redacted]`, control/bidi characters become `\uXXXX`, so two different tags
  can display alike and an escaped name is not a real ref). The model names the tag by what it sees: `tid` is nowhere in the pack (not in
  `head_tags[]` and not in `decisions[].resolves_when`; the snapshot and state keep it for the script), so a carried predicate copied
  verbatim from the pack is the predicate it was raised with, and `tid` is an unknown key in a model-written predicate. At raise the script binds the display name to exactly one identity and stores it as `tid` in
  the predicate: a display name matching exactly one tag at HEAD is bound to that tag's `tid`; matching several (two `[redacted]`) is
  rejected as ambiguous; matching none is bound to the hash of the plain name itself (the tag the decision waits for) only when the name is
  its own display form and a legal git tag name, otherwise rejected: no backslash or bracket, and the rules of
  `git check-ref-format refs/tags/<name>` (no `..`, no leading `.` or `.lock` suffix on a path component, no space, control character or
  `~ ^ : ? * [ \`, no `@{`, no trailing `.` or `/`, no `//`, not a lone `@`, not empty), implemented in Python (`pm_git.tag_name_problem`)
  and confirmed by the real git through the script-internal exact tuple `check-ref-format refs/tags/<name>` when git can answer (the agent
  wrapper refuses it); a name git refuses is rejected at raise ("is not a legal git tag name"). Evaluation compares `tid`s, so a predicate bound
  to one raw tag is never satisfied by another tag with the same display, and a bidi tag holds only while that raw tag is at HEAD. `name`
  null still means any tag at HEAD. A predicate without a stored `tid` (not produced by the script) falls back to the hash of its plain name.
- `{"kind":"branch_in_sync","repo":<path>}`: the repository's `release.sync.state` is `aligned` (`unknown` and every other state fail). Evidence `sync:aligned`.
- `{"kind":"commit","repo":<path>,"sha":<7-40 lowercase hex>}`: listed in that repository's snapshot commits (7-hex), or `cat-file -t` says commit in that repository. Evidence `commit:<sha>`.
- `{"kind":"file","path":<rel>,"exists":true|false}` (`exists` defaults to true): a regular file under ROOT (true) or no such directory entry (false). Evidence `file:<path>` / `absent:<path>`.
  `exists:false` is about the ENTRY: the confined original path (ROOT-joined; its resolved path must not escape ROOT) is `lstat`ed, never its
  dereferenced target, so a dangling symlink at the path is an entry that exists (predicate false). `ENOENT`/`ENOTDIR` mean absent; any
  other filesystem error (permission, loop, I/O) is unknown: the predicate is not satisfied and the reason is reported (below).
  **Repository confinement.** Every repo predicate (`tag_at_head`, `branch_in_sync`, `commit`) re-resolves the recorded `repos[].path` at
  raise and at every evaluation: its realpath must be inside ROOT's realpath, be a directory, and still be the root of its own git work
  tree (`git rev-parse --show-toplevel` equals it). A path replaced by a link to a repository elsewhere, removed, or turned into another
  tree fails closed (predicate false, reason `repo path escaped or changed; refresh facts`; at raise a `PM_EMBED_ERROR`); `cat-file` for
  a commit predicate only ever runs in the confined directory.
`repo` is a `repos[].path` of the snapshot (`"."` allowed) and must be a git repository; `path` must be relative, inside ROOT and outside
`.project-map/` and `.git/`. Checked at raise; a malformed or out-of-snapshot predicate is a `PM_EMBED_ERROR`.

12.2 **Closing by events.** An `open` or `overdue` decision may carry `overtaken: {why <=120 bytes, ref O}`. It is accepted only when the
decision has a `resolves_when` AND the script evaluates every predicate true against the staged snapshot (file and commit predicates
against the disk and git at embed time). `why` is an explanation only. `ref`, when present, must be one of the evidence strings of the
predicates (anything else is an error); it is no longer needed. A decision without `resolves_when` can only be closed by the owner's
answer (`overtaken` on it is an error naming this). Anything else, unmet predicates, `overtaken` on a decision that is not open or
overdue in the snapshot, or extra keys: `PM_EMBED_ERROR` naming the decision; nothing is published. Never a silent drop. A decision whose
predicates hold but which the model still carries open is fine: the script never closes it by itself; the model closes it on its run or the
owner answers.

12.3 **The pack shows the verdict.** `pack.json` decisions with a `resolves_when` that are `open` or `overdue` carry
`resolved: true|false` (the script's evaluation of the whole predicate set when the pack was staged), so the model does not guess. A
predicate that could not be established (unreadable path, escaped or changed repository) adds `resolved_why` (<= 100 bytes), and the
`overtaken, but resolves_when does not hold yet (...)` error appends ` [could not be established: ...]`.

12.4 **Result (script-owned).** The state record is a verbatim copy of the STAGED decision (`q`, `options`, `recommended`, `default`,
`hard_rule`, `ready`, `deadline`, `raised_at`, `resolves_when`): whatever the model wrote for that id in the same judgement is ignored apart
from `overtaken.why`. Added: `status:"overtaken"`, `closed_by:"events"`, `closed_at` (= the snapshot time), `overtaken_why`,
`overtaken_ref` (the evidence strings joined by ` + `). It follows the answered/defaulted lifecycle (6.4 freezing): it lives for exactly one
generation, the next run's lifecycle drops it, and a judgement that still carries the id is ignored. A hard-rule decision may be overtaken: the
action already happened by the owner's hand. The map never authorized it and still never does: no default is applied, no action is taken,
no answer is recorded, `answers.jsonl` is never written (it is the owner's record only). The `withdrawn` status is gone.

12.5 **Owner answers win at publication.** Embed re-reads `answers.jsonl` under the publish lock. When a valid answer for a decision the
judgement closes by events was appended after the snapshot was staged, the owner's answer wins: the decision is published `answered` with
the lifecycle semantics (the staged decision plus `answer`, `answered_by`, `answered_at`), the closure is dropped, and embed prints an
extra `PM_EMBED_NOTE ...` line after `PM_EMBED_OK`. The answer is never treated as bad input and nothing is written to `answers.jsonl`.
`answers.applied` is a prefix count, so every line appended since the snapshot is applied in file order at that publication (the same
result the next run would give) and `applied`/`applied_hash` advance past them. The key keeps the staged `answers_count`, so the next
verdict is `NEEDS_JUDGEMENT` (pending answers) as for any answer that arrives during a judgement. Without such a conflict nothing changes:
answers appended during a judgement stay pending and the next run applies them. Only complete (newline-terminated) lines take part: an
unfinished tail stays pending, is not bad input, and `applied`/`applied_hash` never advance through it.
**Deferred closure.** When `answers.jsonl` ends in an uncommitted record (non-blank bytes after the last newline) at publication time and
the judgement closes a decision by events that no committed late answer already won, the closure is deferred: that decision is published
still `open` (a verbatim copy of the staged decision, the model's text for it is not used), `judged_key.closure_deferred` lists its id,
and embed prints `PM_EMBED_NOTE uncommitted answer tail; events closure of D-00N deferred`. The tail may be the owner's answer to that
very decision, and its bytes are never applied or hashed. The next facts run re-judges (`NEEDS_JUDGEMENT`, reason `answers pending`, or
`N pending answers` once the newline moved the line count) as soon as the tail is committed or removed; while it is still there nothing
moves. The answer, once committed, then wins as any other owner answer; if the tail was removed the closure can be made again. The staged prefix (its line count
and hash) is verified on every call, also when nothing was appended: a shortened file, a same-length rewrite or a deleted file is
`PM_EMBED_ERROR` ("answers rewritten while the judgement was written"), and an unreadable file is `PM_EMBED_ERROR` (it is never read as
empty); only a genuinely empty or missing file with nothing staged means "no new answers". Both the tail flag and the late answers are taken from a single read of the file, so they describe the same bytes.

12.6 **Never vanish.** `validate_judgement` rejects an UPDATE or FULL whose `decisions[]` omits any decision that is `open` or `overdue`
in the staged snapshot (the previous state after the answers/deadline lifecycle): `decision D-00N is open: carry it, or close it with
overtaken{why} once its resolves_when holds` (with a `resolves_when`) or `... has no resolves_when: carry it unchanged, only the owner's
answer closes it`. Decisions the previous state no longer has, and answered or defaulted ones, may be omitted.

12.7 **Permanent decision tombstones.** `state.retired_decisions` is a compact range string (`"D-000..D-003,D-007"`) of every decision id
that was ever dropped; it is never truncated (the `D-nnn` space is 1000 ids, a few KB at worst). The 200-entry `retired_ids` window still
exists for part ids and as a readable recent list; the retired set is the union of both (a state from before this field seeds the set from
the window). A retired decision id can never be raised again, whatever else was retired since.

12.8 **One generation, also through refreshes.** A closed decision (`answered`, `defaulted`, `overtaken`) is shown in exactly one
published generation. A judged publication drops the previous generation's closed decisions (the lifecycle); a MECHANICAL refresh
(`--mechanical`, the hook and verdict refresh) now does the same: it drops every closed decision of the pinned generation from the
decisions list (so the brief and page notice goes with it) and adds their ids to the tombstones. A newly answered decision is never lost by
this: an answer not yet applied (`answers.applied`) is not touched by a mechanical refresh and stays pending for the next judgement. The
`changes[]` and history entries that recorded the closing remain. The accepted `judgement.json` of that generation may still list a dropped decision, so facts
stages `judgement.in.json` WITHOUT it: every decision id that is retired in the pinned state (tombstone set) and no longer listed in its `decisions[]` is removed from the staged
`decisions[]`, and nothing else in the file changes (open decisions and closed ones the pack still shows stay as they were). An agent that copies `judgement.in.json` verbatim is
therefore accepted; a judgement that raises a retired id again is still refused (`decision id D-00N was retired, ids are never reused (drop it from decisions[])`).

12.9 **Display.** Brief: `D-001 overtaken by events: <why> (<ref>)` (one line per such decision, with the decisions block, below the
next step in priority, not a needs-you line; the 1000-byte cap and whole-line rule are unchanged). Page: a "Resolved by events" panel
in the current phase, textContent only; the "Needs you" tile and pill do not count it. `changes[]` and the history entry's `changed[]`
carry `{id:"D-001", label:"D-001", text:"overtaken: <why>"}`; the history entry's `decisions_closed` lists it.


## 13. 3.4.0: make returning easy (return brief)

Problem: the first screen and the brief led with phase counts and the headline; what changed since the last assessment and what
deserves attention were buried, and a returning owner re-read chats. Everything below is additive: `state.schema` stays
`project-map-4`, `state.focus` keeps its meaning, the byte limits do not move (pack 8192, judgement hard 6144, brief 1000 with the
newline), there is no new model call, and a refresh with no relevant change stays model-free. Design: `docs/PLAN-v3.4-3.6.md` section 13.
Supersedes the line layout of 6.6 and the line-2 description in 5.1; extends 6.1, 6.2, 6.4 and 6.5.

13.1 **Baseline** (script-owned; `pm_collect.since_baseline`). `snapshot.since = {generation, assessed_at, commits, dirty, hours}`:
`generation` is the generation that was current when facts collected, `assessed_at` is that state's `judged_at`, `commits` is
`commits.count` (counted against `judged_key.heads`, which a mechanical refresh keeps, so the baseline is always the previous
JUDGED generation, never "your last visit"), `dirty` is `status.dirty`, `hours` is whole hours since `assessed_at` (null when it does
not parse). `null` on a first map and on a 3.x migration: there is no previous assessment.

13.2 **Model output** (`judgement.out.json`, new top-level key `since`, unknown keys rejected). Required on every UPDATE and FULL whose
pack carries a non-null `since`; absent or `null` otherwise (`since must be absent or null` on a first map).
```
since: {
  changes:     [ {text 1..120, state: "landed"|"uncommitted", ref: ref|null} ]   0..3, most consequential first, texts unique
  attention:   {kind: "decision"|"continue"|"waiting"|"unchecked", text 1..120, why 1..120, id: D-nnn}                       R
  not_checked: [ 1..80 ]                                                                                                  O, 0..3
}
```
- `text` states the consequence ("Import landed; nothing here shows it works"), not a commit subject. Uniqueness ignores case and
  spacing. There is no "checked" state: a 4-call UPDATE cannot establish that behaviour was verified and a resolving ref proves only
  that a file or commit exists. Page and brief say `landed, not checked by the map`; what would show it works belongs in `not_checked`.
- `landed`: `ref` is required and is `commit:<sha7+>` resolving in a known repository (`cat-file`); `file:<rel>[:line]` is accepted
  only when the ROOT repository has `vcs != "git"` (a project without git), and must resolve. `uncommitted`: `ref` is optional, `file:`
  only, and must resolve.
- `attention` is exactly one item. `kind: decision` carries `id` (and no other kind does): a decision that is `open`/`overdue` with
  `ready != false` in the STAGED snapshot and not closed by `overtaken` in this judgement, or raised in this judgement with
  `ready != false`. Whenever such a decision exists, `kind` MUST be `decision` (message: `since.attention.kind must be decision (id D-002):
  D-002 open and ready, ...`); an `id` outside that set is rejected. `continue`: work proceeds without the owner. `waiting`: blocked
  outside the project. `unchecked`: the pack did not allow a judgement. `why` is the consequence of waiting / of not checking.
- Every string passes the existing control-character and secret scans.

13.3 **What the model saw** (script-owned). `pack.since` is the snapshot's, `pack.seen` is computed by `build_pack` from the FINAL pack
object, after the last trim step that ran, and counted in the 8192-byte check (after each step the pack is measured with its current
`seen`; over the cap means the next step runs and `seen` is recomputed; `seen` and `since` are never trimmed):
`{commits, commits_total, dirty, dirty_total, decisions_cut, answers_dropped, ledger_cut, repos_cut, watch_moved, watch_moved_cut}`.
`commits` = commit items still listed (the collector itself lists at most 40, so it never exceeds what was listed), `commits_total` =
`commits.count`, `dirty` = `dirty_paths` kept, `dirty_total` = `status.dirty`, `decisions_cut` = staged decisions the pack lost or whose
`q` / option labels it cut, `answers_dropped` = pending answers removed, `ledger_cut` = a ledger field shortened or the ledger gone,
`repos_cut` = repositories removed, `watch_moved` = watched paths whose hash moved against `snapshot.prev_key.watch_hashes` (a
`partial` hash on either side, or a path the judged key did not have, is not a move), `watch_moved_cut` = of those, the ones the pack no
longer lists, by ANY step (the >40 cut and the whole-list drop included). Hash-only cuts, recent tags and usage detail are not omissions.
At a judged publication embed reads `STAGE/pack.json` (the file the model read, never the pack `finish_files` rebuilds) and stores a
well-formed `seen` as `state.judged_seen`; a pack of another invocation, without `seen`, or with a malformed one gives `null`
(unknown coverage). A mechanical refresh carries it. "Relevant work omitted" = `commits < commits_total`, `dirty < dirty_total`,
`decisions_cut`, `answers_dropped`, `ledger_cut`, `repos_cut` or `watch_moved_cut > 0`.

13.4 **Assurance** (script-owned; ONE predicate, `pm_validate.assurance(S)`, used by `build_state` and by every mechanical refresh).
`state.assurance = {ok, why[<=40 bytes each]}`; `ok` iff no clause adds a reason, in this order: `decision open` (a ready open/overdue
decision); `assessment behind: <stale.why>`; `coverage partial`; `git error`; `tags unverified` (a release entry partial, unverified or
inconsistent); `attention not assessed` (no `since.attention`) or `attention: waiting|unchecked` (anything but `continue`; `decision`
is already `decision open`); `pack coverage unknown` (`judged_seen` null) or the omitted-work phrases (`12 of 30 commits shown to the
model`, `20 of 134 changed files shown`, `2 decisions cut in the pack`, `1 answers left out of the pack`, `ledger cut in the pack`,
`2 repos left out of the pack`, `1 changed watch files not shown`). (3.5) `focus changed after the assessment` and (3.6) the evidence
clauses join this function. **Three-way wording**, `pm_validate.needs_text(S)` (the template implements the same rule in JavaScript):
(a) a ready open/overdue decision exists -> `Needs you`; (b) none and `assurance.ok` -> `Nothing needs you`; (c) none and not ok ->
`No decision identified in the checked information` plus the reasons. Hook: a facts verdict carrying `(deferred: budget)` makes the
SessionStart context `project-map: facts not refreshed (budget); run /project-map`; the brief on disk is not presented as refreshed.

13.5 **State and page.** `state.since = {from: {generation, assessed_at}, commits, listed, dirty, hours, changes[], attention,
not_checked[]}` (`null` on a first map): the script's counts as staged, `listed = judged_seen.commits`, the model block verbatim.
`state.judged_seen`, `state.assurance`, `state.status.git_error` are new. A mechanical refresh keeps `since` and `judged_seen` (they
describe the judged batch; live drift is `stale`) and recomputes `assurance`. **Reconciled attention** (one code path, `build_state`,
after the final answers, deferred closures and late answers): against the FINAL ready open/overdue decision ids, (i) a judged attention
naming one of them is kept; (ii) otherwise, when such ids exist, it becomes `{kind: "decision", id: <lowest id>, text: <its q cut to
120>, why: "still open at publication", by: "script"}`; (iii) a judged attention that named a decision when none remains becomes
`{kind: "unchecked", text: "<id> was answered after the assessment; attention not reassessed", why: "pending the next judgement", by:
"script"}`. In (ii) and (iii) the model's block is kept as `since.attention_judged`. An answered id is never shown as a current owner
decision. Page: a `#since` section between the header and the tiles (eyebrow `Since the previous assessment · <date>`, `<N> commits
· <M> uncommitted files` plus ` · <listed> of <N> shown to the model` when `listed < N`, the attention row, up to 3 change rows
`<text> · landed, not checked by the map | uncommitted`, `not checked: ...`); absent when `state.since` is missing. Pill and "Needs
you" tile follow 13.4 (case c: tile `None found`, its note lists the first two reasons, the Snapshot disclosure lists all of them); a
stale map shows `Assessment may be out of date · <why>` as its own line. A state without `assurance` (before 3.4) keeps the earlier
pill. Everything goes through `textContent`.

13.6 **Brief** (<= 1000 bytes including the final newline, whole lines, fixed display order, dropped by priority):
```
1 <name> · <folder> · phase k/n <label> · <tone>
2 as of <snapshot minute> · assessed <judged minute> · current | behind: <stale.why cut to 60> [· <qualifier cut to 40>]
3 <headline>
4 D-004 needs you: ... (then +N more decisions)
5 attention: <text> · <why>                       (omitted when kind is decision and its D line is shown)
6 next: <title> (<actor>)
7 since <assessed minute>: <N> commits · <M> uncommitted · <k> changes [· <listed> of <N> shown]
8 - <text> · landed, not checked | uncommitted    (0..3)
9 D-001 overtaken by events: ...
10 git: <release line>
11 stale: ... / coverage partial a/b
12 tokens ...
13 generation <seq>-<id>
```
(3.5 adds 6b after 6, 3.6 adds 11b after 11.) Line 2 is never dropped; its qualifier is the first `assurance.why` and is present only in
case (c); a map that is behind already says why on that line, so its own `assessment behind` reason is not repeated. `_fit_folder` keeps
a `~` or short path up to 60 bytes, else `…/<last two components>`, cut to 60 bytes at a character boundary with `…`. Drop order when
over the cap: 12, 10, 8 (last first), 7, 5, 9 (last first), 11 (coverage first), then the decisions collapse into `+N more decisions`;
lines 1-3, 6 and the trailer are never dropped (with every capped field at its maximum they take 664 bytes). Superseded: the old
`assessment <minute> · current | N commits since` line 2, and the `git:` line right after the headline.

13.7 **Pack, prompt, skill.** Pack: `since` and `seen`. Agent prompt (`agents/project-map.md`) and `full-run.md`: the `since` rules
(consequence not subject; `landed` needs a commit; no "checked"; a decision is always the primary attention; `seen` says what was cut:
never `continue` as if the batch were complete), judgement size target 3.5 KB, hard 6 KB. SKILL.md is unchanged: the brief carries the
block and the SessionStart hook prints it.

13.8 **Tests.** `tests/test_embed.sh` section 14 (RB-required, RB-landed-ref, RB-attention, RB-seen and the unit cases on `build_pack`,
RB-assurance with brief line 2 and the page, RB-baseline, RB-brief-max with the exact drop order, RB-page, RB-reconcile,
RB-watch-omitted), `tests/test_hooks.sh` (H-deferred, H-since). The page cases run the template's own JavaScript in Node against a small
DOM shim (`tests/pm_page.js`) and are skipped without Node. `tests/pm_testlib.py` writes a valid `since` for every UPDATE (and for a FULL
whose pack carries a baseline), computing its attention with the validator's rule after the test's own edits, so older cases are unchanged.

13.9 **Decisions taken while implementing** (the design left them open):
1. A state with no `since.attention` (a first map, a 3.x migration, a generation from before 3.4) is `ok: false` with `attention not
   assessed`, and a missing `judged_seen` is `pack coverage unknown`: such a map says `No decision identified in the checked information`
   instead of `Nothing needs you` until its first 3.4 judgement. The first map's brief therefore ends line 2 with that reason.
2. "The facts run was cut by its budget" has no state of its own: a facts run that runs out before it has collected publishes nothing
   (`(deferred: budget)`, handled by the hook), and a run that hashes out of time publishes `coverage partial`, which is the clause.
   The same holds at publication: a path the judgement adds to `watch` is hashed by embed (20 s), its counts join the published
   `coverage`, and a path it could not hash completely makes that coverage `partial` (Codex implementation review, I1).
3. `status.git_error` is carried into the state (it is always null today, since a git failure aborts the run) so the clause reads the state.
4. The forcing rule reads `ready` from the STAGED snapshot. A decision the judgement flips to ready is not forcing; the reconciliation
   in 13.5 picks it up at publication and the page shows it as a decision.
5. Line 5 is omitted when the attention is a decision whose D line is among the decision lines before the `+N more` collapse.
6. Line 2's qualifier skips the `assessment behind` reason (the line already says `behind: <why>`); another reason, if any, follows.
7. `decisions_cut` also counts decisions the pack lost entirely; `answers_dropped` counts removed pending entries, not shortened notes.
8. Wording is not pluralised (`1 commits`), as in the existing lines.
9. Last resort for a hand-made oversized state: the next-step and headline lines are dropped, never line 2, line 1 or the trailer.
