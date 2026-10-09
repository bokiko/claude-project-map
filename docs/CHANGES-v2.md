# project-map v1 -> v2: what changed and why

Nothing in this folder is installed. Files here and where they go:

| File in reviews/v2/ | Install to |
|---|---|
| project-map.md | ~/.claude/agents/project-map.md |
| project-map-guard.sh | ~/.claude/agents/hooks/project-map-guard.sh (chmod +x) |
| project-map-embed.sh | ~/.claude/agents/hooks/project-map-embed.sh |
| project-map-template.html | ~/.claude/agents/hooks/project-map-template.html |
| project-map-usage.py | ~/.claude/agents/hooks/project-map-usage.py |
| CLAUDE-section.md | replaces "# Project map" in ~/.claude/CLAUDE.md |
| test_guard.sh | keep next to the guard, run after any guard edit |
| sample-state.json, shot-1440.png, shot-1440-full.png, shot-390.png | test fixture and screenshots (not installed). history[] before run 7 in the fixture is illustrative; the usage block is real collector output. The fixture was later replaced by `tests/demo-judgement.json` and `docs/demo-state.json`. |

Also at install: update the agent memory note feedback_bash_guard.md (new rules: no `>` or `2>&1`, no chaining, `git -C` only inside the project, screenshot names shot.png / shot-m.png, mobile check uses mobile.html) and MEMORY.md (screenshot size, template is read-only, state lives in state.json). Migrate the pilot project: run one FULL on opus (v1 state is `project-map-1`, so the agent rebuilds it; v1 labels/decisions map across as in the sample fixture).

## Architecture change (the big cost win)
The agent no longer authors HTML. It writes only `state.json`; `project-map-embed.sh` validates it and renders `index.html` from a fixed template (state inlined, page renders itself, still one file you can double-click). This removes the 17 KB markup rewrite on every UPDATE, makes the design identical run to run, and gives a deterministic validator (R3's invariants, enforced in code instead of hoped for in a prompt). The template and scripts live in the hooks dir, outside the agent's write reach (the v2 guard denies them), so a prompt-injected agent cannot plant script in the page. All repo text is inserted with textContent.

## Decisions on conflicts
- **Preloaded skills (R3: drop):** dropped. UPDATE never needs them. FULL invokes `dataviz` and `frontend-design` through the Skill tool once, after the screenshots, as a design review; because the agent cannot edit the template, findings come back as `TEMPLATE_FEEDBACK:` lines for the main session. Skipped when the screenshots show no problem.
- **NO_CHANGE fast path (R3):** adopted. HEAD per repo + watch-file mtimes + answers + deadlines, about 2-3k tokens, writes nothing.
- **template.html + embedded state (R3):** adopted, extended to a build script (above). Screenshot reads in UPDATE only when structure changed.
- **Stuck colour (R1/R3 amber "Waiting" vs R2 amber-only-for-owner):** R2 wins, since amber must mean "needs you". Dependency waits are lavender hatched with a lock and a dashed connector to the blocker; only `decision`/`failure` are red and counted in the header (R1's "1 blocker, not 2 stuck" intent, R3's enum).
- **Done parts (R2 demote vs reference shows full cards):** done parts become a quiet chip strip; active, waiting and idle parts keep full cards like the reference. Removes the empty grid cell and puts weight on live work (R2, R4 #8).
- **Below the fold (R1 collapsed vs R2 always-open band):** a slim always-open band (Trend, Risks, More decisions, Tokens and models) starting below the first screen, plus exactly 3 `<details>` (what is left, usage by job, history and evidence). Kills the empty area and serves "inform me about anything" while the first screen stays calm.
- **Chips (R1 remove vs reference keeps them):** kept (reference), but they are now the real remaining criteria colored by their part's status, first one underlined; the blocker chain is a separate single line that appears only when something is waiting.
- **Confidence (R2 3-dot, R3 enum, R4 labels):** one `confidence` enum per item (verified / reported / inferred / unknown) shown as a tooltip label and an "Unverified" pill; 3-dot meter only on ETA. Evidence links (the arrow glyph) and "Because:" on statuses and next step (R1 #6, R3 #2). Missing files render struck through ("unsourced").
- **Decision readiness (R4 #2):** added `ready`/`ready_when`. A premature decision shows as muted "Coming up: awaiting the diagnosis report" and does not count in "You: N calls" (R1's decision card and R4's refusal to ask early both hold). `urgency` drives the header count.
- **Progress honesty (R1 #5, R4 #6):** bars/rings only from counted items, else none.
- **Mobile (R2):** vertical timeline under 700 px, decision first, connectors replaced by the "Waits on ..." line. Verification at 390 px goes through `mobile.html` (a 390 px iframe) because headless Chrome cannot open a window narrower than about 500 px; this was found by testing, a plain 390 window silently renders at 500.

## Adopted
R1: blocker chain strip; decision brief (options, cost+basis, recommended star, default+deadline, "keeps working on", what it blocks); ETA range + confidence with basis; honest bar; loop warning ("worth a pause to rethink?"); one sparkline on the first screen; actor tags and "You: N calls"; real diff with a morning-headline sentence; evidence links; staleness shown live in the page ("3 h ago", amber after 24 h); `as of <sha>` on hover; proposed-milestones notice; cost only inside options.
R2: full token set (surfaces, ink, five status colors, type scale, radius, spacing), icon+word statuses, hatch/dashed textures for color-blind safety, progress ring on the current milestone, dependency connectors with hover/focus highlight, bullet bar for value-vs-limit in risks, trend rows, tooltips on hover and keyboard focus, mobile layout.
R3: schema project-map-2 with ids, closed enums, evidence, history cap 30; ASK/ANSWERS/ACTIONS_FOR_MAIN round-trip with answers.jsonl fallback; hard-rule categories never auto-defaulted; prompt-injection and secret rules; ROOT contract, caps, no-git and nested-repo handling; PARTIAL on low turns, maxTurns 50; single screenshot name and size; structured reply; guard hardening plus a guard log; answer-from-state.json rule.
R4: lead with the real condition (the `headline` line); "Can proceed now" (`critical_path.meanwhile`); owner/actor per step; Verified / agent-reported / unverified labels; results-over-commit-count diff; exceptions get the emphasis, settled items go to History.

## Rejected or deferred
- R2 countdown ring on the decision card: replaced by plain text "No reply by Oct 9 12:00 -> Keep 1e-2" plus the live "in 2 d" label; a ring adds ink without information.
- R2 per-card sparklines and a per-card trend glyph: moved to the Trend band (calm first screen). R2's 3-dot confidence on every card: ETA only.
- R1 "effort so far" section and R1 review-round table: the round strip is in History; effort is not shown unless the project logs it (usage covers tokens).
- R3 `labels` map and separate schema.md: dropped; the schema is in the prompt (the agent loads it anyway) and the validator enforces it.
- R3's `date -s` style tests were kept as guard tests, but `2>&1`/`2>/dev/null` remain blocked (R3 itself recommended dropping them).
- Real-time "map is N commits behind": impossible in a static page; the page shows time since update, hover shows the sha, and the agent's NO_CHANGE check is the fix.

## Guard v2 (every R3 bypass closed; tests: 95/95 under /bin/bash 3.2 and bash 5)
Chaining `; && || | backticks $() newline`, redirection, `$`, parens, braces and backslashes are rejected; quotes are stripped before checking (defeats `"--out""put=x"`); pipes only into head/tail/wc/uniq/grep/cut/tr/sort (sort without `-o`). `find` denies -delete/-exec/-execdir/-ok/-fprint/-fls. `git`: no global options (`-c`, `--git-dir`...), allowlisted subcommands, `branch` and `tag` listing only (`git branch x` is blocked), `--output`, `--ext-diff`, `--textconv`, `-O` denied, `-C <dir>` only inside cwd or ~/projects. `date` cannot set the clock; `gh` read-only, no `--web`. Chrome: exact flag allowlist, output must be `<project>/.project-map/shot.png` (index.html) or `shot-m.png` (mobile.html), `.project-map` must not be a symlink. Write/Edit: paths resolved to real paths; `..`, `.`, relative paths, newlines, symlink targets and dangling symlinks are rejected; only `.project-map/state.json|index.html`, memory notes `MEMORY.md|feedback_*|reference_*|project_*.md`, and `<project>/.gitignore` append-only of exactly `.project-map/` (only when `.project-map/` already exists in that root; not `~/.gitignore`, not subdirectory .gitignore files, not overwrite, no `replace_all`). The guard, hooks dir, agent file and template are not writable by the agent. Secret-looking paths (.env, credentials, secrets, keys, .ssh, .aws, ...) are blocked for Bash, Read, Grep and Glob arguments. Exactly three trusted commands: Chrome shot, `bash .../project-map-embed.sh <root>`, `python3 .../project-map-usage.py <root> [--since ISO] [--max-jobs N]`. Fails closed (no jq, bad JSON). Each deny is logged to guard.log. Known limits: a repo's own git config can still run code on `git status`/`diff` (fsmonitor); project paths with spaces are unsupported; Grep without a path cannot be filtered by content.

## Token and model usage accounting (owner addition)
`project-map-usage.py` (stdlib, read-only, stdout only, about 1 s) reads Claude Code transcripts (`~/.claude/projects/**`, including `subagents/agent-*.jsonl` and their `.meta.json` for the job label) and Codex rollouts (`~/.codex/sessions/**`). Claude: per assistant message `message.model` + `message.usage`, de-duplicated by message id (streamed content blocks repeat the same usage), attributed by the `cwd` each record carries (a session may start in the home folder and move into the project, so cwd works per record); fallback to whole-file attribution when a transcript mentions the root path >= 25 times, flagged `approximate`. Codex: cumulative `token_count` deltas split per turn (each review round is one turn) and per model from `turn_context`; sessions under ~/.buzz are never read. Missing source dirs report `unavailable`, never 0. Output: `per_job[]`, `per_model{}`, `totals{}` and a ready-to-store `snapshot_for_state` (about 3 KB) for `metrics.usage`, plus `{claude,codex,all}` in each `history[]` entry for the trend. The map shows a small "907M tokens" in the header (tooltip: Claude / Codex / jobs), a Claude-vs-Codex bar and one horizontal bar per model in "Tokens and models", and a per-job table (job, model, in, out, cache, date) in "Usage by job".

These numbers were measured on the pilot project and are superseded by the 3.2 cost table in the README.
Caveat: cache-read tokens dominate (Claude: about 808M of 867M), so the headline is "tokens processed", not billing; the in/out/cache split is in the per-job table and the collector JSON.
