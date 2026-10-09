# project-map v3: light and cheap

## Context
North star: **a helper that lets the developer understand the project at a glance, for very few tokens.**
v2 shows the right things but costs too much per run. Measured from the transcripts, counting unique API calls (my first draft counted JSONL lines and overstated everything 2.3×; reviewer C corrected it):

| Run | Model | API calls | Context at end | Cache reads | Est. cost |
|---|---|---|---|---|---|
| v1 FULL | opus | 26 | — | 2.3M | — |
| v1b FULL | opus | 20 | — | 1.0M | — |
| v2 FULL | opus | **40** | 27K → 171K | **4.2M** | **≈ $2.2** |

Where it went: ~30 of 40 calls were exploration (PLAN.md alone 11 calls ≈ $0.24); ~25K of context was the agent reading its own machinery (template ×3, sample state, embed.sh, CHANGES.md); state.json is 22.7 KB and is rewritten whole; a no-change UPDATE still spawns Sonnet (~$0.12) just to find out nothing moved. Screenshots cost ~2K tokens, not worth chasing for money, but they are 40 % of the transcript bytes.

Interrupted-run check: live files match `reviews/v2.1-backup/` byte for byte. Nothing was half-applied.

Reviewed by Codex (round 1, visible Herdr tab `codex-projmap`: CHANGES) and three Fable 5.1 reviewers (simplicity, correctness, token economics). Their points are folded in; conflicts resolved toward the simpler option when it does not make the map wrong.

## Principle
**Scripts maintain the map. The model is called only when there is something to judge, and it writes one small block.**

## Design

### 1. `project-map-facts.py` (new, read-only, stdlib)
Builds `facts.json` and prints **one verdict line** to stdout (the main session never sees the 4 KB dump; echoing it would cost more than the spawn it avoids).

Facts: repo heads; commits since last map (never dropped: all subjects trimmed to 60 chars, grouped by day, and any touching a watch path or matching `fail|revert|broken|rollback` always shown); `git status --porcelain --untracked-files=all` hash; watch files by content hash (recursing into dirs, absolute paths allowed); ledger Goal / Now / Next / Blockers lines quoted verbatim and tagged `source: ledger` (claims, never evidence); pending answers; expired deadlines (tz-aware, `ready:false` never expires); usage totals via `project-map-usage.py`; template/embed hashes; map age.

Decision lifecycle is **script-owned**: answers and expiries flip `open → answered | defaulted | overdue` in facts; hard rules and `ready:false` never default.

Verdicts:
| Verdict | Condition | Runs | Model cost |
|---|---|---|---|
| `NO_CHANGE` | heads, status hash, watch hashes, answers count, deadlines, template hash all equal | nothing (re-render only if template/embed hash moved) | 0 |
| `NEEDS_JUDGEMENT` | anything above moved | Sonnet UPDATE | ≈ $0.12 |
| `NEEDS_FULL` | no state / schema mismatch / the owner asks | Opus FULL | ≈ $1.4 (vs $2.2) |

### 2. State split: facts (script) + judgement (model)
- `facts.json`: script-owned, rebuilt every run, never written by the model.
- `judgement.json`: model-owned, **≤ 3 KB, replaced whole**. Fields only: `headline`, `parts[{id,status,line,ref}]`, `milestone{current, criteria[{text,done}]}`, `next_step{title,why,actor}`, `decisions[{id,q,options[{id,label}],recommended,default,hard_rule,deadline}]`, `eta|null`, `watch[]`.
  Dropped from the model's job: `observed_at`/`supports` on every evidence record, `if_answered`, `keeps_working_on`, `why_it_matters`, option cost objects, per-round review loops (counts only, from REVIEW-LOG), `risks` beyond 2, `history` (script builds it from previous judgement + facts, cap 10), `usage.jobs` (script, below the fold).
- `embed.sh` re-runs the facts script, merges, validates, writes `state.json` (tmp + mv, `mkdir .lock` guard), renders `index.html`, writes `brief.txt` (≤ 1 KB). On failure: old map stays, reason printed.
- Validation: unknown id, duplicate id, dangling ref, invalid JSON, `ready:false` or `hard_rule` with a default (reject), part `status:done` with only ledger evidence (reject), judgement decision status contradicting facts (reject). Stale guard: if heads or answers moved between facts and embed, reject; otherwise publish and the next facts run says `NEEDS_JUDGEMENT`.
- Two timestamps on the page and in brief.txt: `facts_at`, `judgement_at`. When judgement is older than the last change, the headline is greyed with "judgement N h old, M commits since".
- No archive, no migration script, no `new_ids`, no hash field for the model to fill, no cycle detection. Closed decisions are deleted after one run.

### 3. One command for any project: skill `/project-map [ROOT]`
The owner: "I just run the command/script/skill and it automatically grabs the info and makes the map." So the entry point is a user-invocable skill (`~/.claude/skills/project-map/SKILL.md`), not a rule the main session has to remember:
1. ROOT = argument, else `git rev-parse --show-toplevel`, else cwd.
2. Run `project-map-facts.py ROOT` → one verdict line.
3. `NO_CHANGE` → print `brief.txt`, done. `NEEDS_JUDGEMENT` → spawn UPDATE (Sonnet). `NEEDS_FULL` → spawn FULL (Opus). After a spawn: print `brief.txt` and the index.html path.
4. Any project works: no project names in scripts; non-git folders use mtimes; first run bootstraps a default watch list; ledger discovery by ROOT basename.
The CLAUDE.md § Project map shrinks to a pointer to the skill plus the ASK/ANSWERS round trip and the hard-rule caveat. "Where are we?" is answered from `brief.txt`, never state.json.

### 4. Slim agents
- `project-map.md` → ≤ 5 KB, UPDATE only. Prompt input: facts + current judgement inline. Tools: at most one targeted Read, Write `judgement.json`, Bash embed. No screenshots, no template, no memory, no `cd` (also fixes the "approximate" usage split, see 5).
- Budget stated honestly: **≤ 5 API calls, context-at-end ≤ 35K** (the spawn floor is ~27K; "10–30K total tokens" was not achievable). > 50K means it explored, and the reply says why.
- `project-map-full.md` (new): exploration caps, facts pack first, **30-call cap**, screenshot + design-review steps. Read only on FULL.

### 5. Correctness fixes on the north star
- `warn_rounds`: ignore `kind:review` loops with `failed=0` (live false alarm: 41 rounds, 0 failed, red warning).
- Open decision card above Next step; other decisions as one collapsed line (D-001 was below the fold).
- `project-map-usage.py`: subagent transcripts inherit the parent session's attribution (~10 lines). The main-session `cwd=<home folder>` undercount stays labelled; not worth chasing.

### 6. Layout v3: "graphite instrument panel" (design spec by Codex, round 2)
The owner's brief: modern, sleek, relaxing for the eyes, feels robotic/AI, "wow, that's pro". The template is fixed and script-rendered, so this costs 0 tokens per run. Full Codex spec gets saved to `reviews/v3/DESIGN-SPEC.md` at implementation start.

What holds the current page back: header is a telemetry dump (commits, waiting, 915M tokens at equal weight); the journey is drawn three times (track, criteria chips, critical-path chips) over ~320 px; hazard stripes make ordinary waits look dangerous; nested panels + pills + dashed outlines + arcs with no surface hierarchy; the decision starts at y≈675 and is cut at 900.

Visual system:
- Palette: bg `#090C12`, panel `#111620`, raised `#18202C`, border `#2B3545`; text `#EDF2F7` / `#B6C1D0` / `#8998AC` (4.5:1 minimum). Accents: cyan `#69D9EF` active, violet `#B6A3FF` current milestone, mint `#79D9AD` done, amber `#F2C879` needs-you. Failure = amber + icon + word; waits stay neutral. Colour always has a text twin.
- Type: Space Grotesk (titles, prose) + IBM Plex Mono (timestamps, ids, counts), `display=swap`. Title 28/34 −0.025em; headline 20/28; card title 18/24; body 14/21; mono labels 11/16 +0.08em. No uppercase sentences, no mono paragraphs.
- Surfaces: matte, 1 px border, 14 px radius, faint top-edge highlight, minimal shadow; active card gets one coloured edge. No blur, no grain; a faint static dot field behind the timeline only; glow only on the current node.
- Spacing: 4/8/12/16/24/32; 24 px card padding and gutters; hierarchy by space before borders.
- Motion: one 240 ms opacity reveal (≤ 4 px translate); the rail settles once over 450 ms; only the current-node halo breathes (6 s), and only for active work. `prefers-reduced-motion` removes everything. Snapshot time is always visible so motion never implies live data.

Information order at 1440×900 (content 1280 px, 80 px margins):
1. y 32–76: identity left; updated time + needs-you state right. Commits and usage move below the fold.
2. y 92–148: plain-language headline, ≤ 2 lines, small tone signal beside it.
3. y 168–272: compact 5-stop milestone rail; count + estimate under the current label; "proposed" as a quiet annotation.
4. y 296–620: **action row**: next step left, the one open decision right (≈ 40/60), with all options, cost, reversibility and default. The whole decision is above the fold.
5. y 644+: parts overview left, ≤ 3 recent changes right; dependency note once, beside the affected part.
6. Below the fold, native `<details>`: remaining criteria, risks, other decisions, trends, usage, evidence.
Mobile 390: 16 px margins; headline → current/next summary → decision → next step → parts → changes; rail goes vertical; option cost stacks under the label; 44 px targets; no horizontal scroll.

Signature elements (cheap, calm): a **signal rail** (inline SVG; mint done segments, violet current endpoint, neutral future; one reveal, no travelling particles) and a **precision beacon** (current node with concentric rings, tiny index, restrained halo; progress arc only when criteria are counted, plain ring when unknown).

Remove: waiting-card hatching, dependency arcs, duplicated critical-path chips, repeated "no estimate yet", the oversized remaining-count banner, redundant status pills, radio-looking option controls, empty trend panels, token totals from the first screen.

### Not doing (drift guard)
Cycle detection; field-type validation; archive; migration script; separate usage.json; routine screenshots. The three v2 mobile/wrap fixes are subsumed by the redesign, not done separately.

## Files
| | |
|---|---|
| Backup first | live hooks + agent → `~/.claude/agent-memory/project-map/reviews/v3-backup/`; the pilot project's `.project-map/` → `reviews/v3-backup/pilot-project/` (it is gitignored, so no git safety net) |
| New | `hooks/project-map-facts.py`, `agents/project-map-full.md` |
| Edit | `agents/project-map.md`, `hooks/project-map-embed.sh`, `hooks/project-map-template.html`, `hooks/project-map-usage.py`, `hooks/project-map-guard.sh` (allow facts script with no output-path flag; Write only `judgement.json`; deny `state.json`, `index.html`, `facts.json`, `brief.txt`), `reviews/v2/test_guard.sh` (lines 108–109 flip from allow to block), `~/.claude/CLAUDE.md` § Project map |
| Reuse | `project-map-usage.py` collector core |
| pilot project | no migration: one budgeted FULL under the new design rebuilds it, which is also the FULL measurement |

## Build order
1. Backup.
2. Facts script + embed split + validator + brief.txt.
3. Template rewrite per §6 (renders the new facts + judgement split; warn_rounds fix; two timestamps). Iterate on 1440 + 390 screenshots with the pilot project's data until it matches the spec; Codex design review before step 4.
4. Agent prompt split (UPDATE / FULL), usage.py subagent fix.
5. Guard + tests + CLAUDE.md gate.
6. Codex reviews the full diff until AGREE.

Steps 2, 4, 5 go to Sonnet implementation agents; step 3 (the template) too, but with the design spec file and the screenshot loop, and I check every screenshot myself. I review each step in the main session.

## Verification
1. Guard suite: 95 existing + new cases (facts script allowed, judgement.json allowed, state.json/index.html denied).
2. Embed rejections, each must keep the old map: unknown id; `ready:false` past deadline; invalid judgement JSON; `done` on ledger-only evidence.
3. Gate: facts script twice on the pilot project **with nothing touched between runs** → `NO_CHANGE` both times, nothing spawned. Then touch a watch file → `NEEDS_JUDGEMENT`.
4. One FULL on the pilot project (Opus): ≤ 30 calls, measured by unique `message.id` and context-at-end. Same facts as the v2 map, D-001 shown above the fold with no auto-default.
5. One real UPDATE (Sonnet) after a real change: ≤ 5 calls, context-at-end ≤ 35K.
6. Layout: 1440×900 and 390 screenshots. Checks: headline, rail, next step and the full open decision above the fold at 1440; no horizontal scroll at 390; contrast ≥ 4.5:1 on essential text; `prefers-reduced-motion` renders static; no element from the "Remove" list left. Show the owner both shots; iterate until the owner says it's pro.
