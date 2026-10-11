# project-map FULL run

Read only on `RUN: FULL` (the caller passes `model: opus`). Same trust rules, guard limits and judgement schema as the agent file. The prompt's lines give `ROOT`, `INV`, `RUN`; `STAGE` = `ROOT/.project-map/INV`.

## Gather (hard caps)
- Read `STAGE/pack.json`, `STAGE/judgement.in.json` and `STAGE/plan.json` first. On a first map or a migration, `judgement.in.json` is empty or the legacy judgement and `plan.json` is empty or derived from the legacy milestones.
- Then at most 20 more reads, none over 300 lines (use `head -n 300 <abs path>`). Docs in this order: README, PLAN/ROADMAP/TODO, the continuity ledger named in the pack, CHANGELOG.
- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/pm-git.sh ROOT log -n 60`, `bash ${CLAUDE_PLUGIN_ROOT}/scripts/pm-git.sh ROOT tag`, `gh issue list -L 30`. For counts use `find ROOT -maxdepth 2 -type d | wc -l` and `ls -la ROOT` (the path always comes last or, for `find`, first; `ls -R` is denied). Repos over 5k files: summarise top-level dirs.
- Monorepo: sub-packages are parts, not separate maps. No git: judge from file times and say so in the headline. Nested repos go in `repos[]`. Nested repositories in the pack's `repos[]` already have their commits summarised in the pack; run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/pm-git.sh <ROOT>/<nested path> <sub>` only for a path that appears in `repos[]`, never for any other subfolder.
- Total cap: 30 tool calls. Never read reference images or your memory.
- Decisions you raise may carry `resolves_when` (1-3 predicates, all must hold; fixed by the script once raised): `{kind:"tag_at_head",repo,name|null}`, `{kind:"branch_in_sync",repo}`, `{kind:"commit",repo,sha}`, `{kind:"file",path,exists}` (`repo` is a `repos[]` path, `"."` for the root repository). Close an open decision with `overtaken{why<=120}` only when the pack shows its `resolved:true`; `ref` is optional (one of the predicates' evidence strings). A decision without `resolves_when` is closed only by the owner's answer. Never drop an open decision silently; never close one because you think the owner would agree.
- Rebuilding or migrating: keep `project.ledger`, part ids, phase and criterion ids, and every frozen decision unchanged; re-verify each status against evidence; add or retire parts only with a reason in the reply.

## Write
1. `STAGE/plan.out.json` (`schema:"project-map-plan-1"`, `generation` copied from `pack.json`): 4-6 phases from README and commits, ids `P1..P6`, criteria `P2.c3`, at most 8 per phase, labels <= 60, criterion text <= 80. A criterion is `done:true` only with a resolving `ref`. Set `origin:"proposed"`; keep `"owner"` if `plan.json` already says so and the owner's phases still hold. Rebuilding: keep the existing ids.
2. `STAGE/judgement.out.json` (whole file, target 3.5 KB, hard 6 KB): `run{type:"FULL",model:"opus"}`, `since` exactly as in the agent file (required only when `pack.since` is not null, i.e. a rebuild of an existing map; a first map or migration has none and must omit it), `intent` exactly as in the agent file (always required, a first map included), headline `tone` is only `ok|watch|blocked` (never `stale`, which is script-owned); every `risks[]` entry needs `id` (`R-1`..), `text` and `severity` (`low|med|high`), every `loops[]` entry `id` (`L-01`..), `kind`, `rounds`, `failed`, `note`; `current_phase` a phase id from `plan.out.json`, `watch` = files whose change should trigger a re-judgement. If the ledger lives in `~/thoughts/ledgers/` under a name that is not the ROOT folder name, set `project.ledger` to that name.
3. `bash ${CLAUDE_PLUGIN_ROOT}/scripts/project-map-embed.sh ROOT INV`; fix every `PM_EMBED_ERROR` by Edit (max 2 retries). First map only: if `.gitignore` lacks `.project-map/`, append that single line.

## Check the page (optional: skip and say so when Chrome is missing)
Only after `PM_EMBED_OK`; STAGE stays readable afterwards. Exactly these two commands, then Read both PNGs:
`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=STAGE/shot-desktop.png file://ROOT/.project-map/index.html`
`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=390,844 --screenshot=STAGE/shot-mobile.png file://ROOT/.project-map/index.html`
A published generation is final: if the page looks wrong, do not re-embed (it returns `SUPERSEDED`). Report the problem as `TEMPLATE_FEEDBACK:` lines and as `template_feedback` text for the next run.

## Reply
Same as UPDATE: `DONE gen <seq>-<id>`, `DONE (stale)`, `SUPERSEDED`, `PARTIAL <text>`; then `ASK:` lines and at most 5 `TEMPLATE_FEEDBACK: <one line>` lines for visual problems you cannot fix from text. If turns run low, the out files are already written: reply `PARTIAL` and say what is missing. Do not print the brief.
