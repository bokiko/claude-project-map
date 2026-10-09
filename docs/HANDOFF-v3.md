# project-map v3: handoff brief (2026-10-07)

Supersedes HANDOFF-v2.md (kept for history). Plan: `~/.claude/plans/staged-enchanting-scroll.md`.

## What it is
One command, any project: `/project-map [ROOT]` draws and keeps a calm dark one-file HTML map
(`<ROOT>/.project-map/index.html`) that lets the developer understand the project at a glance.
North star: all the needed information, very few tokens.

## How it works (v3)
**Scripts gather facts; the model only judges; the model writes one small file.**
1. `python3 ~/.claude/agents/hooks/project-map-facts.py <ROOT>` (read-only, stdlib, ~3 s) writes `facts.json`
   (≤8 KB) and prints ONE line: `NO_CHANGE …` | `NEEDS_JUDGEMENT <why>` | `NEEDS_FULL <why>`.
   Key = repo heads + branches, status signature (porcelain + dirty files' mtime/size), watch-file content hashes,
   ledger hash, answers count, expired deadlines, template/embed hashes. Decision lifecycle (answers, expiries) is
   script-owned; hard rules and `ready:false` never default.
   On NO_CHANGE it re-renders by itself (0 tokens) when the template/embed changed, usage moved or the map is >1 h old.
2. `NEEDS_JUDGEMENT` → the skill spawns the `project-map` agent (Sonnet) with facts + current judgement inline.
   The agent writes `<ROOT>/.project-map/judgement.json` (≤3 KB, whole file) and runs
   `bash ~/.claude/agents/hooks/project-map-embed.sh <ROOT>`. ≤8 tool calls.
3. `NEEDS_FULL` (first map, schema change) → same agent on Opus with `RUN: FULL` and
   `~/.claude/agents/project-map-full.md` (exploration caps, 30-call cap, screenshots).
4. `embed` (project-map-embed.py) re-runs facts, merges facts + judgement, validates (unknown/duplicate/retired ids,
   `done` needs `file:`/`commit:` ref, hard-rule/ready:false must default `hold`, frozen non-open decisions,
   stale-facts guard, path confinement), writes `state.json` (schema `project-map-3`), `index.html`, `mobile.html`,
   `brief.txt` (≤1 KB) atomically under a `.lock`. On any error the old map stays.
5. "Where are we?" is answered from `brief.txt`. Never from state.json/index.html.

## Measured cost (pilot project, 2026-10-07, unique API calls)
| Run | Model | Calls | Ctx end | Cache reads | Est. |
|---|---|---|---|---|---|
| v2 FULL (old) | opus | 40 | 171K | 4.2M | ≈$2.20 |
| v3 FULL | opus | 16 | 59K | 0.72M | ≈$0.46 |
| v3 UPDATE | sonnet | 4 | 37K | 0.10M | ≈$0.11 |
| v3 no-change | none | 0 | — | — | $0 |

## Files
| File | Role |
|---|---|
| `~/.claude/skills/project-map/SKILL.md` | Entry point `/project-map [ROOT]`. ROOT defaults to the git toplevel. |
| `~/.claude/agents/project-map.md` | UPDATE agent (≤5 KB, Sonnet). FULL uses the same agent + `project-map-full.md` on Opus. |
| `~/.claude/agents/project-map-full.md` | FULL-run instructions. |
| `~/.claude/agents/hooks/project-map-facts.py` | Facts + verdict. Read-only. |
| `~/.claude/agents/hooks/project-map-embed.py` / `.sh` | Merge, validate, render, brief. `--mechanical` = refresh without re-judging. |
| `~/.claude/agents/hooks/project-map-template.html` | The look ("graphite instrument panel", spec in `reviews/v3/DESIGN-SPEC.md`). Edit THIS to change the look. |
| `~/.claude/agents/hooks/project-map-guard.sh` | PreToolUse guard for the agent: may write only `judgement.json` (+ own memory, root `.gitignore`); Bash = read-only git/ls/cat/head/tail/wc/find/grep/date, the facts/usage/embed scripts, two exact Chrome commands; `cd` denied; ROOT must be under ~/projects, ~/Desktop, ~/thoughts or a scratchpad. |
| `~/.claude/agents/hooks/project-map-usage.py` | Token/model collector (Claude + Codex transcripts). |
| `~/.claude/CLAUDE.md` § Project map | Pointer to the skill + the ASK/ANSWERS round trip + hard-rule caveat. |
| `reviews/v3/test_embed.sh` (147), `reviews/v3/test_guard.sh` (301) | Suites. Run both after any change, under `bash` AND `/bin/bash`. `HOOKS_DIR=<dir>` tests a scratch copy of the hooks. |
| `reviews/v3-backup/` | v2 originals + the pilot project's v2 map. |

## Rules to keep
- Subagents can't ask questions: `ASK:` lines → main session asks the owner → answer appended to `answers.jsonl` → rerun.
- Hard rules never auto-default (deletions, upstream posts, pushes, spending, infra, Hetzner, Buzz, Acurast). The map is never the authority.
- Real data only; `unknown` beats a guess; ETA null without a basis.
- No Opus for routine updates. No screenshots in UPDATE.
- The guard hook cannot be edited by a subagent (auto-mode blocks hook self-modification): edit it in the main session, from a scratch copy, with the suite green.
- Codex reviews run in a visible Herdr tab (`codex-projmap`), until AGREE.

## Known limits (deferred by design)
Paths with spaces (guard rejects); nested repos only one level deep; no dependency-cycle check; criteria have no stable ids;
main-session transcripts started in `~` undercount in usage (labelled).

## Hardening done on 2026-10-07 (Codex rounds 1-6, all fixed)
NO_CHANGE blind spots (dirty-file contents, ledger, branch, scan caps); stale-judgement publishing; `<!--` escaping that
blanked the page; frozen answered decisions; `changed[]` diff; ledger carry-forward + replay; retired ids; guard
bypasses (uniq/sort output operands, abbreviated git options, quoted pipelines, globs, `~`, `$`); root scoping; judgement
must postdate its facts; tree churn never vetoes a publish; a ROOT inside a parent repo (incl. `~`) is scoped to itself.
Hot-repo behaviour: if the repo moves while the model judges, embed PUBLISHES the newer judgement flagged
`stale` (page + brief say so) and the next facts run re-judges; it refuses only a judgement older than its facts,
validation errors and the lock.

## Status at handoff (2026-10-07 14:25)
- Live map: the pilot project's `.project-map/index.html` (schema project-map-3, 6 runs). The pilot project is
  a HOT repo (another session commits every few minutes), so expect `stale` banners there; that is by design.
- Measured today: FULL 16 Opus calls / 59K ctx / ≈$0.46; UPDATE 3–4 Sonnet calls / 37K ctx / ≈$0.10; NO_CHANGE $0 (3 s).
- Codex: rounds 1–7 done in Herdr tab `codex-projmap` (session reset before round 6). Round 7 findings (skill ROOT never
  `$HOME`; `grep -r` secret bypass; stale publish must keep the judged decision lifecycle) were fixed; round 8 = final gate.
- Open / next: run Codex round 8 to AGREE; then try `/project-map` on a quiet second project (any folder under ~/projects)
  to prove the any-project path end to end; then hand the pilot project's map back to its own session.
- 2026-10-07 14:42: Codex round 9 = **AGREE** (rounds 1–8 fixed: ledger retry, frozen-vs-auto_default, brief staleness,
  retired ids on refresh, pid temp files, judgement-postdates-facts, tree churn, parent-repo ROOT, scan caps,
  publish-and-flag on hot repos, stale publish keeps judged lifecycle, answers replay from file). Suites: embed 147/147
  (both bashes), guard 301/301. Any-project bootstrap proven on a scratch clone of the e2e sample repo and a plain folder (0 tokens).
- 2026-10-07 17:00: v3.1.0 = new v4 "Blend" page design (owner-approved from three Codex drafts; draft files removed in 3.2.1);
  plugin guard verified in a fresh headless session (hooks load at session start). Repo is a plugin: `project-map@bokiko-tools`.
- Rule for this file: append a dated line here at the end of each work stretch.
- 2026-10-08: v3.2.0 released-in-tree. The current truth is `docs/PLAN-v3.2.md` (what and why) and `docs/INTERFACES-3.2.md` (contracts); this handoff describes 3.0/3.1 only.
