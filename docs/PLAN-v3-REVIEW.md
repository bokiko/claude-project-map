# PLAN-v3 review: goals vs. what shipped (2026-10-08)

Scope: `docs/PLAN-v3.md` checked against the repo at `4540de1` (main). Every
verdict below comes from a command run on this checkout or a file in it; items
nobody can verify from the repo are marked `unverified`.

## Verdict

**Plan delivered.** All six build-order steps are in the tree, both suites are
green, every measured budget is met except one soft target (UPDATE context-at-end
37K vs. the 35K goal, 6 % over, documented in HANDOFF-v3). Layout §6 was
superseded by an owner decision (v4 "Blend"), not left undone.

## Goals vs. done

| # | Plan goal (PLAN-v3) | Status | Evidence |
|---|---|---|---|
| 1 | `project-map-facts.py`: read-only, stdlib, one verdict line, facts ≤ 8 KB | done | `scripts/project-map-facts.py`; `.project-map/facts.json` = 2,774 B; run twice on this repo → identical `NEEDS_JUDGEMENT 2 new commits; watch changed: …` both times (idempotent) |
| 2 | State split: facts (script) + `judgement.json` (model, ≤ 3 KB, replaced whole) | done | `.project-map/judgement.json` = 2,323 B; `state.json` schema `project-map-3` |
| 2 | Embed: re-run facts, validate, atomic write under `.lock`, `brief.txt` ≤ 1 KB | done | `scripts/project-map-embed.py` line 554 writes `state.json`, `index.html`, `mobile.html`, `brief.txt`, `facts.json`; `brief.txt` = 300 B |
| 2 | Validation rules (unknown/dup id, dangling ref, hard-rule/`ready:false` default, ledger-only `done`, stale guard) | done | `tests/test_embed.sh` → **147/147 PASS** |
| 2 | Two timestamps (`facts_at`, `judgement_at`) + greyed stale headline | done | `state.json` carries both (17:01:51 / 17:01:50); HANDOFF §Hot-repo describes the `stale` flag path |
| 3 | One command for any project: `/project-map [ROOT]` skill | done | `skills/project-map/SKILL.md` (2,454 B); any-project bootstrap proven on an e2e sample repo scratch clone and a plain folder (HANDOFF 14:42 line) — `unverified` here, not re-run |
| 4 | UPDATE agent ≤ 5 KB, ≤ 5 API calls, ctx-at-end ≤ 35K | done / soft miss | `agents/project-map.md` = 4,950 B; measured 4 Sonnet calls, **37K ctx** (HANDOFF table). 2K over the 35K line; the plan itself notes the ~27K spawn floor |
| 4 | FULL instructions, 30-call cap | done, better than target | `skills/project-map/full-run.md`; measured 16 Opus calls / 59K ctx / ≈ $0.46 vs. plan ≈ $1.4 |
| 4 | `usage.py` subagent attribution fix | done per CHANGELOG | `scripts/project-map-usage.py`; main-session `~` undercount still labelled (known limit, by design) |
| 5 | `warn_rounds`: review loops with `failed=0` never warn | done | `scripts/project-map-template.html` line 280–282 |
| 5 | Open decision above Next step / above the fold | done (v4 form) | v4 Blend: focus card + decision rail; `verify-blend.mjs` measures fold positions at 1440×900 |
| 5 | Guard: allow facts script, Write only `judgement.json`, deny `state.json`/`index.html`/`facts.json`/`brief.txt` | done | `tests/test_guard.sh` → **311/311 PASS** (plan asked for 95 + new; 301 at handoff, 311 now) |
| 6 | Layout v3 "graphite instrument panel" per Codex spec | **superseded** | `docs/DESIGN-SPEC.md` kept; owner chose v4 "Blend" from three Codex drafts (`docs/design-drafts/`, CHANGELOG 3.1.0). `prefers-reduced-motion` honoured (template line 172); no network requests; 390 px no-overflow checked with all disclosures open (DESIGNS.md) |
| V1 | Guard suite green | done | 311/311 |
| V2 | Embed rejections keep the old map | done | covered by 147-case embed suite |
| V3 | Facts twice with nothing touched → `NO_CHANGE` | done at handoff; **not reproducible on this repo today** | On this checkout both runs say `NEEDS_JUDGEMENT` because two commits (`a122679`, `4540de1`) landed after the last judgement (17:01). That is the correct verdict, not a defect — but it means the repo's own map is stale (see Open) |
| V4 | One FULL ≤ 30 calls | done | 16 calls |
| V5 | One real UPDATE ≤ 5 calls, ≤ 35K | done / 37K | see row 4 |
| V6 | 1440 + 390 screenshots, contrast, reduced-motion, "Remove" list cleared, owner says "pro" | done (v4) | owner-approved per CHANGELOG 3.1.0; `docs/design-drafts/*.png` + `verify-blend.mjs` |
| — | Codex reviews until AGREE | done | round 9 = AGREE (HANDOFF 14:42) |
| — | "Not doing" list (cycle detection, type validation, archive, migration, usage.json, routine screenshots) | held | none of these exist in `scripts/`; HANDOFF §Known limits matches |

Beyond the plan (shipped anyway): packaged as a Claude Code plugin
(`project-map@bokiko-tools`, 3.0.0), exec-form hook (3.0.1), guard trace env
(3.1.0), README rewritten for non-coders + `docs/FAQ.md`.

## Open

1. **This repo's own map is stale.** `.project-map/` is committed but its
   judgement predates the last two commits; `facts.py` correctly says
   `NEEDS_JUDGEMENT`. Run `/project-map` from a Claude Code session in this
   folder to refresh, or stop committing `.project-map/` (it is gitignored in
   consumer repos per the plan).
2. **HANDOFF-v3 "Open / next"** still lists "hand the pilot project's map back to its
   own session" — not confirmed done anywhere in the repo. `unverified`.
3. **UPDATE ctx 37K vs. 35K target.** Either accept and change the number in
   PLAN/HANDOFF/agent prompt to 40K, or trim the inline facts+judgement payload.
   Recommendation: accept; the plan already admits the 27K floor and the cost
   figure (≈ $0.10) is the goal that matters.
4. `scripts/__pycache__/` is in the tree listing — confirm it is gitignored
   (`.gitignore` exists; not checked line by line here).

## How this was checked

```
bash tests/test_embed.sh        # 147/147 PASS
bash tests/test_guard.sh        # total 311 pass 311 fail 0
wc -c agents/project-map.md .project-map/{judgement.json,brief.txt,facts.json}
python3 scripts/project-map-facts.py "$PWD"   # ×2, identical output
```
