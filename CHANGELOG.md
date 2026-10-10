# Changelog

## 3.2.3 (2026-10-10)
### Changed
- **Any project folder in your home folder works.** 3.2.2 only mapped projects under `~/projects`, `~/Desktop` or `~/thoughts`, so a project in `~/code` or `~/dev` failed after the facts step. The guard now accepts any folder inside `$HOME` except the home folder itself, hidden top-level folders (`~/.config`, `~/.ssh`, `~/.claude`, ...) and `~/Library`; Claude scratchpads stay allowed. Paths are resolved first, so a symlink into a hidden folder is refused; the exclusions are compared case-insensitively (macOS accepts `~/library` for `~/Library`), and `$HOME` itself is resolved, so a trailing slash or a symlinked home still works. Every other guard rule is unchanged. Codex review: AGREE after round 2 (round 1 found the casing bypass and the home spelling issue).
- Skill preflight sentence, README, FAQ, contract and manifests say the same.
- Suites: guard 1030 (21 new home-rule cases), git 219, embed 615, hooks 129 (1993 cases), each under `bash` and `/bin/bash` 3.2.

## 3.2.2 (2026-10-08)
### Fixed
- **Agent wrote its judgement from a shell.** On a live UPDATE the Sonnet agent tried to produce `judgement.out.json` with `cd ... && python3 - <<EOF`; the guard denied it (by design: Bash is only for `pm-git.sh` and `project-map-embed.sh`) and the agent stopped with PARTIAL, so the map stayed stale. The agent prompt now states that rule explicitly and tells it to compose the JSON itself and save it with the Write tool; Bash is scoped per run type (UPDATE: the two scripts; FULL: also the read-only commands in `full-run.md`) and placeholders are explained. No guard change. Codex AGREE (round 2). Verified by a headless run and a real interactive session (background launch, Read, Read, Write, embed, no denials).

## 3.2.1 (2026-10-08)
### Fixed
- **Background subagents (Claude Code 2.1.29x).** Interactive sessions now launch every subagent in the background; PostToolUse fires at launch, so 3.2.0 released the pending invocation before the map agent made its first call and the agent was refused with "no pending invocation, nothing to claim". The guard keeps the record when the spawn result says `async_launched`, stamps it with the launched `agent_id` (SubagentStart does the same), only that agent can claim it, and new `SubagentStart`/`SubagentStop` hooks retire the job when the agent ends. A pending record nobody claimed for 10 minutes no longer blocks the next spawn. The foreground path is unchanged. Contract: `docs/INTERFACES-3.2.md` 4.2 (c)/(d); tests G-spawn-async.
- Skill: says the agent may run in the background and tells the main session to wait for its completion message instead of printing the old brief.
- Suites: guard 1009, git 219, embed 615, hooks 129 (1972 cases), each under `bash` and `/bin/bash` 3.2. Codex review of the guard change: AGREE (round 2, after one Medium finding was fixed: an expired job's late agent could claim the next job; its owner is now made terminal).
### Changed
- `docs/design-drafts/` (the v4/v5 page drafts, built on the pilot project's data) removed from the repo on the owner's request; the chosen designs live on in `scripts/project-map-template.html` and `docs/DESIGN-SPEC.md`.
- Nothing from a private project remains in the repo: README screenshots and `docs/demo-state.json` come from a fictional project (Lanternfish) rendered through the real template; the test fixture is `tests/demo-judgement.json`; planning docs name "the pilot project" instead.

## 3.2.0 (2026-10-08)
Built from the owner's comments, four audits (security, correctness, product, Codex) and two implementation reviews (Codex and Claude) of the result. Plan: `docs/PLAN-v3.2.md`; contracts: `docs/INTERFACES-3.2.md`.
Existing 3.1 maps migrate with one FULL run on the next `/project-map`; ids, ledger link and answered decisions carry over and the old files are kept under `legacy/` in the first 3.2 generation.
Suites at release: guard 927, git 219, embed 615, hooks 119 (1880 cases), each under `bash` and `/bin/bash` 3.2.

### Security
- Guard: it parses its whole input linearly; the main session is never denied for size; for the map agent a Bash command over 2 KB or an input over 8 MB is denied before any other check (a 40 KB padded command is denied in under a second; Claude Code lets a timed-out PreToolUse hook through, so speed is the defence). `Agent` joins the matcher; PostToolUse and PostToolUseFailure hooks record spawn results.
- Invocation binding written by the guard under the plugin data folder: pending, claimed, terminal and closed records per session; one map agent at a time; `--close-session` for uncertain terminations; no foreground-less, resumed or unregistered spawns.
- Two git layers over one hardened core (`pm_git.py`, `pm-git.sh`): config, hooks, pager, fsmonitor and external diff disabled; raw `git` denied for the agent.
- Reads confined to the bound root, the plugin, agent memory and the ledger; symlinks resolved; wider secret patterns (`.git`, `.claude.json`, `*_history`, `settings*.json`, `ssh_host_*`); Grep and Glob removed from the agent.
- Signed generations: each manifest carries an HMAC, and a publish record gates adoption of a generation. The session hook injects only verified briefs.
- Secret and unicode scanning of judgement and plan text: token-like strings, control characters and bidi overrides are rejected before anything is published.
- Watch entries: relative paths only, no `..`, at most 40 entries, confined to the project root.

### Correctness
- Generation-atomic publish: immutable `gen-<seq>-<id>/`, one `current` symlink switched by atomic rename, a base check (`SUPERSEDED` when another run published first) and an OS `flock` publish lock. Crashes at any boundary leave a complete generation current.
- Watched files hashed by content with an incremental cache, partial coverage handled without spawning, `ctime` in the signature.
- `snapshot.json` (complete) separate from `pack.json` (8 KB, model-facing); `ERROR` and `REFRESH_FAILED` verdicts; strict type validation; answers tracked by line hash; brief built by priority and never cut mid-line.

### Lifecycle
- SessionStart hook injects the brief (no model call, about 300 tokens, with "N commits since"); UserPromptSubmit hook re-renders once after a plugin update, and embed acknowledges the plugin hashes at every successful publish.
- Skill rewritten: preflight, a verdict and reply table, recovery lines; unknown agent type says "run /reload-plugins".
- Agent: `maxTurns` 32, staged flow (Read pack and judgement.in, Write out files, embed), PARTIAL on any guard deny, generic "owner" wording, "3 KB target, 6 KB hard".

### Page
- The H "Neat" page: identity block, tiles, phase list with per-phase checklists, plan vs shipped, one decision panel, "A little more context"; `plan.json` with stable ids (`P1`, `P2.c3`); schema `project-map-4`; new `brief.txt` line 1.

### Docs
- README: prerequisites and supported locations up front, "Keep it updated", private-repo note, security section stating exactly what the guard enforces. FAQ: migration, generations, safety, update. Manifests say "any project under a supported root".

## 3.1.0 (2026-10-07)
- New page design (v4 "Blend"): Apple-restraint dark layout chosen by the owner from three Codex drafts (docs/design-drafts/): headline, five-stop journey rail, one focus card (current milestone, progress ring, next step), a quiet decision rail, everything else under disclosures. System font stack, no network requests, fully data-driven, textContent only.
- Guard: env-gated trace (`PM_GUARD_TRACE=<file>`) for diagnosing hook wiring.
- README: plugin hooks load at session start; restart or `/reload-plugins` after install.

## 3.0.1 (2026-10-07)
- Plugin hook declared in exec form (`command` + `args`), as the docs prefer for `${CLAUDE_PLUGIN_ROOT}` paths.
- Verified live through the plugin install: agent `project-map:project-map` loads, guard no-ops outside the agent.

## 3.0.0 (2026-10-07)
- Packaged as a Claude Code plugin (`project-map@bokiko-tools`); `install.sh` is gone, the guard hook ships in `hooks/hooks.json`.
- v3 design: scripts gather facts, the model only judges and writes one small `judgement.json`; no-change runs cost 0 tokens.
- Measured: FULL on Opus 16 calls (about $0.46), UPDATE on Sonnet 3-4 calls (about $0.10), no-change $0.
- Embed validates ids, evidence refs, hard rules and frozen decisions, then renders `index.html`, `mobile.html` and a 1 KB `brief.txt` atomically.
- Hardening (Codex rounds 1-7): stale-judgement publishing, NO_CHANGE blind spots, frozen answered decisions, root scoping.
- Guard hardening: pipe and git option allowlists, glob/`~`/`$` blocks, secret paths, writes only to `judgement.json`, own memory and a root `.gitignore` line.
- Guard is now a no-op unless `agent_type` is `project-map` (or `...:project-map`), and trusts only scripts in its own directory.
- FULL-run instructions moved to `skills/project-map/full-run.md` (a supporting file, not an agent).
- Limits: paths with spaces rejected, nested repos one level deep, usage undercounts sessions started in `~`.
