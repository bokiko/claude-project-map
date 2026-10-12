# project-map 3.2 plan (draft for Codex agreement)

Inputs: owner comments (2026-10-07 23:30), PR #1 (goals vs shipped), three Claude audits
(security / correctness / product), Codex audit. Verified facts from the Claude Code docs:
- A PreToolUse command hook that times out does NOT block the tool (documented fail-open). The
  only defence is a fast guard.
- A plugin loaded in place from a local-path marketplace (the owner's install) re-reads its source at
  every session start or `/reload-plugins`, no version bump needed. GitHub installs are pinned by
  `version` and update via `claude plugin update` or the marketplace auto-update toggle
  (`/plugin` > Marketplaces > Enable auto-update; off by default for third-party marketplaces).
- SessionStart hooks (startup|resume|clear|compact) may return `additionalContext`.
- Hooks, skills and agents load at session start and at `/reload-plugins`; nothing else.

North star unchanged: all the information the developer needs at a glance, very few tokens.

## A. Lifecycle and usability (owner's complaints)
A1. **SessionStart hook** (matcher startup|resume|clear|compact, exec form, timeout 20 s),
    MECHANICAL ONLY. Contract: ROOT = git toplevel of cwd, never `$HOME`; runs when
    `<ROOT>/.project-map/` holds either `current` (3.2 layout) or a legacy `state.json`
    (3.x layout -> the brief says "map needs migration: run /project-map", never "unmapped").
    It runs facts; on NO_CHANGE/NEEDS_REFRESH it re-renders (no model); then injects
    `brief.txt` (<= 1 KB, about 300 context tokens, stated as such in the docs) whose first lines
    carry `assessment from <time> · N commits since` so a stale brief is never presented as
    fresh, plus one line "run /project-map to re-judge". ERROR / REFRESH_FAILED / corrupt outputs
    inject one line naming the problem and the command. Unmapped projects: nothing.
    **Automatic refresh after a plugin update** (owner requirement): a second, cheap
    `UserPromptSubmit` hook (< 50 ms: stat the plugin's template + embed files, compare their
    hash with the stamp in `current/state.json`) re-renders mechanically ONCE when the plugin
    changed under a mapped project (covers `/reload-plugins`, auto-update and local edits) and
    says so in one line; otherwise it is silent and injects nothing. The next launch is covered by
    SessionStart. Both hooks verified in `claude -p` and after `/reload-plugins`.
A2. **Skill preflight** (step 0, runs before any spawn, Opus included): git present (or
    non-git mode stated), python3 + jq present, ROOT canonical (realpath), not `$HOME`, under an
    allowed root, no spaces or `[`, parent writable when `.project-map` does not exist yet,
    Chrome optional (FULL skips screenshots and says so). One clear sentence on failure, stop. If
    the spawn fails with an unknown agent type: "run /reload-plugins (the plugin was installed
    after this session started)"; never fall back to an unguarded agent. Tests: unmapped project,
    every unsupported location, explicit ROOT differing from cwd.
A3. **Docs**: Get-started step 2 becomes "/reload-plugins (or a new session)". Add "Keep it
    updated": local-path install loads in place; GitHub install: enable the marketplace
    auto-update toggle or run `claude plugin update project-map@bokiko-tools`. Private-repo note
    (needs `gh auth login` or an SSH key with access). Prerequisites (python3, jq, git, macOS or
    Linux) move above the fold.
A4. **SKILL.md rewritten for clarity**: first 10 lines = what it does, the three ways to call it
    (`/project-map`, `/project-map <ROOT>`, "where are we?"), what you get, what it costs. Steps
    follow. Failure handling for every step (facts non-zero, embed error, guard deny, DONE (stale),
    PARTIAL, NEED_FULL).

## B. Page redesign for orientation (owner + PR #1), Codex drafts, I port
B1. **Identity block** at the top, always visible: project name (judgement, fallback folder
    name), folder path (`~`-shortened), branch @ short head, snapshot time, "needs you" state.
B2. **Phases** replace "journey": every phase shows done / current / next / later and its own
    done/total criteria; the current phase is expanded ("where we are"); the next phase and the
    next step sit beside it ("what's coming"). Keep the Blend look (restraint, dark, no clutter).
B3. **Plan vs shipped** disclosure (the PR #1 idea): one table of every criterion across phases
    with status and evidence ref, so the reader sees goals against what landed.
B4. **brief.txt** line 1 = `name · ~/folder · phase k/n <label> · <tone>`; then headline.
B5. Phase data: FULL writes `plan.json` (script-validated: phases with stable ids
    `P1..`, criteria with stable ids `P2.c3`, labels <= 80 chars, <= 8 criteria per phase, <= 7
    phases). UPDATE writes judgement.json with `criteria_updates: [{id, done, ref}]` for ANY phase
    whose evidence moved (not only the current one); embed merges plan + updates, computes phase
    completion from criteria evidence, never from position, and carries frozen decisions and ids
    through the schema migration. `project.folder` is facts-owned. judgement stays within
    3 KB target / 6 KB hard because plan text lives in plan.json. Schema -> project-map-4, one
    FULL per existing map (the pilot project, this repo).
B6. Verification: 1440x900 and 390 screenshots, identity + phases + next step above the fold,
    no overflow at 390, reduced-motion static, owner says "pro".

## C. Guard hardening (Claude security audit S1-S10 + Codex S1-S3)
C1. Deny any hook input > 8 KB and any command > 2 KB before parsing; replace the per-character
    quote scan with one linear pass; hook timeout 30 s. Regression test: 40 KB padded command
    must be denied in < 1 s. (Fail-open on timeout is documented Claude Code behaviour.)
C2. Two git layers, one hardened execution core (Codex S1, round 2 #4):
    `scripts/pm_git.py` runs every git call with `GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0`, `-c core.fsmonitor=false -c
    core.hooksPath=/dev/null -c core.pager=cat -c diff.external= -c core.sshCommand=false
    --no-optional-locks` and per-subcommand flag validation. **Internal allowlist** (facts/embed
    only): status, log, ls-files, rev-parse, rev-list, merge-base, cat-file -e/-t, diff --stat
    --no-ext-diff --no-textconv (evidence and rewritten-history checks). **Agent allowlist**
    (`scripts/pm-git.sh <ROOT> <sub>`): `status --porcelain`, `log` (fixed format, `-n <= 60`),
    `rev-parse`, `branch --list`, `ls-files`, `tag --list`. Raw `git` and `remote` are denied for
    the agent. Tests: a repo with configured fsmonitor, textconv, external diff, pager and hook
    helpers through every route of both layers; helpers must not execute; rewritten history and
    bad `commit:` refs detected.
C3. Read/cat/head/tail/stat/wc/find/ls operands: canonicalised (realpath, symlinks resolved) and
    required to sit under ROOT, `${CLAUDE_PLUGIN_ROOT}`, the agent memory dir or the discovered
    ledger file; the secret filter runs on both the requested and the resolved path (Codex S2
    symlink). Grep and Glob are removed from the agent's tool list; the guard still denies them
    outright for the agent. Sensitive list gains `.git/`, `.claude.json`, `.config/gh`,
    `*_history`, `settings*.json`, `ssh_host_*`.
C4. Invocation binding (Codex S3, rounds 1-4), written by the GUARD only, under
    `${CLAUDE_PLUGIN_DATA}/bind/` (the agent cannot write there):
    (a) **invocation record**: the hook matcher gains `Agent`. When the MAIN session calls the
    Agent tool with `subagent_type` ending in `:project-map`, the guard parses `ROOT:` and
    `GEN:` from `tool_input.prompt`, checks `gen-<id>` exists under that ROOT and that ROOT was
    bound by a trusted facts call in this session, and atomically creates PENDING
    `{session_id, root, gen, at}` (O_EXCL file). **Serialised**: an existing unclaimed PENDING
    for the session denies the new spawn ("one map agent at a time").
    (b) **claim**: the first hook call carrying a not-yet-seen `agent_id` of type project-map
    atomically renames PENDING -> `<agent_id>.json = {root, gen}`; from then on every
    project-specific operand must equal that root and gen exactly; no PENDING -> deny, fail
    closed. The agent never selects its authority: the spawn did.
    (c) **recovery**: PENDING stores the spawning `tool_use_id`; `PostToolUseFailure` (matcher
    `Agent`) in the main session removes PENDING only when its `tool_use_id` matches (a
    confirmed failed spawn of THAT invocation, never another). After an interruption or an
    uncertain termination the record stays (never expires by age). The only way out is
    `python3 <plugin>/scripts/project-map-facts.py --close-session` from the main session (the
    guard honours that exact command in main-session mode only): it writes
    `<session_id>.closed`, after which this session accepts NO further map-agent spawn and NO
    claim (a delayed agent from the uncertain invocation can never acquire a replacement
    authority); the skill says "start a new Claude Code session to run the map again". Lineage prerequisite, verified before code with a logging hook in `claude -p`:
    subagent hook input carries `session_id` + `agent_id`; the Agent-tool PreToolUse and
    PostToolUseFailure inputs carry `prompt`/`subagent_type`. If absent, stop and re-plan.
    Tests: A's first op targets bound B -> denied; second concurrent spawn -> denied; failed
    spawn (matching tool_use_id) then retry succeeds; PostToolUseFailure with a non-matching
    tool_use_id leaves PENDING; the exact sequence A leaves PENDING -> main closes the session
    -> main tries to spawn B (denied) -> A's delayed first touch (denied); explicit ROOT != cwd;
    agent facts call on another ROOT; hard-linked target; agent with no PENDING -> all denied.
C5. gh: deny `-R/--repo/--hostname`; date: no operands after the format; cat/head/tail of
    `/dev/*` denied; `ls -R` denied; `tail -f` denied.
C6. README "Security and guard" rewritten to say exactly what the code enforces (including the
    documented fail-open on timeout and why the guard is kept fast). Every C item gets guard tests.

## D. Script correctness (correctness audit C1-C14)
D1. Watch list capped at 40 entries in validate; facts `minimal()` stores one combined watch
    hash; no `assert`, size overflow degrades to a hash-only key with a verdict still printed.
D2. Coverage, not caps (Codex rounds 1-3): watched paths are hashed by CONTENT, completely.
    Incremental cache in `snapshot.json` keyed by `(device, inode, size, mtime_ns, ctime_ns)`;
    ctime cannot be restored by user tools, so a same-size edit with a restored mtime still
    rehashes. Any entry whose identity cannot be established is rehashed. A run that cannot
    finish within its time budget records `coverage: partial` (key, brief, page) and the SCRIPTS
    continue hashing on later runs; while partial, no judging agent is spawned unless the git
    key moved; NO_CHANGE requires complete coverage. Index blob ids: staged evidence only.
    Tests: metadata-preserving edit to a watched file (must flip), repeated unstaged edits,
    untracked and ignored watched files, a run that hits the time budget (no spawn, completes
    on the next run).
D3. brief.txt built by priority (headline, phase line, needs-you decisions, next step, stale
    note, tokens); never cut mid-line; "+N more decisions" when needed; cap counts the newline.
D4. answers.jsonl applied-tracking by line hash, so an edited line is seen.
D5. Single `-n` on git log; `%x1e` record separator; ledger basename match wins over mtime.
D6. eta.low/high validated; `Z` and fractional seconds normalised; years out of range rejected
    cleanly; `glob.escape(root)`; ROOT must be an existing directory before any makedirs.
D7. facts.json rewritten only when the key changed (a second facts run no longer forces a
    re-judge); usage scan only when judging or when the map is > 1 h old.
    (3.3.0: the age is the usage's own as-of time and a slow scan never fails the refresh; see INTERFACES-3.2 section 11.)
D8. Validation: whitelist nested keys, strip model-supplied answer fields, `commit:` must resolve
    to a hex SHA in the repo, `file:` must not point inside `.project-map/`.
D9. Maintainability: one atomic-write helper, `__pycache__` written to `${CLAUDE_PLUGIN_DATA}`
    (PYTHONPYCACHEPREFIX), stale `.tmp.*` cleanup, facts.json written last.
D10. (Codex C1, rounds 1-4) Generation-atomic publish with an ordering rule: embed writes a
    complete immutable `gen-<seq>-<id>/` (state, index, mobile, brief, snapshot, pack, the
    frozen in/out files) and switches ONE symlink `current` by atomic rename; stable paths
    `index.html`, `brief.txt`, `state.json` are symlinks into `current/`. Every generation
    records `base` = the generation it was judged from. **Eligibility check under the D11 lock**:
    publish only if `current` still equals `base`; otherwise the result is SUPERSEDED (verdict
    `SUPERSEDED`, exit 4, nothing replaced, current decisions/criteria/answers preserved) and the
    skill reruns facts, which spawns again only if the key still says so. Out-of-order
    completion test: A starts on gen 5, B starts on gen 5 and publishes gen 6, an answer is
    recorded, A finishes -> A is SUPERSEDED, gen 6 and the answer stay. Crash at any boundary
    leaves `current` on the previous complete generation; incomplete dirs are swept by the next
    facts run. facts reads only via `current/` and checks the stamp across files; mismatch ->
    `NEEDS_REFRESH`. Tests: death at every boundary, concurrent reader during a switch.
D11. (Codex C2) Lock = `fcntl.flock` on `.project-map/.lock` (OS advisory), held for the
    whole publish; no age-based stealing; a dead holder releases automatically. Test: holder
    alive, second embed must fail with "another embed is running".
D12. (Codex C3, round 1 #5) Two files, two purposes: `snapshot.json` is the complete
    script-owned record (watch, answers replay, keys as full maps) with NO cap; `pack.json` is the
    bounded model-facing view (<= 8 KB by trimming lists with explicit `+N more` markers, digests
    instead of maps). Overflow of a trimmed list never drops replay data because replay data is
    not in the pack. Tests: 125 watched files, long paths, 12 KB answer note, concurrent
    snapshot replacement (generation dirs make it impossible).
D13. (Codex C4) A failed git command is an explicit `git_error` fact; the verdict is then
    `ERROR <why>` with exit 2, never NO_CHANGE.
D14. (Codex C5/C6/C7/C9) Strict types: `ready` must be a bool, option ids non-empty `[A-Z]`,
    numbers finite (`parse_constant` rejects NaN/Infinity, `allow_nan=False` on dump), state
    must be an object with the expected nested shape or the verdict is `NEEDS_FULL invalid
    state`; `file:` refs must be regular files and any line number must exist.
D15. (Codex C8) Mechanical refresh failure is its own verdict `REFRESH_FAILED <why>` with exit 3;
    the skill reports it and never prints an old brief as fresh.
D16. (Codex C10) Documented limit: same-size edits with restored mtimes on UNWATCHED dirty files
    are invisible to the status signature (ctime_ns is added to that signature too, which closes
    the common case); watched files are content-hashed (D2).

## E. Prompts, packaging, docs (product audit P1-P14)
E1. Agent `maxTurns` 32; FULL cap stays 30 calls.
E2. Immutable inputs AND invocation-scoped outputs (Codex rounds 2-3): facts creates
    `gen-<id>/` with `pack.json` and `judgement.in.json` (frozen; on a first map a bootstrap
    generation with an empty judgement.in.json). The agent Reads those two literal paths and
    WRITES only `gen-<id>/judgement.out.json` (FULL also `gen-<id>/plan.out.json`); the guard
    allows exactly those paths for the bound (root, gen). Embed is called as `embed <ROOT>
    <gen-id>`, reads that generation's snapshot + out files, validates that the out files belong
    to that generation (stamp inside), and publishes a NEW generation; the shared mutable
    `judgement.json` no longer exists. Two agents on the same ROOT get different gen ids and
    cannot pair the wrong files; publication order is decided by D10's base check (a result whose
    base is no longer `current` is SUPERSEDED). Saves ~6K main-session tokens per judged run.
    Tests: pointer switch between Reads, first-map bootstrap, two agents on one ROOT with
    interleaved writes and embeds.
E3. Guard deny -> reply PARTIAL with the deny text, no variant retries. Chrome missing ->
    skip screenshots and say so. The brief is printed by the main session only; the agent's
    brief Read and the "one targeted Read" exemption are removed. `ANSWERS:` removed. Budget
    recomputed: UPDATE = Read pack + Read judgement + Write + embed = 4, plus 2 Edit/embed
    retries = 8 max (unchanged ceiling).
E4. Generic wording: "owner" instead of the owner's name in shipped prompts; hard-rule list stays generic
    (deletions, pushes, spending, infrastructure, credentials, other people's repos); the
    owner-specific names stay in the owner's own CLAUDE.md.
E5. judgement size: "3 KB target, 6 KB hard" everywhere.
E6. Docs bloat: move `docs/design-drafts/` (3.6 MB) to a `design-history` branch; main keeps
    `docs/screenshot.png` + DESIGNS.md. (Deletion: needs the owner's explicit OK.)
E7. (Codex P1/P2/D2) Agent prompt names the `.gitignore` append as the one allowed extra
    write; `milestone.origin` named explicitly in the FULL schema; "3 KB target, 6 KB hard" in
    README. No brief Read exists any more (E3). Preflight (A2) covers Codex D1; manifests say
    "any project under a supported root".
E8. PR #1 (`docs/PLAN-v3-REVIEW.md`, since removed): merge as history after B lands; its "Open" items are
    covered by A1 (self-map refresh), E5 and this plan.

## Interfaces first (Codex round 1 #10)
Before code: write `docs/INTERFACES-3.2.md` fixing the file layout (`gen-*/`, `current`,
`snapshot.json`, `pack.json`, `plan.json`, `judgement.json`), the verdict set (`NO_CHANGE`,
`NEEDS_REFRESH`, `NEEDS_JUDGEMENT`, `NEEDS_FULL`, `REFRESH_FAILED` exit 3, `SUPERSEDED` exit 4,
`ERROR` exit 2), the
binding record, the pm-git allowlist and the hook contract. Codex reviews that document first. Activation order: interfaces -> lineage probe -> binding ->
generations/lock -> scripts -> prompts -> hooks; nothing activates before its tests pass.

## Order, gates, cost
1. C then D (both suites + new cases green under bash 3.2 and 5).
2. A (hook + skill), verified in a fresh `claude -p` session and after `/reload-plugins`.
3. B: Codex drafts the page on the pilot project's data; owner approves; port; schema -> project-map-4.
4. E, CHANGELOG, version 3.2.0, `claude plugin validate --strict`, tag, push.
5. Measure again: FULL and UPDATE unique API calls and ctx-at-end; NO_CHANGE = no model call;
   SessionStart = no model call, ~300 injected tokens, wall time; UserPromptSubmit check < 50 ms.
Gates: every reproduction from all four audits becomes a test and must pass; lifecycle tests
(binding, generations, lock, coverage); measured SessionStart and NO_CHANGE cost (wall time and
injected tokens). Codex AGREE on the diff before each tag; tag and push only after the owner's
explicit go in the conversation. E6 (design-drafts removal) is optional and separately approved. Out of scope (drift guard): CI, cycle detection,
multi-level nested repos, Windows.
